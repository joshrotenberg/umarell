defmodule Umarell.GitHubTest do
  use ExUnit.Case, async: true

  alias Umarell.GitHub

  # Builds a cmd_fn that captures its arguments and returns canned output.
  defp cmd_fn(output, exit_code \\ 0) do
    fn "gh", args, _opts ->
      send(self(), {:gh_call, args})
      {output, exit_code}
    end
  end

  # Returns a cmd_fn that accumulates multiple calls in order.
  # Each element in `responses` is {output, exit_code}.
  defp multi_cmd_fn(responses) do
    agent = start_supervised!({Agent, fn -> responses end})

    fn "gh", args, _opts ->
      response = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      send(self(), {:gh_call, args})
      response
    end
  end

  # Asserts exactly one call was made and returns the captured args.
  defp assert_single_call do
    assert_received {:gh_call, args}
    refute_received {:gh_call, _}
    args
  end

  describe "list_ready_issues/2" do
    test "builds correct gh arguments" do
      issues = [%{"number" => 1, "title" => "Test", "body" => "", "assignees" => []}]
      json = JSON.encode!(issues)

      GitHub.list_ready_issues("owner/repo", cmd_fn: cmd_fn(json))

      args = assert_single_call()

      assert args == [
               "issue",
               "list",
               "--repo",
               "owner/repo",
               "--label",
               "agent:ready",
               "--state",
               "open",
               "--json",
               "number,title,body,assignees"
             ]
    end

    test "decodes JSON response" do
      issues = [
        %{"number" => 1, "title" => "First", "body" => "body1", "assignees" => []},
        %{"number" => 2, "title" => "Second", "body" => "body2", "assignees" => []}
      ]

      json = JSON.encode!(issues)

      assert {:ok, decoded} = GitHub.list_ready_issues("owner/repo", cmd_fn: cmd_fn(json))
      assert length(decoded) == 2
      assert Enum.at(decoded, 0)["number"] == 1
      assert Enum.at(decoded, 1)["title"] == "Second"
    end

    test "returns error on non-zero exit" do
      assert {:error, {1, _}} =
               GitHub.list_ready_issues("owner/repo", cmd_fn: cmd_fn("error output", 1))
    end

    test "returns error on invalid JSON" do
      assert {:error, {:json_decode, _}} =
               GitHub.list_ready_issues("owner/repo", cmd_fn: cmd_fn("not json"))
    end
  end

  describe "issue_blockers/3" do
    test "builds correct gh api path" do
      blockers = [%{"number" => 5, "state" => "open"}]
      json = JSON.encode!(blockers)

      GitHub.issue_blockers("owner/repo", 42, cmd_fn: cmd_fn(json))

      args = assert_single_call()

      assert args == [
               "api",
               "repos/owner/repo/issues/42/dependencies/blocked_by"
             ]
    end

    test "decodes blocker list with number and state" do
      blockers = [
        %{"number" => 5, "state" => "open"},
        %{"number" => 6, "state" => "closed"}
      ]

      json = JSON.encode!(blockers)

      assert {:ok, decoded} = GitHub.issue_blockers("owner/repo", 42, cmd_fn: cmd_fn(json))
      assert length(decoded) == 2
      assert Enum.at(decoded, 0)["number"] == 5
      assert Enum.at(decoded, 0)["state"] == "open"
      assert Enum.at(decoded, 1)["state"] == "closed"
    end

    test "returns ok with empty list when no blockers" do
      json = JSON.encode!([])
      assert {:ok, []} = GitHub.issue_blockers("owner/repo", 10, cmd_fn: cmd_fn(json))
    end

    test "returns error on non-zero exit" do
      assert {:error, {1, _}} =
               GitHub.issue_blockers("owner/repo", 1, cmd_fn: cmd_fn("error", 1))
    end
  end

  describe "assign/4" do
    test "builds correct gh arguments" do
      GitHub.assign("owner/repo", 7, "someuser", cmd_fn: cmd_fn(""))

      args = assert_single_call()

      assert args == [
               "issue",
               "edit",
               "7",
               "--repo",
               "owner/repo",
               "--add-assignee",
               "someuser"
             ]
    end

    test "returns ok tuple on success" do
      assert {:ok, "done"} = GitHub.assign("owner/repo", 7, "user", cmd_fn: cmd_fn("done"))
    end

    test "returns error on non-zero exit" do
      assert {:error, {2, _}} = GitHub.assign("owner/repo", 7, "user", cmd_fn: cmd_fn("err", 2))
    end
  end

  describe "swap_label/5" do
    test "calls remove then add in sequence" do
      responses = [{"", 0}, {"", 0}]
      f = multi_cmd_fn(responses)

      assert {:ok, _} =
               GitHub.swap_label("owner/repo", 3, "agent:ready", "agent:working", cmd_fn: f)

      assert_received {:gh_call, remove_args}
      assert_received {:gh_call, add_args}

      assert "--remove-label" in remove_args
      assert "agent:ready" in remove_args
      assert "--add-label" in add_args
      assert "agent:working" in add_args
    end

    test "does not call add if remove fails" do
      responses = [{"err", 1}]
      f = multi_cmd_fn(responses)

      assert {:error, {1, "err"}} =
               GitHub.swap_label("owner/repo", 3, "agent:ready", "agent:working", cmd_fn: f)

      assert_received {:gh_call, _}
      refute_received {:gh_call, _}
    end

    test "includes repo and number in both calls" do
      responses = [{"", 0}, {"", 0}]
      f = multi_cmd_fn(responses)

      GitHub.swap_label("owner/repo", 99, "from", "to", cmd_fn: f)

      assert_received {:gh_call, remove_args}
      assert_received {:gh_call, add_args}

      assert "owner/repo" in remove_args
      assert "99" in remove_args
      assert "owner/repo" in add_args
      assert "99" in add_args
    end
  end

  describe "create_draft_pr/3" do
    test "builds base arguments with --draft flag" do
      GitHub.create_draft_pr("owner/repo", [], cmd_fn: cmd_fn(""))

      args = assert_single_call()

      assert "pr" in args
      assert "create" in args
      assert "--draft" in args
      assert "--repo" in args
      assert "owner/repo" in args
    end

    test "adds optional title, body, head, base when provided" do
      pr_opts = [title: "My PR", body: "Body text", head: "feat/foo", base: "main"]
      GitHub.create_draft_pr("owner/repo", pr_opts, cmd_fn: cmd_fn(""))

      args = assert_single_call()

      assert "--title" in args
      assert "My PR" in args
      assert "--body" in args
      assert "Body text" in args
      assert "--head" in args
      assert "feat/foo" in args
      assert "--base" in args
      assert "main" in args
    end

    test "omits flags not present in pr_opts" do
      GitHub.create_draft_pr("owner/repo", [title: "Only Title"], cmd_fn: cmd_fn(""))

      args = assert_single_call()

      assert "--title" in args
      refute "--body" in args
      refute "--head" in args
      refute "--base" in args
    end

    test "returns error on non-zero exit" do
      assert {:error, {1, _}} =
               GitHub.create_draft_pr("owner/repo", [], cmd_fn: cmd_fn("err", 1))
    end
  end

  describe "mark_ready/3" do
    test "builds correct gh arguments" do
      GitHub.mark_ready("owner/repo", 12, cmd_fn: cmd_fn(""))

      args = assert_single_call()

      assert args == [
               "pr",
               "ready",
               "12",
               "--repo",
               "owner/repo"
             ]
    end

    test "returns ok tuple on success" do
      assert {:ok, ""} = GitHub.mark_ready("owner/repo", 12, cmd_fn: cmd_fn(""))
    end

    test "returns error on non-zero exit" do
      assert {:error, {1, _}} =
               GitHub.mark_ready("owner/repo", 12, cmd_fn: cmd_fn("error", 1))
    end
  end

  describe "enable_auto_merge/3" do
    test "builds correct gh arguments" do
      GitHub.enable_auto_merge("owner/repo", 15, cmd_fn: cmd_fn(""))

      args = assert_single_call()

      assert args == [
               "pr",
               "merge",
               "15",
               "--repo",
               "owner/repo",
               "--auto",
               "--squash"
             ]
    end

    test "returns ok tuple on success" do
      assert {:ok, "merged"} =
               GitHub.enable_auto_merge("owner/repo", 15, cmd_fn: cmd_fn("merged"))
    end

    test "returns error on non-zero exit" do
      assert {:error, {1, _}} =
               GitHub.enable_auto_merge("owner/repo", 15, cmd_fn: cmd_fn("err", 1))
    end
  end

  describe "comment/4" do
    test "builds correct gh arguments" do
      GitHub.comment("owner/repo", 20, "Hello!", cmd_fn: cmd_fn(""))

      args = assert_single_call()

      assert args == [
               "issue",
               "comment",
               "20",
               "--repo",
               "owner/repo",
               "--body",
               "Hello!"
             ]
    end

    test "returns ok tuple on success" do
      assert {:ok, ""} = GitHub.comment("owner/repo", 20, "body", cmd_fn: cmd_fn(""))
    end

    test "returns error on non-zero exit" do
      assert {:error, {1, _}} =
               GitHub.comment("owner/repo", 20, "body", cmd_fn: cmd_fn("err", 1))
    end
  end
end
