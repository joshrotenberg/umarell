defmodule Umarell.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    base_children = [
      Umarell.JobSupervisor,
      Umarell.Scheduler
    ]

    children =
      if Application.get_env(:umarell, :start_poller, true) do
        base_children ++ [Umarell.Intake.Poller]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: Umarell.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
