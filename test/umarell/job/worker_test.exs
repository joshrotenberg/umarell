defmodule Umarell.Job.WorkerTest do
  use ExUnit.Case, async: true

  alias Umarell.Job.Worker
  alias Umarell.WorkEvent

  @test_event %WorkEvent{
    repo: "owner/repo",
    number: 42,
    title: "feat: test issue",
    body: "This is the issue body."
  }

  # Builds a cmd_fn for GitHub calls. Sends {:gh_call, args} to notify_pid.
  defp gh_cmd_fn(notify_pid, output \\ "", exit_code \\ 0) do
    fn "gh", args, _opts ->
      send(notify_pid, {:gh_call, args})
      {output, exit_code}
    end
  end

  # Builds a multi-response cmd_fn for GitHub calls.
  defp multi_gh_cmd_fn(notify_pid, responses) do
    agent = start_supervised!({Agent, fn -> responses end})

    fn "gh", args, _opts ->
      response = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      send(notify_pid, {:gh_call, args})
      response
    end
  end

  # A workspace_fn that always succeeds with a fake checkout path.
  defp ok_workspace_fn(notify_pid, path \\ "/tmp/fake-checkout") do
    fn _repo, _number, _opts ->
      send(notify_pid, :workspace_called)
      {:ok, path}
    end
  end

  # A workspace_fn that fails.
  defp fail_workspace_fn do
    fn _repo, _number, _opts ->
      {:error, {:git, "workspace prep failed"}}
    end
  end

  # A claude_fn that always returns a success result.
  defp ok_claude_fn(notify_pid) do
    fn _prompt, _path, _opts ->
      send(notify_pid, :claude_called)
      {:ok, %{status: "success", summary: "Done", cost_usd: 0.05, turns: 10}}
    end
  end

  # A claude_fn that always fails.
  defp fail_claude_fn do
    fn _prompt, _path, _opts ->
      {:error, {1, "claude invocation failed"}}
    end
  end

  # A test_fn that always returns success.
  defp ok_test_fn(notify_pid) do
    fn _path, _opts ->
      send(notify_pid, :test_gate_called)
      {:ok, "All tests passed."}
    end
  end

  # A test_fn that always returns failure.
  defp fail_test_fn(notify_pid, output) do
    fn _path, _opts ->
      send(notify_pid, :test_gate_called)
      {:error, {1, output}}
    end
  end

  # A git_fn that captures calls and returns success.
  defp ok_git_fn(notify_pid) do
    fn command, args, _opts ->
      send(notify_pid, {:git_call, command, args})
      {"", 0}
    end
  end

  describe "success path" do
    setup do
      notify_pid = self()

      # Success path: workspace ok, claude ok, test ok
      # GitHub calls: create_draft_pr returns PR URL, mark_ready ok, enable_auto_merge ok, comment ok
      gh_fn =
        multi_gh_cmd_fn(notify_pid, [
          # create_draft_pr
          {"https://github.com/owner/repo/pull/99\n", 0},
          # mark_ready
          {"", 0},
          # enable_auto_merge
          {"", 0},
          # comment (result envelope)
          {"", 0}
        ])

      opts = [
        workspace_fn: ok_workspace_fn(notify_pid),
        claude_fn: ok_claude_fn(notify_pid),
        test_fn: ok_test_fn(notify_pid),
        git_fn: ok_git_fn(notify_pid),
        github_opts: [cmd_fn: gh_fn]
      ]

      %{opts: opts}
    end

    test "calls workspace, claude, test gate, and GitHub in order", %{opts: opts} do
      assert :ok = Worker.run(@test_event, opts)

      assert_received :workspace_called
      assert_received :claude_called
      assert_received :test_gate_called

      # create_draft_pr
      assert_received {:gh_call, pr_args}
      assert "create" in pr_args
      assert "--draft" in pr_args

      # mark_ready
      assert_received {:gh_call, ready_args}
      assert "ready" in ready_args

      # enable_auto_merge
      assert_received {:gh_call, merge_args}
      assert "--auto" in merge_args

      # comment
      assert_received {:gh_call, comment_args}
      assert "comment" in comment_args
    end

    test "PR body includes Closes #N", %{opts: opts} do
      Worker.run(@test_event, opts)

      # First gh_call is create_draft_pr; find --body arg
      assert_received {:gh_call, pr_args}

      body_index = Enum.find_index(pr_args, &(&1 == "--body"))
      assert body_index, "expected --body flag in pr args"
      pr_body = Enum.at(pr_args, body_index + 1)
      assert pr_body =~ "Closes #42"
    end

    test "does NOT clear agent:working label", %{opts: opts} do
      Worker.run(@test_event, opts)

      # Collect all gh calls and verify none are label removals of agent:working
      # (swap_label is not called on success path)
      all_calls = collect_gh_calls()

      refute Enum.any?(all_calls, fn args ->
               "--remove-label" in args and "agent:working" in args
             end)
    end

    test "comments result envelope with status and summary", %{opts: opts} do
      Worker.run(@test_event, opts)

      # Skip pr, ready, merge calls; get comment call
      assert_received {:gh_call, _pr_args}
      assert_received {:gh_call, _ready_args}
      assert_received {:gh_call, _merge_args}
      assert_received {:gh_call, comment_args}

      body_index = Enum.find_index(comment_args, &(&1 == "--body"))
      comment_body = Enum.at(comment_args, body_index + 1)

      assert comment_body =~ "success"
      assert comment_body =~ "Done"
    end

    test "enable_auto_merge uses squash flag", %{opts: opts} do
      Worker.run(@test_event, opts)

      assert_received {:gh_call, _pr_args}
      assert_received {:gh_call, _ready_args}
      assert_received {:gh_call, merge_args}

      assert "--squash" in merge_args
      assert "--auto" in merge_args
    end

    test "git commit and push are called", %{opts: opts} do
      Worker.run(@test_event, opts)

      git_calls = collect_git_calls()

      assert "add" in git_calls
      assert "commit" in git_calls
      assert "push" in git_calls
    end
  end

  describe "park path (local gate failure)" do
    setup do
      notify_pid = self()

      # GitHub calls: swap_label (remove + add = 2 calls), comment
      gh_fn =
        multi_gh_cmd_fn(notify_pid, [
          # swap_label: remove agent:working
          {"", 0},
          # swap_label: add agent:blocked
          {"", 0},
          # comment failure
          {"", 0}
        ])

      opts = [
        workspace_fn: ok_workspace_fn(notify_pid),
        claude_fn: ok_claude_fn(notify_pid),
        test_fn: fail_test_fn(notify_pid, "1 test, 1 failure"),
        git_fn: ok_git_fn(notify_pid),
        github_opts: [cmd_fn: gh_fn]
      ]

      %{opts: opts}
    end

    test "swaps agent:working to agent:blocked on gate failure", %{opts: opts} do
      assert :ok = Worker.run(@test_event, opts)

      # swap_label: remove
      assert_received {:gh_call, remove_args}
      assert "--remove-label" in remove_args
      assert "agent:working" in remove_args

      # swap_label: add
      assert_received {:gh_call, add_args}
      assert "--add-label" in add_args
      assert "agent:blocked" in add_args
    end

    test "comments failure output on gate failure", %{opts: opts} do
      assert :ok = Worker.run(@test_event, opts)

      # Skip the two swap_label calls
      assert_received {:gh_call, _remove}
      assert_received {:gh_call, _add}

      assert_received {:gh_call, comment_args}
      assert "comment" in comment_args

      body_index = Enum.find_index(comment_args, &(&1 == "--body"))
      comment_body = Enum.at(comment_args, body_index + 1)

      assert comment_body =~ "1 test, 1 failure"
    end

    test "does NOT open a PR on gate failure", %{opts: opts} do
      assert :ok = Worker.run(@test_event, opts)

      all_calls = collect_gh_calls()

      refute Enum.any?(all_calls, fn args -> "create" in args and "--draft" in args end)
    end

    test "test gate is called even on gate failure", %{opts: opts} do
      Worker.run(@test_event, opts)
      assert_received :test_gate_called
    end

    test "workspace and claude are still called before gate", %{opts: opts} do
      Worker.run(@test_event, opts)
      assert_received :workspace_called
      assert_received :claude_called
    end
  end

  describe "workspace failure" do
    test "returns error without calling claude or GitHub" do
      notify_pid = self()
      gh_fn = gh_cmd_fn(notify_pid)

      opts = [
        workspace_fn: fail_workspace_fn(),
        claude_fn: ok_claude_fn(notify_pid),
        test_fn: ok_test_fn(notify_pid),
        git_fn: ok_git_fn(notify_pid),
        github_opts: [cmd_fn: gh_fn]
      ]

      result = Worker.run(@test_event, opts)
      assert match?({:error, _}, result)

      refute_received :claude_called
      refute_received :test_gate_called
      refute_received {:gh_call, _}
    end
  end

  describe "claude failure" do
    test "returns error without calling test gate or GitHub" do
      notify_pid = self()
      gh_fn = gh_cmd_fn(notify_pid)

      opts = [
        workspace_fn: ok_workspace_fn(notify_pid),
        claude_fn: fail_claude_fn(),
        test_fn: ok_test_fn(notify_pid),
        git_fn: ok_git_fn(notify_pid),
        github_opts: [cmd_fn: gh_fn]
      ]

      result = Worker.run(@test_event, opts)
      assert match?({:error, _}, result)

      refute_received :test_gate_called
      refute_received {:gh_call, _}
    end
  end

  describe "start_link/1" do
    test "accepts event and starts successfully" do
      notify_pid = self()

      gh_fn =
        multi_gh_cmd_fn(notify_pid, [
          {"https://github.com/owner/repo/pull/1\n", 0},
          {"", 0},
          {"", 0},
          {"", 0}
        ])

      opts = [
        event: @test_event,
        workspace_fn: ok_workspace_fn(notify_pid),
        claude_fn: ok_claude_fn(notify_pid),
        test_fn: ok_test_fn(notify_pid),
        git_fn: ok_git_fn(notify_pid),
        github_opts: [cmd_fn: gh_fn]
      ]

      assert {:ok, pid} = Worker.start_link(opts)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end
  end

  describe "auto_merge option" do
    test "auto_merge true: enable_auto_merge is called" do
      notify_pid = self()

      gh_fn =
        multi_gh_cmd_fn(notify_pid, [
          # create_draft_pr
          {"https://github.com/owner/repo/pull/99\n", 0},
          # mark_ready
          {"", 0},
          # enable_auto_merge
          {"", 0},
          # comment
          {"", 0}
        ])

      opts = [
        workspace_fn: ok_workspace_fn(notify_pid),
        claude_fn: ok_claude_fn(notify_pid),
        test_fn: ok_test_fn(notify_pid),
        git_fn: ok_git_fn(notify_pid),
        github_opts: [cmd_fn: gh_fn],
        auto_merge: true
      ]

      assert :ok = Worker.run(@test_event, opts)

      # create_draft_pr
      assert_received {:gh_call, _pr_args}
      # mark_ready
      assert_received {:gh_call, ready_args}
      assert "ready" in ready_args
      # enable_auto_merge
      assert_received {:gh_call, merge_args}
      assert "--auto" in merge_args
      # comment
      assert_received {:gh_call, _comment_args}
    end

    test "auto_merge false: enable_auto_merge NOT called, PR marked ready, envelope notes human merge" do
      notify_pid = self()

      gh_fn =
        multi_gh_cmd_fn(notify_pid, [
          # create_draft_pr
          {"https://github.com/owner/repo/pull/99\n", 0},
          # mark_ready
          {"", 0},
          # comment (no enable_auto_merge call)
          {"", 0}
        ])

      opts = [
        workspace_fn: ok_workspace_fn(notify_pid),
        claude_fn: ok_claude_fn(notify_pid),
        test_fn: ok_test_fn(notify_pid),
        git_fn: ok_git_fn(notify_pid),
        github_opts: [cmd_fn: gh_fn],
        auto_merge: false
      ]

      assert :ok = Worker.run(@test_event, opts)

      # create_draft_pr
      assert_received {:gh_call, _pr_args}
      # mark_ready
      assert_received {:gh_call, ready_args}
      assert "ready" in ready_args
      # comment
      assert_received {:gh_call, comment_args}
      body_index = Enum.find_index(comment_args, &(&1 == "--body"))
      comment_body = Enum.at(comment_args, body_index + 1)
      assert comment_body =~ "human to merge"

      # No further gh calls (enable_auto_merge was not called)
      remaining = collect_gh_calls()
      refute Enum.any?(remaining, fn args -> "--auto" in args end)
    end
  end

  # Collects all {:gh_call, args} messages from the mailbox (non-blocking).
  defp collect_gh_calls do
    Stream.repeatedly(fn ->
      receive do
        {:gh_call, args} -> args
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
  end

  # Collects all {:git_call, cmd, _args} messages, returns command names.
  defp collect_git_calls do
    Stream.repeatedly(fn ->
      receive do
        {:git_call, cmd, _args} -> cmd
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
  end
end
