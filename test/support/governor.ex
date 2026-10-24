defmodule SpaceTraders.Test.Governor do
  @moduledoc "Restores the application's Capacity Governor to its supervised default after a test configures it."

  @governor SpaceTraders.API.CapacityGovernor

  @doc "Restarts the application-supervised Capacity Governor with fresh state."
  @spec restart() :: {:ok, pid()}
  def restart do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, @governor)
    {:ok, _pid} = Supervisor.restart_child(SpaceTraders.Supervisor, @governor)
  end
end
