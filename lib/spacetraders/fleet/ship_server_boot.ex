defmodule SpaceTraders.Fleet.ShipServerBoot do
  @moduledoc """
  Re-arms ship servers when the app boots.

  A one-shot GenServer: on init it asks `SpaceTraders.Fleet.Intents.rearm_on_boot/0`
  to start a ship server for every ship with a pending timeline event. Each
  server then re-arms its own timers and catches up any events that came due
  while the app was down (ADR 0005). It stops normally once done, so it is not
  restarted by the supervisor.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    SpaceTraders.Fleet.Intents.rearm_on_boot()
    :ignore
  end
end
