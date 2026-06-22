defmodule Umarell.JobSupervisor do
  @moduledoc """
  DynamicSupervisor that hosts `Job.Worker` processes.

  Started by `Umarell.Application` before the Scheduler so the Scheduler's
  default `start_fn` can always find this supervisor alive.
  """

  use DynamicSupervisor

  @doc """
  Starts the JobSupervisor as a linked process, registered under its module name.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
