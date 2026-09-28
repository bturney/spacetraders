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

  @type t :: %__MODULE__{
          tokens: float(),
          burst: non_neg_integer(),
          rate: float(),
          pool_tokens: float(),
          pool_burst: non_neg_integer(),
          pool_rate: float(),
          last_refill: integer()
        }

  defstruct tokens: 0,
            burst: 0,
            rate: 0.0,
            pool_tokens: 0,
            pool_burst: 0,
            pool_rate: 0.0,
            last_refill: 0

  @doc "Starts the limiter. Options: `:name`, `:rate`, `:burst`, `:pool_rate`, `:pool_burst`."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Waits until a token is available, then consumes one and returns `:ok`.

  Returns immediately when no limiter process is running under `name` (the
  disabled-in-test behaviour).
  """
  @spec acquire(GenServer.server()) :: :ok
  def acquire(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> acquire_from(pid)
    end
  end

  defp acquire_from(pid) do
    case GenServer.call(pid, :acquire, :infinity) do
      :ok ->
        :ok

      {:wait, ms} ->
        Process.sleep(ms)
        acquire_from(pid)
    end
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:spacetraders, __MODULE__, [])
    rate = Keyword.get(opts, :rate, Keyword.get(config, :rate, 2.0))
    burst = Keyword.get(opts, :burst, Keyword.get(config, :burst, 2))
    pool_rate = Keyword.get(opts, :pool_rate, Keyword.get(config, :pool_rate, 0.5))
    pool_burst = Keyword.get(opts, :pool_burst, Keyword.get(config, :pool_burst, 30))

    {:ok,
     %__MODULE__{
       tokens: burst * 1.0,
       burst: burst,
       rate: rate,
       pool_tokens: pool_burst * 1.0,
       pool_burst: pool_burst,
       pool_rate: pool_rate,
       last_refill: now()
     }}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    state = refill(state)

    cond do
      state.tokens >= 1 ->
        {:reply, :ok, %{state | tokens: state.tokens - 1}}

      state.pool_tokens >= 1 ->
        {:reply, :ok, %{state | pool_tokens: state.pool_tokens - 1}}

      true ->
        {:reply, {:wait, wait_ms(state)}, state}
    end
  end

  defp refill(%__MODULE__{} = state) do
    now = now()
    elapsed_sec = (now - state.last_refill) / 1000

    %{
      state
      | tokens: min(state.burst, state.tokens + elapsed_sec * state.rate),
        pool_tokens: min(state.pool_burst, state.pool_tokens + elapsed_sec * state.pool_rate),
        last_refill: now
    }
  end

  defp wait_ms(%__MODULE__{tokens: tokens, rate: rate}), do: ceil((1 - tokens) / rate * 1000)

  defp now, do: System.monotonic_time(:millisecond)
end
