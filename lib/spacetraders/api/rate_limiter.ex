defmodule SpaceTraders.API.RateLimiter do
  @moduledoc """
  Dual-pool token-bucket limiter guarding the SpaceTraders API client.

  The game grants two requests per second, plus a separate pool of 30 requests
  per minute that can burst through in a shorter period. Modelled as:

    * a steady pool: `rate` tokens per second (default 2.0), burst 2 — the
      per-second grant;
    * an overflow pool: `pool_rate` = 30/60 = 0.5 tokens per second capped at
      `pool_burst` = 30 — the per-minute grant, drained when the steady pool
      is exhausted.

  Sustained average throughput therefore tops out at 2.5 req/s (2 + 0.5) and
  never exceeds 2 req/s steady except by draining the finite overflow pool.
  `acquire/0` blocks the caller until a token is available, preferring the
  steady pool and falling back to the overflow pool only when the steady pool
  is empty.

  429 retry with Retry-After is a safety net only — calibration targets
  maximum safe useful throughput through this limiter and the capacity
  governor, not zero rejections.

  In test env the limiter is disabled by config (`enabled: false`), so the app
  does not start it and `acquire/1` becomes a no-op — API tests are not
  throttled. The limiter's own tests start an instance under a custom name and
  assert the real 2 rps / 30-per-minute budget.
  """

  use GenServer
  alias SpaceTraders.API.ScarcityClock
  alias SpaceTraders.Simulation.{NavigationClock, NavigationParticipant}

  @type t :: %__MODULE__{
          tokens: float(),
          burst: non_neg_integer(),
          rate: float(),
          pool_tokens: float(),
          pool_burst: non_neg_integer(),
          pool_rate: float(),
          last_refill: integer(),
          clock: %{now: (-> integer()), sleep: (non_neg_integer() -> term())}
        }

  defstruct tokens: 0,
            burst: 0,
            rate: 0.0,
            pool_tokens: 0,
            pool_burst: 0,
            pool_rate: 0.0,
            last_refill: 0,
            clock: nil,
            release: nil

  @doc "Starts the limiter. Options: `:name`, `:rate`, `:burst`, `:pool_rate`, `:pool_burst`, and a `:clock` with monotonic-millisecond `now/0` and `sleep/1` callbacks."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Waits until a token is available, then consumes one and returns `:ok`.

  Only explicit `enabled: false` configuration disables this gate. Missing
  enabled authority fails closed, including startup and restart races.
  """
  @spec acquire(GenServer.server()) :: :ok | {:error, :capacity_unavailable}
  def acquire(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> missing()
      pid -> acquire_from(pid)
    end
  end

  @doc "Consumes one protocol token, or returns its semantic release without blocking the owner."
  def try_acquire(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> missing()
      pid -> GenServer.call(pid, :try_acquire)
    end
  catch
    :exit, _ -> {:error, :capacity_unavailable}
  end

  defp missing do
    if Application.get_env(:spacetraders, __MODULE__, [])[:enabled] == false,
      do: :ok,
      else: {:error, :capacity_unavailable}
  end

  defp acquire_from(pid) do
    case GenServer.call(pid, :acquire, :infinity) do
      :ok ->
        :ok

      {:wait, ms, sleep} ->
        sleep.(ms)
        acquire_from(pid)

      {:error, :capacity_unavailable} = error ->
        error
    end
  catch
    :exit, _ -> {:error, :capacity_unavailable}
  end

  @impl true
  def init(opts) do
    if NavigationClock.enabled?(), do: NavigationClock.register(self(), __MODULE__)
    config = Application.get_env(:spacetraders, __MODULE__, [])
    rate = Keyword.get(opts, :rate, Keyword.get(config, :rate, 2.0))
    burst = Keyword.get(opts, :burst, Keyword.get(config, :burst, 2))
    pool_rate = Keyword.get(opts, :pool_rate, Keyword.get(config, :pool_rate, 0.5))
    pool_burst = Keyword.get(opts, :pool_burst, Keyword.get(config, :pool_burst, 30))

    clock =
      Keyword.get(opts, :clock, %{
        now: &refill_now/0,
        sleep: &Process.sleep/1
      })

    {:ok,
     %__MODULE__{
       tokens: burst * 1.0,
       burst: burst,
       rate: rate,
       pool_tokens: pool_burst * 1.0,
       pool_burst: pool_burst,
       pool_rate: pool_rate,
       last_refill: clock.now.(),
       clock: clock
     }}
  end

  @impl true
  def handle_call(:simulation_barrier, _from, state),
    do: {:reply, %{unresolved: 0, release_at: state.release && elem(state.release, 2)}, state}

  def handle_call(message, from, state),
    do: NavigationParticipant.work(fn -> handle_protocol_call(message, from, state) end)

  defp handle_protocol_call(message, _from, state) when message in [:acquire, :try_acquire] do
    state = refill(state)

    cond do
      state.tokens >= 1 ->
        {:reply, :ok, %{state | tokens: state.tokens - 1}}

      state.pool_tokens >= 1 ->
        {:reply, :ok, %{state | pool_tokens: state.pool_tokens - 1}}

      true ->
        case wait_ms(state) do
          nil ->
            {:reply, {:error, :capacity_unavailable}, state}

          ms when message == :acquire ->
            {:reply, {:wait, ms, state.clock.sleep}, state}

          ms ->
            at = DateTime.add(ScarcityClock.utc_now(), ms, :millisecond)
            {:reply, {:defer, at}, schedule_release(state, at)}
        end
    end
  end

  @impl true
  def handle_info({:simulation_wake, reference, message}, state),
    do: NavigationClock.work(fn -> release(message, state) end, reference)

  def handle_info(message, state),
    do: NavigationParticipant.work(fn -> release(message, state) end)

  defp release({:protocol_release, token}, %{release: {_, token, _}} = state),
    do: {:noreply, refill(%{state | release: nil})}

  defp release({:protocol_release, _stale}, state), do: {:noreply, state}

  defp schedule_release(%{release: {_, _, at}} = state, at), do: state

  defp schedule_release(state, at) do
    if state.release, do: ScarcityClock.cancel_timer(elem(state.release, 0))
    token = make_ref()
    %{state | release: {ScarcityClock.send_at(self(), {:protocol_release, token}, at), token, at}}
  end

  defp refill(%__MODULE__{} = state) do
    now = state.clock.now.()
    elapsed_sec = max(now - state.last_refill, 0) / 1000

    %{
      state
      | tokens: min(state.burst, state.tokens + elapsed_sec * state.rate),
        pool_tokens: min(state.pool_burst, state.pool_tokens + elapsed_sec * state.pool_rate),
        last_refill: now
    }
  end

  defp wait_ms(state) do
    [
      {state.tokens, state.rate, state.burst},
      {state.pool_tokens, state.pool_rate, state.pool_burst}
    ]
    |> Enum.filter(fn {_, rate, burst} -> rate > 0 and burst >= 1 end)
    # Round only floating-point noise, not a real fractional millisecond.
    |> Enum.map(fn {tokens, rate, _} ->
      max(ceil(Float.round((1 - tokens) / rate * 1000, 9)), 1)
    end)
    |> Enum.min(fn -> nil end)
  end

  # Keep native pacing immune to wall-clock corrections. Controlled gameplay
  # uses the semantic clock instead; socket/DB timeouts are never routed here.
  defp refill_now do
    ScarcityClock.refill_ms()
  end
end
