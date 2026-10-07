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
    * `diagnostics/1` — bounded diagnostic projection for operators and tests;
      never a decision input.

  Owners supply ordering context; the governor interprets it. Recognized
  `purpose` (`:safety`, `:recovery`/`:reconciliation`, or `:deadline_critical`
  together with a genuine `deadline_at`) is protected; the legacy `:safety` and
  `:reconciliation` lanes remain recognized during migration. Arbitrary lane
  names or a timestamp alone confer no protection. Within a protection class,
  lower `strategic_priority` precedes higher, then earlier deadline, then
  higher numeric `expected_value`.

  Pressure is interpreted here, bounded, and never left to callers:

    * `Retry-After` defers ordinary work (honored up to 60 seconds). Protected
      work may send one immediate probe after a rejection; sustained rejection
      backs protected probes off exponentially, one in flight at a time.
    * A 5xx or transport failure paces only its own request family (operation)
      with bounded probes. Failures spanning several families with no clean
      response between them are a Fleet-wide outage: all work, protected work
      included, waits for one bounded probe at a time.
    * A caller that dies while queued or holding an admission releases its
      place; no outcome is recorded for it.

  Ordinary work progresses only when capacity and higher-priority demand
  permit; there is no unconditional liveness promise. Prolonged deferral is
  observable through `diagnostics/1`.

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

  defmodule Admission do
    @moduledoc "A production API admission held until the request completes."
    @enforce_keys [:id, :operation_id, :lane, :requested_at]
    defstruct @enforce_keys
  end

  defmodule Disposition do
    @moduledoc """
    Advisory capacity meaning: never a reservation, never gameplay authority.

    `reason` is one of `:capacity_available`, `:contention`, `:retry_after`,
    `:scoped_failure`, `:outage`, `:authority_unavailable`, or `:test_disabled`. `retry_at` is the governor's
    reconsideration guidance for `:defer` and `:unavailable`.
    """
    @enforce_keys [:status, :reason, :observed_at]
    defstruct @enforce_keys ++ [retry_at: nil]

    @type t :: %__MODULE__{
            status: :proceed | :defer | :unavailable,
            reason:
              :capacity_available
              | :contention
              | :retry_after
              | :scoped_failure
              | :outage
              | :authority_unavailable
              | :test_disabled,
            observed_at: DateTime.t(),
            retry_at: DateTime.t() | nil
          }
  end

  defmodule Diagnostics do
    @moduledoc """
    Bounded diagnostic projection of the governor's state for operators and
    tests. It explains pressure and prolonged deferral; it is not a decision
    interface: work asks `SpaceTraders.API.CapacityGovernor.disposition/3`.

    `deferred` maps each waiting protection class to its queued count and the
    longest wait so far in seconds. `outage` is the next Fleet-wide probe time,
    and `scoped_failures` the request families currently paced on their own.
    """

    @enforce_keys [:observed_at, :admitted_capacity, :in_flight, :deferred, :backpressure]
    defstruct @enforce_keys ++
                [
                  protocol_rejections: 0,
                  retry_after_until: nil,
                  outage: nil,
                  scoped_failures: []
                ]
  end

  @restart_capacity 2
  @probe_base_ms 1_000
  @probe_max_ms 60_000
  @outage_families 2
  @max_retry_after_seconds 60
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

  @doc "Bounded diagnostic projection; `nil` without a governor. Never a decision input."
  def diagnostics(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> nil
      _pid -> GenServer.call(name, :diagnostics)
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
       pressure_probe_at: nil,
       failures: %{},
       failing_families: MapSet.new(),
       outage: nil,
       probe_base_ms: setting(opts, config, :probe_base_ms, @probe_base_ms),
       probe_max_ms: setting(opts, config, :probe_max_ms, @probe_max_ms),
       now: Keyword.get(opts, :now, &DateTime.utc_now/0)
     }}
  end

  defp setting(opts, config, key, default),
    do: Keyword.get(opts, key, Keyword.get(config, key, default))

  @impl true
  def handle_call({:disposition, operation, attrs}, _from, state) do
    {:reply, interpret(%{operation: operation, attrs: attrs}, state), state}
  end

  # Each caller is monitored: one that dies while queued or holding an
  # admission releases its place without any outcome being recorded.
  def handle_call({:admit, operation, attrs}, {caller, _tag} = from, state) do
    request = %{
      from: from,
      monitor: Process.monitor(caller),
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

  def handle_call(:diagnostics, _from, state) do
    now = now(state)

    deferred =
      state.queue
      |> Enum.group_by(&protection/1)
      |> Map.new(fn {class, requests} ->
        oldest = Enum.min_by(requests, & &1.requested_at, DateTime)

        {class,
         %{count: length(requests), longest_seconds: DateTime.diff(now, oldest.requested_at)}}
      end)

    {:reply,
     %Diagnostics{
       observed_at: now,
       admitted_capacity: state.admitted_capacity,
       in_flight: map_size(state.in_flight),
       deferred: deferred,
       backpressure: backpressure_state(state.backpressure_streak),
       protocol_rejections: recent_rejections(state),
       retry_after_until: state.ordinary_delayed_until,
       outage: state.outage && state.outage.probe_at,
       scoped_failures: state.failures |> Map.keys() |> Enum.sort()
     }, state}
  end

  @impl true
  def handle_cast({:complete, id, status}, state) do
    case Map.pop(state.in_flight, id) do
      {nil, _in_flight} ->
        {:noreply, state}

      {request, in_flight} ->
        Process.demonitor(request.monitor, [:flush])
        {:noreply, dispatch(record_outcome(%{state | in_flight: in_flight}, request, status))}
    end
  end

  def handle_cast({:protocol_rejected, retry_after_seconds}, state) do
    state =
      state
      |> note_rejection(retry_after_seconds)
      |> schedule_reconsideration()

    {:noreply, dispatch(state)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state) do
    abandoned? = &(&1.monitor == monitor)

    {:noreply,
     dispatch(%{
       state
       | queue: Enum.reject(state.queue, abandoned?),
         in_flight: Map.reject(state.in_flight, fn {_id, request} -> abandoned?.(request) end)
     })}
  end

  def handle_info(:reconsider, state) do
    now = now(state)

    ordinary_delayed_until =
      case state.ordinary_delayed_until do
        nil -> nil
        until -> if DateTime.after?(until, now), do: until, else: nil
      end

    {:noreply, dispatch(%{state | ordinary_delayed_until: ordinary_delayed_until})}
  end

  defp record_outcome(state, request, status)
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
        pressure_probe_at: nil,
        admitted_capacity: min(state.admitted_capacity + 1, state.max_in_flight),
        failures: Map.delete(state.failures, request.operation.id),
        failing_families: MapSet.new(),
        outage: nil
    }
  end

  # Every transport-level protocol rejection is reported through
  # protocol_rejected/2 (transparent retries included), so a 429 reaching
  # completion here is not counted a second time.
  defp record_outcome(state, _request, 429), do: state

  # A failure paces only its own request family. Failures spanning several
  # families with no clean response between them are a Fleet-wide outage:
  # everything, protected work included, waits for one bounded probe at a time.
  defp record_outcome(state, request, status) when status in 500..599 or status == :unknown do
    family = request.operation.id
    streak = get_in(state.failures, [family, :streak]) || 0
    failure = %{streak: streak + 1, probe_at: probe_at(state, streak + 1)}
    families = MapSet.put(state.failing_families, family)

    state = %{
      state
      | failures: Map.put(state.failures, family, failure),
        failing_families: families
    }

    if MapSet.size(families) >= @outage_families do
      streak = if state.outage, do: state.outage.streak + 1, else: 1

      %{
        state
        | admitted_capacity: min(@restart_capacity, state.max_in_flight),
          outage: %{streak: streak, probe_at: probe_at(state, streak)}
      }
    else
      state
    end
  end

  # Not dispatched or abandoned: no protocol evidence either way.
  defp record_outcome(state, _request, _status), do: state

  # Protocol pressure: the first rejection allows one immediate probe; sustained
  # rejection backs probes off, never past the server's own Retry-After.
  defp pressure_probe_at(state, streak, retry_after_seconds) do
    backoff_ms = if streak == 1, do: 0, else: backoff_ms(state, streak - 1)

    delay_ms =
      if is_integer(retry_after_seconds) and retry_after_seconds > 0,
        do: min(backoff_ms, retry_after_seconds * 1000),
        else: backoff_ms

    DateTime.add(now(state), delay_ms, :millisecond)
  end

  defp backoff_ms(state, streak),
    do: min(state.probe_base_ms * Integer.pow(2, streak - 1), state.probe_max_ms)

  defp probe_at(state, streak) do
    DateTime.add(now(state), backoff_ms(state, streak), :millisecond)
  end

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

    streak = state.backpressure_streak + 1

    %{
      state
      | backpressure_streak: streak,
        pressure_probe_at: pressure_probe_at(state, streak, retry_after_seconds),
        rejection_window: rejection_window,
        first_rejection_at: state.first_rejection_at || now_ms,
        admitted_capacity: max(state.admitted_capacity - 1, 1),
        ordinary_delayed_until: ordinary_delayed_until
    }
  end

  # Admits the best eligible request one at a time: each admission can change
  # what the policy allows next (a probe in flight, contention).
  defp dispatch(state) do
    state.queue
    |> Enum.sort_by(&ordering_key/1)
    |> Enum.find(&(interpret(&1, state).status == :proceed))
    |> case do
      # Deferred demand stays queued. Demand that arrives after a window
      # opened needs its own reconsideration, or it would wait for a timer
      # that already fired.
      nil -> schedule_reconsideration(state)
      request -> state |> admit_request(request) |> dispatch()
    end
  end

  defp admit_request(state, request) do
    admission = %Admission{
      id: request.id,
      operation_id: request.operation.id,
      lane: protection(request),
      requested_at: request.requested_at
    }

    :telemetry.execute(
      [:spacetraders, :api, :capacity, :governor],
      %{count: 1, queue_time: max(monotonic_ms() - request.requested_ms, 0)},
      %{
        operation_id: request.operation.id,
        lane: admission.lane,
        backpressure: backpressure_state(state.backpressure_streak),
        ordinary_delayed_until: state.ordinary_delayed_until
      }
    )

    GenServer.reply(request.from, {:ok, admission})
    in_flight = Map.put(request, :probe, probe_kind(request, state))

    %{
      state
      | queue: List.delete(state.queue, request),
        in_flight: Map.put(state.in_flight, request.id, in_flight)
    }
  end

  # Under outage, an admitted request is the probe that tests recovery.
  defp probe_kind(_request, %{outage: %{}}), do: :outage

  defp probe_kind(request, state) do
    cond do
      Map.has_key?(state.failures, request.operation.id) -> {:scoped, request.operation.id}
      state.backpressure_streak > 0 -> :protocol
      true -> nil
    end
  end

  defp probe_in_flight?(state, kind),
    do: Enum.any?(state.in_flight, fn {_id, request} -> request.probe == kind end)

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

  # The one policy both advisory disposition and live dispatch apply.
  defp interpret(request, state) do
    observed_at = now(state)

    {reason, retry_at} =
      cond do
        state.outage &&
            (probe_in_flight?(state, :outage) or future?(state.outage.probe_at, observed_at)) ->
          {:outage,
           later(
             state.outage.probe_at,
             DateTime.add(observed_at, @reconsider_seconds, :second),
             observed_at
           )}

        scoped_failure_pending?(request, state, observed_at) ->
          failure = Map.fetch!(state.failures, request.operation.id)

          {:scoped_failure,
           later(
             failure.probe_at,
             DateTime.add(observed_at, @reconsider_seconds, :second),
             observed_at
           )}

        protection(request) == :standard and future?(state.ordinary_delayed_until, observed_at) ->
          {:retry_after, state.ordinary_delayed_until}

        state.backpressure_streak > 0 and
            (probe_in_flight?(state, :protocol) or future?(state.pressure_probe_at, observed_at)) ->
          {:retry_after,
           later(
             state.pressure_probe_at,
             DateTime.add(observed_at, @reconsider_seconds, :second),
             observed_at
           )}

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

  defp scoped_failure_pending?(request, state, now) do
    family = request.operation.id

    case state.failures do
      %{^family => failure} ->
        probe_in_flight?(state, {:scoped, family}) or future?(failure.probe_at, now)

      _ ->
        false
    end
  end

  # Reconsideration guidance: the probe time while it is ahead, else a short
  # reconsideration while a probe is out.
  defp later(probe_at, fallback, now),
    do: if(future?(probe_at, now), do: probe_at, else: fallback)

  defp future?(nil, _now), do: false
  defp future?(until, now), do: DateTime.after?(until, now)

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

  @doc """
  The protection class the governor recognizes for work: `:safety`,
  `:reconciliation`, `:deadline_critical`, or `:standard`. Shared explanatory
  meaning for diagnostics and shadow review; it grants no admission.
  """
  def protection_class(%Operation{} = operation, attrs) when is_map(attrs),
    do: protection(%{operation: operation, attrs: attrs})

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

  # The server's Retry-After is honored up to a bound, so one extreme header
  # cannot strand ordinary work beyond the governor's own probe horizon.
  defp delayed_until(seconds, current, state) when is_integer(seconds) and seconds > 0 do
    proposed = DateTime.add(now(state), min(seconds, @max_retry_after_seconds), :second)
    if future?(current, proposed), do: current, else: proposed
  end

  defp delayed_until(_seconds, current, _state), do: current

  defp now(state), do: state.now.()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
