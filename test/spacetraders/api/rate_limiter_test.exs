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

  defp start_limiter(opts) do
    name = :"rate_limiter_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      RateLimiter.start_link(
        Keyword.merge(
          [
            name: name,
            rate: @rate,
            burst: @burst,
            pool_rate: @pool_rate,
            pool_burst: @pool_burst
          ],
          opts
        )
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
    {name, _time} = controlled_limiter()

    tasks =
      for _ <- 1..(@burst + @pool_burst), do: Task.async(fn -> RateLimiter.acquire(name) end)

    assert Enum.map(tasks, &Task.await/1) == List.duplicate(:ok, 32)
    refute_received {:waiting, _, _}
    extra = Task.async(fn -> RateLimiter.acquire(name) end)
    assert_receive {:waiting, pid, 500}
    assert pid == extra.pid
    Task.shutdown(extra, :brutal_kill)
  end

  test "steady: after draining both pools, requests refill at the 2/s grant" do
    {name, time} = controlled_limiter()
    owner = self()

    # Drain the steady grant and the overflow pool.
    Enum.each(1..(@burst + @pool_burst), fn _ -> RateLimiter.acquire(name) end)

    caller =
      Task.async(fn ->
        RateLimiter.acquire(name)
        send(owner, :first_grant)
        RateLimiter.acquire(name)
        :two_grants
      end)

    assert_receive {:waiting, pid, 500}
    assert pid == caller.pid
    Agent.update(time, fn _ -> 499 end)
    send(pid, :wake)
    assert_receive {:waiting, ^pid, _remaining_delay}
    refute_received :first_grant
    Agent.update(time, fn _ -> 500 end)
    send(pid, :wake)
    assert_receive :first_grant
    assert_receive {:waiting, ^pid, 500}
    Agent.update(time, fn _ -> 1000 end)
    send(pid, :wake)
    assert Task.await(caller) == :two_grants
  end

  test "never grants more than 2/s steady once both pools drain" do
    {name, time} = controlled_limiter()

    # Drain the steady grant and the whole overflow pool instantly.
    Enum.each(1..(@burst + @pool_burst), fn _ -> RateLimiter.acquire(name) end)

    owner = self()

    task =
      Task.async(fn ->
        for n <- 1..3 do
          :ok = RateLimiter.acquire(name)
          send(owner, {:grant, n})
        end
      end)

    pid = task.pid

    for {n, at} <- [{1, 500}, {2, 1000}, {3, 1500}] do
      assert_receive {:waiting, ^pid, 500}
      Agent.update(time, fn _ -> at - 1 end)
      send(pid, :wake)
      assert_receive {:waiting, ^pid, _remaining_delay}
      refute_received {:grant, ^n}
      Agent.update(time, fn _ -> at end)
      send(pid, :wake)
      assert_receive {:grant, ^n}
    end

    Task.await(task)
  end

  defp controlled_limiter do
    time = start_supervised!({Agent, fn -> 0 end})
    owner = self()

    clock = %{
      now: fn -> Agent.get(time, & &1) end,
      sleep: fn ms ->
        send(owner, {:waiting, self(), ms})

        receive do
          :wake -> :ok
        end
      end
    }

    {start_limiter(clock: clock), time}
  end
end
