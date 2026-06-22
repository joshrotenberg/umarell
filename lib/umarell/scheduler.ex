defmodule Umarell.Scheduler do
  @moduledoc """
  GenServer that receives `WorkEvent`s from the Poller, evaluates the claim predicate,
  claims issues via GitHub assign and label swap, and starts a `Job.Worker` per claimed issue.

  ## Claim predicate (slice 0)

  An issue is claimed iff ALL of:
  1. The issue has exactly one agent-state label and it is `agent:ready` (enforced by the
     Poller, which filters by that label before constructing `WorkEvent`s).
  2. The issue is unassigned (detected at claim time: if `GitHub.assign/4` fails, the
     issue is already taken; treat as a lost claim).
  3. Every direct blocked-by dependency is a closed issue (checked via `issue_blockers`).
  4. The in-flight worker count is below `Config.concurrency/0`.

  On a lost claim (assign returns an error), no worker is started and the event is dropped.
  Cycle detection is deferred; a cycle leaves both issues unclaimed but does not deadlock
  the GenServer.

  ## Start options

  - `:name` -- optional atom passed to `GenServer.start_link/3`.
  - `:blockers_fn` -- injectable; defaults to `&Umarell.GitHub.issue_blockers/3`.
    Called as `blockers_fn.(repo, number, github_opts)`.
  - `:assign_fn` -- injectable; defaults to `&Umarell.GitHub.assign/4`.
    Called as `assign_fn.(repo, number, identity, github_opts)`.
  - `:swap_label_fn` -- injectable; defaults to `&Umarell.GitHub.swap_label/5`.
    Called as `swap_label_fn.(repo, number, from_label, to_label, github_opts)`.
  - `:start_fn` -- injectable worker starter; defaults to starting `Job.Worker` under
    `Umarell.JobSupervisor` via `DynamicSupervisor.start_child/2`.
    Called as `start_fn.(event)`. Must return `{:ok, pid}` or `{:error, reason}`.
  - `:github_opts` -- keyword list forwarded to every `Umarell.GitHub.*` call.
    Supports `:cmd_fn` injection for tests. Default `[]`.

  ## Message handling

  The Poller hands off work by casting `{:work_event, %WorkEvent{}}` to this module.
  """

  use GenServer

  require Logger

  alias Umarell.Config
  alias Umarell.GitHub
  alias Umarell.WorkEvent

  @doc """
  Starts the Scheduler as a linked GenServer.

  Accepts a keyword list of start options. See module doc for the full option list.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name_opt, opts} = Keyword.pop(opts, :name)
    gen_opts = if name_opt, do: [name: name_opt], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    state = %{
      in_flight: 0,
      monitors: %{},
      blockers_fn: Keyword.get(opts, :blockers_fn, &GitHub.issue_blockers/3),
      assign_fn: Keyword.get(opts, :assign_fn, &GitHub.assign/4),
      swap_label_fn: Keyword.get(opts, :swap_label_fn, &GitHub.swap_label/5),
      start_fn: Keyword.get(opts, :start_fn, &default_start_fn/1),
      github_opts: Keyword.get(opts, :github_opts, [])
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:work_event, %WorkEvent{} = event}, state) do
    {:noreply, maybe_claim(event, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.monitors, ref) do
      {:noreply,
       %{
         state
         | in_flight: max(0, state.in_flight - 1),
           monitors: Map.delete(state.monitors, ref)
       }}
    else
      {:noreply, state}
    end
  end

  # Evaluates the claim predicate and, if all conditions hold, claims the issue
  # and starts a worker. Returns the updated state.
  defp maybe_claim(%WorkEvent{repo: repo, number: number} = event, state) do
    concurrency = Config.concurrency()

    cond do
      state.in_flight >= concurrency ->
        Logger.debug(
          "Scheduler: at concurrency cap (#{state.in_flight}/#{concurrency}), skipping #{repo}##{number}"
        )

        state

      not all_blockers_closed?(repo, number, state) ->
        state

      true ->
        claim(event, state)
    end
  end

  # Checks that every direct blocker of the issue is closed. Returns false on fetch error
  # (conservative: skip rather than claim under uncertainty).
  defp all_blockers_closed?(repo, number, state) do
    case state.blockers_fn.(repo, number, state.github_opts) do
      {:ok, blockers} ->
        Enum.all?(blockers, fn b -> b["state"] == "closed" end)

      {:error, reason} ->
        Logger.warning(
          "Scheduler: failed to fetch blockers for #{repo}##{number}: #{inspect(reason)}; skipping"
        )

        false
    end
  end

  # Attempts to claim the issue: assign then swap label. If either fails, treats
  # it as a lost claim and drops the event (no worker started). On success, starts
  # a worker, monitors its pid, and increments in_flight.
  defp claim(%WorkEvent{repo: repo, number: number} = event, state) do
    identity = Config.identity()
    labels = Config.labels()

    with {:ok, _} <- state.assign_fn.(repo, number, identity, state.github_opts),
         {:ok, _} <-
           state.swap_label_fn.(repo, number, labels.ready, labels.working, state.github_opts) do
      case state.start_fn.(event) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          %{
            state
            | in_flight: state.in_flight + 1,
              monitors: Map.put(state.monitors, ref, true)
          }

        {:error, reason} ->
          Logger.error(
            "Scheduler: failed to start worker for #{repo}##{number}: #{inspect(reason)}"
          )

          state
      end
    else
      {:error, reason} ->
        Logger.warning("Scheduler: lost claim for #{repo}##{number}: #{inspect(reason)}")

        state
    end
  end

  defp default_start_fn(%WorkEvent{} = event) do
    DynamicSupervisor.start_child(
      Umarell.JobSupervisor,
      {Umarell.Job.Worker, [event: event]}
    )
  end
end
