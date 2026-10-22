defmodule SpaceTraders.ShipyardProofArrivalTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.{Clock, TestClock, Timeline}
  alias SpaceTraders.ShipyardProofRuntime, as: Runtime
  alias SpaceTraders.ShipyardProofWorld, as: World

  @t0 ~U[2026-10-22 00:00:00Z]

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true) end)
    :ok
  end

  setup do
    start_supervised!({TestClock, @t0})
    previous_clock = Application.fetch_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)
    governor = SpaceTraders.API.CapacityGovernor
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, governor)
    start_supervised!({governor, now: &Clock.utc_now/0, probe_base_ms: 1000})
    controller = self()

    start_supervised!(
      {SpaceTraders.API.RateLimiter,
       clock: %{
         now: fn -> DateTime.diff(Clock.utc_now(), @t0, :millisecond) end,
         sleep: fn ms -> Runtime.wait(controller, :protocol, ms) end
       }}
    )

    on_exit(fn ->
      SpaceTraders.Quiesced.stop_ship("PROOF824-1")
      SpaceTraders.Quiesced.stop_ship("PROOF824-2")

      case previous_clock do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, governor)
    end)

    :ok
  end

  test "an earlier unrelated retry is processed without mistaking it for the selected trade arrival" do
    world = start_supervised!({World, []})
    controller = self()
    Req.Test.stub(SpaceTraders.API, fn conn -> World.reply(world, conn, controller) end)

    Req.Test.allow(SpaceTraders.API, self(), fn ->
      DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
    end)

    # Minimal state retained in the independently failing #839 database: an
    # older probe wake, unrelated to the selected trader and its current Intent.
    {:ok, retry} =
      Timeline.schedule_event(:ship, "PROOF824-2", :intent_retry, DateTime.add(@t0, 69), %{
        "intent_id" => -1
      })

    fleet = Runtime.fresh_generation(world, "steady_growth")
    assert {:ok, %{action: :published}} = Runtime.run(fn -> Runtime.reconcile(fleet) end)
    Runtime.settle_ships()
    assert DateTime.diff(TestClock.next_due_at(), @t0) == 69

    Runtime.next_arrival("PROOF824-1")
    Runtime.settle_ships()

    assert [record] = SpaceTraders.Outcomes.Earnings.list(fleet.generation.id)
    assert {record.goods_cost, record.revenue, record.net_earnings} == {40_000, 60_000, 20_000}
    assert World.snapshot(world).credits == 420_000
    assert World.snapshot(world).ships["PROOF824-1"]["fuel"]["current"] == 38
    assert Repo.reload!(retry).status == "done"
    assert DateTime.diff(Clock.utc_now(), @t0) == 1579
    refute Enum.any?(World.snapshot(world).requests, &String.contains?(&1.path, "PROOF824-2"))
  end
end
