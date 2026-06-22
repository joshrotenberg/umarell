defmodule Umarell.SupervisionTreeTest do
  use ExUnit.Case, async: false

  alias Umarell.Intake.Poller
  alias Umarell.Scheduler
  alias Umarell.WorkEvent

  test "Application supervision tree children are running" do
    # Verify the Application started JobSupervisor and Scheduler.
    # Poller is excluded in test env via :start_poller config.
    assert Process.whereis(Umarell.JobSupervisor) != nil,
           "Umarell.JobSupervisor should be running"

    assert Process.whereis(Umarell.Supervisor) != nil,
           "Umarell.Supervisor should be running"
  end

  test "poll -> claim -> worker start end-to-end with injected seams" do
    test_pid = self()
    repo = "owner/test-repo"
    issue_number = 42

    fake_issue = %{
      "number" => issue_number,
      "title" => "feat: test issue",
      "body" => "test body"
    }

    list_fn = fn ^repo, _opts -> {:ok, [fake_issue]} end

    blockers_fn = fn _repo, _number, _opts -> {:ok, []} end

    assign_fn = fn ^repo, ^issue_number, _identity, _opts ->
      send(test_pid, {:assigned, repo, issue_number})
      {:ok, ""}
    end

    swap_label_fn = fn ^repo, ^issue_number, _from, _to, _opts ->
      send(test_pid, {:label_swapped, repo, issue_number})
      {:ok, ""}
    end

    start_fn = fn %WorkEvent{repo: ^repo, number: ^issue_number} = event ->
      send(test_pid, {:worker_started, event})
      pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, pid}
    end

    # Start an anonymous Scheduler with fully injected seams.
    # This runs independently from the Application-started Scheduler.
    {:ok, scheduler} =
      start_supervised(
        {Scheduler,
         blockers_fn: blockers_fn,
         assign_fn: assign_fn,
         swap_label_fn: swap_label_fn,
         start_fn: start_fn}
      )

    # Start a Poller pointing at the anonymous scheduler above.
    {:ok, _poller} =
      start_supervised(
        {Poller, repos: [repo], poll_interval_ms: 60_000, list_fn: list_fn, scheduler: scheduler}
      )

    # Verify the full poll -> claim -> worker-start path fires.
    assert_receive {:assigned, ^repo, ^issue_number}, 1_000
    assert_receive {:label_swapped, ^repo, ^issue_number}, 1_000
    assert_receive {:worker_started, %WorkEvent{repo: ^repo, number: ^issue_number}}, 1_000

    assert Process.alive?(scheduler)
  end
end
