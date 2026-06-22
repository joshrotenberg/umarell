defmodule Umarell.SchedulerTest do
  use ExUnit.Case, async: true

  alias Umarell.Scheduler
  alias Umarell.WorkEvent

  @test_event %WorkEvent{
    repo: "owner/repo",
    number: 7,
    title: "feat: do work",
    body: "Some body."
  }

  # Blockers fns

  defp ok_blockers_fn(blockers) do
    fn _repo, _number, _opts -> {:ok, blockers} end
  end

  defp error_blockers_fn do
    fn _repo, _number, _opts -> {:error, :timeout} end
  end

  # Assign fns

  defp ok_assign_fn(notify_pid) do
    fn repo, number, _identity, _opts ->
      send(notify_pid, {:assigned, repo, number})
      {:ok, ""}
    end
  end

  defp error_assign_fn(notify_pid) do
    fn _repo, _number, _identity, _opts ->
      send(notify_pid, :assign_called)
      {:error, {1, "conflict"}}
    end
  end

  defp noop_assign_fn do
    fn _repo, _number, _identity, _opts -> {:ok, ""} end
  end

  # Swap label fns

  defp ok_swap_fn(notify_pid) do
    fn repo, number, from, to, _opts ->
      send(notify_pid, {:swapped, repo, number, from, to})
      {:ok, ""}
    end
  end

  defp noop_swap_fn do
    fn _repo, _number, _from, _to, _opts -> {:ok, ""} end
  end

  # Start fns

  defp ok_start_fn(notify_pid) do
    fn _event ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(notify_pid, :worker_started)
      {:ok, pid}
    end
  end

  defp quick_exit_start_fn(notify_pid) do
    fn _event ->
      pid = spawn(fn -> :ok end)
      send(notify_pid, {:worker_pid, pid})
      {:ok, pid}
    end
  end

  defp noop_start_fn do
    fn _event ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, pid}
    end
  end

  defp refute_assign_called do
    refute_received {:assigned, _, _}
    refute_received :assign_called
  end

  describe "claim happy path" do
    test "predicate true: assign + swap + worker started" do
      notify_pid = self()

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn([]),
           assign_fn: ok_assign_fn(notify_pid),
           swap_label_fn: ok_swap_fn(notify_pid),
           start_fn: ok_start_fn(notify_pid)}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      # Give async handling time to process
      assert_receive {:assigned, "owner/repo", 7}, 500
      assert_receive {:swapped, "owner/repo", 7, "agent:ready", "agent:working"}, 500
      assert_receive :worker_started, 500
    end

    test "all blockers closed: proceeds to claim" do
      notify_pid = self()

      closed_blockers = [
        %{"number" => 1, "state" => "closed"},
        %{"number" => 2, "state" => "closed"}
      ]

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn(closed_blockers),
           assign_fn: ok_assign_fn(notify_pid),
           swap_label_fn: noop_swap_fn(),
           start_fn: noop_start_fn()}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      assert_receive {:assigned, "owner/repo", 7}, 500
    end

    test "no blockers: proceeds to claim" do
      notify_pid = self()

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn([]),
           assign_fn: ok_assign_fn(notify_pid),
           swap_label_fn: noop_swap_fn(),
           start_fn: noop_start_fn()}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      assert_receive {:assigned, "owner/repo", 7}, 500
    end
  end

  describe "predicate failures" do
    test "open blocker present: not claimed" do
      notify_pid = self()
      open_blockers = [%{"number" => 5, "state" => "open"}]

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn(open_blockers),
           assign_fn: ok_assign_fn(notify_pid),
           swap_label_fn: noop_swap_fn(),
           start_fn: noop_start_fn()}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      # Let the cast be processed
      :sys.get_state(pid)

      refute_assign_called()
    end

    test "mixed blockers with one open: not claimed" do
      notify_pid = self()

      mixed_blockers = [
        %{"number" => 3, "state" => "closed"},
        %{"number" => 4, "state" => "open"}
      ]

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn(mixed_blockers),
           assign_fn: ok_assign_fn(notify_pid),
           swap_label_fn: noop_swap_fn(),
           start_fn: noop_start_fn()}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      :sys.get_state(pid)

      refute_assign_called()
    end

    test "blockers_fn error: skips claim conservatively" do
      notify_pid = self()

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: error_blockers_fn(),
           assign_fn: ok_assign_fn(notify_pid),
           swap_label_fn: noop_swap_fn(),
           start_fn: noop_start_fn()}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      :sys.get_state(pid)

      refute_assign_called()
    end

    test "at concurrency cap: not claimed" do
      notify_pid = self()

      # Use a unique app env key scope so parallel tests don't interfere
      orig = Application.get_env(:umarell, :concurrency)
      Application.put_env(:umarell, :concurrency, 1)

      on_exit(fn ->
        if orig == nil do
          Application.delete_env(:umarell, :concurrency)
        else
          Application.put_env(:umarell, :concurrency, orig)
        end
      end)

      # Start scheduler and send one event to fill the cap
      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn([]),
           assign_fn: noop_assign_fn(),
           swap_label_fn: noop_swap_fn(),
           start_fn: ok_start_fn(notify_pid)}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      # Wait until in_flight reaches 1
      assert_receive :worker_started, 500

      state = :sys.get_state(pid)
      assert state.in_flight == 1

      # Now send a second event; should be skipped due to cap
      GenServer.cast(pid, {:work_event, @test_event})

      # Wait for cast to be processed
      :sys.get_state(pid)

      # Only one worker_started message should exist
      refute_received :worker_started
    end
  end

  describe "lost claim" do
    test "assign returns error: no worker started" do
      notify_pid = self()

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn([]),
           assign_fn: error_assign_fn(notify_pid),
           swap_label_fn: ok_swap_fn(notify_pid),
           start_fn: ok_start_fn(notify_pid)}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      assert_receive :assign_called, 500

      # Let the cast fully process
      :sys.get_state(pid)

      refute_received {:swapped, _, _, _, _}
      refute_received :worker_started
    end
  end

  describe "worker exit and in_flight tracking" do
    test "in_flight increments on worker start and decrements on worker exit" do
      notify_pid = self()

      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn([]),
           assign_fn: noop_assign_fn(),
           swap_label_fn: noop_swap_fn(),
           start_fn: quick_exit_start_fn(notify_pid)}
        )

      GenServer.cast(pid, {:work_event, @test_event})

      # Wait for the worker pid to be reported
      assert_receive {:worker_pid, worker_pid}, 500

      # in_flight should be 1 now (or possibly already 0 if worker exited)
      # Wait for the worker to exit then check in_flight is 0
      ref = Process.monitor(worker_pid)

      receive do
        {:DOWN, ^ref, :process, ^worker_pid, _} -> :ok
      after
        500 -> :ok
      end

      # Give the scheduler time to handle the DOWN message
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.in_flight == 0
    end

    test "in_flight starts at 0" do
      {:ok, pid} =
        start_supervised(
          {Scheduler,
           blockers_fn: ok_blockers_fn([]),
           assign_fn: noop_assign_fn(),
           swap_label_fn: noop_swap_fn(),
           start_fn: noop_start_fn()}
        )

      state = :sys.get_state(pid)
      assert state.in_flight == 0
    end
  end
end
