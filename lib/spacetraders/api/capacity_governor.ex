defmodule SpaceTraders.API.CapacityGovernor do
  @moduledoc """
  Admission gate for governed API reads and mutations, and the one publisher
  of global API capacity.

  The raw rate limiter protects the protocol budget. This module protects the
  application budget by ordering waiting work before handing it to the raw
  limiter; the governor alone owns API policy — callers never tune it or infer
  capacity state for themselves.

  Three distinct surfaces:

    * `disposition/3` — advisory `Disposition` (proceed, defer with retry
      guidance, or unavailable). Point-in-time; reserves nothing.
    * `admit/3` — live admission immediately before transport. It applies the
      same policy as `disposition/3` against current state, so it may still
      wait after an earlier advisory proceed; the raw limiter then paces every
      admitted request.
    * `snapshot/1` — diagnostic projection. Legacy callers still read it while
      they migrate to `disposition/3`; it is not the decision interface.

  Owners supply ordering context; the governor interprets it. Recognized
  `purpose` (`:safety`, `:recovery`/`:reconciliation`, or `:deadline_critical`
  together with a genuine `deadline_at`) is protected; the legacy `:safety` and
  `:reconciliation` lanes remain recognized during migration. Arbitrary lane
  names or a timestamp alone confer no protection. Within a protection class,
  lower `strategic_priority` precedes higher, then earlier deadline, then
  higher numeric `expected_value`. `Retry-After` defers ordinary work only;
  protected work stays subject to raw protocol pacing.

  Missing governor authority fails closed: `admit/3` returns
  `{:error, :capacity_unavailable}` and `disposition/3` reports unavailable.
  Tests that intentionally bypass admission pass the `:test_disabled` server,
  which only builds with `:capacity_test_disabled_allowed` compiled in.

  Admission is deliberately process-local: recovery starts from fresh callers
  and does not replay queued work selected against stale state. On restart the
  governor re-enters a conservative admitted capacity that widens only as
  clean responses prove the protocol is healthy.
  """

  use GenServer
  require Logger

  alias SpaceTraders.API.OperationInventory.Operation
  alias SpaceTraders.Clock

  defmodule Admission do
    @moduledoc "A production API admission held until the request completes."
    @enforce_keys [:id, :operation_id, :lane, :requested_at]
    defstruct @enforce_keys
  end

  defmodule Disposition do
    @moduledoc """
    Advisory capacity meaning: never a reservation, never gameplay authority.

    `reason` is one of `:capacity_available`, `:contention`, `:retry_after`,
    `:authority_unavailable`, or `:test_disabled`. `retry_at` is the governor's
    reconsideration guidance for `:defer` and `:unavailable`.
    """
    @enforce_keys [:status, :reason, :observed_at]
    defstruct @enforce_keys ++ [retry_at: nil]

    @type t :: %__MODULE__{
            status: :proceed | :defer | :unavailable,
            reason: :capacity_available | :contention | :retry_after | :authority_unavailable,
            observed_at: DateTime.t(),
            retry_at: DateTime.t() | nil
          }
  end

  defmodule Snapshot do
    @moduledoc """
    Diagnostic projection of the governor's admission state. Legacy Fleet
    callers still read it during migration to `Disposition`; new decisions
    use `SpaceTraders.API.CapacityGovernor.disposition/3`.
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
  @reconsider_seconds 1
  @protection_rank %{safety: 0, reconciliation: 1, deadline_critical: 2, standard: 3}
  @test_disabled_allowed Application.compile_env(
                           :spacetraders,
                           :capacity_test_disabled_allowed,
                           false
                         )

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Diagnostic projection of global API capacity; `nil` without a governor."
  def snapshot(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> nil
      _pid -> GenServer.call(name, :snapshot)
    end
  end

  @doc "Advises whether work may approach live admission; reserves no capacity."
  @spec disposition(Operation.t(), map(), GenServer.server()) :: Disposition.t()
  def disposition(%Operation{} = operation, attrs \\ %{}, name \\ __MODULE__)
      when is_map(attrs) do
    case capacity_call(name, {:disposition, operation, attrs}) do
      {:error, :capacity_unavailable} ->
        unavailable()

      :test_disabled ->
        %Disposition{status: :proceed, reason: :test_disabled, observed_at: DateTime.utc_now()}

      %Disposition{} = disposition ->
        disposition
    end
  end

  @doc "Waits until the request is admitted, returning its completion identity."
  @spec admit(Operation.t(), map(), GenServer.server()) ::
          {:ok, Admission.t() | nil} | {:error, :capacity_unavailable}
  def admit(%Operation{} = operation, attrs \\ %{}, name \\ __MODULE__) when is_map(attrs) do
    case capacity_call(name, {:admit, operation, attrs}) do
      :test_disabled -> {:ok, nil}
      result -> result
    end
  end

  # The test-only bypass is a distinct, compile-time path; missing production
  # authority never borrows it. Calls racing governor shutdown fail closed.
  defp capacity_call(:test_disabled, _message) do
    if @test_disabled_allowed, do: :test_disabled, else: {:error, :capacity_unavailable}
  end

  defp capacity_call(name, message) do
    GenServer.call(name, message, :infinity)
  catch
    :exit, _reason -> {:error, :capacity_unavailable}
  end

  defp unavailable do
    now = DateTime.utc_now()

    %Disposition{
      status: :unavailable,
      reason: :authority_unavailable,
      observed_at: now,
      retry_at: DateTime.add(now, @reconsider_seconds, :second)
    }
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
       next_outage_probe_at: nil,
       now: Keyword.get(opts, :now, &DateTime.utc_now/0)
     }}
  end

  @impl true
  def handle_call({:disposition, operation, attrs}, _from, state) do
    {:reply, interpret(%{operation: operation, attrs: attrs}, state), state}
  end

  def handle_call({:admit, operation, attrs}, from, state) do
    request = %{
      from: from,
      operation: operation,
      attrs: attrs,
      id: Integer.to_string(state.sequence + 1),
      requested_at: now(state),
      requested_ms: monotonic_ms(),
      sequence: state.sequence + 1
    }

    state
    |> Map.update!(:queue, &[request | &1])
    |> Map.put(:sequence, request.sequence)
    |> dispatch()
    |> then(&{:noreply, &1})
  end

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
      |> schedule_reconsideration()

    {:noreply, dispatch(state)}
  end

  @impl true
  def handle_info(:reconsider, state) do
    now = now(state)

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
        next_outage_probe_at: DateTime.add(now(state), probe_delay_seconds, :second)
    }
  end

  defp record_outcome(state, _status), do: state

  defp note_rejection(state, retry_after_seconds) do
    now_ms = monotonic_ms()
    rejection_window = [now_ms | state.rejection_window]

    ordinary_delayed_until =
      delayed_until(retry_after_seconds, state.ordinary_delayed_until, state)

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

  defp dispatch(state) do
    available = state.admitted_capacity - map_size(state.in_flight)

    if available > 0 and state.queue != [] do
      {eligible, deferred} =
        Enum.split_with(state.queue, &(interpret(&1, state).status == :proceed))

      case eligible do
        # Deferred demand stays queued. Demand that arrives after a window
        # opened needs its own reconsideration, or it would wait for a timer
        # that already fired.
        [] ->
          schedule_reconsideration(state)

        _ ->
          dispatch_selected(%{state | queue: eligible}, available)
          |> then(fn dispatched -> %{dispatched | queue: dispatched.queue ++ deferred} end)
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
        lane: protection(request),
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

  defp schedule_reconsideration(state) do
    retry_at =
      state.queue
      |> Enum.map(&interpret(&1, state).retry_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

    if retry_at do
      ms = max(DateTime.diff(retry_at, now(state), :millisecond), 0)
      Process.send_after(self(), :reconsider, ms + 1)
    end

    state
  end

  # The one policy both advisory disposition and live dispatch apply. Outage
  # pacing currently narrows admitted capacity only; probe bounding is #588.
  defp interpret(request, state) do
    observed_at = now(state)

    {reason, retry_at} =
      cond do
        protection(request) == :standard and future?(state.ordinary_delayed_until, observed_at) ->
          {:retry_after, state.ordinary_delayed_until}

        map_size(state.in_flight) >= state.admitted_capacity ->
          {:contention, DateTime.add(observed_at, @reconsider_seconds, :second)}

        true ->
          {:capacity_available, nil}
      end

    %Disposition{
      status: if(is_nil(retry_at), do: :proceed, else: :defer),
      reason: reason,
      observed_at: observed_at,
      retry_at: retry_at
    }
  end

  defp future?(nil, _now), do: false
  defp future?(until, now), do: DateTime.after?(until, now)

  defp take_best(queue, count) do
    queue = Enum.sort_by(queue, &ordering_key/1)
    Enum.split(queue, count)
  end

  defp ordering_key(request) do
    attrs = request.attrs
    protection = protection(request)

    [
      Map.fetch!(@protection_rank, protection),
      Map.get(attrs, :strategic_priority) || :infinity,
      deadline_key(attrs),
      value_key(Map.get(attrs, :expected_value)),
      not Map.get(attrs, :discovery, false),
      request.sequence
    ]
  end

  defp deadline_key(%{deadline_at: %DateTime{} = deadline_at}),
    do: DateTime.to_unix(deadline_at, :microsecond)

  defp deadline_key(_attrs), do: :infinity

  defp value_key(value) when is_number(value), do: -value
  defp value_key(_value), do: :infinity

  # Protection is recognized from purpose, never from an arbitrary lane name
  # or the mere presence of a timestamp.
  defp protection(%{attrs: %{purpose: :safety}}), do: :safety

  defp protection(%{attrs: %{purpose: purpose}}) when purpose in [:recovery, :reconciliation],
    do: :reconciliation

  defp protection(%{attrs: %{purpose: :deadline_critical, deadline_at: %DateTime{}}}),
    do: :deadline_critical

  # Legacy lanes recognized during the expand phase.
  defp protection(%{attrs: %{lane: lane}}) when lane in [:safety, :reconciliation], do: lane
  defp protection(%{operation: %{owner: :fleet_reconciliation}}), do: :reconciliation
  defp protection(_request), do: :standard

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

  defp delayed_until(seconds, current, state) when is_integer(seconds) and seconds > 0 do
    proposed = DateTime.add(now(state), seconds, :second)
    if future?(current, proposed), do: current, else: proposed
  end

  defp delayed_until(_seconds, current, _state), do: current

  defp now(state), do: state.now.()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
