defmodule SpaceTraders.API.CapacityGovernor do
  @moduledoc """
  Admission gate for governed API reads and mutations, and the one publisher
  of global API capacity.

  The raw rate limiter protects the protocol budget. This module protects the
  application budget by ordering waiting work by safety, reconciliation, and
  then ordinary demand before handing it to the raw limiter. Fleet planning and
  allocation consume the published `Snapshot` under ADR-0010; the governor
  alone owns API policy — callers never tune it or infer capacity state for
  themselves.

  `Retry-After` reported by the raw transport delays new *ordinary*
  admissions until the window closes. Safety, reconciliation, and
  deadline-critical work is never delayed by the gate; a small, measured
  protocol-rejection rate is acceptable calibration ground truth, so the gate
  stays partially open on purpose.

  Admission is deliberately process-local: recovery starts from fresh callers
  and does not replay queued work selected against stale state. On restart the
  governor re-enters a conservative admitted capacity that widens only as
  clean responses prove the protocol is healthy.
  """

  use GenServer
  require Logger

  alias SpaceTraders.API.OperationInventory.Operation
  alias SpaceTraders.API.ShadowAdmission
  alias SpaceTraders.API.ShadowAdmission.Candidate
  alias SpaceTraders.Clock

  defmodule Admission do
    @moduledoc "A production API admission held until the request completes."
    @enforce_keys [:id, :operation_id, :lane, :requested_at]
    defstruct @enforce_keys
  end

  defmodule Snapshot do
    @moduledoc """
    An immutable API capacity snapshot consumed by Fleet Planning and Fleet
    Allocation. Point-in-time view of the governor's admission state; the
    governor owns API policy so consumers never take it from elsewhere.
    """

    @enforce_keys [
      :observed_at,
      :available_slots,
      :evidence_fingerprint,
      :backpressure
    ]

    defstruct @enforce_keys ++
                [
                  next_outage_probe_at: nil,
                  ordinary_delayed_until: nil,
                  admitted_capacity: nil,
                  protocol_rejections: 0
                ]
  end

  @restart_capacity 2
  @rejection_window_ms 60_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The durable global API capacity snapshot for Fleet evidence."
  def snapshot(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> nil
      _pid -> GenServer.call(name, :snapshot)
    end
  end

  @doc "Waits until the request is admitted, returning its completion identity."
  @spec admit(Operation.t(), map(), GenServer.server()) :: {:ok, Admission.t() | nil}
  def admit(%Operation{} = operation, attrs \\ %{}, name \\ __MODULE__) when is_map(attrs) do
    case Process.whereis(name) do
      nil -> {:ok, nil}
      _pid -> GenServer.call(name, {:admit, operation, attrs}, :infinity)
    end
  end

  @doc "Releases an admission and reports the request outcome to the governor."
  def complete(admission, status, name \\ __MODULE__)

  def complete(nil, _status, _name), do: :ok

  def complete(%Admission{id: id}, status, name) do
    if Process.whereis(name), do: GenServer.cast(name, {:complete, id, status}), else: :ok
  end

  @doc """
  Reports a protocol-limit rejection observed by the raw transport — including
  ones transparently retried there — and the `Retry-After` delay when one was
  supplied.
  """
  def protocol_rejected(retry_after_seconds, name \\ __MODULE__)
      when is_integer(retry_after_seconds) do
    if Process.whereis(name), do: GenServer.cast(name, {:protocol_rejected, retry_after_seconds})
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:spacetraders, __MODULE__, [])

    max_in_flight = Keyword.get(opts, :max_in_flight, Keyword.get(config, :max_in_flight, 10))

    restart_capacity =
      Keyword.get(
        opts,
        :restart_capacity,
        Keyword.get(config, :restart_capacity, @restart_capacity)
      )

    {:ok,
     %{
       max_in_flight: max_in_flight,
       admitted_capacity: min(restart_capacity, max_in_flight),
       in_flight: %{},
       queue: [],
       sequence: 0,
       backpressure_streak: 0,
       rejection_window: [],
       first_rejection_at: nil,
       ordinary_delayed_until: nil,
       outage_streak: 0,
       next_outage_probe_at: nil
     }}
  end

  @impl true
  def handle_call({:admit, operation, attrs}, from, state) do
    request = %{
      from: from,
      operation: operation,
      attrs: attrs,
      id: Integer.to_string(state.sequence + 1),
      requested_at: DateTime.utc_now(),
      requested_ms: monotonic_ms(),
      sequence: state.sequence + 1
    }

    state
    |> Map.update!(:queue, &[request | &1])
    |> Map.put(:sequence, request.sequence)
    |> dispatch()
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %Snapshot{
       observed_at: Clock.utc_now(),
       available_slots: max(state.admitted_capacity - map_size(state.in_flight), 0),
       evidence_fingerprint: "runtime",
       next_outage_probe_at: state.next_outage_probe_at,
       backpressure: backpressure_state(state.backpressure_streak),
       ordinary_delayed_until: state.ordinary_delayed_until,
       admitted_capacity: state.admitted_capacity,
       protocol_rejections: recent_rejections(state)
     }, state}
  end

  @impl true
  def handle_cast({:complete, id, status}, state) do
    state =
      case Map.pop(state.in_flight, id) do
        {nil, _in_flight} -> state
        {_request, in_flight} -> %{state | in_flight: in_flight}
      end

    {:noreply, dispatch(record_outcome(state, status))}
  end

  def handle_cast({:protocol_rejected, retry_after_seconds}, state) do
    state =
      state
      |> note_rejection(retry_after_seconds)
      |> schedule_ordinary_release()

    {:noreply, dispatch(state)}
  end

  @impl true
  def handle_info(:ordinary_window_expired, state) do
    now = DateTime.utc_now()

    ordinary_delayed_until =
      case state.ordinary_delayed_until do
        nil -> nil
        until -> if DateTime.after?(until, now), do: until, else: nil
      end

    {:noreply, dispatch(%{state | ordinary_delayed_until: ordinary_delayed_until})}
  end

  defp record_outcome(state, status)
       when status in 200..299 or (status in 400..499 and status != 429) do
    if state.backpressure_streak > 0 do
      :telemetry.execute(
        [:spacetraders, :api, :capacity, :recovered],
        %{count: 1},
        %{
          recovery_ms: monotonic_ms() - state.first_rejection_at,
          rejected_before: length(state.rejection_window)
        }
      )

      Logger.info("API capacity recovered from protocol backpressure",
        rejected_before: length(state.rejection_window)
      )
    end

    %{
      state
      | backpressure_streak: 0,
        rejection_window: [],
        first_rejection_at: nil,
        admitted_capacity: min(state.admitted_capacity + 1, state.max_in_flight),
        outage_streak: 0,
        next_outage_probe_at: nil
    }
  end

  # Every transport-level protocol rejection is reported through
  # protocol_rejected/2 (transparent retries included), so a 429 reaching
  # completion here is not counted a second time.
  defp record_outcome(state, 429), do: state

  defp record_outcome(state, status) when status in 500..599 or status == :unknown do
    outage_streak = state.outage_streak + 1
    probe_delay_seconds = min(trunc(:math.pow(2, outage_streak - 1)), 60)

    %{
      state
      | admitted_capacity: min(@restart_capacity, state.max_in_flight),
        outage_streak: outage_streak,
        next_outage_probe_at: DateTime.add(DateTime.utc_now(), probe_delay_seconds, :second)
    }
  end

  defp record_outcome(state, _status), do: state

  defp note_rejection(state, retry_after_seconds) do
    now_ms = monotonic_ms()
    rejection_window = [now_ms | state.rejection_window]
    ordinary_delayed_until = delayed_until(retry_after_seconds, state.ordinary_delayed_until)

    :telemetry.execute(
      [:spacetraders, :api, :capacity, :reject],
      %{count: 1, protocol_rejections: recent_rejection_count(rejection_window)},
      %{
        retry_after_seconds: retry_after_seconds,
        ordinary_delayed: not is_nil(ordinary_delayed_until)
      }
    )

    Logger.info(
      "API capacity protocol rejection",
      retry_after_seconds: retry_after_seconds,
      protocol_rejections: recent_rejection_count(rejection_window)
    )

    %{
      state
      | backpressure_streak: state.backpressure_streak + 1,
        rejection_window: rejection_window,
        first_rejection_at: state.first_rejection_at || now_ms,
        admitted_capacity: max(state.admitted_capacity - 1, 1),
        ordinary_delayed_until: ordinary_delayed_until
    }
  end

  defp schedule_ordinary_release(%{ordinary_delayed_until: nil} = state), do: state

  defp schedule_ordinary_release(%{ordinary_delayed_until: until, queue: queue} = state) do
    if Enum.any?(queue, &ordinary_request?/1) do
      ms = max(DateTime.diff(until, DateTime.utc_now(), :millisecond), 0)
      Process.send_after(self(), :ordinary_window_expired, ms + 1)
    end

    state
  end

  defp dispatch(state) do
    available = state.admitted_capacity - map_size(state.in_flight)

    if available > 0 and state.queue != [] do
      {eligible, delayed} = partition_delayed(state.queue, state.ordinary_delayed_until)

      case eligible do
        [] ->
          # Ordinary demand still waits out the Retry-After window; kept in
          # queue without resorting eligible work ahead of it.
          state

        _ ->
          dispatch_selected(%{state | queue: eligible}, available)
          |> then(fn dispatched -> %{dispatched | queue: dispatched.queue ++ delayed} end)
      end
    else
      state
    end
  end

  defp dispatch_selected(state, available) do
    {selected, remaining} = take_best(state.queue, available)
    now = monotonic_ms()

    Enum.each(selected, fn request ->
      admission = %Admission{
        id: request.id,
        operation_id: request.operation.id,
        lane: lane(request),
        requested_at: request.requested_at
      }

      :telemetry.execute(
        [:spacetraders, :api, :capacity, :governor],
        %{count: 1, queue_time: max(now - request.requested_ms, 0)},
        %{
          operation_id: request.operation.id,
          lane: admission.lane,
          backpressure: backpressure_state(state.backpressure_streak),
          ordinary_delayed_until: state.ordinary_delayed_until
        }
      )

      GenServer.reply(request.from, {:ok, admission})
    end)

    in_flight =
      Enum.reduce(selected, state.in_flight, fn request, acc ->
        Map.put(acc, request.id, request)
      end)

    %{state | queue: remaining, in_flight: in_flight}
  end

  defp partition_delayed(queue, nil), do: {queue, []}

  defp partition_delayed(queue, until) do
    Enum.split_with(queue, &eligible_now?(&1, until))
  end

  defp eligible_now?(request, until) do
    bypasses_ordinary_delay?(request) or not DateTime.before?(DateTime.utc_now(), until)
  end

  defp bypasses_ordinary_delay?(%{operation: %{owner: :fleet_reconciliation}}), do: true

  defp bypasses_ordinary_delay?(%{attrs: %{lane: lane}}) when is_atom(lane) and lane != :standard,
    do: true

  defp bypasses_ordinary_delay?(%{attrs: %{deadline_at: %DateTime{}}}), do: true

  defp bypasses_ordinary_delay?(_request), do: false

  defp ordinary_request?(request), do: not bypasses_ordinary_delay?(request)

  defp take_best(queue, count) do
    queue = Enum.sort_by(queue, &ordering_key/1)
    Enum.split(queue, count)
  end

  defp ordering_key(request) do
    attrs = request.attrs

    ShadowAdmission.ordering_key(%Candidate{
      id: request.id,
      operation_id: request.operation.id,
      lane: lane(request),
      deadline_at: Map.get(attrs, :deadline_at),
      strategic_priority: Map.get(attrs, :strategic_priority),
      expected_value: Map.get(attrs, :expected_value),
      discovery: Map.get(attrs, :discovery, false)
    })
  end

  defp lane(%{attrs: %{lane: lane}}) when is_atom(lane), do: lane
  defp lane(%{operation: %{owner: :fleet_reconciliation}}), do: :reconciliation

  defp lane(_request), do: :standard

  @doc "Protocol backpressure state for a streak of recent 429 rejections."
  def backpressure_state(streak) when streak >= 2, do: :sustained
  def backpressure_state(1), do: :transient
  def backpressure_state(_streak), do: :none

  defp recent_rejections(state) do
    recent_rejection_count(state.rejection_window)
  end

  defp recent_rejection_count(rejection_window) do
    cutoff = monotonic_ms() - @rejection_window_ms

    Enum.count(rejection_window, &(&1 >= cutoff))
  end

  defp delayed_until(seconds, _current) when is_integer(seconds) and seconds > 0,
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp delayed_until(_seconds, current), do: current

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
