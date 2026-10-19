defmodule SpaceTraders.API.SemanticAPITest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.API
  alias SpaceTraders.API.{CapacityGovernor, OperationInventory, RateLimiter}
  alias SpaceTraders.{Clock, TestClock}

  setup do
    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({TestClock, DateTime.utc_now()})
    Application.put_env(:spacetraders, :clock, TestClock)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, CapacityGovernor)
    start_supervised!({CapacityGovernor, probe_base_ms: 1_000})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, CapacityGovernor)
    end)

    :ok
  end

  test "429 releases the owner immediately and every retry re-enters actual admission" do
    parent = self()

    Req.Test.stub(API, fn conn ->
      send(parent, :request)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "5")
      |> Plug.Conn.send_resp(
        429,
        Jason.encode!(%{"error" => %{"code" => 429, "message" => "rate limited"}})
      )
    end)

    caller = Task.async(fn -> API.get_status() end)
    Req.Test.allow(API, self(), caller.pid)
    assert_receive :request
    result = Task.yield(caller, 100)
    unless result, do: Task.shutdown(caller, :brutal_kill)
    assert {:ok, {:error, _}} = result
    assert %{in_flight: 0} = CapacityGovernor.diagnostics()
    assert {:error, :capacity_unavailable} = API.get_status()
    refute_received :request
    TestClock.advance(4_999, :millisecond)
    assert {:error, :capacity_unavailable} = API.get_status()
    refute_received :request
    TestClock.advance(1, :millisecond)

    Req.Test.stub(API, fn conn ->
      send(parent, :progress)
      Req.Test.json(conn, %{"status" => "online"})
    end)

    assert {:ok, %{"status" => "online"}} = API.get_status()
    assert_receive :progress

    assert %{observed_at: now, status: :proceed} =
             CapacityGovernor.disposition(OperationInventory.fetch!("get-status"))

    assert now == Clock.utc_now()
  end

  test "finite protocol capacity and missing enabled limiter never forward or widen admission" do
    previous = Application.fetch_env(:spacetraders, RateLimiter)
    Application.put_env(:spacetraders, RateLimiter, enabled: true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, RateLimiter, value)
        :error -> Application.delete_env(:spacetraders, RateLimiter)
      end
    end)

    Req.Test.stub(API, fn _ -> flunk("no protocol capacity, no transport") end)
    assert {:error, :capacity_unavailable} = API.get_status()
    assert %{in_flight: 0, admitted_capacity: 2} = CapacityGovernor.diagnostics()
    start_supervised!({RateLimiter, burst: 1, pool_burst: 0, rate: 2.0})
    assert :ok = RateLimiter.try_acquire()
    assert {:error, :capacity_unavailable} = API.get_status()

    assert %{in_flight: 0, admitted_capacity: 2, protocol_rejections: 0} =
             CapacityGovernor.diagnostics()

    TestClock.advance(499, :millisecond)
    assert {:error, :capacity_unavailable} = API.get_status()
    TestClock.advance(1, :millisecond)
    Req.Test.stub(API, &Req.Test.json(&1, %{"status" => "online"}))
    assert {:ok, %{"status" => "online"}} = API.get_status()
    assert {:error, :capacity_unavailable} = API.get_status()
  end

  test "ordinary transient reads retry only at the governor's semantic family release" do
    parent = self()

    Req.Test.stub(API, fn conn ->
      send(parent, :failed_read)
      conn |> Plug.Conn.send_resp(503, "unavailable")
    end)

    assert {:error, :capacity_unavailable} = API.get_status()
    assert_receive :failed_read
    assert {:error, :capacity_unavailable} = API.get_status()
    refute_received :failed_read
    TestClock.advance(999, :millisecond)
    assert {:error, :capacity_unavailable} = API.get_status()
    refute_received :failed_read
    TestClock.advance(1, :millisecond)
    Req.Test.stub(API, &Req.Test.json(&1, %{"status" => "online"}))
    assert {:ok, %{"status" => "online"}} = API.get_status()
  end

  test "HTTP-date Retry-After is measured against semantic time, not wall time" do
    TestClock.advance(86_400)
    retry_at = Clock.utc_now() |> DateTime.add(10) |> DateTime.truncate(:second)
    header = Calendar.strftime(retry_at, "%a, %d %b %Y %H:%M:%S GMT")

    Req.Test.stub(API, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", header)
      |> Plug.Conn.send_resp(
        429,
        Jason.encode!(%{"error" => %{"code" => 429, "message" => "rate limited"}})
      )
    end)

    assert {:error, _} = API.get_status()

    assert %{reason: :retry_after, retry_at: guided} =
             CapacityGovernor.disposition(OperationInventory.fetch!("get-status"))

    # Governor rounds a fractional-second duration up conservatively.
    assert DateTime.diff(guided, Clock.utc_now(), :second) == 10
  end
end
