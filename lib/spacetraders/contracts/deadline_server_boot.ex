defmodule SpaceTraders.Contracts.DeadlineServerBoot do
  @moduledoc "Re-arms persisted contract deadlines when the app boots."

  use GenServer

  alias SpaceTraders.Contracts

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Contracts.rearm_deadlines_on_boot()
    :ignore
  end
end
