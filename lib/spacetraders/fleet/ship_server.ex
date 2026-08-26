defmodule SpaceTraders.Fleet.ShipServer do
  @moduledoc """
  Owns one ship's async timers (arrival, cooldown) in memory.

  The game's waiting is modeled per-entity (ADR 0005): each ship has a GenServer
  that owns its `Process.send_after` timers, backed by persisted `timeline_events`
  rows so a restart re-arms it. On init the server re-arms every pending event —
  future events get a timer, events already due are caught up immediately. When a
  timer fires the ship re-pulls its real state from the game API (the server is
  the source of truth), marks the event done, and broadcasts so dashboards can
  refresh. A failed re-pull keeps the event pending and retries.

  The server also answers `ensure_ready/1`: while an arrival or cooldown is
  pending the ship is busy and further actions are refused, so the app never
  blind-clicks an in-transit ship.
  """

  use GenServer
  require Logger

  alias SpaceTraders.API.Model.{Cooldown, Ship, ShipNav}
  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  @retry_delay_ms 30_000

  @doc "Starts a ship server (registered under `SpaceTraders.Fleet.ShipRegistry`)."
  def start_link(opts) do
    symbol = Keyword.fetch!(opts, :symbol)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {SpaceTraders.Fleet.ShipRegistry, symbol}}
    )
  end

  @doc """
  Ensures a ship server is running, starting one under the ship supervisor.

  A running server is reused as-is; its stored agent token is the one the server
  was started with (on boot, resolved from the database).
  """
  @spec ensure_started(Agent.t(), String.t()) :: {:ok, pid()}
  def ensure_started(%Agent{} = agent, ship_symbol) do
    ensure_started(ship_symbol, agent.id, agent.agent_token)
  end

  @doc "Ensures a ship server is running with an explicit agent id + token."
  @spec ensure_started(String.t(), non_neg_integer(), String.t() | nil) :: {:ok, pid()}
  def ensure_started(ship_symbol, agent_id, agent_token) do
    case Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship_symbol) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          SpaceTraders.Fleet.ShipSupervisor,
          {__MODULE__, symbol: ship_symbol, agent_id: agent_id, agent_token: agent_token}
        )
    end
  end

  @doc "Stops the running server for one ship, if any."
  @spec stop(String.t()) :: :ok
  def stop(ship_symbol) do
    case Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship_symbol) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SpaceTraders.Fleet.ShipSupervisor, pid)
      [] -> :ok
    end
  end

  @doc """
  Returns `:ok` when the ship is ready to act, or an error while it is busy.

  `:ok` when no server is running (the game API remains the backstop).
  """
  @spec ensure_ready(String.t()) :: :ok | {:error, :ship_in_transit | :cooldown_active}
  def ensure_ready(ship_symbol) do
    case Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship_symbol) do
      [{pid, _}] -> GenServer.call(pid, :ensure_ready, 5_000)
      [] -> :ok
    end
  end

  @doc "Clears locally pending timers after an Operator preempts a Miner Job."
  def cancel_pending(ship_symbol) do
    case Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship_symbol) do
      [{pid, _}] -> GenServer.call(pid, :cancel_pending, 5_000)
      [] -> :ok
    end
  end

  @doc "Arms a timer for an already-persisted event on the ship's server."
  @spec arm(Agent.t(), String.t(), Event.t()) :: :ok | {:error, term()}
  def arm(%Agent{} = agent, ship_symbol, %Event{} = event) do
    with {:ok, pid} <- ensure_started(agent, ship_symbol) do
      GenServer.cast(pid, {:arm, event})
      :ok
    end
  end

  @doc "Terminates every running ship server. Used by tests between cases."
  @spec stop_all() :: :ok
  def stop_all do
    SpaceTraders.Fleet.ShipSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(SpaceTraders.Fleet.ShipSupervisor, pid)

      _ ->
        :ok
    end)

    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      symbol: Keyword.fetch!(opts, :symbol),
      agent_id: Keyword.fetch!(opts, :agent_id),
      agent_token: Keyword.fetch!(opts, :agent_token),
      pending: %{}
    }

    state =
      Enum.reduce(Timeline.pending_events(:ship, state.symbol), state, &rearm/2)

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_ready, _from, state) do
    {:reply, ready_reply(state), state}
  end

  @impl true
  def handle_call(:cancel_pending, _from, state) do
    {:reply, :ok, %{state | pending: %{}}}
  end

  @impl true
  def handle_cast({:arm, %Event{} = event}, state) do
    {:noreply, rearm(event, state)}
  end

  @impl true
  def handle_info({:timeline, %Event{} = event}, state) do
    type = String.to_existing_atom(event.event_type)

    if not Timeline.pending?(event) do
      {:noreply, drop_pending_event(state, type, event)}
    else
      handle_pending_event(type, event, state)
    end
  end

  defp handle_pending_event(type, event, state) do
    case refresh(state) do
      {:ok, ship} ->
        if still_busy?(type, ship) do
          retry(event, state, "ship is still #{busy_label(type)} after #{type}")
        else
          Timeline.fire_event(event)
          state = drop_pending_event(state, type, event)

          case type do
            :arrival ->
              SpaceTraders.Fleet.revalidate_miner_job_arrival(
                state.agent_id,
                state.symbol,
                ship,
                event.payload["job_id"]
              )

              SpaceTraders.Fleet.revalidate_manual_intent_arrival(
                state.agent_id,
                state.symbol,
                ship,
                event.payload["intent_id"]
              )

            :cooldown ->
              SpaceTraders.Fleet.revalidate_miner_job_cooldown(
                state.agent_id,
                state.symbol,
                ship,
                event.payload["job_id"]
              )

              SpaceTraders.Fleet.revalidate_manual_intent_cooldown(
                state.agent_id,
                state.symbol,
                ship,
                event.payload["intent_id"]
              )

            _ ->
              :ok
          end

          Phoenix.PubSub.broadcast(
            SpaceTraders.PubSub,
            "fleet:#{state.agent_id}",
            {:ship_updated, state.agent_id, state.symbol}
          )

          {:noreply, state}
        end

      {:error, reason} ->
        retry(event, state, "refresh after #{type} failed (#{inspect(reason)})")
    end
  end

  defp ready_reply(%{pending: pending}) do
    cond do
      Map.has_key?(pending, :arrival) -> {:error, :ship_in_transit}
      Map.has_key?(pending, :cooldown) -> {:error, :cooldown_active}
      true -> :ok
    end
  end

  defp retry(event, state, reason) do
    Logger.warning("ship #{state.symbol}: #{reason}; retrying in #{@retry_delay_ms}ms")
    Process.send_after(self(), {:timeline, event}, @retry_delay_ms)
    {:noreply, state}
  end

  # An arrival is only done once the game reports the ship out of transit, and a
  # cooldown only once it no longer reports time remaining — clock skew between
  # the game server and this app must not unblock a ship the game still says is
  # busy.
  defp still_busy?(:arrival, %Ship{nav: %ShipNav{status: "IN_TRANSIT"}}), do: true

  defp still_busy?(:cooldown, %Ship{cooldown: %Cooldown{remaining_seconds: seconds}})
       when is_integer(seconds) and seconds > 0,
       do: true

  defp still_busy?(_type, _ship), do: false

  defp busy_label(:arrival), do: "in transit"
  defp busy_label(:cooldown), do: "on cooldown"

  # Arms one persisted event: an immediate catch-up message when already due,
  # otherwise a `Process.send_after` timer. Records the type as pending. Re-arming
  # the same event id is a no-op, so a cast that races a just-started
  # server's init (which re-arms from the same row) does not double the timer.
  defp rearm(%Event{} = event, state) do
    type = String.to_existing_atom(event.event_type)

    if match?(%{id: id} when id == event.id, Map.get(state.pending, type)) do
      state
    else
      delay_ms =
        if Timeline.due?(event) do
          0
        else
          DateTime.diff(event.due_at, DateTime.utc_now(), :millisecond)
        end

      if delay_ms == 0 do
        Process.send(self(), {:timeline, event}, [])
      else
        Process.send_after(self(), {:timeline, event}, delay_ms)
      end

      pending_event = %{id: event.id, due_at: event.due_at}
      %{state | pending: Map.put(state.pending, type, pending_event)}
    end
  end

  defp drop_pending_event(state, type, event) do
    case Map.get(state.pending, type) do
      %{id: id} when id == event.id -> %{state | pending: Map.delete(state.pending, type)}
      _ -> state
    end
  end

  # Re-pulls the ship's real state from the game. The result is not cached — the
  # dashboard reads the live fleet through the Fleet context; this call is what
  # confirms the event is genuinely done before the ship is unblocked.
  defp refresh(%{agent_token: agent_token, symbol: symbol})
       when is_binary(agent_token) and agent_token != "" do
    SpaceTraders.API.get_ship(agent_token, symbol)
  end

  defp refresh(_state), do: {:error, :agent_token_missing}
end
