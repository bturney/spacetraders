defmodule SpaceTraders.API.RateLimiterTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.RateLimiter

  # The game's budget: 3 req/s sustained, burst 10.
  @rate 3.0
  @burst 10

  defp start_limiter do
    name = :"rate_limiter_#{System.unique_integer([:positive])}"
    {:ok, pid} = RateLimiter.start_link(name: name, rate: @rate, burst: @burst)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  test "disabled limiter is a no-op (acquire returns immediately)" do
    assert RateLimiter.acquire(:does_not_exist) == :ok
  end

  test "burst: a full bucket lets @burst requests through immediately" do
    name = start_limiter()

    {time, :ok} =
      :timer.tc(fn ->
        Enum.map(1..@burst, fn _ ->
          Task.async(fn -> RateLimiter.acquire(name) end)
        end)
        |> Enum.each(&Task.await/1)
      end)

    assert time < 500_000, "expected burst under 500ms, took #{div(time, 1000)}ms"
  end

  test "sustained: after draining the bucket, requests refill at the rate" do
    name = start_limiter()

    # Drain the burst.
    Enum.each(1..@burst, fn _ -> RateLimiter.acquire(name) end)

    # Three more tokens should take ~1 second (3 req/s).
    {time, :ok} =
      :timer.tc(fn ->
        Enum.each(1..3, fn _ -> RateLimiter.acquire(name) end)
      end)

    elapsed_ms = div(time, 1000)
    assert elapsed_ms >= 800, "expected ~1s for 3 tokens at 3 rps, got #{elapsed_ms}ms"
    assert elapsed_ms <= 3_000, "took too long: #{elapsed_ms}ms"
  end

  test "never grants more than the sustained rate over a window" do
    name = start_limiter()

    # Consume 13 tokens (burst 10 + 3 refilled) and assert total elapsed >= 1s.
    {time, :ok} =
      :timer.tc(fn ->
        Enum.each(1..13, fn _ -> RateLimiter.acquire(name) end)
      end)

    elapsed_ms = div(time, 1000)
    assert elapsed_ms >= 800, "13 tokens at 3 rps should take >= 1s, got #{elapsed_ms}ms"
  end
end
