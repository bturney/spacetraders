defmodule SpaceTraders.API.RateLimiterTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.RateLimiter

  # The game's granted budget: 2 requests per second plus a separate pool of
  # 30 requests per minute. Pool arithmetic: 30/60 = 0.5 tokens per second,
  # so sustained average throughput tops out at 2.0 + 0.5 = 2.5 req/s.
  @rate 2.0
  @burst 2
  @pool_rate 0.5
  @pool_burst 30

  defp start_limiter do
    name = :"rate_limiter_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      RateLimiter.start_link(
        name: name,
        rate: @rate,
        burst: @burst,
        pool_rate: @pool_rate,
        pool_burst: @pool_burst
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  test "configured sustained rate never exceeds the 2/s game grant" do
    rate = Application.get_env(:spacetraders, RateLimiter, []) |> Keyword.get(:rate)

    assert is_number(rate)
    assert rate <= 2.0
  end

  test "disabled limiter is a no-op (acquire returns immediately)" do
    assert RateLimiter.acquire(:does_not_exist) == :ok
  end

  test "burst: the steady grant plus drained overflow pool let many requests through immediately" do
    name = start_limiter()

    {time, :ok} =
      :timer.tc(fn ->
        Enum.map(1..@pool_burst, fn _ ->
          Task.async(fn -> RateLimiter.acquire(name) end)
        end)
        |> Enum.each(&Task.await/1)
      end)

    assert time < 500_000, "expected pool-sized burst under 500ms, took #{div(time, 1000)}ms"
  end

  test "steady: after draining both pools, requests refill at the 2/s grant" do
    name = start_limiter()

    # Drain the steady grant and the overflow pool.
    Enum.each(1..(@burst + @pool_burst), fn _ -> RateLimiter.acquire(name) end)

    # Two more tokens should take ~1 second (2 req/s).
    {time, :ok} =
      :timer.tc(fn ->
        Enum.each(1..2, fn _ -> RateLimiter.acquire(name) end)
      end)

    elapsed_ms = div(time, 1000)

    assert elapsed_ms >= 1000,
           "3 tokens past full drain should take >= ~1.5s at 2 rps, got #{elapsed_ms}ms"

    assert elapsed_ms <= 3_500, "took too long: #{elapsed_ms}ms"
  end

  test "never grants more than 2/s steady once both pools drain" do
    name = start_limiter()

    # Drain the steady grant and the whole overflow pool instantly.
    Enum.each(1..(@burst + @pool_burst), fn _ -> RateLimiter.acquire(name) end)

    # Three more tokens: two refill at 2 rps (~0.5s), the third waits for the
    # next steady token (~1s) because the overflow pool refills slower.
    {time, :ok} =
      :timer.tc(fn ->
        Enum.each(1..3, fn _ -> RateLimiter.acquire(name) end)
      end)

    elapsed_ms = div(time, 1000)

    assert elapsed_ms >= 700,
           "3 tokens past full drain should take >= ~1s at 2 rps, got #{elapsed_ms}ms"

    assert elapsed_ms <= 3_000, "took too long: #{elapsed_ms}ms"
  end
end
