defmodule SpaceTraders.API.ShadowAdmission do
  @moduledoc """
  Compares hypothetical API Capacity Governor decisions without controlling traffic.

  Callers provide immutable demand, capacity, and evidence snapshots. The result
  is deterministic and explains the ordering applied before capacity and outage
  pacing are considered.
  """

  use GenServer
  require Logger

  defmodule Candidate do
    @moduledoc "A read or mutation considered by shadow API capacity admission."
    @enforce_keys [:id, :operation_id]
    defstruct [
      :id,
      :operation_id,
      lane: :standard,
      deadline_at: nil,
      strategic_priority: nil,
      expected_value: nil,
      discovery: false
    ]
  end

  defmodule Snapshot do
    @moduledoc "An immutable API capacity and evidence snapshot used for comparison."
    @enforce_keys [
      :observed_at,
      :available_slots,
      :evidence_fingerprint,
      :next_outage_probe_at,
      :backpressure
    ]
    defstruct @enforce_keys
  end

  defmodule Decision do
    @moduledoc false
    @enforce_keys [
      :candidate_id,
      :operation_id,
      :rank,
      :disposition,
      :reason,
      :ordering,
      :observed_at,
      :available_slots,
      :next_outage_probe_at,
      :backpressure,
      :evidence_fingerprint,
      :fingerprint
    ]
    defstruct @enforce_keys
  end

  @lane_rank %{safety: 0, reconciliation: 1, standard: 2}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Asynchronously records a production request for shadow comparison."
  def observe_request(operation, attrs \\ %{}, name \\ __MODULE__) when is_map(attrs) do
    correlation_id = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    attrs = Map.merge(logger_admission_context(), attrs)

    GenServer.cast(
      name,
      {:request, correlation_id, operation, attrs, DateTime.utc_now(), monotonic_ms()}
    )

    correlation_id
  end

  @doc "Asynchronously records when a production request reaches network dispatch."
  def observe_dispatch(correlation_id, name \\ __MODULE__) do
    GenServer.cast(name, {:dispatch, correlation_id, DateTime.utc_now(), monotonic_ms()})
  end

  @doc "Asynchronously correlates the final production outcome to its shadow decision."
  def observe_outcome(correlation_id, status, outcome, name \\ __MODULE__) do
    GenServer.cast(
      name,
      {:outcome, correlation_id, status, outcome, DateTime.utc_now(), monotonic_ms()}
    )
  end

  @doc "Returns explained shadow decisions in deterministic admission order."
  def compare(candidates, %Snapshot{} = snapshot) when is_list(candidates) do
    candidates
    |> Enum.sort_by(&ordering_key/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {demand, rank} -> decision(demand, snapshot, rank) end)
  end

  @doc "Returns the current governed capacity snapshot for Fleet reconciliation."
  def snapshot(name \\ __MODULE__), do: GenServer.call(name, :snapshot)

  @impl true
  def init(opts) do
    config = Application.get_env(:spacetraders, SpaceTraders.API.RateLimiter, [])
    burst = Keyword.get(opts, :burst, Keyword.get(config, :burst, 10))
    rate = Keyword.get(opts, :rate, Keyword.get(config, :rate, 3.0))

    {:ok,
     %{
       tokens: burst * 1.0,
       burst: burst,
       rate: rate,
       last_refill: monotonic_ms(),
       outage_streak: 0,
       next_outage_probe_at: nil,
       backpressure_streak: 0,
       requests: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = DateTime.utc_now()

    {:reply,
     %Snapshot{
       observed_at: now,
       available_slots: floor(state.tokens),
       evidence_fingerprint: "runtime",
       next_outage_probe_at: state.next_outage_probe_at,
       backpressure: if(state.backpressure_streak >= 2, do: :sustained, else: :none)
     }, state}
  end

  @impl true
  def handle_cast({:request, correlation_id, operation, attrs, requested_at, requested_ms}, state) do
    state = refill(state, requested_ms)
    backpressure = if state.backpressure_streak >= 2, do: :sustained, else: :none

    candidate = %Candidate{
      id: correlation_id,
      operation_id: operation.id,
      lane: Map.get(attrs, :lane, operation_lane(operation)),
      deadline_at: Map.get(attrs, :deadline_at),
      strategic_priority: Map.get(attrs, :strategic_priority),
      expected_value: Map.get(attrs, :expected_value),
      discovery: Map.get(attrs, :discovery, false)
    }

    snapshot = %Snapshot{
      observed_at: requested_at,
      available_slots: floor(state.tokens),
      evidence_fingerprint: Map.get(attrs, :evidence_fingerprint, "unavailable"),
      next_outage_probe_at: state.next_outage_probe_at,
      backpressure: backpressure
    }

    request = %{
      requested_at: requested_at,
      requested_ms: requested_ms,
      dispatched_at: nil,
      dispatched_ms: nil,
      operation: operation,
      candidate: candidate,
      decision: nil
    }

    requests = Map.put(state.requests, correlation_id, request)

    pending_candidates =
      requests
      |> Map.values()
      |> Enum.filter(&is_nil(&1.dispatched_at))
      |> Enum.map(& &1.candidate)

    decisions = compare(pending_candidates, snapshot)
    decision = Enum.find(decisions, &(&1.candidate_id == correlation_id))

    requests =
      Enum.reduce(decisions, requests, fn current_decision, acc ->
        Map.update!(acc, current_decision.candidate_id, &%{&1 | decision: current_decision})
      end)

    Enum.each(decisions, fn current_decision ->
      emit_admission(Map.fetch!(requests, current_decision.candidate_id), current_decision)
    end)

    backpressure_streak =
      if decision.disposition == :would_delay,
        do: state.backpressure_streak + 1,
        else: 0

    state = %{
      state
      | backpressure_streak: backpressure_streak,
        requests: requests
    }

    {:noreply, state}
  end

  def handle_cast({:dispatch, correlation_id, dispatched_at, dispatched_ms}, state) do
    state = refill(state, dispatched_ms)

    requests =
      Map.update!(state.requests, correlation_id, fn request ->
        %{request | dispatched_at: dispatched_at, dispatched_ms: dispatched_ms}
      end)

    {:noreply, %{state | tokens: max(state.tokens - 1, 0.0), requests: requests}}
  end

  def handle_cast({:outcome, correlation_id, status, outcome, completed_at, completed_ms}, state) do
    case Map.pop(state.requests, correlation_id) do
      {nil, _requests} ->
        {:noreply, update_pressure(state, status, completed_at)}

      {request, requests} ->
        dispatched_ms = request.dispatched_ms || completed_ms

        measurements = %{
          count: 1,
          queue_time: max(dispatched_ms - request.requested_ms, 0),
          request_time: max(completed_ms - dispatched_ms, 0)
        }

        metadata = %{
          correlation_id: correlation_id,
          shadow_fingerprint: request.decision.fingerprint,
          shadow_disposition: request.decision.disposition,
          status: status,
          outcome: outcome,
          requested_at: request.requested_at,
          dispatched_at: request.dispatched_at,
          completed_at: completed_at
        }

        :telemetry.execute([:spacetraders, :api, :capacity, :actual], measurements, metadata)

        Logger.info(
          "Shadow API capacity actual outcome",
          Map.to_list(Map.merge(metadata, measurements))
        )

        state = %{state | requests: requests} |> update_pressure(status, completed_at)
        {:noreply, state}
    end
  end

  defp decision(candidate, snapshot, rank) do
    pacing? = outage_pacing?(snapshot)
    available_slots = Map.fetch!(snapshot, :available_slots)
    disposition = if not pacing? and rank <= available_slots, do: :would_admit, else: :would_delay
    reason = if pacing?, do: :outage_pacing, else: capacity_reason(disposition)
    ordering = ordering(candidate)

    attributes = %{
      candidate_id: candidate.id,
      operation_id: candidate.operation_id,
      rank: rank,
      disposition: disposition,
      reason: reason,
      ordering: ordering,
      observed_at: Map.fetch!(snapshot, :observed_at),
      available_slots: available_slots,
      next_outage_probe_at: Map.fetch!(snapshot, :next_outage_probe_at),
      backpressure: Map.fetch!(snapshot, :backpressure),
      evidence_fingerprint: Map.fetch!(snapshot, :evidence_fingerprint)
    }

    struct!(Decision, Map.put(attributes, :fingerprint, fingerprint(attributes)))
  end

  defp emit_admission(request, decision) do
    metadata = %{
      correlation_id: request.candidate.id,
      operation_id: request.operation.id,
      classification: request.operation.classification,
      owner: request.operation.owner,
      rank: decision.rank,
      disposition: decision.disposition,
      reason: decision.reason,
      lane: request.candidate.lane,
      backpressure: decision.backpressure,
      ordering: decision.ordering,
      available_slots: decision.available_slots,
      next_outage_probe_at: decision.next_outage_probe_at,
      fingerprint: decision.fingerprint,
      evidence_fingerprint: decision.evidence_fingerprint,
      requested_at: request.requested_at,
      observed_at: decision.observed_at
    }

    :telemetry.execute([:spacetraders, :api, :capacity, :admission], %{count: 1}, metadata)
    Logger.info("Shadow API capacity admission", Map.to_list(metadata))
  end

  @doc false
  def ordering_key(%Candidate{} = candidate) do
    [
      Map.fetch!(@lane_rank, candidate.lane),
      datetime_key(candidate.deadline_at),
      candidate.strategic_priority || :infinity,
      descending_number(candidate.expected_value),
      not candidate.discovery,
      to_string(candidate.id)
    ]
  end

  defp ordering(%Candidate{} = candidate) do
    [
      lane: candidate.lane,
      deadline_at: candidate.deadline_at,
      strategic_priority: candidate.strategic_priority,
      expected_value: candidate.expected_value,
      discovery: candidate.discovery
    ]
  end

  defp outage_pacing?(%{next_outage_probe_at: nil}), do: false

  defp outage_pacing?(snapshot) do
    DateTime.before?(
      Map.fetch!(snapshot, :observed_at),
      Map.fetch!(snapshot, :next_outage_probe_at)
    )
  end

  defp capacity_reason(:would_admit), do: :capacity_available
  defp capacity_reason(:would_delay), do: :backpressure

  defp datetime_key(nil), do: :infinity
  defp datetime_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp descending_number(nil), do: :infinity
  defp descending_number(value) when is_number(value), do: -value

  defp fingerprint(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp operation_lane(%{owner: :fleet_reconciliation}), do: :reconciliation
  defp operation_lane(_operation), do: :standard

  defp logger_admission_context do
    Logger.metadata()
    |> Map.new()
    |> Map.take([
      :lane,
      :deadline_at,
      :strategic_priority,
      :expected_value,
      :discovery,
      :evidence_fingerprint
    ])
  end

  defp refill(%{rate: rate} = state, now) when rate > 0 do
    elapsed_seconds = max(now - state.last_refill, 0) / 1000

    %{
      state
      | tokens: min(state.burst * 1.0, state.tokens + elapsed_seconds * rate),
        last_refill: now
    }
  end

  defp refill(state, now), do: %{state | last_refill: now}

  defp update_pressure(state, status, _completed_at) when status == 429 do
    %{state | backpressure_streak: state.backpressure_streak + 1}
  end

  defp update_pressure(state, status, completed_at)
       when status == :unknown or status in 500..599 do
    outage_streak = state.outage_streak + 1
    delay_seconds = min(trunc(:math.pow(2, outage_streak - 1)), 60)

    %{
      state
      | outage_streak: outage_streak,
        next_outage_probe_at: DateTime.add(completed_at, delay_seconds, :second)
    }
  end

  defp update_pressure(state, _status, _completed_at) do
    %{state | outage_streak: 0, next_outage_probe_at: nil, backpressure_streak: 0}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
