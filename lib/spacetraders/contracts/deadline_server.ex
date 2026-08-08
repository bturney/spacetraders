defmodule SpaceTraders.Contracts.DeadlineServer do
  @moduledoc "Owns one contract deadline timer backed by the persisted Timeline."

  use GenServer

  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  def start_link(contract_id) do
    GenServer.start_link(__MODULE__, contract_id,
      name: {:via, Registry, {SpaceTraders.Contracts.Registry, contract_id}}
    )
  end

  @doc "Ensures a deadline owner is running for a contract."
  def ensure_started(contract_id) do
    case Registry.lookup(SpaceTraders.Contracts.Registry, contract_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          SpaceTraders.Contracts.Supervisor,
          {__MODULE__, contract_id}
        )
    end
  end

  @doc "Terminates every deadline owner. Used by tests between cases."
  def stop_all do
    SpaceTraders.Contracts.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(SpaceTraders.Contracts.Supervisor, pid)

      _ ->
        :ok
    end)

    :ok
  end

  @impl true
  def init(contract_id) do
    state = %{contract_id: contract_id, event: nil}

    case Timeline.pending_events(:contract, contract_id) do
      [event | _] -> {:ok, arm(event, state)}
      [] -> {:stop, :no_pending_deadline}
    end
  end

  @impl true
  def handle_info({:timeline, %Event{} = event}, state) do
    Timeline.fire_event(event)
    {:stop, :normal, %{state | event: nil}}
  end

  defp arm(%Event{} = event, state) do
    delay = max(DateTime.diff(event.due_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), {:timeline, event}, delay)
    %{state | event: event}
  end
end
