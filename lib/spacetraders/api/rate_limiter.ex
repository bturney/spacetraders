defmodule SpaceTraders.API.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter guarding the SpaceTraders API client.

  Budget: `rate` tokens per second sustained, burst up to `burst` tokens.
  Defaults come from app config (see `config/config.exs`): 3 req/s, burst 10.

  `acquire/0` blocks the caller until a token is available, so the client never
  exceeds the sustained rate; the burst allows short, fast sequences (e.g. a
  dashboard refresh) without serialising them.

  In test env the limiter is disabled by config (`enabled: false`), so the app
  does not start it and `acquire/1` becomes a no-op — API tests are not
  throttled. The limiter's own tests start an instance under a custom name and
  assert the real 3 rps / burst-10 budget.
  """

  use GenServer

  @type t :: %__MODULE__{
          tokens: float(),
          burst: non_neg_integer(),
          rate: float(),
          last_refill: integer()
        }

  defstruct tokens: 0, burst: 0, rate: 0.0, last_refill: 0

  @doc "Starts the limiter. Options: `:name`, `:rate`, `:burst` (config-backed defaults)."
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
    rate = Keyword.get(opts, :rate, Keyword.get(config, :rate, 3.0))
    burst = Keyword.get(opts, :burst, Keyword.get(config, :burst, 10))

    {:ok, %__MODULE__{tokens: burst, burst: burst, rate: rate, last_refill: now()}}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    state = refill(state)

    if state.tokens >= 1 do
      {:reply, :ok, %{state | tokens: state.tokens - 1}}
    else
      {:reply, {:wait, wait_ms(state)}, state}
    end
  end

  defp refill(%__MODULE__{} = state) do
    now = now()
    elapsed_sec = (now - state.last_refill) / 1000

    %{
      state
      | tokens: min(state.burst, state.tokens + elapsed_sec * state.rate),
        last_refill: now
    }
  end

  defp wait_ms(%__MODULE__{tokens: tokens, rate: rate}) do
    ceil((1 - tokens) / rate * 1000)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
