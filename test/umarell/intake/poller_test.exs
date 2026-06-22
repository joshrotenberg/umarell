defmodule Umarell.Intake.PollerTest do
  use ExUnit.Case, async: true

  alias Umarell.Intake.Poller
  alias Umarell.WorkEvent

  # A simple GenServer that records all :work_event casts it receives.
  defmodule SchedulerSpy do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, [], opts)
    end

    def received(pid) do
      GenServer.call(pid, :received)
    end

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def handle_cast({:work_event, event}, events) do
      {:noreply, [event | events]}
    end

    @impl true
    def handle_call(:received, _from, events) do
      {:reply, Enum.reverse(events), events}
    end
  end

  defp list_fn_ok(issues) do
    fn _repo, _opts -> {:ok, issues} end
  end

  defp list_fn_error(reason) do
    fn _repo, _opts -> {:error, reason} end
  end

  defp wait_until(condition, timeout \\ 200, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(condition, deadline, interval)
  end

  defp do_wait(condition, deadline, interval) do
    if condition.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Condition not met within timeout")
      else
        Process.sleep(interval)
        do_wait(condition, deadline, interval)
      end
    end
  end

  describe "start_link/1" do
    test "starts without a name option" do
      {:ok, pid} =
        Poller.start_link(
          repos: ["owner/repo"],
          poll_interval_ms: 60_000,
          list_fn: list_fn_ok([]),
          scheduler: NonexistentScheduler
        )

      assert Process.alive?(pid)
    end
  end

  describe "polling" do
    test "hands off a ready issue as a WorkEvent" do
      issues = [%{"number" => 1, "title" => "Do thing", "body" => "Details"}]
      {:ok, spy} = start_supervised(SchedulerSpy)

      {:ok, _pid} =
        start_supervised(
          {Poller,
           repos: ["owner/repo"],
           poll_interval_ms: 10,
           list_fn: list_fn_ok(issues),
           scheduler: spy}
        )

      wait_until(fn -> length(SchedulerSpy.received(spy)) >= 1 end)

      [event] = SchedulerSpy.received(spy)
      assert %WorkEvent{repo: "owner/repo", number: 1, title: "Do thing", body: "Details"} = event
    end

    test "de-duplicates: same issue is only handed off once across multiple ticks" do
      issues = [%{"number" => 7, "title" => "Already done", "body" => ""}]
      {:ok, spy} = start_supervised(SchedulerSpy)

      {:ok, _pid} =
        start_supervised(
          {Poller,
           repos: ["owner/repo"],
           poll_interval_ms: 10,
           list_fn: list_fn_ok(issues),
           scheduler: spy}
        )

      # Wait for at least two poll cycles
      Process.sleep(50)

      received = SchedulerSpy.received(spy)
      assert length(received) == 1
    end

    test "polls multiple repos and produces WorkEvents for each" do
      {:ok, spy} = start_supervised(SchedulerSpy)

      {:ok, _pid} =
        start_supervised(
          {Poller,
           repos: ["owner/repo-a", "owner/repo-b"],
           poll_interval_ms: 10,
           list_fn: fn repo, _opts -> {:ok, [%{"number" => 1, "title" => repo, "body" => ""}]} end,
           scheduler: spy}
        )

      wait_until(fn -> length(SchedulerSpy.received(spy)) >= 2 end)

      received = SchedulerSpy.received(spy)
      repos = Enum.map(received, & &1.repo)
      assert "owner/repo-a" in repos
      assert "owner/repo-b" in repos
    end
  end

  describe "scheduler absence" do
    test "does not crash when the scheduler module has no running process" do
      issues = [%{"number" => 99, "title" => "Title", "body" => "Body"}]

      {:ok, pid} =
        start_supervised(
          {Poller,
           repos: ["owner/repo"],
           poll_interval_ms: 10,
           list_fn: list_fn_ok(issues),
           scheduler: Umarell.Scheduler}
        )

      # Give it time for a couple of polls; the Poller should remain alive
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "list_fn errors" do
    test "does not crash on fetch error" do
      {:ok, pid} =
        start_supervised(
          {Poller,
           repos: ["owner/repo"],
           poll_interval_ms: 10,
           list_fn: list_fn_error(:timeout),
           scheduler: NonexistentScheduler}
        )

      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "seen state" do
    test "seen set grows after each new issue is polled" do
      issues = [%{"number" => 5, "title" => "New", "body" => ""}]
      {:ok, spy} = start_supervised(SchedulerSpy)

      {:ok, pid} =
        start_supervised(
          {Poller,
           repos: ["owner/repo"],
           poll_interval_ms: 10,
           list_fn: list_fn_ok(issues),
           scheduler: spy}
        )

      wait_until(fn ->
        state = :sys.get_state(pid)
        MapSet.member?(state.seen, {"owner/repo", 5})
      end)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.seen, {"owner/repo", 5})
    end
  end
end
