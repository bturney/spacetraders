defmodule SpaceTraders.ShipyardProofTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.API.Model.Ship
  alias SpaceTraders.Fleet.TradeEstimate
  alias SpaceTraders.ShipyardProofWorld, as: World
  alias SpaceTraders.ShipyardProofRuntime, as: Runtime

  @t0 ~U[2026-10-22 00:00:00Z]

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true) end)
    :ok
  end

  setup do
    start_supervised!({SpaceTraders.TestClock, @t0})
    previous_clock = Application.fetch_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    start_supervised!(
      {SpaceTraders.API.CapacityGovernor, now: &SpaceTraders.Clock.utc_now/0, probe_base_ms: 1000}
    )

    controller = self()

    start_supervised!(
      {SpaceTraders.API.RateLimiter,
       clock: %{
         now: fn -> DateTime.diff(SpaceTraders.Clock.utc_now(), @t0, :millisecond) end,
         sleep: fn ms -> Runtime.wait(controller, :protocol, ms) end
       }}
    )

    on_exit(fn ->
      SpaceTraders.Quiesced.stop_ship("PROOF824-1")
      SpaceTraders.Quiesced.stop_ship("PROOF824-2")
      restore(:clock, previous_clock)
      restart_governor()
    end)

    :ok
  end

  test "the frozen two-Ship starting facts are complete and the CRUISE leg costs real time and fuel" do
    world = start_supervised!({World, []})
    state = World.snapshot(world)
    trader = Ship.from_json(state.ships["PROOF824-1"])
    probe = Ship.from_json(state.ships["PROOF824-2"])

    assert state.credits == 400_000
    assert state.reset_at == DateTime.add(@t0, 120, :hour)
    assert state.requests == []
    assert {trader.cargo.capacity, trader.cargo.units, trader.cargo.inventory} == {40, 0, []}
    assert {trader.fuel.current, trader.fuel.capacity} == {100, 100}

    assert {trader.engine.speed, trader.engine.condition, trader.nav.flight_mode} ==
             {1, 1.0, "CRUISE"}

    assert trader.frame.module_slots == 4
    assert trader.frame.mounting_points == 2
    assert length(trader.modules) == 1
    assert trader.mounts == []
    assert {probe.cargo.capacity, probe.cargo.units, probe.fuel.capacity} == {0, 0, 0}
    assert trader.cooldown.ship_symbol == trader.symbol
    assert probe.cooldown.ship_symbol == probe.symbol

    assert TradeEstimate.leg(%{x: 0, y: 0}, %{x: 62, y: 0}, %{
             speed: trader.engine.speed,
             condition: trader.engine.condition,
             fuel_capacity: trader.fuel.capacity
           }) == %{seconds: 1565, fuel: 62}

    assert World.waypoint("X1-UX81-A1")["x"] == 0
    assert World.waypoint("X1-UX81-A2")["x"] == 62
    assert World.waypoint("X1-UX81-A3")["y"] == 62
  end

  for preset_id <- ~w(steady_growth charted_expansion) do
    @preset_id preset_id
    test "#{preset_id}: ordinary selected trading buys, travels, sells and pays to refuel and return" do
      world = start_supervised!({World, []})
      controller = self()
      Req.Test.stub(SpaceTraders.API, fn conn -> World.reply(world, conn, controller) end)

      Req.Test.allow(SpaceTraders.API, self(), fn ->
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
      end)

      fleet = Runtime.fresh_generation(world, @preset_id)
      assert SpaceTraders.Outcomes.Earnings.list(fleet.generation.id) == []

      assert SpaceTraders.Evidence.latest_observation(fleet.agent, "shipyard:X1-UX81:X1-UX81-A1") ==
               nil

      assert {:ok, %{action: :published, commitments: commitments} = selection} =
               Runtime.run(fn -> Runtime.reconcile(fleet) end)

      assert Enum.any?(commitments, &(&1.claims == ["PROOF824-1"]))
      trade = Enum.find(commitments, &(&1.claims == ["PROOF824-1"]))
      assert trade.reservations["credits"] == 50_000
      assert SpaceTraders.CreditCalibration.active().margin_percent == 25
      assert {:ok, floor} = SpaceTraders.FleetExecution.credit_floor(fleet.revision)
      assert floor == if(@preset_id == "steady_growth", do: 50_000, else: 75_000)
      episode = SpaceTraders.FleetAllocation.commitment_decision_episode(trade)
      assert Enum.any?(episode.alternatives, &(&1["reasons"] == ["claim_conflict"]))

      assert Enum.all?(selection.dispatched, fn {_, result} -> match?({:ok, _}, result) end),
             inspect(selection.dispatched, limit: :infinity)

      Runtime.settle_ships()
      assert %DateTime{} = SpaceTraders.TestClock.next_due_at()
      Runtime.next_arrival("PROOF824-1")
      Runtime.settle_ships()

      assert [record] = SpaceTraders.Outcomes.Earnings.list(fleet.generation.id)
      assert {record.units, record.goods_cost, record.revenue} == {40, 40_000, 60_000}
      assert record.net_earnings == 20_000

      # A second ordinary selection must reposition itself, not teleport home or
      # reset the remaining 38 fuel. Complete its actual return and productive use.
      assert {:ok, %{action: :published}} = Runtime.run(fn -> Runtime.reconcile(fleet) end)
      Runtime.settle_ships()
      Runtime.next_arrival("PROOF824-1")
      Runtime.settle_ships()

      assert SpaceTraders.TestClock.next_due_at(),
             inspect(
               %{
                 intents:
                   Enum.map(
                     Repo.all(SpaceTraders.Fleet.Intent),
                     &Map.take(&1, [:type, :status, :blocker, :last_action_result])
                   ),
                 requests: Enum.map(World.snapshot(world).requests, &{&1.path, &1.completed_at})
               },
               limit: :infinity
             )

      Runtime.next_arrival("PROOF824-1")
      Runtime.settle_ships()
      state = World.snapshot(world)
      purchases = Enum.filter(state.requests, &String.ends_with?(&1.path, "/purchase"))
      refuels = Enum.filter(state.requests, &String.ends_with?(&1.path, "/refuel"))
      navigations = Enum.filter(state.requests, &String.ends_with?(&1.path, "/navigate"))
      assert length(purchases) == 2
      assert length(refuels) == 2

      for refuel <- refuels do
        assert refuel.response["transaction"]["totalPrice"] == 100
        assert refuel.before.ships["PROOF824-1"]["fuel"]["current"] == 38
        assert refuel.after.ships["PROOF824-1"]["fuel"]["current"] == 100
      end

      [outbound, return, repeat] = navigations
      assert return.body["waypointSymbol"] == "X1-UX81-A1"

      for leg <- [outbound, repeat],
          do: assert(leg.body["waypointSymbol"] in ~w(X1-UX81-A2 X1-UX81-A3))

      for request <- navigations do
        nav = request.response["nav"]
        {:ok, departure, 0} = DateTime.from_iso8601(nav["route"]["departureTime"])
        {:ok, arrival, 0} = DateTime.from_iso8601(nav["route"]["arrival"])
        assert DateTime.diff(arrival, departure) == 1565
        assert request.response["fuel"]["consumed"]["amount"] == 62
      end

      assert state.credits == 439_800
      assert state.low_credits == 360_000
      records = SpaceTraders.Outcomes.Earnings.list(fleet.generation.id)

      assert Enum.map(records, &{&1.goods_cost, &1.revenue, &1.fuel_cost, &1.net_earnings}) ==
               [{40_000, 60_000, 0, 20_000}, {40_000, 60_000, 200, 19_800}]

      assert Enum.all?(
               records,
               &(DateTime.compare(&1.started_at, @t0) != :lt and
                   DateTime.compare(&1.finished_at, SpaceTraders.Clock.utc_now()) != :gt and
                   &1.ship_seconds >= 1565)
             )

      attempts = SpaceTraders.MutationAttempts.list_for_agent(fleet.agent)
      assert length(attempts) == Enum.count(state.requests, &(&1.method == "POST"))

      for attempt <- attempts do
        assert attempt.state == "succeeded"

        request =
          Enum.find(state.requests, fn request ->
            request.path == "/v2" <> attempt.prepared_evidence["request"]["path"] and
              request.body == (attempt.prepared_evidence["request"]["body"] || %{}) and
              DateTime.compare(request.started_at, attempt.sent_or_unknown_at) == :eq
          end)

        assert request, "attempt #{attempt.operation_id} timestamp does not match transport"
        assert [%{classification: "succeeded", recorded_at: recorded_at}] = attempt.outcomes
        assert DateTime.compare(recorded_at, request.completed_at) == :eq
      end

      assert DateTime.diff(SpaceTraders.Clock.utc_now(), @t0) == 4695 + length(state.requests)

      assert Enum.all?(
               state.requests,
               &(DateTime.diff(&1.completed_at, &1.started_at, :millisecond) == 1000)
             )

      assert SpaceTraders.API.CapacityGovernor.diagnostics().in_flight == 0

      assert SpaceTraders.API.CapacityGovernor.diagnostics().observed_at ==
               SpaceTraders.Clock.utc_now()

      for request <- state.requests, is_map(request.response) do
        refute Map.has_key?(request, :failure)

        for field <- ~w(nav cargo fuel), value = request.response[field], not is_nil(value) do
          assert value == request.after.ships["PROOF824-1"][field]
        end

        if agent = request.response["agent"],
          do: assert(agent["credits"] == request.after.credits)

        if transaction = request.response["transaction"] do
          assert transaction["shipSymbol"] == "PROOF824-1"

          assert transaction["waypointSymbol"] ==
                   request.after.ships["PROOF824-1"]["nav"]["waypointSymbol"]

          {:ok, at, 0} = DateTime.from_iso8601(transaction["timestamp"])
          assert DateTime.compare(at, request.completed_at) == :eq
        end
      end

      Runtime.write_receipt(world, fleet, @preset_id)
    end
  end

  test "the normal protocol budget waits on the same clock before one second of API service" do
    world = start_supervised!({World, []})
    controller = self()
    Req.Test.stub(SpaceTraders.API, fn conn -> World.reply(world, conn, controller) end)
    fleet = Runtime.fresh_generation(world, "steady_growth")

    # Exhaust the real default two-token steady pool and 30-token overflow
    # without advancing time. The next request is paced, not waved through.
    for _ <- 1..32, do: assert(:ok == SpaceTraders.API.RateLimiter.acquire())

    assert %{result: {:ok, agent}, waits: waits} =
             Runtime.run_trace(fn -> SpaceTraders.Evidence.get_agent(fleet.agent) end)

    assert agent.credits == 400_000

    assert Enum.map(waits, &{&1.kind, DateTime.diff(&1.due_at, &1.started_at, :millisecond)}) ==
             [{:protocol, 500}, {:service, 1000}]

    assert DateTime.diff(SpaceTraders.Clock.utc_now(), @t0, :millisecond) == 1500
    assert [request] = World.snapshot(world).requests
    assert DateTime.diff(request.started_at, @t0, :millisecond) == 500
    assert request.completed_at == SpaceTraders.Clock.utc_now()
  end

  test "unsupported API requests fail rather than inventing an effect" do
    world = start_supervised!({World, []})
    controller = self()
    before = World.snapshot(world)

    conn =
      Plug.Test.conn(:post, "/v2/my/ships/PROOF824-1/jettison", %{
        "symbol" => "IRON",
        "units" => 1
      })

    Runtime.run(fn ->
      assert_raise RuntimeError, "unsupported proof action jettison", fn ->
        World.reply(world, conn, controller)
      end
    end)

    after_rejection = World.snapshot(world)
    assert after_rejection.credits == before.credits
    assert after_rejection.ships == before.ships
    assert [%{failure: "unsupported proof action jettison"}] = after_rejection.requests
  end

  defp restart_governor do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:spacetraders, key, value)
  defp restore(key, :error), do: Application.delete_env(:spacetraders, key)
end
