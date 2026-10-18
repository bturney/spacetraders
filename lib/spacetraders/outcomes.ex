defmodule SpaceTraders.Outcomes do
  @moduledoc """
  One fail-soft worker for all outcome metrics from retained authoritative facts.

  The Agent's credits and committed Earnings records publish in this mailbox; `emit_earnings/1` is the one emitter of earnings metrics. Fleet
  status DB projections share its 2000 ms event-coalescing window. Gameplay only
  enqueues facts or post-commit notifications; it never waits for the worker.
  Scrapes collect coherent metric bytes here, then the HTTP request process sends
  its own response. No Plug.Conn or adapter callback enters this process.
  """

  use GenServer

  require Logger

  alias SpaceTraders.Evidence.Observation

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The read only enqueues already-retained facts. No database access, polling,
  # or wait on the exporter is introduced into gameplay.
  def observe(%Observation{} = observation) do
    if Process.whereis(__MODULE__),
      do: GenServer.cast(__MODULE__, {:observe, observation}),
      else: log_failure(observation)

    :ok
  end

  @doc false
  def metrics(prom_ex_module) do
    GenServer.call(__MODULE__, {:metrics, prom_ex_module})
  catch
    :exit, _reason -> :prom_ex_down
  end

  @impl true
  def init(opts) do
    :ok = SpaceTraders.Outcomes.PostCommit.attach(self())
    projections =
      if Keyword.get(
           opts,
           :db_projections,
           Application.get_env(:spacetraders, :outcome_db_projections_enabled, true)
         ) do
        SpaceTraders.Outcomes.Fleet.init(opts)
      end

    {:ok,
     %{
       credit: nil,
       started_at: SpaceTraders.Clock.utc_now(),
       projections: projections
     }}
  end

  @impl true
  def handle_call({:metrics, prom_ex_module}, _from, state) do
    # Every metric publication shares this mailbox. Return bytes only; adapter
    # functions must stay in the request process that owns the HTTP stream.
    {:reply, PromEx.get_metrics(prom_ex_module), state}
  end

  @impl true
  def handle_info(_message, %{projections: nil} = state), do: {:noreply, state}

  def handle_info({:dirty, change}, state) do
    {:noreply,
     %{state | projections: SpaceTraders.Outcomes.Fleet.dirty(change, state.projections)}}
  end

  def handle_info(:recompute, state) do
    {:noreply, %{state | projections: SpaceTraders.Outcomes.Fleet.recompute(state.projections)}}
  end

  @impl true
  def terminate(_reason, _state), do: SpaceTraders.Outcomes.PostCommit.detach()

  @impl true
  def handle_cast({:observe, observation}, state) do
    # Historical replay after restart is not a newly acquired observation.
    # This process deliberately waits for two post-start acquisitions.
    if DateTime.compare(observation.observed_at, state.started_at) == :lt,
      do: {:noreply, state},
      else: {:noreply, emit(observation, state)}
  rescue
    _error ->
      log_failure(observation)
      {:noreply, state}
  catch
    _kind, _reason ->
      log_failure(observation)
      {:noreply, state}
  end

  def handle_cast({:earnings, record}, state) do
    emit_earnings(record)
    SpaceTraders.MissionControl.Channels.broadcast_earnings()
    {:noreply, state}
  rescue
    _error ->
      log_failure(%{operation_id: "earnings_record"})
      {:noreply, state}
  catch
    _kind, _reason ->
      log_failure(%{operation_id: "earnings_record"})
      {:noreply, state}
  end

  # The one place earnings metrics are emitted: once per committed record,
  # labelled by bounded values only. Ship and route go in the Loki line.
  defp emit_earnings(record) do
    labels = %{
      source: record.source,
      ship_type: record.ship_type,
      good: record.good,
      price_age: SpaceTraders.Outcomes.Earnings.price_age_bucket(record.price_age_seconds)
    }

    flows =
      [
        revenue: record.revenue,
        goods: record.goods_cost,
        fuel: record.fuel_cost,
        other: record.other_cost,
        expected: record.expected_value
      ]

    for {flow, credits} <- flows, is_integer(credits) and credits > 0 do
      :telemetry.execute(
        [:earnings, :credits],
        %{credits: credits},
        Map.put(labels, :flow, Atom.to_string(flow))
      )
    end

    result =
      if is_integer(record.expected_value) and record.net_earnings < record.expected_value,
        do: "missed",
        else: "beat"

    :telemetry.execute([:earnings, :trips], %{count: 1}, Map.put(labels, :result, result))
    :telemetry.execute([:earnings, :ship_seconds], %{seconds: record.ship_seconds}, labels)

    Logger.info("Earnings record",
      ship_symbol: record.ship_symbol,
      route: "#{record.source_waypoint}->#{record.destination_waypoint}",
      earnings: %{
        id: record.id,
        source: record.source,
        ship_type: record.ship_type,
        good: record.good,
        units: record.units,
        jettisoned_units: record.jettisoned_units,
        revenue: record.revenue,
        goods_cost: record.goods_cost,
        fuel_cost: record.fuel_cost,
        other_cost: record.other_cost,
        net_earnings: record.net_earnings,
        expected_value: record.expected_value,
        price_age_seconds: record.price_age_seconds,
        ship_seconds: record.ship_seconds,
        result: result
      }
    )
  end

  defp log_failure(observation) do
    Logger.error("Outcome metric emission failed; dropping observation",
      operation_id: observation.operation_id
    )
  end

  defp emit(%Observation{operation_id: "get-my-agent", facts: facts} = observation, state) do
    %{"credits" => credits} = facts["response"]
    true = is_integer(credits) and credits >= 0
    identity = {observation.agent_id, observation.fleet_generation_id}

    current = %{
      id: observation.id,
      identity: identity,
      credits: credits,
      fingerprint: observation.response_fingerprint,
      observed_at: observation.observed_at
    }

    last = state.credit

    cond do
      last &&
          (current.id == last.id || DateTime.compare(current.observed_at, last.observed_at) == :lt) ->
        state

      last && current.identity == last.identity &&
        current.fingerprint == last.fingerprint &&
          DateTime.compare(current.observed_at, last.observed_at) == :eq ->
        state

      true ->
        :telemetry.execute([:agent, :credits], %{credits: credits}, %{})
        %{state | credit: current}
    end
  end

  defp emit(_observation, state), do: state


end
