defmodule Umarell.Job.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Umarell.Job.Workspace

  # Builds a git_fn that captures calls and returns canned results.
  # Each element in `responses` is {output, exit_code}.
  defp multi_git_fn(responses) do
    agent = start_supervised!({Agent, fn -> responses end})

    fn command, args, _opts ->
      response = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      send(self(), {:git_call, command, args})
      response
    end
  end

  defp success_git_fn, do: multi_git_fn([{"", 0}, {"", 0}])
  defp fail_on_first_git_fn, do: multi_git_fn([{"clone failed", 1}])
  defp fail_on_second_git_fn, do: multi_git_fn([{"", 0}, {"branch failed", 128}])

  describe "prepare/3 when checkout does not exist" do
    test "calls clone then checkout -b", %{tmp_dir: tmp} do
      git_fn = success_git_fn()

      assert {:ok, path} =
               Workspace.prepare("owner/repo", 42,
                 checkout_root: tmp,
                 git_fn: git_fn
               )

      assert path == Path.join([tmp, "owner", "repo"])

      assert_received {:git_call, "clone", clone_args}
      assert_received {:git_call, "checkout", branch_args}

      assert Enum.any?(clone_args, &String.ends_with?(&1, "owner/repo.git"))
      assert "-b" in branch_args
      assert "umarell/issue-42" in branch_args
    end

    test "returns error when clone fails", %{tmp_dir: tmp} do
      git_fn = fail_on_first_git_fn()

      assert {:error, {1, "clone failed"}} =
               Workspace.prepare("owner/repo", 99,
                 checkout_root: tmp,
                 git_fn: git_fn
               )
    end

    test "returns error when branch creation fails after clone", %{tmp_dir: tmp} do
      git_fn = fail_on_second_git_fn()

      assert {:error, {128, "branch failed"}} =
               Workspace.prepare("owner/repo", 7,
                 checkout_root: tmp,
                 git_fn: git_fn
               )
    end
  end

  describe "prepare/3 when checkout already exists" do
    setup %{tmp_dir: tmp} do
      # Pre-create the checkout directory to simulate an existing clone.
      checkout_path = Path.join([tmp, "owner", "repo"])
      File.mkdir_p!(checkout_path)
      %{checkout_path: checkout_path}
    end

    test "calls fetch then checkout -b when dir exists", %{tmp_dir: tmp} do
      git_fn = success_git_fn()

      assert {:ok, path} =
               Workspace.prepare("owner/repo", 10,
                 checkout_root: tmp,
                 git_fn: git_fn
               )

      assert path == Path.join([tmp, "owner", "repo"])

      assert_received {:git_call, "fetch", fetch_args}
      assert_received {:git_call, "checkout", branch_args}

      assert "origin" in fetch_args
      assert "umarell/issue-10" in branch_args
    end

    test "returns error when fetch fails", %{tmp_dir: tmp} do
      git_fn = fail_on_first_git_fn()

      assert {:error, {1, "clone failed"}} =
               Workspace.prepare("owner/repo", 10,
                 checkout_root: tmp,
                 git_fn: git_fn
               )
    end

    test "returns error when branch creation fails after fetch", %{tmp_dir: tmp} do
      git_fn = fail_on_second_git_fn()

      assert {:error, {128, "branch failed"}} =
               Workspace.prepare("owner/repo", 10,
                 checkout_root: tmp,
                 git_fn: git_fn
               )
    end
  end

  describe "prepare/3 branch naming" do
    test "uses correct branch name with issue number", %{tmp_dir: tmp} do
      git_fn = success_git_fn()

      Workspace.prepare("owner/repo", 123,
        checkout_root: tmp,
        git_fn: git_fn
      )

      assert_received {:git_call, "clone", _}
      assert_received {:git_call, "checkout", branch_args}
      assert "umarell/issue-123" in branch_args
    end
  end

  setup do
    tmp = System.tmp_dir!() |> Path.join("workspace_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp_dir: tmp}
  end
end
