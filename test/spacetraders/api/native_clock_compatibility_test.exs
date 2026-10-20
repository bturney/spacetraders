defmodule SpaceTraders.API.NativeClockCompatibilityTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.{API, TestClock}
  alias SpaceTraders.API.{CapacityGovernor, OperationInventory}

  setup do
    previous =
      Map.new([:clock, :semantic_api_scarcity], &{&1, Application.fetch_env(:spacetraders, &1)})

    start_supervised!({TestClock, DateTime.utc_now()})
    Application.put_env(:spacetraders, :clock, TestClock)
    Application.delete_env(:spacetraders, :semantic_api_scarcity)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, CapacityGovernor)
    start_supervised!({CapacityGovernor, probe_base_ms: 0})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:spacetraders, key, value)
        {key, :error} -> Application.delete_env(:spacetraders, key)
      end)

      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, CapacityGovernor)
    end)

    :ok
  end

  test "a gameplay clock alone does not replace native transient retries with semantic deferral" do
    {:ok, requests} = Agent.start_link(fn -> 0 end)
    TestClock.advance(60)

    Req.Test.stub(API, fn conn ->
      count = Agent.get_and_update(requests, &{&1, &1 + 1})

      if count < 3,
        do: Plug.Conn.send_resp(conn, 503, "unavailable"),
        else: Req.Test.json(conn, %{"status" => "online"})
    end)

    assert {:ok, %{"status" => "online"}} = API.get_status()
    assert Agent.get(requests, & &1) == 4
  end

  test "a shared zero-probe governor cannot inherit future backoff from another gameplay clock lifetime" do
    epoch = TestClock.utc_now()
    operation = OperationInventory.fetch!("get-market")
    TestClock.advance(60)
    {:ok, admission} = CapacityGovernor.admit(operation)
    CapacityGovernor.complete(admission, 503)
    assert %{scoped_failures: ["get-market"]} = CapacityGovernor.diagnostics()
    stop_supervised!(TestClock)
    start_supervised!({TestClock, epoch})
    assert %{status: :proceed} = CapacityGovernor.disposition(operation)
  end
end
