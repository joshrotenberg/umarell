defmodule Umarell.GitHub do
  @moduledoc """
  Thin wrapper over `System.cmd("gh", ...)` for the operations the coordinator needs.

  All functions accept an optional `opts` keyword list as their last argument.
  When `opts[:cmd_fn]` is provided, it is used instead of `System.cmd/3`. This
  makes the `gh` invocation injectable for testing without hitting the network.

  ## Return values

  Every function returns `{:ok, result}` or `{:error, reason}`. A non-zero exit
  code from `gh` is always an error, returned as `{:error, {exit_code, output}}`.

  ## Dependency read path

  `issue_blockers/3` calls the native GitHub dependency API:

      gh api repos/{owner}/{repo}/issues/{number}/dependencies/blocked_by

  This returns a JSON array of blocking issues, each with at least `number` and
  `state` fields.
  """

  alias Umarell.Config

  @doc """
  Lists open issues in `repo` that carry the agent-ready label.

  Uses `Umarell.Config.labels().ready` for the label name.
  Returns `{:ok, [map()]}` on success where each map is a decoded JSON object.
  """
  @spec list_ready_issues(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_ready_issues(repo, opts \\ []) do
    label = Config.labels().ready

    args = [
      "issue",
      "list",
      "--repo",
      repo,
      "--label",
      label,
      "--state",
      "open",
      "--json",
      "number,title,body,assignees"
    ]

    case run_gh(args, opts) do
      {:ok, output} -> decode_json(output)
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns the blocking issues for the given issue number in `repo`.

  Uses `gh api repos/{owner}/{repo}/issues/{number}/dependencies/blocked_by`.
  Each element in the returned list includes at least `number` and `state`.
  """
  @spec issue_blockers(String.t(), pos_integer(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def issue_blockers(repo, number, opts \\ []) do
    args = ["api", "repos/#{repo}/issues/#{number}/dependencies/blocked_by"]

    case run_gh(args, opts) do
      {:ok, output} -> decode_json(output)
      {:error, _} = err -> err
    end
  end

  @doc """
  Adds `login` as an assignee on the given issue or PR number in `repo`.
  """
  @spec assign(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def assign(repo, number, login, opts \\ []) do
    args = [
      "issue",
      "edit",
      to_string(number),
      "--repo",
      repo,
      "--add-assignee",
      login
    ]

    run_gh(args, opts)
  end

  @doc """
  Removes `from_label` and adds `to_label` on the given issue or PR number in `repo`.

  Runs the remove first; if it fails the add is not attempted and the error is
  returned. Preserves the exactly-one-agent-state-label invariant by always
  doing a remove before the add.
  """
  @spec swap_label(String.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def swap_label(repo, number, from_label, to_label, opts \\ []) do
    remove_args = [
      "issue",
      "edit",
      to_string(number),
      "--repo",
      repo,
      "--remove-label",
      from_label
    ]

    with {:ok, _} <- run_gh(remove_args, opts) do
      add_args = [
        "issue",
        "edit",
        to_string(number),
        "--repo",
        repo,
        "--add-label",
        to_label
      ]

      run_gh(add_args, opts)
    end
  end

  @doc """
  Creates a draft PR in `repo`.

  `pr_opts` keyword list supports:
  - `:title` - PR title string
  - `:body` - PR body string
  - `:head` - head branch
  - `:base` - base branch
  """
  @spec create_draft_pr(String.t(), keyword(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_draft_pr(repo, pr_opts, opts \\ []) do
    base_args = ["pr", "create", "--repo", repo, "--draft"]

    extra_args =
      []
      |> maybe_add_arg("--title", Keyword.get(pr_opts, :title))
      |> maybe_add_arg("--body", Keyword.get(pr_opts, :body))
      |> maybe_add_arg("--head", Keyword.get(pr_opts, :head))
      |> maybe_add_arg("--base", Keyword.get(pr_opts, :base))

    run_gh(base_args ++ extra_args, opts)
  end

  @doc """
  Marks the PR identified by `number` as ready for review in `repo`.
  """
  @spec mark_ready(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def mark_ready(repo, number, opts \\ []) do
    args = ["pr", "ready", to_string(number), "--repo", repo]
    run_gh(args, opts)
  end

  @doc """
  Enables auto-merge (squash strategy) on the PR identified by `number` in `repo`.
  """
  @spec enable_auto_merge(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def enable_auto_merge(repo, number, opts \\ []) do
    args = ["pr", "merge", to_string(number), "--repo", repo, "--auto", "--squash"]
    run_gh(args, opts)
  end

  @doc """
  Posts a comment on the issue or PR identified by `number` in `repo`.
  """
  @spec comment(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def comment(repo, number, body, opts \\ []) do
    args = ["issue", "comment", to_string(number), "--repo", repo, "--body", body]
    run_gh(args, opts)
  end

  # Private helpers

  defp run_gh(args, opts) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &System.cmd/3)
    {output, exit_code} = cmd_fn.("gh", args, stderr_to_stdout: true)

    if exit_code == 0 do
      {:ok, output}
    else
      {:error, {exit_code, output}}
    end
  end

  defp decode_json(output) do
    case JSON.decode(output) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:json_decode, reason}}
    end
  end

  defp maybe_add_arg(args, _flag, nil), do: args
  defp maybe_add_arg(args, flag, value), do: args ++ [flag, value]
end
