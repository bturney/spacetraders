defmodule SpaceTraders.ShipyardPurchasePathTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.{Clock, Evidence, Fleet, FleetAllocation, MutationAttempts}
  alias SpaceTraders.ShipyardProofRuntime, as: Runtime
  alias SpaceTraders.ShipyardProofWorld, as: World

  @t0 ~U[2026-10-22 00:00:00Z]

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true) end)
    :ok
  end

  setup do
    start_supervised!({SpaceTraders.TestClock, @t0})
    previous = Application.fetch_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    start_supervised!(
      {SpaceTraders.API.CapacityGovernor, now: &Clock.utc_now/0, probe_base_ms: 1000}
    )

    controller = self()

    start_supervised!(
      {SpaceTraders.API.RateLimiter,
       clock: %{
         now: fn -> DateTime.diff(Clock.utc_now(), @t0, :millisecond) end,
         sleep: fn ms -> Runtime.wait(controller, :protocol, ms) end
       }}
    )

    on_exit(fn ->
      for symbol <- ~w(PROOF824-1 PROOF824-2 PROOF824-3),
          do: SpaceTraders.Quiesced.stop_ship(symbol)

      case previous do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      SpaceTraders.Test.Governor.restart()
    end)

    :ok
  end

  for preset <- ~w(steady_growth charted_expansion) do
    @preset preset
    test "#{preset}: ordinary unmet work observes, buys and registers the finite ready Ship" do
      world = start_supervised!({World, []})
      controller = self()
      context = start_supervised!({Elixir.Agent, fn -> nil end})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        fleet = Elixir.Agent.get(context, & &1)

        if conn.method == "POST" and conn.request_path == "/v2/my/ships" do
          send(controller, {:purchase_send, send_evidence(fleet, world)})
        end

        if conn.method == "GET" and conn.request_path == "/v2/my/ships/PROOF824-3" do
          send(
            controller,
            {:readiness_read, Clock.utc_now(), Fleet.owned_ship(fleet.agent, "PROOF824-3")}
          )
        end

        World.reply(world, conn, controller)
      end)

      Req.Test.allow(SpaceTraders.API, self(), fn ->
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
      end)

      fleet = Runtime.fresh_generation(world, @preset)
      Elixir.Agent.update(context, fn _ -> fleet end)
      refute Evidence.latest_observation(fleet.agent, "shipyard:X1-UX81:X1-UX81-A1")
      assert {:error, :ship_not_owned} = Fleet.owned_ship(fleet.agent, "PROOF824-3")
      start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))

      result =
        Runtime.finite_control(world, fleet, @preset, DateTime.add(@t0, 48, :hour),
          boundary: :application,
          stop_at_readiness: true
        )

      assert result.run_kind == "acquisition_readiness_prefix"
      assert DateTime.compare(result.as_of, DateTime.add(@t0, 48, :hour)) == :lt

      send_check =
        receive do
          {:purchase_send, evidence} -> evidence
        after
          0 -> nil
        end

      write_receipt(result, send_check)

      purchases =
        Enum.filter(result.request_effects, &(&1.method == "POST" and &1.path == "/v2/my/ships"))

      assert length(purchases) == 1,
             inspect(%{
               refusals:
                 for(
                   d <- result.decisions,
                   d.selection_kind == :acquisition_refused,
                   do: Enum.map(d.expectations["limitations"] || [], & &1["reason"])
                 ),
               requests: length(result.request_effects),
               acquisition_outlays: result.account.acquisition_outlays
             })

      assert {:ok, ship} = Fleet.owned_ship(fleet.agent, "PROOF824-3")
      assert ship.ship_type == "SHIP_LIGHT_HAULER"

      assert {:error, :no_current_ship_claim} =
               FleetAllocation.current_ship_claim(fleet.agent, ship.symbol)

      purchase_attempts =
        Enum.filter(
          MutationAttempts.list_for_agent(fleet.agent),
          &(&1.operation_id == "purchase-ship")
        )

      assert [attempt] = Enum.filter(purchase_attempts, &(&1.state == "succeeded"))
      assert Enum.all?(purchase_attempts, &(&1.state in ["succeeded", "not_sent"]))
      assert attempt.state == "succeeded"
      assert result.account.acquisition_outlays == 100_000
      assert_send_and_readiness(result, send_check, attempt, fleet)
    end
  end

  defp send_evidence(fleet, world) do
    [attempt] =
      Enum.filter(
        MutationAttempts.list_for_agent(fleet.agent),
        &(&1.operation_id == "purchase-ship" and &1.state == "sent_or_unknown")
      )

    portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
    purchase = Enum.find(portfolio.commitments, &(&1.id == attempt.provenance["commitment_id"]))
    episode = FleetAllocation.commitment_decision_episode(purchase)
    retained = Enum.reject(portfolio.commitments, &(&1.id == purchase.id))

    %{
      at: Clock.utc_now(),
      attempt:
        Map.take(
          attempt,
          ~w(id state prepared_at sent_or_unknown_at prepared_evidence provenance)a
        ),
      episode: Map.take(episode, ~w(id expectations evidence_references calibration_version)a),
      purchase: Map.take(purchase, ~w(id claims reservations dependencies)a),
      retained: Enum.map(retained, &Map.take(&1, ~w(id claims reservations dependencies)a)),
      current_work: FleetAllocation.ship_bound_unmet_work(fleet.agent),
      world: World.snapshot(world),
      registered: Fleet.owned_ship(fleet.agent, "PROOF824-3")
    }
  end

  defp assert_send_and_readiness(result, check, attempt, fleet) do
    assert check.registered == {:error, :ship_not_owned}
    assert check.attempt.id == attempt.id
    assert check.attempt.state == "sent_or_unknown"
    assert DateTime.compare(check.attempt.prepared_at, check.attempt.sent_or_unknown_at) != :gt
    assert check.attempt.sent_or_unknown_at == check.at

    assert Enum.any?(check.world.ships, fn {_symbol, ship} ->
             ship["nav"]["waypointSymbol"] == "X1-UX81-A1" and
               ship["nav"]["status"] in ["DOCKED", "IN_ORBIT"]
           end)

    assert check.purchase.claims == []
    assert check.purchase.reservations["credits"] == 135_000
    assert check.attempt.prepared_evidence["spending"]["worst_case_exposure"] == 125_000
    assert check.episode.calibration_version == "ship-acquisition-v2"

    valuation = check.episode.expectations["valuation"]

    assert valuation["calibration"] == %{
             "version" => "ship-acquisition-v2",
             "horizon_window_seconds" => 172_800,
             "no_history_discount" => 0.5
           }

    assert valuation["horizon"]["duration_seconds"] == 172_800
    assert valuation["enabled_value"] > 135_000
    assert valuation["offered_configuration"]["engine"]["speed"] == 1
    work = valuation["enabled_work"]
    assert work["expected_outcomes"]["net_credits_per_ship_hour"] == nil
    assert work["expected_outcomes"]["trade_estimate"]["fuel_price"] == 100

    assert Enum.any?(
             check.current_work,
             &(&1.candidate_id == work["candidate_id"] and
                 &1.decision_episode_id == work["decision_episode_id"])
           )

    protected = Enum.sum_by(check.retained, &(&1.reservations["credits"] || 0))
    assert protected >= 50_000
    pricing = first_cycle_pricing(result, check)
    assert pricing.goods_units == 40
    assert pricing.fuel_unit_price == 100
    assert pricing.goods_exposure + pricing.support_exposure <= 60_000
    # Protect the full frozen envelope, not just this independently priced
    # outlay. No new runtime Reservation or forecast sale funds the send.
    assert check.world.credits - result.floor - protected - 135_000 >= 60_000
    assert result.floor == if(result.preset == "steady_growth", do: 50_000, else: 75_000)
    assert result.account.low_credits >= result.floor
    assert result.account.unexplained_cash == 0
    assert result.account.credits == 400_000 + result.account.net_cash
    refute result.manifest.external_liability

    purchase =
      Enum.find(result.request_effects, &(&1.method == "POST" and &1.path == "/v2/my/ships"))

    assert purchase.started_at == check.at
    assert purchase.signed_cash == -100_000
    assert purchase.after.credits == purchase.before.credits - 100_000
    refute Map.has_key?(purchase.before.ships, "PROOF824-3")
    assert map_size(purchase.before.ships) == 2
    assert Map.has_key?(purchase.after.ships, "PROOF824-3")
    assert map_size(purchase.after.ships) == 3
    assert purchase.after.offer_stock == 0
    assert_received {:readiness_read, readiness_at, {:error, :ship_not_owned}}
    assert DateTime.compare(readiness_at, purchase.completed_at) != :lt

    source = Evidence.latest_observation(fleet.agent, "shipyard:X1-UX81:X1-UX81-A1")
    offers = Enum.filter(result.request_effects, &String.ends_with?(&1.path, "/shipyard"))
    observed = Enum.find(offers, &(&1.completed_at == source.observed_at))
    assert observed
    assert DateTime.compare(observed.completed_at, purchase.started_at) == :lt
    assert observed.before.ships["PROOF824-2"]["nav"]["waypointSymbol"] == "X1-UX81-A1"
    assert observed.before.ships["PROOF824-2"]["nav"]["status"] == "DOCKED"

    ready = Enum.find(result.request_effects, &(&1.path == "/v2/my/ships/PROOF824-3"))
    ship = SpaceTraders.API.Model.Ship.from_json(ready.response)
    offer = observed.response["ships"] |> hd() |> SpaceTraders.API.Model.ShipyardShip.from_json()

    for field <- ~w(frame reactor engine modules mounts)a,
        do: assert(Map.fetch!(ship, field) == Map.fetch!(offer, field))

    for field <- ~w(required capacity)a,
        do: assert(Map.fetch!(ship.crew, field) == Map.fetch!(offer.crew, field))

    assert {ship.cargo.capacity, ship.cargo.units, ship.fuel.current, ship.fuel.capacity} ==
             {40, 0, 100, 100}

    assert ship.cooldown.remaining_seconds == 0
    assert ship.crew.current >= ship.crew.required
    assert length(Fleet.current_ships(fleet.agent.id)) == 3

    readiness_source = Evidence.latest_observation(fleet.agent, "ship:PROOF824-3")
    assert readiness_source.operation_id == "get-my-ship"
    assert readiness_source.observed_at == ready.completed_at

    assert source.operation_id == "get-shipyard"
    assert source.observed_at == observed.completed_at

    facts = SpaceTraders.Intelligence.subject(fleet.agent, :shipyard, "X1-UX81", "X1-UX81-A1")
    assert facts["ships"].observation.evidence_observation_id == source.id

    assert Enum.any?(check.purchase.dependencies, fn dependency ->
             dependency["subject"] == "shipyard:X1-UX81:X1-UX81-A1" and
               dependency["evidence_id"] ==
                 "intelligence-observation:#{facts["ships"].observation_id}"
           end)

    assert {:ok, binding} = Evidence.retained_binding(fleet.agent, source.id)
    assert binding.observation.id == source.id
    assert binding.observation.observed_at == observed.completed_at

    assert Enum.any?(result.all_demands, fn demand ->
             demand.owner == "fleet_acquisition" and demand.subject == source.subject and
               DateTime.compare(demand.due_at, source.observed_at) == :lt
           end)

    assert Enum.any?(
             result.all_demands,
             &(&1.fulfilled_observation_id == source.id and &1.owner == "ship_execution")
           )

    assert Enum.any?(
             result.intents,
             &(&1.type == "acquire_intelligence" and &1.status == "completed" and
                 &1.parameters["subject_type"] == "shipyard" and
                 is_integer(&1.fleet_commitment_id))
           )

    assert Enum.any?(result.decisions, fn decision ->
             Enum.any?(decision.alternatives || [], &(&1["reasons"] == ["claim_conflict"]))
           end)

    assert Enum.all?(
             result.request_effects,
             &(DateTime.diff(&1.completed_at, &1.started_at, :millisecond) == 1000)
           )

    refute Enum.any?(result.request_effects, &Map.has_key?(&1, :failure))
  end

  defp write_receipt(result, send_check) do
    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      File.mkdir_p!(directory)

      receipt =
        Map.merge(result, %{
          ticket: 836,
          classification: "purchase/readiness prefix only; not P1/payback/Gate 0",
          send_check: send_check,
          independently_priced_first_cycle:
            if(send_check, do: first_cycle_pricing(result, send_check)),
          limits: [
            "No productive acquired-Ship cycle or payback claim; #837 remains separate.",
            "Pinned #834 controls retained separately; baseline mixed clocks preclude causal cash-superiority claims.",
            "This prefix stops at registration, not the full 48h cutoff/restart/reset matrix."
          ]
        })

      File.write!(
        Path.join(directory, "836-#{result.preset}.json"),
        Jason.encode!(Runtime.receipt_json(receipt), pretty: true)
      )
    end
  end

  defp first_cycle_pricing(result, check) do
    source =
      result.request_effects
      |> Enum.filter(fn request ->
        request.path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" and
          DateTime.compare(request.completed_at, check.at) != :gt
      end)
      |> List.last()

    trade = check.episode.expectations["valuation"]["enabled_work"]["trade_symbol"]
    goods = Enum.find(source.response["tradeGoods"], &(&1["symbol"] == trade))
    fuel = Enum.find(source.response["tradeGoods"], &(&1["symbol"] == "FUEL"))

    %{
      observed_at: source.completed_at,
      trade_symbol: trade,
      goods_units: 40,
      goods_unit_price: goods["purchasePrice"],
      goods_exposure: div(goods["purchasePrice"] * 40 * 125 + 99, 100),
      fuel_unit_price: fuel["purchasePrice"],
      # Two independently quoted full-tank purchases cover the loaded leg,
      # return and repeat preparation; current bought fuel is not free revenue.
      support_exposure: 2 * div(fuel["purchasePrice"] * 125 + 99, 100),
      protected_envelope: 60_000
    }
  end
end
