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
      SpaceTraders.Quiesced.stop_ship("PROOF824-3")
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

  test "the amended positive prefix retains actual work without an external liability" do
    # The exact 48h replay is opt-in: test/diagnostics/shipyard_finite_control.exs.
    preset = System.get_env("SHIPYARD_PROOF_PRESET", "steady_growth")
    world = start_supervised!({World, []})
    controller = self()
    Req.Test.stub(SpaceTraders.API, fn conn -> World.reply(world, conn, controller) end)

    Req.Test.allow(SpaceTraders.API, self(), fn ->
      DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
    end)

    fleet = Runtime.fresh_generation(world, preset)
    start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))
    result = Runtime.finite_control(world, fleet, preset, DateTime.add(@t0, 1, :hour))
    assert result.as_of == DateTime.add(@t0, 1, :hour)
    assert result.account.credits == 400_000 + result.account.net_cash
    assert result.account.receipts > 0
    assert result.account.goods_outlays > 0
    assert result.account.fuel_outlays > 0
    assert result.account.unexplained_cash == 0
    refute Map.has_key?(World.snapshot(world), :pending_debit)
    refute Enum.any?(result.account.effects, &(&1.path == "/fixture/external-debit"))
    assert result.manifest.worst_preset_funding == 320_000
    assert result.manifest.selected_work_initial_reservation == 50_000
    assert result.manifest.acquisition_preparation_bound == 135_000
    assert result.manifest.first_cycle_envelope == 60_000
    assert result.floor == if(preset == "steady_growth", do: 50_000, else: 75_000)
    assert result.account.low_credits >= result.floor
    assert length(result.decisions) > 0

    assert Enum.any?(result.decisions, fn decision ->
             Enum.any?(decision.alternatives || [], &(&1["reasons"] == ["claim_conflict"]))
           end)

    assert result.account.acquisition_outlays == 0 or result.classification == "blocked"
    assert Enum.all?(result.earnings, &is_integer(&1.fleet_commitment_id))
    assert Enum.all?(result.earnings, &is_integer(&1.strategy_decision_episode_id))
    assert Enum.count(result.waits, &(&1.kind == :service)) == length(result.request_effects)
    assert [_ | _] = unfinished = SpaceTraders.Fleet.Intents.current(fleet.agent)
    for intent <- unfinished, do: assert(Enum.any?(result.intents, &(&1.id == intent.id)))
    Runtime.write_control_receipt(result, preset)

    for symbol <- ~w(PROOF824-1 PROOF824-2 PROOF824-3),
        do: SpaceTraders.Quiesced.stop_ship(symbol)

    assert {:ok, _} = Runtime.cleanup_control_fixture(fleet)
    refute Repo.get(SpaceTraders.Agent.Agent, fleet.agent.id)
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

  for preset <- ~w(steady_growth charted_expansion) do
    @payment_preset preset
    test "#{preset}: separate payment safety protects and settles its real 20-unit purchase once" do
      world = start_supervised!({World, scenario: :payment_safety})
      controller = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        if String.ends_with?(conn.request_path, "/purchase"),
          do: World.reply(world, conn, controller, :lost_response),
          else: World.reply(world, conn, controller)
      end)

      Req.Test.allow(SpaceTraders.API, self(), fn ->
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
      end)

      fleet = Runtime.fresh_generation(world, @payment_preset)

      assert {:ok, %{action: :published, commitments: commitments}} =
               Runtime.run(fn -> Runtime.reconcile(fleet) end)

      trade = Enum.find(commitments, &(&1.claims == ["PROOF824-1"]))
      assert trade.reservations["credits"] == 25_000

      [attempt] =
        Enum.filter(
          SpaceTraders.MutationAttempts.list_for_agent(fleet.agent),
          &(&1.operation_id == "purchase-cargo")
        )

      assert attempt.state == "ambiguous"
      assert attempt.prepared_evidence["spending"]["worst_case_exposure"] == 25_000
      assert attempt.prepared_evidence["request"]["body"]["units"] == 20
      assert attempt.provenance["commitment_id"] == trade.id
      assert attempt.provenance["intent_id"]
      assert %DateTime{} = attempt.sent_or_unknown_at

      assert [%{id: id}] =
               SpaceTraders.SafetyFence.blocking_attempts([
                 SpaceTraders.SafetyFence.DependencyKey.agent_credits(fleet.agent.id)
               ])

      assert id == attempt.id
      assert World.snapshot(world).credits == 380_000
      assert World.account(world, SpaceTraders.Clock.utc_now()).goods_outlays == 20_000

      unknown = %{
        at: SpaceTraders.Clock.utc_now(),
        attempt:
          Map.take(
            attempt,
            ~w(id state prepared_evidence provenance prepared_at sent_or_unknown_at)a
          ),
        commitment: Map.take(trade, ~w(id claims reservations dependencies)a),
        intent:
          SpaceTraders.Fleet.Intents.current(fleet.agent)
          |> Enum.find(&(&1.id == attempt.provenance["intent_id"]))
          |> Map.take(
            ~w(id status blocker in_flight_action mutation_attempt_id fleet_commitment_id next_attempt_at)a
          )
      }

      effect_at =
        World.snapshot(world).requests
        |> Enum.find(&String.ends_with?(&1.path, "/purchase"))
        |> Map.fetch!(:completed_at)

      for symbol <- ~w(PROOF824-1 PROOF824-2), do: SpaceTraders.Quiesced.stop_ship(symbol)
      Req.Test.stub(SpaceTraders.API, fn conn -> World.reply(world, conn, controller) end)

      for symbol <- ~w(PROOF824-1 PROOF824-2),
          do: SpaceTraders.Fleet.ShipServer.ensure_started(fleet.agent, symbol)

      Runtime.run(fn -> SpaceTraders.Fleet.Intents.rearm_on_boot() end)

      retry =
        SpaceTraders.Timeline.pending_events(:ship, "PROOF824-1")
        |> Enum.find(&(&1.event_type == "intent_retry"))

      assert retry

      Stream.repeatedly(fn ->
        Runtime.next_event()
        Runtime.settle_ships()
      end)
      |> Enum.find(fn _ -> not SpaceTraders.Timeline.pending?(retry) end)

      Runtime.settle_ships()
      settled = SpaceTraders.MutationAttempts.get!(attempt.id)

      assert settled.state == "accepted",
             inspect(
               %{
                 intents:
                   Enum.map(
                     SpaceTraders.Fleet.Intents.current(fleet.agent),
                     &Map.take(&1, ~w(id status blocker next_attempt_at last_action_result)a)
                   ),
                 capacity: SpaceTraders.API.CapacityGovernor.diagnostics(),
                 requests:
                   World.snapshot(world).requests
                   |> Enum.take(-6)
                   |> Enum.map(&{&1.path, &1.completed_at})
               },
               limit: :infinity
             )

      assert Enum.map(settled.outcomes, & &1.classification) == ["ambiguous", "accepted"]
      assert DateTime.compare(List.last(settled.outcomes).recorded_at, effect_at) == :gt
      Runtime.run(fn -> SpaceTraders.Fleet.Intents.rearm_on_boot() end)
      Runtime.settle_ships()

      purchases =
        Enum.filter(
          SpaceTraders.MutationAttempts.list_for_agent(fleet.agent),
          &(&1.operation_id == "purchase-cargo")
        )

      assert Enum.map(purchases, & &1.id) == [attempt.id]

      assert SpaceTraders.SafetyFence.blocking_attempts([
               SpaceTraders.SafetyFence.DependencyKey.agent_credits(fleet.agent.id)
             ]) == []

      account = World.account(world, SpaceTraders.Clock.utc_now())

      assert {account.credits, account.goods_outlays, account.net_cash} ==
               {380_000, 20_000, -20_000}

      assert Enum.count(account.effects, &(&1.signed_cash != 0)) == 1

      assert Enum.count(World.snapshot(world).requests, &String.ends_with?(&1.path, "/purchase")) ==
               1

      receipt = Runtime.write_payment_receipt(world, fleet, @payment_preset, unknown)
      assert receipt.unknown.attempt.state == "ambiguous"
      assert receipt.settled_attempt.state == "accepted"
      assert receipt.account.net_cash == -20_000
    end
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

  test "finite shared route stock reprices partial transactions and replenishes only depleted units" do
    world = start_supervised!({World, []})
    controller = self()

    request = fn units ->
      Runtime.run(fn ->
        World.reply(
          world,
          Plug.Test.conn(:post, "/v2/my/ships/PROOF824-1/purchase", %{
            "symbol" => "IRON",
            "units" => units
          }),
          controller
        )
      end)
    end

    request.(20)
    assert World.snapshot(world).routes["IRON"].source_units == 1580
    assert hd(World.market(world, "X1-UX81-A1")["tradeGoods"])["purchasePrice"] == 1005
    request.(20)
    assert World.snapshot(world).routes["IRON"].source_units == 1560
    assert hd(World.market(world, "X1-UX81-A1")["tradeGoods"])["purchasePrice"] == 1010
    assert World.snapshot(world).routes["COPPER"].source_units == 1600
    SpaceTraders.TestClock.advance(1798)
    assert World.snapshot(world).routes["IRON"].source_units == 1600
    assert hd(World.market(world, "X1-UX81-A1")["tradeGoods"])["purchasePrice"] == 1000
    SpaceTraders.TestClock.advance(1800)
    assert World.snapshot(world).routes["IRON"].source_units == 1600
    assert World.snapshot(world).cargo_basis["PROOF824-1"]["IRON"] == 40_100
  end

  test "an unrepresentable fractional-credit quote is inconclusive, never silently rounded" do
    world = start_supervised!({World, []})
    controller = self()

    Runtime.run(fn ->
      World.reply(
        world,
        Plug.Test.conn(:post, "/v2/my/ships/PROOF824-1/purchase", %{
          "symbol" => "IRON",
          "units" => 1
        }),
        controller
      )
    end)

    assert_raise RuntimeError, "frozen pro-rata quote is not an integer API credit amount", fn ->
      World.market(world, "X1-UX81-A1")
    end

    assert World.snapshot(world).credits == 399_000
    assert World.snapshot(world).routes["IRON"].source_units == 1599
  end

  test "the canonical on-site Ship Offer agrees with its single obtainable ready Ship" do
    world = start_supervised!({World, []})
    controller = self()
    Req.Test.stub(SpaceTraders.API, fn conn -> World.reply(world, conn, controller) end)
    fleet = Runtime.fresh_generation(world, "steady_growth")
    refute SpaceTraders.Evidence.latest_observation(fleet.agent, "shipyard:X1-UX81:X1-UX81-A1")

    assert {:ok, yard} =
             Runtime.run(fn ->
               SpaceTraders.Evidence.get_shipyard(fleet.agent, "X1-UX81", "X1-UX81-A1")
             end)

    assert yard.modifications_fee == 2000
    assert [offer] = yard.ships
    assert offer.purchase_price == 100_000
    assert offer.type == "SHIP_LIGHT_HAULER"

    required =
      File.read!("priv/spec/models/ShipyardShip.json")
      |> Jason.decode!()
      |> Map.fetch!("required")

    raw_offer =
      World.snapshot(world).requests
      |> List.last()
      |> Map.fetch!(:response)
      |> Map.fetch!("ships")
      |> hd()

    assert Enum.reject(required, &Map.has_key?(raw_offer, &1)) == []

    request = fn ->
      Runtime.run(fn ->
        World.reply(
          world,
          Plug.Test.conn(:post, "/v2/my/ships", %{
            "shipType" => "SHIP_LIGHT_HAULER",
            "waypointSymbol" => "X1-UX81-A1"
          }),
          controller
        )
      end)
    end

    response = request.() |> Map.fetch!(:resp_body) |> Jason.decode!() |> Map.fetch!("data")
    acquired = Ship.from_json(response["ship"])
    assert acquired.cargo.capacity == 40
    assert acquired.engine == offer.engine
    assert acquired.frame == offer.frame
    assert acquired.modules == offer.modules
    assert World.snapshot(world).credits == 300_000
    assert World.snapshot(world).offer_stock == 0

    Runtime.run(fn ->
      assert_raise RuntimeError, "proof Ship Offer exhausted", fn ->
        World.reply(
          world,
          Plug.Test.conn(:post, "/v2/my/ships", %{
            "shipType" => "SHIP_LIGHT_HAULER",
            "waypointSymbol" => "X1-UX81-A1"
          }),
          controller
        )
      end
    end)

    assert {:ok, %{ships: []}} =
             Runtime.run(fn ->
               SpaceTraders.Evidence.get_shipyard(fleet.agent, "X1-UX81", "X1-UX81-A1")
             end)

    assert World.snapshot(world).credits == 300_000

    for symbol <- ~w(PROOF824-1 PROOF824-3) do
      Runtime.run(fn ->
        World.reply(
          world,
          Plug.Test.conn(:post, "/v2/my/ships/#{symbol}/purchase", %{
            "symbol" => "IRON",
            "units" => 40
          }),
          controller
        )
      end)
    end

    assert World.snapshot(world).routes["IRON"].source_units == 1520
    assert World.snapshot(world).credits == 219_600
    assert World.snapshot(world).cargo_basis["PROOF824-1"]["IRON"] == 40_000
    assert World.snapshot(world).cargo_basis["PROOF824-3"]["IRON"] == 40_400
  end

  test "the shared world's transaction maximum rejects over-depth sends without charging" do
    world = start_supervised!({World, []})
    controller = self()

    Runtime.run(fn ->
      assert_raise RuntimeError, "proof transaction exceeds depth", fn ->
        World.reply(
          world,
          Plug.Test.conn(:post, "/v2/my/ships/PROOF824-1/purchase", %{
            "symbol" => "IRON",
            "units" => 41
          }),
          controller
        )
      end
    end)

    assert World.snapshot(world).credits == 400_000
    assert World.snapshot(world).routes["IRON"].source_units == 1600
    assert World.snapshot(world).effects == []
  end

  test "status uses the same announced reset and every pinned required response field" do
    world = start_supervised!({World, []})
    controller = self()
    conn = Runtime.run(fn -> World.reply(world, Plug.Test.conn(:get, "/v2/"), controller) end)
    response = Jason.decode!(conn.resp_body)

    schema =
      File.read!("priv/spec/SpaceTraders.json")
      |> Jason.decode!()
      |> get_in([
        "paths",
        "/",
        "get",
        "responses",
        "200",
        "content",
        "application/json",
        "schema"
      ])

    assert Enum.reject(schema["required"], &Map.has_key?(response, &1)) == []

    assert Enum.reject(
             schema["properties"]["serverResets"]["required"],
             &Map.has_key?(response["serverResets"], &1)
           ) == []

    assert response["serverResets"]["next"] == DateTime.to_iso8601(DateTime.add(@t0, 120, :hour))
    assert response["resetDate"] == "2026-10-22"
  end

  test "a service completion after T remains a closure tail, not pre-T cash or Cargo" do
    world = start_supervised!({World, []})
    controller = self()
    cutoff = DateTime.add(@t0, 48, :hour)
    SpaceTraders.Clock.send_at(self(), :before_cutoff, DateTime.add(cutoff, -500, :millisecond))
    Runtime.next_event()
    assert_received :before_cutoff

    Runtime.run(fn ->
      World.reply(
        world,
        Plug.Test.conn(:post, "/v2/my/ships/PROOF824-1/purchase", %{
          "symbol" => "IRON",
          "units" => 40
        }),
        controller
      )
    end)

    account = World.account(world, cutoff)
    assert account.credits == 400_000
    assert account.goods_outlays == 0
    assert account.ships["PROOF824-1"]["cargo"]["units"] == 0
    assert account.stock["IRON"].source_units == 1600
    assert account.cargo_basis == %{}
    assert [%{signed_cash: -40_000}] = account.closure_tail
  end

  defp restart_governor do
    SpaceTraders.Test.Governor.restart()
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:spacetraders, key, value)
  defp restore(key, :error), do: Application.delete_env(:spacetraders, key)
end
