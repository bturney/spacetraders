defmodule SpaceTraders.Outbox.Deliverer do
  @moduledoc false

  use GenServer
  use SpaceTraders.Simulation.NavigationParticipant

  @interval_ms 1_000

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(options, :name, __MODULE__))
  end

  def init_participant(:ok) do
    send(self(), :dispatch)
    {:ok, nil}
  end

  def handle_participant_info(:dispatch, state) do
    if SpaceTraders.RuntimeAuthority.execution_allowed?() == :ok do
      SpaceTraders.Outbox.dispatch_pending()
    end

    SpaceTraders.Clock.send_after(self(), :dispatch, @interval_ms)
    {:noreply, state}
  end
end
