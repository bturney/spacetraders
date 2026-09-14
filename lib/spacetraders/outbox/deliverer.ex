defmodule SpaceTraders.Outbox.Deliverer do
  @moduledoc false

  use GenServer

  @interval_ms 1_000

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(options, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    send(self(), :dispatch)
    {:ok, nil}
  end

  @impl true
  def handle_info(:dispatch, state) do
    if SpaceTraders.RuntimeAuthority.execution_allowed?() == :ok do
      SpaceTraders.Outbox.dispatch_pending()
    end

    Process.send_after(self(), :dispatch, @interval_ms)
    {:noreply, state}
  end
end
