defmodule Umarell.Intake.Poller do
  @moduledoc """
  GenServer that polls GitHub on a configurable interval and hands off new
  ready issues as `Umarell.WorkEvent` structs to the Scheduler.

  ## Start options

  - `:repos` -- list of `owner/repo` strings to poll. Defaults to
    `Umarell.Config.watched_repos/0`.
  - `:poll_interval_ms` -- milliseconds between poll ticks. Defaults to
    `Umarell.Config.poll_interval_ms/0`.
  - `:list_fn` -- callable used to fetch ready issues. Called as
    `list_fn.(repo, [])` for each repo. Defaults to
    `&Umarell.GitHub.list_ready_issues/2`. Override in tests to avoid
    network access.
  - `:scheduler` -- atom (module name) that receives
    `GenServer.cast(scheduler, {:work_event, event})` for each new
    `WorkEvent`. Defaults to `Umarell.Scheduler`. The Poller does not
    crash if the Scheduler is absent.
  - `:name` -- optional name passed through to `GenServer.start_link/3`.

  ## State

  The GenServer state is a map with keys:
  - `:repos` -- the list of repos being polled
  - `:poll_interval_ms` -- the interval in milliseconds
  - `:list_fn` -- the injectable fetch function
  - `:scheduler` -- the scheduler module atom
  - `:seen` -- a `MapSet` of `{repo, number}` tuples already handed off
  """

  use GenServer

  require Logger

  alias Umarell.Config
  alias Umarell.GitHub
  alias Umarell.WorkEvent

  @doc """
  Starts the Poller as a linked process.

  Accepts a keyword list of start options. See module doc for the full list.
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
      repos: Keyword.get(opts, :repos, Config.watched_repos()),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, Config.poll_interval_ms()),
      list_fn: Keyword.get(opts, :list_fn, &GitHub.list_ready_issues/2),
      scheduler: Keyword.get(opts, :scheduler, Umarell.Scheduler),
      seen: MapSet.new()
    }

    Process.send_after(self(), :poll, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_seen =
      Enum.reduce(state.repos, state.seen, fn repo, seen ->
        case state.list_fn.(repo, []) do
          {:ok, issues} ->
            events =
              issues
              |> Enum.map(&issue_to_event(repo, &1))
              |> Enum.reject(fn event -> MapSet.member?(seen, {event.repo, event.number}) end)

            Enum.reduce(events, seen, fn event, acc ->
              hand_off(event, state.scheduler)
              MapSet.put(acc, {event.repo, event.number})
            end)

          {:error, reason} ->
            Logger.error("Poller failed to fetch issues for #{repo}: #{inspect(reason)}")
            seen
        end
      end)

    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, %{state | seen: new_seen}}
  end

  defp issue_to_event(repo, issue) do
    %WorkEvent{
      repo: repo,
      number: issue["number"],
      title: issue["title"] || "",
      body: issue["body"] || ""
    }
  end

  defp hand_off(event, scheduler) when is_pid(scheduler) do
    if Process.alive?(scheduler) do
      GenServer.cast(scheduler, {:work_event, event})
    else
      Logger.debug(
        "Scheduler #{inspect(scheduler)} is not alive; skipping hand-off for #{event.repo}##{event.number}"
      )
    end
  end

  defp hand_off(event, scheduler) when is_atom(scheduler) do
    case Process.whereis(scheduler) do
      nil ->
        Logger.debug(
          "Scheduler #{inspect(scheduler)} not running; skipping hand-off for #{event.repo}##{event.number}"
        )

      _pid ->
        GenServer.cast(scheduler, {:work_event, event})
    end
  end
end
