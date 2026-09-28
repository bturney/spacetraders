defmodule SpaceTraders.Evidence.DemandScheduler do
  @moduledoc """
  One durable scheduler over persisted Observation Demands.

  Boot and every demand change reconstruct the single earliest due wakeup from
  durable state, so process timer memory is never correctness state and a
  restart never loses due work. A wakeup selects due demands and rearms; it
  never acquires evidence itself — waking Strategy reconciliation is the
  consumer's decision. Work deferred by API backpressure stays open and is
  retried on a bounded wakeup interval; the durable demand, not the timer,
  carries the requirement.

  Each armed wake carries a generation token. A demand change arms a new token
  without being able to cancel the previous timer, so only the currently armed
  wake is effective and stale or duplicate wake messages are ignored — the
  earliest due instant can move without producing early or duplicate broadcasts.
  """

  use GenServer

  alias SpaceTraders.{Clock, Evidence}

  @topic "observation_demands"
  @deferred_wake_ms 30_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, @topic)

    {:ok, arm(%{wake_at: nil, wake_token: 0})}
  end

  @impl true
  def handle_info({:wake, token}, %{wake_token: token} = state) do
    wake_due(state)
  end

  # A stale wake from a superseded arm: the earliest due instant moved after
  # this timer was scheduled. Ignore it; the currently armed wake is effective.
  def handle_info({:wake, _stale_token}, state) do
    {:noreply, state}
  end

  def handle_info({:observation_demands_changed, _agent_id}, state) do
    {:noreply, arm(%{state | wake_at: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp wake_due(state) do
    now = Clock.utc_now()

    # Durable missed-deadline limitation: open demands whose optional deadline
    # passed get their historical marker before any due broadcast rearms the
    # schedule. They stay open and late evidence may still fulfil them.
    {:ok, _marked} = Evidence.mark_missed_deadlines(now)

    now
    |> Evidence.due_demands()
    |> Enum.group_by(& &1.agent_id)
    |> Enum.each(fn {agent_id, demands} ->
      subjects = Enum.map(demands, & &1.subject)

      Phoenix.PubSub.broadcast(
        SpaceTraders.PubSub,
        @topic,
        {:observation_demand_due, agent_id, subjects}
      )
    end)

    # Due work that could not be admitted yet stays open; retry on a bounded
    # wakeup interval instead of spinning on a due time already in the past.
    case Evidence.earliest_due_at() do
      nil ->
        {:noreply, %{state | wake_at: nil}}

      earliest ->
        if due_in_future?(earliest, now) do
          {:noreply, arm(%{state | wake_at: nil})}
        else
          token = state.wake_token + 1
          wake_at = DateTime.add(now, @deferred_wake_ms, :millisecond)
          Clock.send_at(self(), {:wake, token}, wake_at)
          {:noreply, %{state | wake_at: wake_at, wake_token: token}}
        end
    end
  end

  # Reconstructs the one earliest due wakeup from durable state. A wakeup that
  # is already armed for the same instant keeps its token; anything else arms a
  # new token, so the previously scheduled timer becomes stale and inert.
  defp arm(%{wake_at: wake_at} = state) do
    case Evidence.earliest_due_at() do
      nil ->
        %{state | wake_at: nil}

      %DateTime{} = earliest ->
        if wake_at && DateTime.compare(wake_at, earliest) == :eq do
          state
        else
          token = state.wake_token + 1
          Clock.send_at(self(), {:wake, token}, earliest)
          %{state | wake_at: earliest, wake_token: token}
        end
    end
  end

  defp due_in_future?(earliest, now), do: DateTime.compare(earliest, now) == :gt
end
