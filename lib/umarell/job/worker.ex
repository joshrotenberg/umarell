defmodule Umarell.Job.Worker do
  @moduledoc """
  GenServer that drives a single claimed GitHub issue from start to merged PR.

  Started by the Scheduler under a `JobSupervisor`. Marked `restart: :temporary`
  so a crash does not cause a restart loop; the Scheduler is responsible for
  error recovery at a higher level.

  ## Lifecycle

  1. Workspace prep: clone/fetch the repo and create `umarell/issue-<N>`.
  2. Compose prompt from the issue body and done-predicate.
  3. Run `claude` non-interactively with `--full-auto` (injectable).
  4. Local gate: run `Config.test_command/0` in the checkout (injectable).
     On failure: park the issue (swap `agent:working` -> `agent:blocked`,
     comment the failure) then exit normally.
  5. Commit and push the branch.
  6. `GitHub.create_draft_pr` with `Closes #N` in the body.
  7. `GitHub.mark_ready`, then `GitHub.enable_auto_merge` (if `:auto_merge` is true).
  8. Comment the result envelope (status, summary, cost_usd, turns, test outcome).
  9. Exit. `agent:working` is NOT cleared; the issue closes on auto-merge (or manual merge).

  ## Start options

  - `:event` (required) -- a `%Umarell.WorkEvent{}` describing the issue.
  - `:workspace_fn` -- injectable workspace preparation. Defaults to
    `&Umarell.Job.Workspace.prepare/3`. Called as
    `workspace_fn.(repo, number, opts)`.
  - `:claude_fn` -- injectable claude invocation. Defaults to
    `default_claude_fn/3`. Called as `claude_fn.(prompt, checkout_path, opts)`.
    Returns `{:ok, result_map}` | `{:error, reason}`.
  - `:test_fn` -- injectable local gate. Defaults to `default_test_fn/2`.
    Called as `test_fn.(checkout_path, opts)`.
    Returns `{:ok, output}` | `{:error, {exit_code, output}}`.
  - `:git_fn` -- injectable git executor forwarded to the workspace and the
    commit/push steps. Defaults to a `System.cmd`-based implementation.
  - `:github_opts` -- keyword list forwarded as opts to every
    `Umarell.GitHub.*` call (supports `:cmd_fn` injection for tests).
  - `:auto_merge` -- boolean (default `Config.auto_merge?()`). When true, calls
    `GitHub.enable_auto_merge` after marking ready. When false, skips that call
    and notes in the result envelope that the PR is left at ready for a human to merge.

  ## Entry points

  The Scheduler may use either:
  - `start_link/1` -- supervised; starts the GenServer under the caller's
    supervisor.
  - `run/2` -- synchronous; runs the full lifecycle inline and returns the
    result. Useful for testing and for direct invocation.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Umarell.Config
  alias Umarell.GitHub
  alias Umarell.Job.Workspace

  @doc """
  Starts the Worker as a linked GenServer.

  `opts` must include `:event`. All other keys are optional injectable seams.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Runs the full worker lifecycle synchronously.

  Starts the GenServer without a link so that abnormal exits do not propagate
  to the caller. Useful for the Scheduler to call directly when it does not
  need a supervised process.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec run(%Umarell.WorkEvent{}, keyword()) :: :ok | {:error, term()}
  def run(event, opts \\ []) do
    opts = Keyword.put(opts, :event, event)

    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
          {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    event = Keyword.fetch!(opts, :event)

    state = %{
      event: event,
      workspace_fn: Keyword.get(opts, :workspace_fn, &Workspace.prepare/3),
      claude_fn: Keyword.get(opts, :claude_fn, &default_claude_fn/3),
      test_fn: Keyword.get(opts, :test_fn, &default_test_fn/2),
      git_fn: Keyword.get(opts, :git_fn, &default_git_fn/3),
      github_opts: Keyword.get(opts, :github_opts, []),
      auto_merge: Keyword.get(opts, :auto_merge, Config.auto_merge?())
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    case do_run(state) do
      :ok ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error(
          "Worker failed for #{state.event.repo}##{state.event.number}: #{inspect(reason)}"
        )

        {:stop, reason, state}
    end
  end

  defp do_run(state) do
    %{
      event: event,
      workspace_fn: workspace_fn,
      claude_fn: claude_fn,
      test_fn: test_fn,
      git_fn: git_fn,
      github_opts: github_opts,
      auto_merge: auto_merge
    } = state

    with {:ok, checkout_path} <- workspace_fn.(event.repo, event.number, git_fn: git_fn),
         prompt = compose_prompt(event),
         {:ok, claude_result} <- claude_fn.(prompt, checkout_path, []),
         test_result = test_fn.(checkout_path, []),
         :ok <-
           handle_gate(
             test_result,
             event,
             checkout_path,
             claude_result,
             git_fn,
             github_opts,
             auto_merge
           ) do
      :ok
    end
  end

  # Handles the local gate result. On success, proceeds with commit/push/PR.
  # On failure, parks the issue and returns :ok (worker exits normally).
  defp handle_gate(
         {:ok, test_output},
         event,
         checkout_path,
         claude_result,
         git_fn,
         github_opts,
         auto_merge
       ) do
    with {:ok, pr_url} <- commit_push_pr(event, checkout_path, git_fn, github_opts),
         pr_number = extract_pr_number(pr_url),
         {:ok, _} <- GitHub.mark_ready(event.repo, pr_number, github_opts),
         {:ok, _} <- maybe_enable_auto_merge(auto_merge, event.repo, pr_number, github_opts),
         {:ok, _} <-
           GitHub.comment(
             event.repo,
             event.number,
             result_envelope(claude_result, test_output, auto_merge),
             github_opts
           ) do
      :ok
    end
  end

  defp handle_gate(
         {:error, {_code, output}},
         event,
         _checkout_path,
         _claude_result,
         _git_fn,
         github_opts,
         _auto_merge
       ) do
    labels = Config.labels()

    with {:ok, _} <-
           GitHub.swap_label(
             event.repo,
             event.number,
             labels.working,
             labels.blocked,
             github_opts
           ),
         {:ok, _} <-
           GitHub.comment(
             event.repo,
             event.number,
             park_comment(output),
             github_opts
           ) do
      :ok
    end
  end

  defp maybe_enable_auto_merge(true, repo, pr_number, github_opts) do
    GitHub.enable_auto_merge(repo, pr_number, github_opts)
  end

  defp maybe_enable_auto_merge(false, _repo, _pr_number, _github_opts) do
    {:ok, :skipped}
  end

  defp commit_push_pr(event, checkout_path, git_fn, github_opts) do
    branch = "umarell/issue-#{event.number}"

    with {:ok, _} <-
           run_git(git_fn, "add", ["-A"], cd: checkout_path),
         {:ok, _} <-
           run_git(
             git_fn,
             "commit",
             ["-m", "feat: implement issue ##{event.number} changes"],
             cd: checkout_path
           ),
         {:ok, _} <-
           run_git(
             git_fn,
             "push",
             ["--set-upstream", "origin", branch],
             cd: checkout_path
           ),
         {:ok, pr_url} <-
           GitHub.create_draft_pr(
             event.repo,
             [
               title: event.title,
               body: pr_body(event),
               head: branch,
               base: "main"
             ],
             github_opts
           ) do
      {:ok, pr_url}
    end
  end

  defp compose_prompt(event) do
    """
    #{event.title}

    #{event.body}

    ---
    Done predicate: The implementation is complete when `mix test` passes and all acceptance criteria in the issue body above are satisfied.
    """
  end

  defp pr_body(event) do
    """
    Implements #{event.title}.

    Closes ##{event.number}
    """
  end

  defp result_envelope(claude_result, test_output, auto_merge) do
    status = Map.get(claude_result, :status, "unknown")
    summary = Map.get(claude_result, :summary, "")
    cost_usd = Map.get(claude_result, :cost_usd)
    turns = Map.get(claude_result, :turns)

    cost_str = if cost_usd, do: "$#{:erlang.float_to_binary(cost_usd, decimals: 4)}", else: "N/A"
    turns_str = if turns, do: "#{turns}", else: "N/A"

    merge_note =
      if auto_merge do
        ""
      else
        "\n### Merge\n\nPR left at ready for a human to merge.\n"
      end

    """
    ## Result Envelope

    **Status:** #{status}
    **Cost:** #{cost_str}
    **Turns:** #{turns_str}

    ### Summary

    #{summary}

    ### Test Output

    ```
    #{String.trim(test_output)}
    ```
    #{merge_note}
    """
  end

  defp park_comment(test_output) do
    """
    ## Agent Blocked

    The local test gate failed. Issue parked as `agent:blocked`.

    ### Test Output

    ```
    #{String.trim(test_output)}
    ```
    """
  end

  defp extract_pr_number(pr_url) do
    pr_url
    |> String.trim()
    |> String.split("/")
    |> List.last()
    |> String.to_integer()
  end

  defp run_git(git_fn, command, args, opts) do
    case git_fn.(command, args, opts) do
      {_output, 0} = result -> {:ok, result}
      {output, code} -> {:error, {code, output}}
    end
  end

  defp default_claude_fn(prompt, checkout_path, _opts) do
    model = Config.model()
    budget = Config.max_budget_usd()

    args = ["--full-auto", "-p", prompt]
    args = if model, do: args ++ ["--model", model], else: args

    args =
      if budget,
        do: args ++ ["--max-budget", to_string(budget)],
        else: args

    env = [{"CLAUDE_CODE_OAUTH_TOKEN", System.get_env("CLAUDE_CODE_OAUTH_TOKEN", "")}]

    case System.cmd("claude", args,
           cd: checkout_path,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, %{status: "success", summary: output, cost_usd: nil, turns: nil}}

      {output, code} ->
        {:error, {code, output}}
    end
  end

  defp default_test_fn(checkout_path, _opts) do
    cmd = Config.test_command()

    case System.cmd("sh", ["-c", cmd],
           cd: checkout_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  end

  defp default_git_fn(command, args, opts) do
    System.cmd("git", [command | args], Keyword.merge([stderr_to_stdout: true], opts))
  end
end
