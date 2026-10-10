defmodule SpaceTraders.RuntimeQualification do
  @moduledoc """
  Explicit diagnostic qualification for whole-runtime composition.

  This retains one behavior that cheaper seams do not prove: a fresh authenticated
  Strategy activation composes production reconciliation, Evidence, Fleet Planning,
  Fleet Allocation, Ship Execution, runtime restart, and Mission Control into a
  profitable distant trade.

  Seam-level correctness belongs to the deterministic merge suite instead:
  Observation Demand restart in `evidence_scheduling_test.exs`, incomplete Market
  coverage planning in `fleet_planning_test.exs`, and first/lost-response Ship
  dispatch recovery in `ship_execution_durability_test.exs`.

  This file intentionally does not end in `_test.exs`; ordinary `mix test` and
  `scripts/verify` do not discover it. Run the timing-sensitive qualification only
  when whole-runtime composition is the question:

      mix test test/diagnostics/runtime_qualification.exs --seed 0 --trace
  """

  use ExUnit.Case, async: false

  @endpoint SpaceTradersWeb.Endpoint

  use SpaceTradersWeb, :verified_routes

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Plug.Conn

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.Evidence.DemandScheduler
  alias SpaceTraders.Fleet.ShipServerBoot
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.Repo
  alias SpaceTraders.RuntimeBaselineGame, as: Game
  alias SpaceTraders.RuntimeFleetGame, as: FleetGame
  alias SpaceTraders.TestClock
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag committed: true
  @moduletag skip: Repo.__adapter__() != Ecto.Adapters.Postgres && "requires PostgreSQL"

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    start_supervised!({TestClock, ~U[2026-09-14 12:00:00Z]})

    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      SpaceTraders.Quiesced.stop_all_ships()
      SpaceTraders.Contracts.DeadlineServer.stop_all()
      SpaceTraders.EmergencyStopAdmission.clear()
      SpaceTraders.FleetGenerationAdmission.clear()
      Sandbox.mode(Repo, :manual)

      if previous_clock do
        Application.put_env(:spacetraders, :clock, previous_clock)
      else
        Application.delete_env(:spacetraders, :clock)
      end
    end)

    advance_time(
      DateTime.diff(DateTime.utc_now(), SpaceTraders.Clock.utc_now(), :microsecond),
      :microsecond
    )

    calibration_floor_id =
      Repo.one(from v in SpaceTraders.CreditCalibration.Version, select: max(v.id))

    on_exit(fn ->
      SpaceTraders.Quiesced.stop_all_ships()

      operator_ids =
        Repo.all(from o in Operator, where: like(o.email, "baseline-503-%"), select: o.id)

      agent_ids = Repo.all(from a in Agent, where: a.operator_id in ^operator_ids, select: a.id)

      topics =
        Enum.map(operator_ids, &"fleet_allocation:#{&1}") ++ Enum.map(agent_ids, &"fleet:#{&1}")

      attempt_ids =
        Repo.all(from a in Attempt, where: a.operator_id in ^operator_ids, select: a.id)

      # Gate 1 scenarios write global calibration and per-Agent credit evidence.
      Repo.delete_all(
        from r in SpaceTraders.CreditCalibration.Realization, where: r.agent_id in ^agent_ids
      )

      Repo.delete_all(
        from s in SpaceTraders.CreditCalibration.Shortfall, where: s.agent_id in ^agent_ids
      )

      Repo.delete_all(
        from v in SpaceTraders.CreditCalibration.Version, where: v.id > ^calibration_floor_id
      )

      Repo.delete_all(from o in Outcome, where: o.mutation_attempt_id in ^attempt_ids)
      Repo.delete_all(from a in Attempt, where: a.id in ^attempt_ids)

      Repo.delete_all(
        from d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id in ^agent_ids
      )

      Repo.delete_all(
        from o in SpaceTraders.Evidence.Observation, where: o.agent_id in ^agent_ids
      )

      Repo.delete_all(from n in SpaceTraders.Outbox.Notification, where: n.topic in ^topics)
      Repo.delete_all(from o in Operator, where: o.id in ^operator_ids)

      Repo.delete_all(
        from e in SpaceTraders.Timeline.Event, where: e.owner_id in ["BASELINE-1", "BASELINE-2"]
      )
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp stub_api(handler), do: Req.Test.stub(SpaceTraders.API, handler)

  defp advance_time(amount, unit \\ :second), do: TestClock.advance(amount, unit)

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  test "fresh Strategy activation completes a profitable distant trade across runtime restart", %{
    conn: conn
  } do
    game = start_supervised!({Game, []})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    start_runtime()
    {conn, agent} = activate_fresh_generation(conn)

    assert_eventually(fn -> Game.snapshot(game).status == "IN_TRANSIT" end, 500)
    settle_runtime()

    # Cross-seam qualification only: interrupt the production runtime while the
    # trade is in flight, then let production boot reconstruct enough work for
    # the same Strategy activation to finish. Narrow tests own the individual
    # scheduling, dispatch, and recovery guarantees exercised underneath.
    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(Reconciler)
    assert :ok = SpaceTraders.Quiesced.stop_ship("BASELINE-1")
    advance_time(60)
    start_runtime()
    start_supervised!({ShipServerBoot, []})

    Enum.reduce_while(1..20, :ok, fn _, :ok ->
      settle_runtime()
      Process.sleep(20)
      settle_runtime()

      if Game.snapshot(game).credits > 175_000 do
        {:halt, :ok}
      else
        due_at = SpaceTraders.TestClock.next_due_at()
        assert %DateTime{} = due_at

        advance_time(
          max(DateTime.diff(due_at, SpaceTraders.Clock.utc_now(), :microsecond), 0),
          :microsecond
        )

        {:cont, :ok}
      end
    end)

    settle_runtime()
    state = Game.snapshot(game)
    counts = Enum.frequencies_by(state.requests, & &1.path)

    IO.inspect(
      %{
        credits: state.credits,
        fuel: state.fuel,
        requests: Enum.map(state.requests, &{&1.method, &1.path, &1.reply, &1.at}),
        as_of: SpaceTraders.Clock.utc_now()
      },
      label: "runtime qualification",
      limit: :infinity
    )

    {:ok, view, html} = live(conn, ~p"/mission-control")
    IO.puts("Operator-visible operating health: " <> render(element(view, "#operating-health")))
    assert html =~ agent.symbol
    assert Map.get(counts, "/v2/my/ships/BASELINE-1/purchase", 0) == 1
    assert Map.get(counts, "/v2/my/ships/BASELINE-1/sell", 0) == 1
    assert state.credits == 175_800
    assert state.units == 0
  end

  # Gate 1 (#589): spending and capacity authority through the same seam.
  # Each scenario starts from authenticated Strategy activation (the Steady
  # Growth preset keeps a 50,000 credit floor) and lets the production runtime
  # plan, allocate, admit, and execute against the stateful game.
  describe "Gate 1 authority" do
    test "the credit floor bounds a Market purchase's worst-case exposure", %{conn: conn} do
      # 300 credits of headroom: at the 25% margin a 10-credit quote funds at
      # most 24 units, never the full 40-unit hold.
      game = start_game(credits: 50_300)
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, &sold?/1)

      state = Game.snapshot(game)
      purchases = requests(state, "/v2/my/ships/BASELINE-1/purchase")

      # Planning may size the purchase down or decline it; either way no
      # purchase whose worst case exceeds the headroom leaves transport.
      assert state.low_credits >= 50_000
      assert Enum.all?(purchases, &(&1.body["units"] * 10 * 125 <= 300 * 100))
    end

    # #589 finding: owned Agent/Fleet reads persisted Observation Demands that
    # the scheduler announced as due at once, waking reconciliation into the
    # same reads again; overdue unacquirable Market work re-announced on every
    # demand change. Together they spun reads for as long as the wait lasted.
    test "a Neutral Wait holds without spinning Agent and Fleet reads", %{conn: conn} do
      # 5 credits of headroom fund no unit, so planning proposes no trade and
      # the Fleet waits. (300 now sizes a 24-unit trade from the headroom.)
      game = start_game(credits: 50_005)
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, fn _state -> false end, 8)
      Process.sleep(1_000)

      state = Game.snapshot(game)
      before = length(state.requests)
      Process.sleep(1_000)
      during_wait = length(Game.snapshot(game).requests) - before

      assert during_wait == 0,
             "#{during_wait} game requests in one second of frozen-clock Neutral Wait"

      assert Repo.exists?(
               from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
                 where: e.selection_kind == :neutral_wait
             )
    end

    # #662 finding: 300 credits of headroom fund one 24-unit trade. Afterwards
    # the Ship lacked fuel for the next source, every buy ended infeasible, and
    # each failed buy's refuel Market read re-planned the same infeasible trade
    # under a new candidate id: about 30 requests a second.
    for {label, opts} <- [
          {"no FUEL Market", [credits: 50_300]},
          {"FUEL sold only at the unreachable source", [credits: 50_300, fuel_price: 2]}
        ] do
      @tag game_opts: opts
      test "after a funded trade, a fuel-infeasible next trade does not spin reads (#{label})", %{
        conn: conn,
        game_opts: game_opts
      } do
        stranded_without_spin(conn, game_opts)
      end
    end

    test "a pricing-model breach records evidence, widens calibration, and pauses only spending",
         %{conn: conn} do
      initial = SpaceTraders.CreditCalibration.active()
      # The game charges 15 per unit against a 10-credit quote: 600 against a
      # 500-credit worst-case bound for 40 units.
      game = start_game(purchase_charge: 15)
      {_conn, agent} = activate_fresh_generation(conn)
      drive(game, &sold?/1)

      state = Game.snapshot(game)
      assert [_one] = requests(state, "/v2/my/ships/BASELINE-1/purchase")
      # Non-spending work continues: the purchased Cargo is still sold.
      assert [_sale] = requests(state, "/v2/my/ships/BASELINE-1/sell")

      assert [%{kind: "pricing_model_miss"} | _] =
               SpaceTraders.CreditCalibration.shortfalls(agent)

      widened = SpaceTraders.CreditCalibration.active()
      assert widened.margin_percent > initial.margin_percent
      assert widened.basis == "pricing_model_miss"

      assert Repo.exists?(
               from c in SpaceTraders.OperatorConditions.Condition,
                 where:
                   c.operator_id == ^agent.operator_id and
                     c.key == ^"credit-pricing-breach:#{agent.id}" and c.kind == :attention
             )
    end

    test "API Retry-After defers Market reads without Attention and the trade completes",
         %{conn: conn} do
      game = start_game(throttled_market_reads: 3)
      {_conn, agent} = activate_fresh_generation(conn)
      drive(game, &sold?/1)

      state = Game.snapshot(game)
      assert Enum.count(state.requests, &(&1.reply == :throttled)) == 3
      assert length(requests(state, "/v2/my/ships/BASELINE-1/purchase")) == 1, trace(state)
      assert length(requests(state, "/v2/my/ships/BASELINE-1/sell")) == 1, trace(state)
      assert state.credits == 175_800

      refute Repo.exists?(
               from c in SpaceTraders.OperatorConditions.Condition,
                 where: c.operator_id == ^agent.operator_id and c.kind == :attention
             )

      # Capacity Deferral never becomes Attention or objective infeasibility.
      # (A later trade may be infeasible for fuel; that is not capacity.)
      outcomes =
        Repo.all(
          from i in SpaceTraders.Fleet.Intent,
            join: ship in SpaceTraders.Fleet.Ship,
            on: ship.id == i.ship_id,
            where: ship.agent_id == ^agent.id and i.status in ["blocked", "infeasible"],
            select: {i.status, i.blocker, i.last_action_result}
        )

      refute Enum.any?(outcomes, &(inspect(&1) =~ ~r/capacity|429|retry/i)), inspect(outcomes)
    end

    test "below the floor no fuel or Market spending leaves transport", %{conn: conn} do
      # Credits already below the 50,000 floor and too little fuel to reach the
      # distant Market: there is no recovery-spend exception.
      game = start_game(credits: 49_000, fuel: 30)
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, fn _state -> false end, 6)

      state = Game.snapshot(game)
      assert requests(state, "/v2/my/ships/BASELINE-1/purchase") == []
      assert requests(state, "/v2/my/ships/BASELINE-1/refuel") == []
      assert state.low_credits == 49_000
    end

    # A pricing-model breach on the purchase leaves credits below the floor.
    # The trade then needs fuel the Ship cannot buy: no recovery-spend
    # exception, so the Ship's work blocks for the Operator instead.
    test "below-floor fuel stranding raises Attention instead of refuelling", %{conn: conn} do
      # 500 credits of headroom funds the 40-unit hold at the 25% margin; the
      # game charges 15 per unit (600), leaving 49,900 below the floor. 130
      # fuel covers surveying the distant Market and returning (60 + 60), not
      # the second 60-fuel leg to sell.
      game = start_game(credits: 50_500, purchase_charge: 15, fuel: 130, fuel_price: 72)
      {conn, agent} = activate_fresh_generation(conn)
      drive(game, fn _state -> false end, 10)

      state = Game.snapshot(game)
      assert [_purchase] = requests(state, "/v2/my/ships/BASELINE-1/purchase")
      assert state.credits == 49_900
      assert requests(state, "/v2/my/ships/BASELINE-1/refuel") == []

      # The Cargo stays aboard: the Ship never leaves for the selling Market.
      after_purchase =
        Enum.drop_while(state.requests, &(&1.path != "/v2/my/ships/BASELINE-1/purchase"))

      refute Enum.any?(after_purchase, &(&1.path == "/v2/my/ships/BASELINE-1/navigate"))
      assert state.units == 40

      blocked =
        Repo.all(
          from i in SpaceTraders.Fleet.Intent,
            join: ship in SpaceTraders.Fleet.Ship,
            on: ship.id == i.ship_id,
            where: ship.agent_id == ^agent.id and i.status == "blocked",
            select: i.blocker
        )

      assert Enum.any?(blocked, &(&1 && &1.reason == "credit_spending_paused")),
             "no stranding Attention: blocked=#{inspect(blocked)} #{inspect(paths(state))}"

      {:ok, _view, html} = live(conn, ~p"/mission-control")
      assert html =~ "Spending stays paused"
    end
  end

  # Gate 2A (#675): the multi-Ship partial-coverage trading handoff, through the
  # same seam. Nothing here selects, publishes or executes: the Operator
  # activates Strategy and the production runtime does the rest against a
  # physically located, fuel-consuming two-Ship game.
  describe "Gate 2A partial-coverage handoff" do
    test "a distant trade completes before coverage does", %{conn: conn} do
      game = start_fleet_game()
      {_conn, agent} = activate_fresh_generation(conn)
      drive(game, &fleet_sold?/1, 30)

      state = FleetGame.snapshot(game)
      assert fleet_sold?(state), fleet_trace(state)
      {before_sale, [sale | _]} = Enum.split_while(state.requests, &(not sale?(&1)))

      # The 60-unit route depth is capped to the frigate's 40-unit hold: one
      # purchase, by the cargo Ship, before the sale, at the planned price.
      assert [purchase] = Enum.filter(before_sale, &ship_post?(&1, "BASELINE-1", "purchase"))
      assert purchase.body == %{"symbol" => "IRON_ORE", "units" => 40}
      assert purchase.transaction["totalPrice"] == 400
      assert sale.transaction["shipSymbol"] == "BASELINE-1"
      assert {sale.transaction["units"], sale.transaction["totalPrice"]} == {40, 1200}

      # The evidence that made the route admissible came from a coverage
      # observation at the distant Market, taken before the purchase, while a
      # known Marketplace (A4) was still never observed.
      assert index_of(before_sale, &market_read?(&1, "A2")) <
               index_of(before_sale, &(&1 == purchase))

      refute Enum.any?(before_sale, &market_read?(&1, "A4"))

      # The probe, not the cargo Ship, did the scouting: the frigate only
      # trades, and only the probe ever left for an unobserved Marketplace.
      assert [%{body: %{"waypointSymbol" => "X1-UX81-A2"}}] =
               Enum.filter(before_sale, &ship_post?(&1, "BASELINE-1", "navigate"))

      assert Enum.any?(before_sale, &ship_post?(&1, "BASELINE-2", "navigate"))
      refute Enum.any?(state.requests, &ship_post?(&1, "BASELINE-2", "purchase"))

      # Independent admitted work continued while the frigate's Intent was
      # unfinished: the probe set out for another Marketplace after the frigate
      # had left, and before the frigate's sale.
      frigate_left = index_of(before_sale, &ship_post?(&1, "BASELINE-1", "navigate"))

      assert Enum.any?(
               Enum.drop(before_sale, frigate_left),
               &ship_post?(&1, "BASELINE-2", "navigate")
             )

      scouts = ship_symbols_of("acquire_intelligence")
      assert "BASELINE-2" in scouts
      refute "BASELINE-1" in scouts
      assert Enum.uniq(ship_symbols_of("buy") ++ ship_symbols_of("sell")) == ["BASELINE-1"]

      # The refuel topped the tank up at the observed source Market, the FUEL
      # transaction is the only supporting cost the game supplied, and the
      # source Listing survives it at its original observation time.
      assert [refuel] = Enum.filter(state.requests, &ship_post?(&1, "BASELINE-1", "refuel"))
      assert refuel.body == %{"units" => 170}
      fuel_cost = refuel.transaction["totalPrice"]
      assert fuel_cost == 144

      interpretation =
        SpaceTraders.Intelligence.market_interpretation(
          agent,
          FleetGame.system(),
          SpaceTraders.Clock.utc_now()
        )

      assert %{state: :current, observed_at: observed_at, trade_goods: goods} =
               Enum.find(interpretation.markets, &(&1.subject == "market:X1-UX81:X1-UX81-A1"))

      assert "IRON_ORE" in Enum.map(goods, & &1["symbol"])
      assert DateTime.compare(observed_at, refuel.at) != :gt
      open_gaps = interpretation.coverage_gaps

      # Realized economics are receipt-backed: the trade margin is proven from
      # the buy and sell transaction receipts, the supporting fuel cost is known
      # to the game fixture but not retained against the Episode, so Net
      # Earnings is reported unknown, never exact.
      progress = FleetAllocation.trade_progress(first_trade_episode_id())
      assert progress.completed_round_trips == 1
      assert {progress.units_bought, progress.units_sold} == {40, 40}
      assert {progress.credits_spent, progress.credits_received} == {400, 1200}
      assert progress.trade_margin == 1200 - 400
      assert progress.net_earnings == "unknown"

      # Every send is one recorded Mutation Attempt with a confirmed outcome:
      # one purchase, one refuel and one sale reached transport, none unknown.
      attempts = attempt_summary(agent)
      assert Enum.all?(attempts, &match?({_, _, "succeeded", "succeeded"}, &1))

      assert Enum.frequencies_by(attempts, &elem(&1, 0))
             |> Map.take(~w(purchase-cargo refuel-ship sell-cargo)) ==
               %{"purchase-cargo" => 1, "refuel-ship" => 1, "sell-cargo" => 1}

      assert 1200 - 400 - fuel_cost > 0
      assert 1200 - 400 - fuel_cost > 0

      # Outstanding Demand survives the trade selection: the unobserved
      # Marketplace is still owed an observation.
      assert Enum.any?(open_demand_subjects(), &(&1 == "market:X1-UX81:X1-UX81-A4"))
      assert Enum.any?(open_gaps, &(&1.subject =~ "A4"))
    end

    test "a runtime restart with Cargo in flight neither duplicates the buy nor strands the Cargo",
         %{conn: conn} do
      game = start_fleet_game()
      {_conn, agent} = activate_fresh_generation(conn)
      drive(game, &frigate_hauling?/1, 12)
      assert frigate_hauling?(FleetGame.snapshot(game)), fleet_trace(FleetGame.snapshot(game))
      settle_runtime()

      # Scouting is still owed when the runtime goes down.
      owed = open_demand_subjects()
      assert "market:X1-UX81:X1-UX81-A4" in owed
      before_restart = length(FleetGame.snapshot(game).requests)

      # Cross-seam qualification: interrupt the production runtime while the
      # frigate is in flight, then let production boot rebuild the work.
      assert :ok = stop_supervised!(DemandScheduler)
      assert :ok = stop_supervised!(Reconciler)
      SpaceTraders.Quiesced.stop_all_ships()
      advance_time(60)
      start_runtime()
      start_supervised!({ShipServerBoot, []})

      drive(game, &fleet_sold?/1, 30)
      state = FleetGame.snapshot(game)
      assert fleet_sold?(state), fleet_trace(state)
      {before_sale, [sale | _]} = Enum.split_while(state.requests, &(not sale?(&1)))

      # One purchase for that Commitment, all of it sold: nothing was bought
      # again after the restart and no Cargo was stranded or lost.
      assert [purchase] = Enum.filter(before_sale, &ship_post?(&1, "BASELINE-1", "purchase"))
      assert purchase.transaction["units"] == 40
      assert sale.transaction["units"] == 40
      assert Enum.take(state.requests, before_restart) |> Enum.count(&sale?/1) == 0

      # No Neutral Wait was invented and nothing was rejected without a reason.
      refute Repo.exists?(
               from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
                 where: e.selection_kind == :neutral_wait
             )

      # The unrelated scouting Commitment survived: the Marketplace owed an
      # observation before the restart is eventually observed.
      drive(game, fn s -> Enum.any?(s.requests, &market_read?(&1, "A4")) end, 30)
      assert Enum.any?(FleetGame.snapshot(game).requests, &market_read?(&1, "A4"))

      refute Enum.any?(
               market_interpretation(agent).coverage_gaps,
               &(&1.reason == :never_observed)
             )
    end

    test "a source price that moves after planning is refused and replanned from fresh evidence",
         %{conn: conn} do
      game = start_fleet_game()
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, &probe_departed?/1, 6)
      assert probe_departed?(FleetGame.snapshot(game))

      # The source Market reprices while the probe is still travelling: every
      # retained Listing still says 10, the game now asks 14 (still profitable).
      FleetGame.set_good(game, "X1-UX81-A1", "IRON_ORE", purchase_price: 14)

      drive(game, &fleet_sold?/1, 30)
      state = FleetGame.snapshot(game)
      assert fleet_sold?(state), fleet_trace(state)
      {before_sale, [sale | _]} = Enum.split_while(state.requests, &(not sale?(&1)))

      # Nothing was bought at the planned price: the refused purchase never
      # reached transport, and the replanned one pays the fresh price.
      assert [purchase] = Enum.filter(before_sale, &ship_post?(&1, "BASELINE-1", "purchase"))
      assert purchase.transaction["pricePerUnit"] == 14

      # The refused Intent ended with its reason; the Commitment replanned
      # instead of holding the Ship in a blocked state nobody resolves.
      assert [
               {"infeasible", %{"evidence" => %{"reason" => "price_constraint"}}},
               {"completed", _}
             ] =
               buy_intents() |> Enum.take(2)

      # Compatible work was retained: the probe kept scouting throughout.
      assert "BASELINE-2" in ship_symbols_of("acquire_intelligence")
      assert Enum.any?(before_sale, &market_read?(&1, "A3"))

      progress = FleetAllocation.trade_progress(first_trade_episode_id())
      assert {progress.credits_spent, progress.credits_received} == {40 * 14, 40 * 30}
      assert progress.trade_margin == 40 * (30 - 14)
      assert sale.transaction["totalPrice"] == 1200
    end

    test "a source price that makes the route unprofitable buys nothing and keeps scouting",
         %{conn: conn} do
      game = start_fleet_game()
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, &probe_departed?/1, 6)
      FleetGame.set_good(game, "X1-UX81-A1", "IRON_ORE", purchase_price: 35)

      drive(game, fn s -> Enum.any?(s.requests, &market_read?(&1, "A4")) end, 30)
      state = FleetGame.snapshot(game)

      # The repriced route loses money, so no IRON_ORE was bought at any price
      # and the refused Intent is not left blocking the Ship. (The Fleet may
      # still find the unrelated COPPER_ORE route; that is useful work.)
      refute Enum.any?(purchases(state), &(&1.body["symbol"] == "IRON_ORE"))
      assert Enum.any?(state.requests, &market_read?(&1, "A4"))
      assert [{"infeasible", _} | _] = buy_intents()
      refute Repo.exists?(from i in SpaceTraders.Fleet.Intent, where: i.status == "blocked")
    end

    test "API Retry-After defers Market reads without Attention or a Neutral Wait and the trade completes",
         %{conn: conn} do
      game = start_fleet_game(throttled_market_reads: 3)
      {_conn, agent} = activate_fresh_generation(conn)
      drive(game, &fleet_sold?/1, 40)

      state = FleetGame.snapshot(game)
      assert fleet_sold?(state), fleet_trace(state)
      assert Enum.count(state.requests, &(&1.reply == :throttled)) == 3

      # Capacity Deferral is advisory timing, never an Operator condition, a
      # false infeasibility or a wait minted by the Fleet.
      refute Repo.exists?(
               from c in SpaceTraders.OperatorConditions.Condition,
                 where: c.operator_id == ^agent.operator_id and c.kind == :attention
             )

      refute Repo.exists?(
               from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
                 where: e.selection_kind == :neutral_wait
             )

      refute Repo.exists?(
               from i in SpaceTraders.Fleet.Intent,
                 where: i.status in ["blocked", "infeasible"]
             )

      # Due scouting survived the deferral: the owed Marketplace is observed.
      drive(game, fn s -> Enum.any?(s.requests, &market_read?(&1, "A4")) end, 40)
      assert Enum.any?(FleetGame.snapshot(game).requests, &market_read?(&1, "A4"))
    end

    # The coverage completion boundary announces itself twice: a Waypoint
    # intelligence event and a Market evidence event. Capture the production
    # announcements while the Reconciler is down, then hand them to the restarted
    # Reconciler in each order. Both orders must reach the same one decision.
    for order <- [:market_first, :coverage_first] do
      test "swapped coverage and Market event order (#{order}) selects the same single trade",
           %{conn: conn} do
        order = unquote(order)
        game = start_fleet_game()
        {_conn, _agent} = activate_fresh_generation(conn)
        drive(game, &probe_departed?/1, 6)
        assert probe_departed?(FleetGame.snapshot(game))
        settle_runtime()

        Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_market_evidence")
        Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_intelligence_evidence")
        assert :ok = stop_supervised!(DemandScheduler)
        assert :ok = stop_supervised!(Reconciler)
        flush_fleet_events()

        advance_time(60)

        assert_eventually(
          fn -> Enum.any?(FleetGame.snapshot(game).requests, &market_read?(&1, "A2")) end,
          500
        )

        settle_ships()
        events = flush_fleet_events()
        market = Enum.filter(events, &match?({:market_evidence_observed, _, _}, &1))
        coverage = Enum.filter(events, &match?({:waypoint_intelligence_observed, _, _}, &1))
        assert market != [] and coverage != [], inspect(events)

        assert purchases(FleetGame.snapshot(game)) == []
        start_runtime()
        reconciler = Process.whereis(Reconciler)

        for event <-
              if(Atom.to_string(order) == "market_first",
                do: market ++ coverage,
                else: coverage ++ market
              ),
            do: send(reconciler, event)

        drive(game, &fleet_sold?/1, 30)
        state = FleetGame.snapshot(game)
        assert fleet_sold?(state), fleet_trace(state)
        {before_sale, [sale | _]} = Enum.split_while(state.requests, &(not sale?(&1)))

        assert [purchase] = Enum.filter(before_sale, &ship_post?(&1, "BASELINE-1", "purchase"))
        assert {purchase.transaction["units"], sale.transaction["units"]} == {40, 40}

        refute Repo.exists?(
                 from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
                   where:
                     e.selection_kind == :neutral_wait or
                       e.selection_kind == :publication_rejected
               )
      end
    end

    test "the pilot emits bounded allocation and invalidation telemetry without identities",
         %{conn: conn} do
      test_pid = self()
      handler = "q675-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:spacetraders, :fleet_allocation, :publication],
          [:spacetraders, :fleet_allocation, :market_domain],
          [:spacetraders, :intelligence, :invalidation]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      game = start_fleet_game()
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, &fleet_sold?/1, 30)
      assert fleet_sold?(FleetGame.snapshot(game))

      events = collect_telemetry()
      by_event = Enum.group_by(events, &elem(&1, 0))

      # G1: every publication outcome; G2: every trade-versus-coverage decision.
      assert [_ | _] = by_event[[:spacetraders, :fleet_allocation, :publication]]
      assert [_ | _] = decisions = by_event[[:spacetraders, :fleet_allocation, :market_domain]]

      assert Enum.any?(decisions, fn {_, m, meta} ->
               m.trade_candidates > 0 and meta.result == :published
             end)

      # G4: the refuel invalidated by cause, with counts only.
      assert [_ | _] = invalidations = by_event[[:spacetraders, :intelligence, :invalidation]]

      assert Enum.all?(invalidations, fn {_, _, meta} ->
               Map.keys(meta) |> Enum.sort() == [:cause, :subject_type]
             end)

      # Identities never ride telemetry metadata, so they cannot become labels.
      for {_event, _measurements, meta} <- events,
          key <- Map.keys(meta),
          do: refute(key in [:agent_id, :operator_id, :ship_symbol, :subject, :candidate_id])

      # Every rejected publication left a durable, inspectable Episode.
      rejected =
        Enum.count(by_event[[:spacetraders, :fleet_allocation, :publication]], fn {_, _, meta} ->
          meta.result == :rejected
        end)

      recorded =
        Repo.aggregate(
          from(e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
            where: e.selection_kind == :publication_rejected
          ),
          :count
        )

      assert recorded >= rejected
    end

    # The source Listing was observed while the probe set out for the distant
    # Market. Each fact below is one way that retained evidence stops being able
    # to authorize a purchase before the distant observation completes the
    # route. The Fleet must report the actual gap and re-observe the source
    # first, never buy against it, and never conclude there is no opportunity.
    for {kind, label} <- [
          stale: "aged past the Market freshness window",
          untraceable: "legacy without an exact retained source",
          invalidated: "invalidated by the game",
          wrong_generation: "from another Fleet Generation",
          future: "dated after the decision time"
        ] do
      test "a source Listing #{label} is re-observed before any purchase", %{conn: conn} do
        kind = unquote(kind)
        game = start_fleet_game()
        {_conn, agent} = activate_fresh_generation(conn)
        drive(game, &probe_departed?/1, 6)
        assert probe_departed?(FleetGame.snapshot(game)), fleet_trace(FleetGame.snapshot(game))
        assert purchases(FleetGame.snapshot(game)) == []

        tamper_source_listing(agent, kind)
        tampered_at = length(FleetGame.snapshot(game).requests)

        assert %{state: ^kind} = source_listing(agent)

        drive(game, &fleet_sold?/1, 30)
        state = FleetGame.snapshot(game)
        assert fleet_sold?(state), fleet_trace(state)

        {before_sale, _sale} = Enum.split_while(state.requests, &(not sale?(&1)))
        after_tamper = Enum.drop(before_sale, tampered_at)

        # The first purchase follows a fresh read of the source Market.
        assert index_of(after_tamper, &market_read?(&1, "A1")) <
                 index_of(after_tamper, &ship_post?(&1, "BASELINE-1", "purchase"))

        assert [_one] = Enum.filter(before_sale, &ship_post?(&1, "BASELINE-1", "purchase"))
      end
    end
  end

  # Gate 2B (#684, #685): the production Portfolio 4039 / Intent 4077 shape.
  # The scout's governed navigate is accepted, the Operator activates a new
  # Strategy Revision while it is in transit, the Ship arrives and its next
  # intelligence action is refused on old-Portfolio authority. Nothing here
  # selects, publishes or executes: the Operator activates through the
  # Strategy LiveView and the production runtime does the rest.
  describe "Gate 2B Revision change during coverage" do
    test "a Revision activated while the scout is in transit leaves no stale Claim behind",
         %{conn: conn} do
      game = start_fleet_game()
      {conn, agent} = activate_fresh_generation(conn)
      drive(game, &probe_departed?/1, 6)
      in_transit = FleetGame.snapshot(game)
      assert probe_departed?(in_transit), fleet_trace(in_transit)
      settle_runtime()

      # The scout's navigate reached transport and its attempt succeeded.
      [scout_navigate] =
        Enum.filter(in_transit.requests, &ship_post?(&1, "BASELINE-2", "navigate"))

      destination = scout_navigate.body["waypointSymbol"]
      refute Enum.any?(in_transit.requests, &market_read?(&1, String.slice(destination, -2, 2)))
      assert {"navigate-ship", _, "succeeded", "succeeded"} = last_attempt(agent, "navigate-ship")

      old_portfolio =
        FleetAllocation.current_portfolio(Scope.for_operator(operator(agent)), agent)

      old_revision = old_portfolio.fleet_strategy_revision_id
      assert scout_claimed?(old_portfolio, "BASELINE-2")

      # The Operator activates a new Revision while the scout is in transit.
      episode_floor = max_episode_id()
      activate_next_revision(conn, 2)
      new_revision = active_revision_id(agent)
      assert new_revision != old_revision

      # Still in transit: the accepted navigate is the scout's last action and
      # nothing has refused it yet.
      settle_runtime()
      during_transit = FleetGame.snapshot(game)
      assert during_transit.ships["BASELINE-2"].status == "IN_TRANSIT"
      assert [{"acquire_intelligence", status}] = scout_intents(agent)
      assert status in ~w(active waiting), fleet_trace(during_transit)

      # The activation's boundary retired the old Portfolio at once: the
      # scout's Commitment settles on its own Ship while BASELINE-1 already
      # holds active-Revision work. No Fleet-wide fence.
      transit_portfolio =
        FleetAllocation.current_portfolio(Scope.for_operator(operator(agent)), agent)

      assert transit_portfolio.fleet_strategy_revision_id == new_revision,
             fleet_trace(during_transit)

      assert scout_claimed?(transit_portfolio, "BASELINE-1"), fleet_trace(during_transit)
      refute scout_claimed?(transit_portfolio, "BASELINE-2"), fleet_trace(during_transit)
      assert [%{unwind_state: :settling}] = settling_scout(old_portfolio)

      # Normal time progression: the scout arrives and its next step is the
      # Revision-authority boundary.
      drive(game, &fleet_sold?/1, 30)
      state = FleetGame.snapshot(game)
      # The scout arrived where the accepted navigate sent it; its old-Revision
      # next step was refused, its Claim released, and it scouts again only
      # under an active-Revision Commitment: never a second navigate there.
      after_navigate =
        Enum.drop_while(state.requests, &(&1 != scout_navigate)) |> Enum.drop(1)

      assert %{path: "/v2/my/ships/BASELINE-2/navigate", body: %{"waypointSymbol" => next}} =
               Enum.find(after_navigate, &(&1.method == "POST" and &1.path =~ "BASELINE-2")),
             fleet_trace(state)

      assert next != destination
      assert [%{unwind_state: :released}] = settling_scout(old_portfolio)
      assert scout_claimed_under?(new_revision, "BASELINE-2"), fleet_trace(state)
      assert Enum.any?(state.requests, &market_read?(&1, String.slice(next, -2, 2)))

      report = revision_stall_report(agent, game, old_portfolio, new_revision, episode_floor)

      # The accepted navigate settled: nothing is sent-or-unknown, so no
      # Safety Fence is justified for the old Claim.
      assert report.unresolved_attempts == 0, report.text
      assert report.navigate_sends == 1, report.text

      # Desired forward progress under the active Revision.
      refute report.stale_claim?, "stale old-Revision Claim retained\n" <> report.text
      refute report.blocked_intents != [], "authority-blocked Intent retained\n" <> report.text

      assert Enum.any?(state.requests, &market_read?(&1, String.slice(destination, -2, 2))),
             "no current-Revision coverage of #{destination}\n" <> report.text

      assert fleet_sold?(state), "no current-Revision trade completed\n" <> report.text
      assert report.current_portfolio_revision == new_revision, report.text

      [sale] = Enum.filter(state.requests, &sale?/1)
      [purchase] = Enum.filter(state.requests, &ship_post?(&1, "BASELINE-1", "purchase"))
      assert sale.transaction["totalPrice"] > purchase.transaction["totalPrice"]
      assert report.duplicate_sends == [], report.text

      # Reconciliation is busy work, not a structural stall, and no rejected
      # publication is recorded per reconciliation tick.
      assert stall_episodes_since(episode_floor) == [], report.text

      refute Enum.any?(
               report.episodes_since_activation,
               &match?({_, :publication_rejected, _}, &1)
             ),
             report.text
    end
  end

  # The old Portfolio's scout Commitment (BASELINE-2), whatever its state.
  defp settling_scout(old_portfolio) do
    Repo.all(
      from c in SpaceTraders.FleetAllocation.Commitment,
        where:
          c.fleet_commitment_portfolio_id == ^old_portfolio.id and
            fragment("? = ANY(?)", "BASELINE-2", c.claims)
    )
  end

  defp scout_claimed_under?(revision_id, ship) do
    Repo.exists?(
      from c in SpaceTraders.FleetAllocation.Commitment,
        join: p in SpaceTraders.FleetAllocation.Portfolio,
        on: p.id == c.fleet_commitment_portfolio_id,
        where: p.fleet_strategy_revision_id == ^revision_id and ^ship in c.claims
    )
  end

  defp stall_episodes_since(floor) do
    Repo.all(
      from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
        where: e.id > ^floor and e.selection_kind == :structural_stall,
        order_by: e.id
    )
  end

  defp max_episode_id do
    Repo.one(from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode, select: max(e.id)) ||
      0
  end

  # The scout's first navigate destination, the one accepted before activation.
  defp old_destination(_portfolio, state) do
    state.requests
    |> Enum.find(&ship_post?(&1, "BASELINE-2", "navigate"))
    |> then(& &1.body["waypointSymbol"])
  end

  # The scout's unfinished Intents (completed coverage of its start excluded).
  defp scout_intents(agent) do
    Repo.all(
      from i in SpaceTraders.Fleet.Intent,
        join: ship in SpaceTraders.Fleet.Ship,
        on: ship.id == i.ship_id,
        where:
          ship.agent_id == ^agent.id and ship.symbol == "BASELINE-2" and
            i.status != "completed",
        select: {i.type, i.status}
    )
  end

  defp operator(agent), do: Repo.get!(Operator, agent.operator_id)

  defp active_revision_id(agent) do
    Repo.one!(
      from s in SpaceTraders.FleetStrategy.Strategy,
        where: s.operator_id == ^agent.operator_id,
        select: s.active_revision_id
    )
  end

  defp scout_claimed?(nil, _ship), do: false

  defp scout_claimed?(portfolio, ship),
    do: Enum.any?(portfolio.commitments, &(ship in &1.claims))

  defp last_attempt(agent, operation) do
    agent
    |> attempt_summary()
    |> Enum.filter(&(elem(&1, 0) == operation))
    |> List.last()
  end

  # The Operator re-activates the Steady Growth preset, as production
  # Revision 6 did.
  defp activate_next_revision(conn, number) do
    {:ok, strategy, _html} = live(conn, ~p"/strategy")
    strategy |> element("#select-preset-steady_growth") |> render_click()
    strategy |> element("#activate-strategy") |> render_click()
    assert render(strategy) =~ "Active revision #{number}"
  end

  # Every fact #685 names, read from durable state at one boundary: the
  # stale Portfolio and its Claim, blocked Intents, attempts, Demands,
  # Episodes, and any duplicate send the game saw.
  defp revision_stall_report(agent, game, old_portfolio, new_revision, episode_floor) do
    state = FleetGame.snapshot(game)
    now = SpaceTraders.Clock.utc_now()
    current = FleetAllocation.current_portfolio(Scope.for_operator(operator(agent)), agent)

    blocked =
      Repo.all(
        from i in SpaceTraders.Fleet.Intent,
          join: ship in SpaceTraders.Fleet.Ship,
          on: ship.id == i.ship_id,
          where: i.status == "blocked",
          select: {i.id, ship.symbol, i.type, i.blocker, i.fleet_commitment_id}
      )

    attempts = attempt_summary(agent)

    overdue =
      Repo.all(
        from d in SpaceTraders.Evidence.ObservationDemand,
          where:
            d.agent_id == ^agent.id and is_nil(d.withdrawn_at) and
              is_nil(d.fulfilled_observation_id) and
              d.strategy_revision_id == ^new_revision and d.due_at <= ^now and
              like(d.subject, "market:%"),
          select: d.subject
      )

    new_commitments =
      Repo.all(
        from c in SpaceTraders.FleetAllocation.Commitment,
          join: p in SpaceTraders.FleetAllocation.Portfolio,
          on: p.id == c.fleet_commitment_portfolio_id,
          where: p.fleet_strategy_revision_id == ^new_revision,
          select: {c.id, c.candidate_id, c.claims}
      )

    episodes_since =
      Repo.all(
        from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
          where: e.id > ^episode_floor,
          select: {e.id, e.selection_kind, e.fleet_strategy_revision_id}
      )

    sends =
      for r <- state.requests, r.method == "POST", r.reply == :ok, do: {r.path, r.body}

    duplicate_sends =
      sends
      |> Enum.frequencies()
      |> Enum.filter(fn {{path, _body}, count} ->
        count > 1 and String.ends_with?(path, ["/purchase", "/sell"])
      end)

    stale_claim? =
      current != nil and current.id == old_portfolio.id and
        current.fleet_strategy_revision_id != new_revision and
        scout_claimed?(current, "BASELINE-2")

    facts = %{
      old_portfolio: {old_portfolio.id, old_portfolio.fleet_strategy_revision_id},
      current_portfolio: current && {current.id, current.fleet_strategy_revision_id},
      active_revision: new_revision,
      blocked_intents: blocked,
      unresolved_attempts:
        Enum.count(
          attempts,
          &(elem(&1, 2) in ~w(prepared sent_or_unknown ambiguous bounded_unknown))
        ),
      attempts: Enum.frequencies_by(attempts, &{elem(&1, 0), elem(&1, 2)}),
      frigate: Map.take(state.ships["BASELINE-1"], [:status, :waypoint, :cargo, :fuel]),
      overdue_new_revision_market_demands: overdue,
      new_revision_commitments: new_commitments,
      episodes_since_activation: episodes_since
    }

    %{
      stale_claim?: stale_claim?,
      blocked_intents: blocked,
      unresolved_attempts: facts.unresolved_attempts,
      navigate_sends:
        Enum.count(
          state.requests,
          &(ship_post?(&1, "BASELINE-2", "navigate") and
              &1.body["waypointSymbol"] == old_destination(old_portfolio, state))
        ),
      current_portfolio_revision: current && current.fleet_strategy_revision_id,
      episodes_since_activation: episodes_since,
      duplicate_sends: duplicate_sends,
      text:
        inspect(facts, pretty: true, limit: :infinity, width: 120) <> "\n" <> fleet_trace(state)
    }
  end

  defp frigate_hauling?(state) do
    frigate = state.ships["BASELINE-1"]
    frigate.status == "IN_TRANSIT" and map_size(frigate.cargo) > 0
  end

  defp market_interpretation(agent) do
    SpaceTraders.Intelligence.market_interpretation(
      agent,
      FleetGame.system(),
      SpaceTraders.Clock.utc_now()
    )
  end

  defp buy_intents do
    Repo.all(
      from i in SpaceTraders.Fleet.Intent,
        where: i.type == "buy",
        order_by: i.id,
        select: {i.status, i.last_action_result}
    )
  end

  defp flush_fleet_events(acc \\ []) do
    receive do
      {kind, _agent_id, _subject} = event
      when kind in [:market_evidence_observed, :waypoint_intelligence_observed] ->
        flush_fleet_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp settle_ships do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor) do
      :sys.get_state(pid)
    end

    :ok
  end

  defp collect_telemetry(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        collect_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp probe_departed?(state),
    do: state.ships["BASELINE-2"].status == "IN_TRANSIT"

  defp purchases(state),
    do: Enum.filter(state.requests, &(&1.path =~ ~r{/purchase$} and &1.reply == :ok))

  defp source_listing(agent) do
    interpretation =
      SpaceTraders.Intelligence.market_interpretation(
        agent,
        FleetGame.system(),
        SpaceTraders.Clock.utc_now()
      )

    Enum.find(interpretation.markets, &(&1.subject == "market:X1-UX81:X1-UX81-A1"))
  end

  # Changes only what the retained evidence says about the source Marketplace,
  # never a Commitment, Portfolio or Ship action.
  defp tamper_source_listing(agent, kind) do
    now = SpaceTraders.Clock.utc_now()
    subject = "market:X1-UX81:X1-UX81-A1"

    evidence =
      from o in SpaceTraders.Evidence.Observation,
        where: o.agent_id == ^agent.id and o.subject == ^subject

    case kind do
      :stale ->
        aged = DateTime.add(now, -400)
        Repo.update_all(evidence, set: [observed_at: aged])

      :future ->
        Repo.update_all(evidence, set: [observed_at: DateTime.add(now, 86_400)])

      :wrong_generation ->
        Repo.update_all(evidence, set: [fleet_generation_id: nil])

      :untraceable ->
        Repo.update_all(
          from(o in SpaceTraders.Intelligence.Observation,
            where: o.agent_id == ^agent.id and o.subject_symbol == "X1-UX81-A1"
          ),
          set: [evidence_observation_id: nil]
        )

      :invalidated ->
        Repo.update_all(
          from(f in SpaceTraders.Intelligence.Fact,
            where:
              f.agent_id == ^agent.id and f.subject_symbol == "X1-UX81-A1" and
                f.field == "trade_goods"
          ),
          set: [invalidated_at: DateTime.add(now, -1) |> DateTime.truncate(:second)]
        )
    end
  end

  defp start_fleet_game(opts \\ []) do
    game = start_supervised!({FleetGame, opts})
    stub_api(fn conn -> FleetGame.reply(conn, FleetGame.call(game, conn)) end)
    allow_game_runtime()
    start_runtime()
    game
  end

  defp fleet_sold?(state), do: Enum.any?(state.requests, &sale?/1)

  defp sale?(request), do: request.path =~ ~r{/sell$} and request.reply == :ok

  defp ship_post?(request, ship, action),
    do: request.method == "POST" and request.path == "/v2/my/ships/#{ship}/#{action}"

  defp market_read?(request, suffix),
    do:
      request.method == "GET" and
        request.path == "/v2/systems/X1-UX81/waypoints/X1-UX81-#{suffix}/market"

  defp index_of(requests, fun), do: Enum.find_index(requests, fun) || flunk("no such request")

  defp ship_symbols_of(type) do
    Repo.all(
      from i in SpaceTraders.Fleet.Intent,
        join: ship in SpaceTraders.Fleet.Ship,
        on: ship.id == i.ship_id,
        where: i.type == ^type,
        distinct: true,
        order_by: ship.symbol,
        select: ship.symbol
    )
  end

  # The Decision Episode that published the first completed sell's Commitment.
  defp first_trade_episode_id do
    Repo.one!(
      from i in SpaceTraders.Fleet.Intent,
        join: c in SpaceTraders.FleetAllocation.Commitment,
        on: c.id == i.fleet_commitment_id,
        join: p in SpaceTraders.FleetAllocation.Portfolio,
        on: p.id == c.fleet_commitment_portfolio_id,
        where: i.type == "sell" and i.status == "completed",
        order_by: i.id,
        limit: 1,
        select: p.strategy_decision_episode_id
    )
  end

  defp attempt_summary(agent) do
    Repo.all(
      from a in Attempt,
        left_join: o in Outcome,
        on: o.mutation_attempt_id == a.id,
        where: a.agent_id == ^agent.id,
        order_by: [a.inserted_at, o.recorded_at],
        select: {a.operation_id, a.operation_owner, a.state, o.classification}
    )
  end

  defp open_demand_subjects do
    Repo.all(
      from d in SpaceTraders.Evidence.ObservationDemand,
        where: is_nil(d.withdrawn_at) and like(d.subject, "market:%"),
        select: d.subject
    )
  end

  # Failure message only: the actions the game saw (idle Agent/Fleet reads
  # elided), then what the Fleet decided and why.
  defp fleet_trace(state) do
    actions =
      for r <- state.requests, r.path not in ["/v2/my/agent", "/v2/my/ships"] do
        {String.slice(r.method, 0, 1), r.path |> String.replace("/v2/", ""), r.reply,
         Calendar.strftime(r.at, "%H:%M:%S")}
      end

    episodes =
      Repo.all(
        from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
          order_by: e.id,
          select:
            {e.id, e.selection_kind, e.rejection_reason, e.binding_limitation_kind,
             e.classification, e.alternatives}
      )

    commitments =
      Repo.all(
        from c in SpaceTraders.FleetAllocation.Commitment,
          order_by: c.id,
          select: {c.id, c.candidate_id, c.claims, c.decisive_reason}
      )

    demands =
      Repo.all(
        from d in SpaceTraders.Evidence.ObservationDemand,
          order_by: d.id,
          select: {d.subject, d.due_at, d.withdrawn_at}
      )

    intents =
      Repo.all(
        from i in SpaceTraders.Fleet.Intent,
          order_by: i.id,
          select: {i.id, i.type, i.status, i.target_waypoint, i.blocker}
      )

    inspect(
      %{
        actions: actions,
        episodes: episodes,
        commitments: commitments,
        intents: intents,
        demands: demands
      },
      limit: :infinity,
      pretty: true,
      width: 120
    )
  end

  # Funds one trade, then holds the frozen clock: the stranded Ship must be
  # offered nothing, so the game hears nothing.
  defp stranded_without_spin(conn, game_opts) do
    game = start_game(game_opts)
    {_conn, _agent} = activate_fresh_generation(conn)
    drive(game, &sold?/1)
    assert sold?(Game.snapshot(game)), trace(Game.snapshot(game))
    drive(game, fn _state -> false end, 8)
    Process.sleep(1_000)

    state = Game.snapshot(game)
    before = length(state.requests)
    Process.sleep(1_000)
    during_wait = length(Game.snapshot(game).requests) - before

    assert during_wait == 0,
           "#{during_wait} game requests in one second of frozen-clock wait after the trade " <>
             trace(Game.snapshot(game))

    # The stranded Ship is offered no trade, so no buy is attempted again.
    assert length(requests(Game.snapshot(game), "/v2/my/ships/BASELINE-1/purchase")) == 1

    refute Repo.exists?(
             from i in SpaceTraders.Fleet.Intent,
               where: i.type == "buy" and i.status == "infeasible"
           )
  end

  defp start_game(opts) do
    game = start_supervised!({Game, opts})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    start_runtime()
    game
  end

  # Advances controllable time to each next durable wakeup until the game
  # reaches the expected state or the rounds run out.
  defp drive(game, done?, rounds \\ 20) do
    Enum.reduce_while(1..rounds, :ok, fn _, :ok ->
      settle_or_busy()
      Process.sleep(20)
      settle_or_busy()

      if done?.(Game.snapshot(game)) do
        {:halt, :ok}
      else
        await_governor_window()

        case SpaceTraders.TestClock.next_due_at() do
          %DateTime{} = due_at ->
            advance_time(
              max(DateTime.diff(due_at, SpaceTraders.Clock.utc_now(), :microsecond), 0),
              :microsecond
            )

            {:cont, :ok}

          nil ->
            {:halt, :ok}
        end
      end
    end)

    settle_or_busy()
  end

  # The governor paces Retry-After on wall time while the runtime schedules on
  # the controllable clock. Synchronization only: let a server-imposed window
  # pass before waking deferred work, so rounds are not spent on early wakeups.
  defp await_governor_window do
    case SpaceTraders.API.CapacityGovernor.diagnostics() do
      %{retry_after_until: %DateTime{} = until} ->
        wait = DateTime.diff(until, DateTime.utc_now(), :millisecond)
        if wait > 0, do: Process.sleep(min(wait + 10, 2_000))

      _ ->
        :ok
    end
  end

  # Like settle_runtime/0, but a runtime process that stays busy (a blocking
  # Retry-After wait, or a Neutral Wait read loop) is reported by the
  # scenario's outcome assertions instead of aborting the drive.
  defp settle_or_busy do
    settle_runtime()
  catch
    :exit, {:timeout, _call} -> :busy
  end

  defp sold?(state), do: requests(state, "/v2/my/ships/BASELINE-1/sell") != []

  defp requests(state, path), do: Enum.filter(state.requests, &(&1.path == path))

  # Failure message only: the game transcript and the Agent's Intents.
  defp trace(state) do
    intents =
      Repo.all(
        from i in SpaceTraders.Fleet.Intent,
          join: ship in SpaceTraders.Fleet.Ship,
          on: ship.id == i.ship_id,
          where: ship.symbol == "BASELINE-1",
          order_by: i.id,
          select: {i.id, i.type, i.status, i.fleet_commitment_id, i.last_action_result}
      )

    inspect(%{requests: paths(state), intents: intents}, limit: :infinity, pretty: true)
  end

  defp paths(state), do: Enum.map(state.requests, &{&1.method, &1.path, &1.reply})

  defp activate_fresh_generation(conn) do
    email = "baseline-503-#{System.unique_integer([:positive])}@example.com"

    conn =
      post(conn, ~p"/setup", %{
        "operator" => %{
          "email" => email,
          "password" => "a long baseline password",
          "password_confirmation" => "a long baseline password",
          "account_token" => "BASELINE_ACCOUNT_TOKEN"
        }
      })

    assert get_session(conn, :operator_token)
    {:ok, mint, _html} = live(conn, ~p"/agents/new")

    assert {:error, {:redirect, %{to: "/mission-control", status: 302}}} =
             mint
             |> form("#mint_form", %{"agent" => %{"symbol" => "BASELINE", "faction" => "COSMIC"}})
             |> render_submit()

    {:ok, strategy, _html} = live(conn, ~p"/strategy")
    strategy |> element("#select-preset-steady_growth") |> render_click()
    strategy |> element("#activate-strategy") |> render_click()
    assert render(strategy) =~ "Active revision 1"

    {conn, Repo.get_by!(Agent, symbol: "BASELINE")}
  end

  defp start_runtime do
    start_supervised!({Reconciler, []})
    start_supervised!({DemandScheduler, []})
  end

  # Synchronization only: observe that already-delivered work has been handled.
  # These system messages neither wake reconciliation nor select a continuation.
  defp settle_runtime do
    :sys.get_state(DemandScheduler)
    :sys.get_state(Reconciler)

    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor) do
      :sys.get_state(pid)
    end

    :sys.get_state(Reconciler)
  end

  defp allow_game_runtime do
    Req.Test.allow(SpaceTraders.API, self(), fn ->
      runtime_pids = [
        Process.whereis(Reconciler),
        Process.whereis(SpaceTraders.Fleet.ShipServerBoot)
      ]

      ships =
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

      Enum.filter(runtime_pids ++ ships, &is_pid/1)
    end)
  end
end
