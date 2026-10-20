defmodule SpaceTraders.MarketDomainAllocationTest do
  # Commitment dispatch may start Ship servers in the shared registry.
  use SpaceTraders.DataCase, async: false

  import Ecto.Query
  import SpaceTraders.EvidenceFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation

  alias SpaceTraders.FleetAllocation.{
    Commitment,
    MarketDomain,
    Portfolio,
    Reconciler,
    StrategyDecisionEpisode,
    StructuralStall
  }

  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Test.CapacityDispositions

  @system "X1"
  @frigate "FRIGATE"
  @probe "PROBE"

  setup do
    on_exit(fn -> SpaceTraders.Quiesced.stop_all_ships() end)
    :ok
  end

  describe "the Market trade and coverage pilot domain" do
    test "at a coverage completion boundary trade and due coverage are chosen in one decision" do
      fleet = fleet([@frigate, @probe])

      assert :ok = Reconciler.observe_waypoint_intelligence(fleet.agent.id, @system, proceed())
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      assert %{"market_trade" => [@frigate], "market_coverage" => [@probe]} =
               published_work(fleet)

      # Both Commitments came from one Strategy Decision Episode, so neither
      # capability published ahead of the comparison.
      assert [episode] = selected_episodes(fleet)
      assert length(commitments_of(episode)) == 2
    end

    for order <- [:intelligence_first, :market_first] do
      test "#{order} evidence order selects the same coherent portfolio" do
        fleet = fleet([@frigate, @probe])

        if unquote(order) == :intelligence_first do
          Reconciler.observe_waypoint_intelligence(fleet.agent.id, @system, proceed())
          Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
        else
          Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
          Reconciler.observe_waypoint_intelligence(fleet.agent.id, @system, proceed())
        end

        assert published_work(fleet) == %{
                 "market_trade" => [@frigate],
                 "market_coverage" => [@probe]
               }
      end
    end

    test "with one capable Ship the positive trade wins and the Episode explains coverage's loss" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)

      assert %{"market_trade" => [@frigate]} = published_work(fleet)
      assert [episode] = selected_episodes(fleet)

      assert Enum.any?(episode.alternatives, fn alternative ->
               alternative["reasons"] == ["claim_conflict"] and
                 is_binary(alternative["decisive_reason"])
             end)
    end

    test "a busy Ship keeps its retained Commitment while the free Ship receives new work" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      %Portfolio{id: portfolio_id} = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

      # The coverage scout finished; the trader is still mid round trip.
      finish_intents(commitment_for(fleet, @probe))
      observe_marketplace(fleet.agent, "X1-A4", 4)

      assert {:ok, %{action: action}} = reconcile(fleet)
      assert action in [:published, :retained]

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert current.id == portfolio_id
      assert Enum.any?(current.commitments, &(&1.id == trade.id))

      # Only newly published work activates: the retained trade is never
      # dispatched a second time.
      assert %{"buy" => 1} = intent_counts(trade)
    end

    test "with every known Ship occupied the decision spends no game request" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)

      stub_game(fleet.agent, [@frigate, @probe], report_requests: true)

      assert {:ok, %{action: :retained, reason: :all_ships_occupied}} = reconcile(fleet)
      refute_received {:game_request, _method, _path}
    end

    test "an activation error is reported without undoing the published decision" do
      fleet = fleet([@frigate])
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)

      assert {:ok, %{action: :published, commitments: [trade], dispatched: dispatched}} =
               reconcile(fleet)

      assert {:error, _reason} = Map.fetch!(dispatched, trade.candidate_id)

      # The Portfolio and its Episode stay the durable decision.
      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert [%Commitment{id: id}] = current.commitments
      assert id == trade.id
      assert [episode] = selected_episodes(fleet)
      assert current.strategy_decision_episode_id == episode.id
      assert intent_counts(trade) == %{}
    end

    test "a rejected publication leaves a durable reason instead of a swallowed error" do
      fleet = fleet([@frigate, @probe])
      handler = attach_telemetry([:spacetraders, :fleet_allocation, :publication])

      # A newer Revision activates between the decision and its publication.
      stale = fleet.revision
      supersede_revision(fleet)

      assert {:ok, %{action: :publication_rejected, reason: :stale_source}} =
               MarketDomain.reconcile(
                 fleet.scope,
                 fleet.agent,
                 stale,
                 @system,
                 proceed()
               )

      assert [
               %StrategyDecisionEpisode{
                 selection_kind: :publication_rejected,
                 rejection_reason: "stale_source",
                 classification: :superseded
               } = episode
             ] = Repo.all(StrategyDecisionEpisode)

      assert episode.alternatives != []
      assert Repo.aggregate(Portfolio, :count) == 0

      assert_receive {:telemetry, ^handler, %{count: 1},
                      %{result: :rejected, reason: :stale_source}}
    end

    test "every domain decision reports trade and coverage candidate counts" do
      fleet = fleet([@frigate, @probe])
      handler = attach_telemetry([:spacetraders, :fleet_allocation, :market_domain])

      assert {:ok, _} = reconcile(fleet)

      assert_receive {:telemetry, ^handler,
                      %{
                        trade_candidates: trade,
                        coverage_candidates: 1,
                        claimable_ships: 2,
                        selected: 2
                      }, %{result: :published, decisive_reason: _}}

      assert trade >= 1
    end

    test "G1 and G2 outcomes reach the metrics scrape with bounded labels only" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :published}} = reconcile(fleet)

      metrics = PromEx.get_metrics(SpaceTraders.PromEx)

      assert metrics =~
               ~s(spacetraders_fleet_allocation_market_domain_decisions_total{decisive_reason="trade_and_coverage_selected",result="published"})

      assert metrics =~
               ~s(spacetraders_fleet_allocation_publication_total{operation="publish",reason="none",result="published"})

      refute metrics =~ ~r/spacetraders_fleet_allocation_[a-z_]+\{[^}]*(agent_id|generation_id)/
    end

    test "API-capacity deferral is explicit and publishes nothing" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :deferred_for_capacity}} =
               MarketDomain.reconcile(
                 fleet.scope,
                 fleet.agent,
                 fleet.revision,
                 @system,
                 CapacityDispositions.defer()
               )

      assert Repo.aggregate(Portfolio, :count) == 0
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end
  end

  describe "surplus-first acquisition at the Market boundary" do
    for evidence <- [:missing, :stale] do
      test "eligible investment refreshes #{evidence} reset evidence before purchasing" do
        fleet = investment_fleet(seed_status: unquote(evidence) == :stale)

        if source = SpaceTraders.Evidence.latest_observation(fleet.agent, "server:status") do
          Repo.update!(
            Ecto.Changeset.change(source, observed_at: DateTime.add(DateTime.utc_now(), -31))
          )
        end

        stub_game(fleet.agent, [@frigate],
          investment: true,
          reset_seconds: 864_000,
          purchase: :pending_readiness,
          refuse_ship_reads: true,
          report_requests: true
        )

        assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
        assert_received {:game_request, "GET", "/v2/"}
        assert_received {:game_request, "POST", "/v2/my/ships"}
        source = SpaceTraders.Evidence.latest_observation(fleet.agent, "server:status")
        assert source.operation_id == "get-status"
        assert source.fleet_generation_id == FleetAllocation.active_generation(fleet.agent).id
        assert {:ok, binding} = SpaceTraders.Evidence.retained_binding(fleet.agent, source.id)
        assert binding.observation.id == source.id

        purchase =
          FleetAllocation.current_portfolio(fleet.scope, fleet.agent).commitments
          |> Enum.find(&(&1.claims == []))

        episode = Repo.get!(StrategyDecisionEpisode, purchase.replan_decision_episode_id)

        assert episode.expectations["valuation"]["horizon"]["evidence_ref"]["observation_id"] ==
                 source.id
      end
    end

    test "failed reset refresh stays unknown and repeated boundaries do not loop on HTTP" do
      fleet = investment_fleet(seed_status: false)

      stub_game(fleet.agent, [@frigate],
        investment: true,
        refuse_ship_reads: true,
        report_requests: true
      )

      for _ <- 1..2 do
        assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      end

      assert_received {:game_request, "GET", "/v2/"}
      refute_received {:game_request, "GET", "/v2/"}
      refute_received {:game_request, "POST", "/v2/my/ships"}
      assert %{status: :unknown} = SpaceTraders.GenerationHorizon.current(fleet.agent)

      assert [refusal] =
               Repo.all(
                 from e in StrategyDecisionEpisode,
                   where: e.selection_kind == :acquisition_refused
               )

      assert refusal.rejection_reason == "unknown_generation_horizon"
      assert refusal.observation_count == 2
    end

    test "purchase capacity cannot authorize investment while the enabled trade's navigation is deferred" do
      fleet = investment_fleet()
      governor = :"acquisition_governor_#{System.unique_integer([:positive])}"

      start_supervised!(
        {SpaceTraders.API.CapacityGovernor, name: governor, probe_base_ms: 60_000}
      )

      previous = Application.fetch_env(:spacetraders, SpaceTraders.FleetCapacity)
      Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, governor: governor)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, value)
          :error -> Application.delete_env(:spacetraders, SpaceTraders.FleetCapacity)
        end
      end)

      operation = SpaceTraders.API.OperationInventory.fetch!("navigate-ship")
      assert {:ok, admission} = SpaceTraders.API.CapacityGovernor.admit(operation, %{}, governor)
      SpaceTraders.API.CapacityGovernor.complete(admission, 503, governor)

      assert SpaceTraders.FleetCapacity.proceed?(
               SpaceTraders.FleetCapacity.disposition("purchase-ship")
             )

      refute SpaceTraders.FleetCapacity.proceed?(
               SpaceTraders.FleetCapacity.disposition("navigate-ship")
             )

      stub_game(fleet.agent, [@frigate],
        investment: true,
        refuse_ship_reads: true,
        report_requests: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system)

      assert [refusal] =
               Repo.all(
                 from e in StrategyDecisionEpisode,
                   where: e.selection_kind == :acquisition_refused
               )

      assert refusal.rejection_reason == "capacity_not_proceed"
      refute_received {:game_request, "GET", "/v2/"}
      refute_received {:game_request, "POST", "/v2/my/ships"}
    end

    test "a worthwhile offer publishes claimless beside retained trade and dispatches under its own Episode" do
      fleet = investment_fleet()

      stub_game(fleet.agent, [@frigate],
        investment: true,
        purchase: :pending_readiness,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      purchases = Enum.filter(portfolio.commitments, &(&1.claims == []))
      assert length(purchases) == 1, inspect(Repo.all(StrategyDecisionEpisode), limit: :infinity)
      [purchase] = purchases
      assert purchase.claims == []
      assert purchase.reservations["credits"] == 2_250
      assert Enum.any?(portfolio.commitments, &(&1.id == fleet.trade.id))

      assert [attempt] =
               SpaceTraders.MutationAttempts.list_for_agent(fleet.agent)
               |> Enum.filter(&(&1.operation_id == "purchase-ship"))

      assert attempt.state == "succeeded"
      assert attempt.provenance["decision_episode_id"] == purchase.replan_decision_episode_id
      episode = Repo.get!(StrategyDecisionEpisode, purchase.replan_decision_episode_id)

      assert episode.expectations["valuation"]["enabled_work"]["decision_episode_id"] ==
               fleet.trade.replan_decision_episode_id

      assert episode.expectations["readiness"]["configuration"]["modules"] != []
      assert [_] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      refute Repo.get_by(Ship, agent_id: fleet.agent.id, symbol: ship_symbol(fleet, "PURCHASED"))
    end

    test "no Claim-only trade loser records an acquisition refusal without replacing Market evidence" do
      fleet = fleet([@frigate])
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      assert [refusal] =
               Repo.all(
                 from e in StrategyDecisionEpisode,
                   where: e.selection_kind == :acquisition_refused
               )

      assert refusal.rejection_reason == "no_claim_only_loser"
      assert refusal.calibration_version == "ship-acquisition-v2"
      assert refusal.expectations["domain"] == "ship_acquisition"
      assert [market] = selected_episodes(fleet)

      assert FleetAllocation.current_portfolio(fleet.scope, fleet.agent).strategy_decision_episode_id ==
               market.id

      refute Repo.exists?(
               from e in StrategyDecisionEpisode, where: e.selection_kind == :neutral_wait
             )
    end

    test "the exact surplus boundary protects the floor once and every retained Reservation once" do
      fleet = investment_fleet()

      stub_game(fleet.agent, [@frigate],
        investment: true,
        credits: 3_250,
        purchase: :pending_readiness,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert Enum.sum_by(portfolio.commitments, &(&1.reservations["credits"] || 0)) == 2_750
      assert Enum.count(portfolio.commitments, &(&1.claims == [])) == 1
    end

    test "registration alone grants no Claim and the next boundary allocates the purchased Ship normally" do
      fleet = investment_fleet()

      stub_game(fleet.agent, [@frigate],
        investment: true,
        purchase: :ready,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      symbol = ship_symbol(fleet, "PURCHASED")
      assert %Ship{} = Repo.get_by(Ship, agent_id: fleet.agent.id, symbol: symbol)

      assert {:error, :no_current_ship_claim} =
               FleetAllocation.current_ship_claim(fleet.agent, symbol)

      assert Enum.any?(
               FleetAllocation.current_portfolio(fleet.scope, fleet.agent).commitments,
               &(&1.id == fleet.trade.id)
             )

      stub_game(fleet.agent, [@frigate],
        investment: true,
        owned_purchase: true,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert {:ok, _claim} = FleetAllocation.current_ship_claim(fleet.agent, symbol)
    end

    test "later Market selection protects the pending purchase Reservation without double charging released trade" do
      fleet = investment_fleet()

      stub_game(fleet.agent, [@frigate],
        investment: true,
        purchase: :pending_readiness,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      [purchase] = Enum.filter(current.commitments, &(&1.claims == []))
      finish_intents(fleet.trade)
      listing(fleet.agent, "X1-A1", 80, 9)
      listing(fleet.agent, "X1-A2", 110, 100)
      listing(fleet.agent, "X1-A3", 120, 99)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert Enum.any?(current.commitments, &(&1.id == purchase.id))
      assert Enum.sum_by(current.commitments, &(&1.reservations["credits"] || 0)) <= 4_500
    end

    test "an owned but unregistered purchase cannot poison otherwise admissible Market selection" do
      fleet = investment_fleet()

      stub_game(fleet.agent, [@frigate],
        investment: true,
        purchase: :pending_readiness,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      stub_game(fleet.agent, [@frigate],
        investment: true,
        owned_purchase: true,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      refute Repo.exists?(
               from e in StrategyDecisionEpisode, where: e.selection_kind == :publication_rejected
             )

      assert {:error, :no_current_ship_claim} =
               FleetAllocation.current_ship_claim(fleet.agent, ship_symbol(fleet, "PURCHASED"))

      assert Enum.any?(
               FleetAllocation.current_portfolio(fleet.scope, fleet.agent).commitments,
               &(&1.claims == [])
             )

      assert [refusal] =
               Repo.all(
                 from e in StrategyDecisionEpisode,
                   where: e.selection_kind == :acquisition_refused
               )

      assert refusal.rejection_reason == "acquisition_already_unsettled"
    end

    test "refusal reason comes from the objective that owns the unmet work" do
      chart = %{
        "objective" => "Chart useful waypoints",
        "kind" => "continuous",
        "evaluation" => "Maximize useful waypoint coverage",
        "scope" => "recurring"
      }

      fleet = investment_fleet(horizon_seconds: 600, leading_objectives: [chart])

      stub_game(fleet.agent, [@frigate],
        investment: true,
        report_requests: true,
        refuse_ship_reads: true
      )

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      assert [refusal] =
               Repo.all(
                 from e in StrategyDecisionEpisode,
                   where: e.selection_kind == :acquisition_refused
               )

      assert refusal.rejection_reason == "enabled_value_not_above_cost"
      refute_received {:game_request, "POST", "/v2/my/ships"}
    end

    # #739 diagnosis: the matched counterpart of the worthwhile-offer case,
    # varying only the Shipyard offer evidence the preset Strategies never acquire.
    for shipyard <- [:absent, :aged] do
      test "#{shipyard} Shipyard offer evidence refuses an otherwise eligible investment" do
        fleet = investment_fleet(shipyard: unquote(shipyard))

        stub_game(fleet.agent, [@frigate],
          investment: true,
          report_requests: true,
          refuse_ship_reads: true
        )

        assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

        assert [refusal] =
                 Repo.all(
                   from e in StrategyDecisionEpisode,
                     where: e.selection_kind == :acquisition_refused
                 )

        assert refusal.rejection_reason == "shipyard_offers_unavailable"
        assert refusal.expectations["considered_work"] != []
        refute_received {:game_request, "GET", "/v2/"}
        refute_received {:game_request, "POST", "/v2/my/ships"}
      end
    end

    for {scenario, reason} <- [
          {:horizon, "unknown_generation_horizon"},
          {:value, "enabled_value_not_above_cost"},
          {:capacity, "capacity_not_proceed"},
          {:credits, "insufficient_acquisition_credits"},
          {:precondition, "purchase_precondition_unmet"}
        ] do
      test "#{scenario} refusal retains its evidence and never creates a Neutral Wait" do
        fleet =
          investment_fleet(
            horizon_seconds: if(unquote(scenario) == :value, do: 600, else: 864_000)
          )

        if unquote(scenario) == :horizon,
          do:
            Repo.delete_all(
              from o in SpaceTraders.Evidence.Observation, where: o.subject == "server:status"
            )

        changes =
          if unquote(scenario) == :precondition, do: %{"nav" => nav_at("X1-A2")}, else: %{}

        stub_game(fleet.agent, [@frigate],
          investment: true,
          report_requests: true,
          refuse_ship_reads: true,
          credits: if(unquote(scenario) == :credits, do: 3_000, else: 5_000),
          ship_changes: changes
        )

        capacity =
          if unquote(scenario) == :capacity, do: CapacityDispositions.defer(), else: proceed()

        assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, capacity)

        assert [refusal] =
                 Repo.all(
                   from e in StrategyDecisionEpisode,
                     where: e.selection_kind == :acquisition_refused
                 )

        assert refusal.rejection_reason == unquote(reason)
        assert refusal.expectations["considered_work"] != []
        assert refusal.calibration_version == "ship-acquisition-v2"
        unless unquote(scenario) == :capacity, do: assert(refusal.alternatives != [])

        refute Repo.exists?(
                 from e in StrategyDecisionEpisode, where: e.selection_kind == :neutral_wait
               )

        refute_received {:game_request, "POST", "/v2/my/ships"}

        if unquote(scenario) in [:capacity, :precondition],
          do: refute_received({:game_request, "GET", "/v2/"})
      end
    end
  end

  describe "durable Ship-bound unmet work" do
    test "the selected trade and its rejected alternative carry their net credits per Ship-hour" do
      fleet = fleet([@frigate])

      retained_market_listing(fleet.agent, @system, "X1-A1", [
        %{symbol: "IRON", purchase_price: 10, sell_price: 9, trade_volume: 60},
        %{symbol: "FUEL", purchase_price: 100, sell_price: 90, trade_volume: 60}
      ])

      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      # The speed-1 frigate at X1-A1: 6 units to X1-A3 burn 6 fuel (6 credits)
      # and take 165 s, so 14 × 40 − 6 = 554 credits is 12,087 per Ship-hour.
      assert [work] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      assert work.destination_waypoint == "X1-A3"
      assert work.planned_rate == 12_087

      assert %{
               "state" => "estimated",
               "ship" => ship,
               "net_credits" => 554,
               "seconds" => 165,
               "fuel_price" => 100
             } = work.expected_outcomes["trade_estimate"]

      assert ship == ship_symbol(fleet, @frigate)

      # X1-A2 won: 15 × 40 − 3 = 597 credits in 90 s, beating X1-A3.
      selected = commitment_for(fleet, @frigate)
      [episode] = selected_episodes(fleet)

      assert [chosen] = episode.expectations["selected_trades"]
      assert chosen["candidate_id"] == selected.candidate_id
      assert chosen["destination_waypoint"] == "X1-A2"
      assert chosen["net_credits_per_ship_hour"] == 23_880
      assert chosen["trade_estimate"]["seconds"] == 90

      assert [beaten] = chosen["alternatives"]
      assert beaten["candidate_id"] == work.candidate_id
      assert beaten["net_credits_per_ship_hour"] == 12_087
      assert beaten["trade_estimate"]["net_credits"] == 554
    end

    test "the last free Ship leaves a readable Claim-only trade alternative" do
      fleet = fleet([@frigate])
      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      assert [work] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      assert work.objective_index == 0
      assert work.objective["objective"] == "Grow credits"
      assert work.expected_outcomes["maximum_credit_change"] == 560
      # No FUEL is sold, so the frigate's fuel cannot be priced.
      assert work.planned_rate == nil
      assert work.expected_outcomes["trade_estimate"]["reason"] == "unknown_fuel_price"
      assert work.required_roles == [%{"role" => "market_trader", "count" => 1}]

      assert %{"capability" => "cargo_transport", "minimum_capacity" => 40} in work.required_capabilities

      assert %{"capability" => "market_access", "waypoints" => ["X1-A1", "X1-A3"]} in work.required_capabilities

      assert %DateTime{} = work.validity.as_of
      assert DateTime.compare(work.validity.expires_at, work.validity.as_of) == :gt
      assert [episode] = selected_episodes(fleet)
      assert work.decision_episode_id == episode.id

      assert Enum.any?(episode.alternatives, fn alternative ->
               alternative["candidate_id"] == work.candidate_id and
                 alternative["reasons"] == ["claim_conflict"]
             end)
    end

    test "invalidated Market evidence cannot justify unmet work" do
      fleet = fleet([@frigate])
      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert [_] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      assert {:ok, _} = Intelligence.invalidate(fleet.agent, :market, @system, "X1-A3")
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
    end

    test "expired decision evidence yields no work without reacquiring the game" do
      fleet = fleet([@frigate])
      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert [work] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      stub_game(fleet.agent, [@frigate], report_requests: true)

      assert [] =
               FleetAllocation.ship_bound_unmet_work(
                 fleet.agent,
                 DateTime.add(work.validity.expires_at, 1, :second)
               )

      refute_received {:game_request, _method, _path}
    end

    test "no decision or a superseded Revision yields no unmet work" do
      fleet = fleet([@frigate])
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert [_] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      supersede_revision(fleet)
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
    end

    test "a Claim conflict combined with exhausted credits is not Ship-bound unmet work" do
      fleet = fleet([@frigate])
      listing(fleet.agent, "X1-A1", 400, 390)
      listing(fleet.agent, "X1-A2", 600, 500)
      listing(fleet.agent, "X1-A3", 600, 490)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)

      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert [episode] = selected_episodes(fleet)

      assert Enum.any?(episode.alternatives, fn alternative ->
               alternative["reasons"] == ["claim_conflict", "insufficient_reservation"]
             end)

      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
    end

    for reason <- [
          "credit_floor",
          "unbacked_pledge",
          "unsatisfied_dependency",
          "observation_demand_unavailable"
        ] do
      test "a persisted Claim conflict also rejected for #{reason} is excluded" do
        fleet = fleet([@frigate])
        listing(fleet.agent, "X1-A3", 50, 24)
        stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
        assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
        assert [_] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

        # Arrange a durable rejected alternative with another binding reason.
        # The read must not reinterpret "contains Claim conflict" as Claim-only.
        [episode] = selected_episodes(fleet)

        alternatives =
          Enum.map(episode.alternatives, fn alternative ->
            Map.put(alternative, "reasons", ["claim_conflict", unquote(reason)])
          end)

        Repo.update!(Ecto.Changeset.change(episode, alternatives: alternatives))
        assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      end
    end

    for provenance <- [:untraceable, :wrong_generation, :future] do
      test "#{provenance} provenance cannot support previously rejected work" do
        fleet = fleet([@frigate])
        {source, retained} = listing(fleet.agent, "X1-A3", 50, 24)
        stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
        assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
        assert [_] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

        case unquote(provenance) do
          :untraceable ->
            Repo.update!(Ecto.Changeset.change(retained, evidence_observation_id: nil))

          :wrong_generation ->
            Repo.update!(Ecto.Changeset.change(source, fleet_generation_id: nil))

          :future ->
            Repo.update!(
              Ecto.Changeset.change(source,
                observed_at: DateTime.add(DateTime.utc_now(), 60, :second)
              )
            )
        end

        assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      end
    end

    test "a newer Listing never revalidates work planned from the older Listing" do
      fleet = fleet([@frigate])
      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert [_] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      listing(fleet.agent, "X1-A3", 50, 24)
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
    end

    test "only the latest Market Episode contributes, not older losers or another domain" do
      fleet = fleet([@frigate])
      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert [work] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      [episode] = selected_episodes(fleet)

      # A later decision outside Market must not replace Market evidence.
      unrelated = %{episode | id: nil, alternatives: [], expectations: %{"domain" => "other"}}
      Repo.insert!(unrelated)
      assert [^work] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      Repo.insert!(%{episode | id: nil, alternatives: []})
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
    end

    test "an alternative without its original evidence dependencies fails closed" do
      fleet = fleet([@frigate])
      listing(fleet.agent, "X1-A3", 50, 24)
      stub_game(fleet.agent, [@frigate], refuse_ship_reads: true)
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
      assert [_] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      [episode] = selected_episodes(fleet)

      alternatives =
        Enum.map(episode.alternatives, fn alternative ->
          update_in(alternative, ["alternative", "dependencies"], fn _ -> [] end)
        end)

      Repo.update!(Ecto.Changeset.change(episode, alternatives: alternatives))
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
    end
  end

  describe "Observation Demand retention through Allocation" do
    test "a selected trade leaves never-observed coverage open with its original timing, then coverage resumes" do
      fleet = fleet([@frigate])

      :ok =
        SpaceTraders.FleetIntelligence.sync_market_observation_demands(
          fleet.agent,
          fleet.revision,
          @system
        )

      before = open_market_demands(fleet)
      assert Map.has_key?(before, "market:X1:X1-A3"), inspect(Map.keys(before))

      assert {:ok, %{action: :published}} = reconcile(fleet)
      assert %{"market_trade" => [@frigate]} = published_work(fleet)

      # The trade did not withdraw, refresh or re-time the unfulfilled Demand.
      assert open_market_demands(fleet)["market:X1:X1-A3"] == before["market:X1:X1-A3"]

      # Valid retained evidence is not reacquired: its refresh waits for the
      # freshness budget instead of being due now.
      {_id, due_at, _deadline, _revision} = open_market_demands(fleet)["market:X1:X1-A1"]
      assert DateTime.compare(due_at, DateTime.utc_now()) == :gt

      # The trade finishes and its spread disappears: the one capable Ship is
      # free for the coverage the Demand still asks for.
      finish_intents(commitment_for(fleet, @frigate), DateTime.add(DateTime.utc_now(), -600))
      listing(fleet.agent, "X1-A2", 10, 9)

      assert {:ok, %{action: :published, dispatched: dispatched}} = reconcile(fleet)
      assert %{"market_coverage" => [@frigate]} = published_work(fleet)
      assert [{:ok, _intent}] = Map.values(dispatched)
      assert Map.has_key?(open_market_demands(fleet), "market:X1:X1-A3")
    end
  end

  describe "capacity deferral and missing evidence" do
    test "a capacity-deferred request names its retry time and keeps the Demand's earliest-useful time" do
      fleet = fleet([@frigate, @probe])

      :ok =
        SpaceTraders.FleetIntelligence.sync_market_observation_demands(
          fleet.agent,
          fleet.revision,
          @system
        )

      before = open_market_demands(fleet)
      deferral = CapacityDispositions.defer()

      assert {:ok,
              %{
                action: :deferred_for_capacity,
                retry_at: retry_at,
                reason: :capacity_deferred,
                pending_demands: pending
              }} =
               MarketDomain.reconcile(
                 fleet.scope,
                 fleet.agent,
                 fleet.revision,
                 @system,
                 deferral
               )

      assert retry_at == deferral.retry_at
      assert Enum.any?(pending, &(&1.subject == "market:X1:X1-A3"))
      assert open_market_demands(fleet) == before
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end

    test "invalid evidence is explained as a Market evidence limitation, not capacity or infeasibility" do
      fleet = fleet([@frigate])

      Repo.update_all(SpaceTraders.Intelligence.Fact, set: [invalidated_at: DateTime.utc_now()])

      assert {:ok,
              %{
                action: :no_admissible_commitment,
                reason: :market_evidence_unusable,
                neutral_wait: nil,
                evidence_limitations: limitations
              } = result} = reconcile(fleet)

      refute Map.has_key?(result, :retry_at)
      assert Enum.all?(limitations, &(&1.reason == :invalidated_market_evidence))

      # Neither a Neutral Wait nor an infeasibility verdict is recorded.
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end
  end

  describe "price and source changes" do
    test "a changed price replans the affected trade and keeps unrelated retained Commitments" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      coverage = commitment_for(fleet, @probe)
      %Portfolio{id: portfolio_id} = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

      # The trade leg finished long ago; the scout is still working.
      finish_intents(trade, DateTime.add(DateTime.utc_now(), -600))
      listing(fleet.agent, "X1-A1", 10, 9)
      listing(fleet.agent, "X1-A2", 40, 35)

      assert {:ok, %{action: :published, commitments: [replanned]}} = reconcile(fleet)

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert current.id == portfolio_id
      kept = Enum.find(current.commitments, &(&1.id == coverage.id))
      assert kept.claims == coverage.claims
      assert kept.reservations == coverage.reservations

      assert replanned.claims == trade.claims
      assert replanned.dependencies != trade.dependencies
      assert replanned.reservations["credits"] > 0

      claims = Enum.flat_map(current.commitments, & &1.claims)
      assert claims == Enum.uniq(claims)
    end
  end

  describe "buy-to-sell continuation" do
    test "a completed buy whose sell was never requested sells on the next Market boundary, once" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")

      # A deferred decision resumes nothing: continuation is new governed work.
      listing(fleet.agent, "X1-A2", 30, 25)

      assert {:ok, %{action: :retained_for_capacity}} =
               MarketDomain.reconcile(
                 fleet.scope,
                 fleet.agent,
                 fleet.revision,
                 @system,
                 CapacityDispositions.defer()
               )

      assert intent_counts(trade) == %{"buy" => 1}

      # A new Market observation (or a restart) reaches the same entry.
      assert {:ok, %{action: :retained}} = reconcile(fleet)

      assert %{"buy" => 1, "sell" => 1} = intent_counts(trade)
      assert %Intent{} = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")

      # A later boundary neither buys nor sells again.
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      assert %{"buy" => 1, "sell" => 1} = intent_counts(trade)
    end

    test "a sell resumed and finished at the boundary frees its Ship for the same decision" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")

      # The frigate waits docked at the sell Market with the bought Cargo.
      stub_game(fleet.agent, [@frigate], sell_at: "X1-A2")

      # Continuation runs before occupancy is read, so the finished round
      # trip no longer fences the frigate.
      assert {:ok, %{action: action}} = reconcile(fleet)
      assert action in [:published, :released]

      assert %Intent{status: "completed"} =
               Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")
    end

    test "a buy whose effect is unconfirmed is never replayed or continued" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "awaiting_confirmation")

      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)

      assert %{"buy" => 1} = counts = intent_counts(trade)
      refute Map.has_key?(counts, "sell")
    end
  end

  # #684: a Portfolio selected under an older Revision is reconciled at the
  # next Market boundary instead of being retained as current work.
  describe "Revision change reconciliation" do
    test "a settled, authority-blocked scout retires and the active Revision reselects without a fence" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      old = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      coverage = commitment_for(fleet, @probe)
      refuse_trade(commitment_for(fleet, @frigate))
      authority_block(coverage)

      fleet = activate_newer_revision(fleet)

      assert {:ok, %{action: :published}} = reconcile(fleet)

      # The settled Intent retired with its reason; nothing was replayed.
      assert [%Intent{status: "superseded", last_action_result: result}] =
               intents_of(coverage)

      assert %{"reason" => "strategy_revision_superseded"} = result

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert current.fleet_strategy_revision_id == fleet.revision.id
      assert %{"market_coverage" => [_scout]} = published_work(fleet)

      # The old selection keeps its own Revision and Episode, now superseded.
      old = Repo.preload(Repo.get!(Portfolio, old.id), :strategy_decision_episode)
      assert old.superseded_at
      assert old.strategy_decision_episode.classification == :superseded

      refute Repo.exists?(
               from e in StrategyDecisionEpisode,
                 where: e.selection_kind in [:publication_rejected, :structural_stall]
             )
    end

    test "a stale Portfolio retires even when API capacity defers the decision" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      old = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      coverage = commitment_for(fleet, @probe)
      refuse_trade(commitment_for(fleet, @frigate))
      authority_block(coverage)

      fleet = activate_newer_revision(fleet)

      # Retirement is local state and runs before the capacity gate, so the
      # deferral retains no obsolete authority.
      assert {:ok, %{action: :deferred_for_capacity}} =
               MarketDomain.reconcile(
                 fleet.scope,
                 fleet.agent,
                 fleet.revision,
                 @system,
                 CapacityDispositions.defer()
               )

      assert Repo.get!(Portfolio, old.id).superseded_at
      assert FleetAllocation.current_portfolio(fleet.scope, fleet.agent) == nil
      assert [%Intent{status: "superseded"}] = intents_of(coverage)
    end

    test "an unresolved scout action fences only its own Ship while the free Ship takes new-Revision work" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      old = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      coverage = commitment_for(fleet, @probe)
      refuse_trade(commitment_for(fleet, @frigate))
      unresolved(coverage)

      fleet = activate_newer_revision(fleet)

      # The first boundary retires the obsolete Portfolio and the free
      # frigate is selected under the active Revision.
      assert {:ok, %{action: :published}} = reconcile(fleet)
      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert current.fleet_strategy_revision_id == fleet.revision.id
      assert [frigate_work] = current.commitments
      assert frigate_work.claims == [ship_symbol(fleet, @frigate)]

      for _tick <- 1..3, do: assert({:ok, _} = reconcile(fleet))

      # The unresolved Intent is untouched: recovery, not Allocation, owns it.
      assert [%Intent{status: "active", in_flight_action: %{}}] = intents_of(coverage)

      # Its Commitment keeps the old Claim, attribution and Episode, on its
      # own Ship only; the old Portfolio is no longer current.
      assert %Commitment{unwind_state: :settling, fleet_commitment_portfolio_id: old_id} =
               Repo.get!(Commitment, coverage.id)

      assert old_id == old.id
      assert Repo.get!(Portfolio, old.id).superseded_at

      assert {:ok, %{commitment_id: claimed, decision_episode_id: episode_id}} =
               FleetAllocation.current_ship_claim(fleet.agent, ship_symbol(fleet, @probe))

      assert claimed == coverage.id
      assert episode_id == old.strategy_decision_episode_id

      # Busy reconciliation is not a structural stall or a rejected publication.
      refute Repo.exists?(
               from e in StrategyDecisionEpisode,
                 where: e.selection_kind in [:publication_rejected, :structural_stall]
             )

      # Recovery settles the action; the next boundary releases its Claim.
      authority_block(coverage)
      assert {:ok, _} = reconcile(fleet)
      assert %Commitment{unwind_state: :released} = Repo.get!(Commitment, coverage.id)
      assert [%Intent{status: "superseded"}] = intents_of(coverage)

      refute match?(
               {:ok, %{commitment_id: id}} when id == coverage.id,
               FleetAllocation.current_ship_claim(fleet.agent, ship_symbol(fleet, @probe))
             )

      old = Repo.preload(Repo.get!(Portfolio, old.id), :strategy_decision_episode, force: true)
      assert old.strategy_decision_episode.classification == :superseded
    end

    for variant <- [:prepared_not_sent, :sent_or_unknown] do
      test "a #{variant} scout action is never replayed and fences only its own Ship" do
        fleet = fleet([@frigate, @probe])
        assert {:ok, %{action: :published}} = reconcile(fleet)
        coverage = commitment_for(fleet, @probe)
        refuse_trade(commitment_for(fleet, @frigate))
        attempt = recorded_attempt(fleet, coverage, unquote(variant))

        fleet = activate_newer_revision(fleet)

        for _tick <- 1..3, do: assert({:ok, _} = reconcile(fleet))

        # The attempt and its Intent are untouched: MutationAttempts stays
        # the one recovery authority, and nothing re-sends the action.
        assert Repo.get!(SpaceTraders.MutationAttempts.Attempt, attempt.id).state ==
                 attempt.state

        assert [%Intent{status: status, mutation_attempt_id: attempt_id}] =
                 intents_of(coverage)

        assert status in Intent.unfinished_states()
        assert attempt_id == attempt.id
        assert %Commitment{unwind_state: :settling} = Repo.get!(Commitment, coverage.id)

        # The free frigate holds active-Revision work meanwhile.
        current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
        assert current.fleet_strategy_revision_id == fleet.revision.id
        assert Enum.any?(current.commitments, &(&1.claims == [ship_symbol(fleet, @frigate)]))
      end
    end

    test "a lost activation wake and a restart: a later boundary reconciles from durable state" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      old = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      coverage = commitment_for(fleet, @probe)
      unresolved(coverage)

      # Activation committed but its wake was lost: no boundary ran.
      fleet = activate_newer_revision(fleet)
      assert FleetAllocation.current_portfolio(fleet.scope, fleet.agent).id == old.id

      # After a restart, a later Market evidence boundary in a fresh process
      # reaches the same decision from durable state alone.
      task =
        Task.async(fn ->
          Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())
        end)

      assert :ok = Task.await(task, 30_000)

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert current.fleet_strategy_revision_id == fleet.revision.id
      assert Repo.get!(Portfolio, old.id).superseded_at
      assert %Commitment{unwind_state: :settling} = Repo.get!(Commitment, coverage.id)
    end

    test "inherited Cargo is held for its sale, which the active Revision authorizes as a disposition" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      sell = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")

      sale_under_way(trade)
      fleet = activate_newer_revision(fleet)

      # The disposition occupies its own Ship: busy, not a structural stall.
      assert {:ok, %{action: :retained, reason: :all_ships_occupied}} = reconcile(fleet)
      assert %Commitment{unwind_state: :settling} = Repo.get!(Commitment, trade.id)
      assert Repo.get!(Intent, sell.id).status in Intent.unfinished_states()
      assert stall_episodes() == []

      # The sale passes the active Revision's authority; a buy would not.
      assert {:ok, _selected} =
               SpaceTraders.Fleet.Intents.RecordedAction.prepare(
                 fleet.agent,
                 Repo.get!(Intent, sell.id),
                 %{"kind" => "sell", "trade_symbol" => "IRON", "units" => 40}
               )

      Repo.update!(Ecto.Changeset.change(Repo.get!(Intent, sell.id), status: "completed"))
      buy = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "buy")
      Repo.update!(Ecto.Changeset.change(buy, status: "active", finished_at: nil))

      assert {:error, :strategy_revision_absent} =
               SpaceTraders.Fleet.Intents.RecordedAction.prepare(
                 fleet.agent,
                 Repo.get!(Intent, buy.id),
                 %{"kind" => "buy", "trade_symbol" => "IRON", "units" => 5, "listing_price" => 10}
               )
    end

    test "a partial sale leaves the rest inherited, and a disposition that ends releases its Ship" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      sell = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")
      sale_under_way(trade)
      fleet = activate_newer_revision(fleet)
      assert {:ok, _} = reconcile(fleet)

      # 25 of the 40 bought units sold: 15 are still inherited.
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Intent, sell.id),
          status: "completed",
          last_action_result: %{"transaction" => %{"units" => 25, "total_price" => 625}}
        )
      )

      portfolio_id = Repo.get!(Commitment, trade.id).fleet_commitment_portfolio_id

      assert MapSet.member?(
               FleetAllocation.inherited_cargo_commitment_ids(portfolio_id),
               trade.id
             )

      # The sale ended: nothing is under way, so the fence ends and the units
      # left aboard are reported, never hidden.
      log =
        capture_info(fn ->
          assert {:ok, _} = reconcile(fleet)
        end)

      assert %Commitment{unwind_state: :released} = Repo.get!(Commitment, trade.id)
      assert log =~ "released a settled Commitment with inherited Cargo aboard"
      assert log =~ "undisposed_units=15"
    end

    test "a blocked disposition sale with no unresolved attempt retires and releases its Ship" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      sale_under_way(trade)
      fleet = activate_newer_revision(fleet)
      assert {:ok, _} = reconcile(fleet)
      assert %Commitment{unwind_state: :settling} = Repo.get!(Commitment, trade.id)

      # The sale is refused for a reason that is not infeasibility; nothing
      # is in flight and no attempt is unresolved.
      authority_block(trade)

      log =
        capture_info(fn ->
          assert {:ok, _} = reconcile(fleet)
        end)

      assert %Intent{status: "superseded"} =
               Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")

      assert %Commitment{unwind_state: :released} = Repo.get!(Commitment, trade.id)
      assert log =~ "with inherited Cargo aboard"
      assert log =~ "commitment_id=#{trade.id}"
      assert log =~ "undisposed_units=40"
    end

    test "Cargo aboard with no sale under way at retirement is released with a warning" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")

      # The bought leg is past its handoff and no sell was ever requested.
      Repo.update_all(
        from(i in Intent, where: i.fleet_commitment_id == ^trade.id and i.type == "buy"),
        set: [finished_at: DateTime.add(DateTime.utc_now(:second), -600)]
      )

      fleet = activate_newer_revision(fleet)

      log =
        capture_info(fn ->
          assert {:ok, _} = reconcile(fleet)
        end)

      assert %Commitment{unwind_state: :released} = Repo.get!(Commitment, trade.id)
      assert log =~ "with inherited Cargo aboard"
      assert log =~ "commitment_id=#{trade.id}"
      assert log =~ "undisposed_units=40"
    end

    test "an infeasible disposition sale does not fence its Ship forever" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      sale_under_way(trade)
      fleet = activate_newer_revision(fleet)
      assert {:ok, _} = reconcile(fleet)
      assert %Commitment{unwind_state: :settling} = Repo.get!(Commitment, trade.id)

      Repo.update_all(
        from(i in Intent, where: i.fleet_commitment_id == ^trade.id and i.type == "sell"),
        set: [status: "infeasible", finished_at: DateTime.utc_now(:second)]
      )

      log =
        capture_info(fn ->
          assert {:ok, %{action: action}} = reconcile(fleet)
          assert action != :retained
        end)

      assert %Commitment{unwind_state: :released} = Repo.get!(Commitment, trade.id)
      assert log =~ "undisposed_units=40"
    end
  end

  describe "Revision activation and decision logs" do
    test "every activation logs its decisive ids, with or without a live Generation" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      old = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      newer = newer_revision(fleet)

      log = capture_info(fn -> :ok = FleetGeneration.activate_strategy(fleet.scope, newer) end)

      assert log =~ "Fleet Strategy Revision activated"
      assert log =~ "agent_id=#{fleet.agent.id}"
      assert log =~ "previous_revision_id=#{fleet.revision.id}"
      assert log =~ "active_revision_id=#{newer.id}"
      assert log =~ "portfolio_id=#{old.id}"
      assert log =~ "decision_episode_id=#{old.strategy_decision_episode_id}"
      assert log =~ "commitment_ids=#{Enum.map_join(old.commitments, ",", & &1.id)}"

      # No live Generation: the activation is still logged, and says so.
      Repo.update_all(Generation, set: [retired_at: DateTime.utc_now()])
      newest = newer_revision(fleet)
      log = capture_info(fn -> :ok = FleetGeneration.activate_strategy(fleet.scope, newest) end)

      assert log =~ "Fleet Strategy Revision activated"
      assert log =~ "active_revision_id=#{newest.id}"
      assert log =~ "disposition=no_live_generation"
    end

    test "every Market decision logs its Generation, even with no Portfolio" do
      fleet = fleet([@frigate, @probe])
      generation = Repo.get_by!(Generation, agent_id: fleet.agent.id)

      log =
        capture_info(fn ->
          MarketDomain.reconcile(
            fleet.scope,
            fleet.agent,
            fleet.revision,
            @system,
            CapacityDispositions.defer()
          )
        end)

      assert log =~ "Fleet Allocation Market domain decision"
      assert log =~ "fleet_generation_id=#{generation.id}"
      assert log =~ "active_revision_id=#{fleet.revision.id}"
      assert log =~ "result=deferred_for_capacity"
      assert log =~ "decisive_reason=capacity_deferred"

      log = capture_info(fn -> assert {:ok, %{action: :published}} = reconcile(fleet) end)
      portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert log =~ "result=published"
      assert log =~ "portfolio_id=#{portfolio.id}"
      assert log =~ "decision_episode_id=#{portfolio.strategy_decision_episode_id}"
    end
  end

  describe "structural stall disposition" do
    test "an unchanged stall observed 500 times is one durable Episode until it changes" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      authority_block(commitment_for(fleet, @probe))
      decision = %{result: {:ok, %{action: :retained}}, counts: %{}}

      for _tick <- 1..500,
          do: StructuralStall.observe(fleet.agent, fleet.revision, portfolio, decision)

      assert [%{stall_reason: :authority_blocked_intent, observation_count: 500} = first] =
               stall_episodes()

      # A changed binding reason resolves the old disposition and opens one.
      newer = activate_newer_revision(fleet)
      StructuralStall.observe(newer.agent, newer.revision, portfolio, decision)

      assert [%{id: id, resolved_at: %DateTime{}}, %{stall_reason: :stale_revision_portfolio}] =
               stall_episodes()

      assert id == first.id
    end

    test "an open stall survives a restart: a fresh process refreshes the same Episode" do
      fleet = fleet([@frigate, @probe])
      overdue_market_demand(fleet)
      decision = %{result: {:ok, %{action: :retained}}, counts: %{claimable_ships: 1}}

      assert {:stalled, first} =
               StructuralStall.observe(fleet.agent, fleet.revision, nil, decision)

      restarted =
        Task.async(fn -> StructuralStall.observe(fleet.agent, fleet.revision, nil, decision) end)

      assert {:stalled, %{id: id, observation_count: 2}} = Task.await(restarted)
      assert id == first.id
      assert [_one] = stall_episodes()
    end

    test "overdue Demands with zero coverage candidates and no current-Revision reason stall" do
      fleet = fleet([@frigate, @probe])
      overdue_market_demand(fleet)

      decision = %{
        result: {:ok, %{action: :retained}},
        counts: %{coverage_candidates: 0, claimable_ships: 1}
      }

      assert {:stalled, %{stall_reason: :overdue_demands_without_coverage}} =
               StructuralStall.observe(fleet.agent, fleet.revision, nil, decision)
    end

    test "a structural stall records one episode that recovery closes" do
      fleet = fleet([@frigate, @probe])
      overdue_market_demand(fleet)
      stalled = %{result: {:ok, %{action: :retained}}, counts: %{claimable_ships: 1}}

      for _tick <- 1..3 do
        assert {:stalled, _episode} =
                 StructuralStall.observe(fleet.agent, fleet.revision, nil, stalled)
      end

      assert [%{id: episode_id}] = stall_episodes()

      assert %{resolved_at: nil} = Repo.get!(StrategyDecisionEpisode, episode_id)

      explained = %{result: {:ok, %{action: :retained}}, counts: %{coverage_candidates: 1}}
      assert :healthy = StructuralStall.observe(fleet.agent, fleet.revision, nil, explained)
      assert %{resolved_at: %DateTime{}} = Repo.get!(StrategyDecisionEpisode, episode_id)
    end

    test "an errored decision or one without candidate counts explains nothing" do
      fleet = fleet([@frigate, @probe])
      overdue_market_demand(fleet)

      # Unknown availability is not a decisive reason: the stall is visible.
      assert {:stalled, %{stall_reason: :overdue_demands_without_coverage} = stall} =
               StructuralStall.observe(fleet.agent, fleet.revision, nil, %{
                 result: {:error, :availability_unknown},
                 counts: %{}
               })

      # Missing counts are not "no claimable Ship": the same stall refreshes.
      assert {:stalled, %{id: id, observation_count: 2}} =
               StructuralStall.observe(fleet.agent, fleet.revision, nil, %{
                 result: {:ok, %{action: :retained}},
                 counts: %{}
               })

      assert id == stall.id
    end

    test "a recorded Neutral Wait is a decisive reason, not a stall" do
      fleet = fleet([@frigate, @probe])
      overdue_market_demand(fleet)

      assert :healthy =
               StructuralStall.observe(fleet.agent, fleet.revision, nil, %{
                 result:
                   {:ok,
                    %{action: :no_admissible_commitment, neutral_wait: %StrategyDecisionEpisode{}}},
                 counts: %{coverage_candidates: 0, claimable_ships: 1}
               })
    end

    test "a Ship trading under the active Revision with overdue Demands is busy, not stalled" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      overdue_market_demand(fleet)
      busy = %{result: {:ok, %{action: :retained, reason: :all_ships_occupied}}, counts: %{}}

      assert :healthy = StructuralStall.observe(fleet.agent, fleet.revision, portfolio, busy)
      assert stall_episodes() == []
    end

    test "retained coverage, Capacity Deferral and an open Shortfall explain overdue Demands" do
      fleet = fleet([@frigate, @probe])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      overdue_market_demand(fleet)
      none = %{coverage_candidates: 0, claimable_ships: 1}

      # Single-scout: current-Revision coverage is retained.
      assert :healthy =
               StructuralStall.observe(fleet.agent, fleet.revision, portfolio, %{
                 result: {:ok, %{action: :retained}},
                 counts: none
               })

      assert :healthy =
               StructuralStall.observe(fleet.agent, fleet.revision, nil, %{
                 result: {:ok, %{action: :deferred_for_capacity}},
                 counts: %{}
               })

      Repo.insert!(%SpaceTraders.CreditCalibration.Shortfall{
        agent_id: fleet.agent.id,
        kind: "revision_floor",
        credits: 100,
        credit_floor: 500,
        detected_at: DateTime.utc_now()
      })

      assert :healthy =
               StructuralStall.observe(fleet.agent, fleet.revision, nil, %{
                 result: {:ok, %{action: :retained}},
                 counts: none
               })

      assert stall_episodes() == []
    end
  end

  defp authority_block(commitment) do
    Repo.update_all(
      from(intent in Intent,
        where: intent.fleet_commitment_id == ^commitment.id and intent.status != "completed"
      ),
      set: [
        status: "blocked",
        in_flight_action: nil,
        mutation_attempt_id: nil,
        blocker: %SpaceTraders.Fleet.IntentBlocker{
          reason: "strategy_revision_absent",
          summary: "Ship action cannot progress: strategy_revision_absent.",
          evidence: ":strategy_revision_absent",
          observed_at: DateTime.utc_now(:second),
          resolver: "game_state",
          retry_condition: "authoritative_state_changed",
          corrective_actions: ["resume"]
        },
        last_action_result: %{"kind" => "navigate", "status" => "IN_TRANSIT"}
      ]
    )
  end

  # The sell leg is progressing (the stubbed game refuses every action, which
  # would otherwise leave it blocked).
  defp sale_under_way(commitment) do
    Repo.update_all(
      from(intent in Intent,
        where: intent.fleet_commitment_id == ^commitment.id and intent.type == "sell"
      ),
      set: [status: "active", blocker: nil, in_flight_action: nil]
    )
  end

  # The trader's buy was refused long ago: its Ship is free, it holds no Cargo.
  defp refuse_trade(commitment) do
    Repo.update_all(
      from(intent in Intent, where: intent.fleet_commitment_id == ^commitment.id),
      set: [
        status: "infeasible",
        finished_at: DateTime.add(DateTime.utc_now(:second), -600)
      ]
    )
  end

  # A sent action whose outcome is not yet reconciled.
  defp unresolved(commitment) do
    Repo.update_all(
      from(intent in Intent,
        where: intent.fleet_commitment_id == ^commitment.id and intent.status != "completed"
      ),
      set: [status: "active", blocker: nil, in_flight_action: %{"kind" => "navigate"}]
    )
  end

  # A real MutationAttempt for the scout's Intent: prepared but not sent
  # (the action is still queued in flight), or sent with an unknown outcome
  # (the Intent blocked awaiting reconciliation).
  defp recorded_attempt(fleet, commitment, variant) do
    [intent] = intents_of(commitment)
    generation = Repo.get_by!(Generation, agent_id: fleet.agent.id)

    action =
      if variant == :prepared_not_sent,
        do: %{"kind" => "navigate", "waypoint_symbol" => "X1-A3"},
        else: nil

    attempt =
      Repo.insert!(%SpaceTraders.MutationAttempts.Attempt{
        operator_id: fleet.agent.operator_id,
        agent_id: fleet.agent.id,
        fleet_generation_id: generation.id,
        operation_id: "navigate-ship",
        operation_owner: "ship_execution",
        state: if(variant == :prepared_not_sent, do: "prepared", else: "sent_or_unknown"),
        request_fingerprint: "scout-#{System.unique_integer([:positive])}",
        prepared_at: DateTime.utc_now(),
        sent_or_unknown_at: if(variant == :sent_or_unknown, do: DateTime.utc_now()),
        prepared_evidence: %{},
        provenance: %{
          "intent_id" => intent.id,
          "selected_action_fingerprint" => action && SpaceTraders.Evidence.fingerprint(action)
        }
      })

    Repo.update!(
      Ecto.Changeset.change(intent,
        status: if(variant == :prepared_not_sent, do: "active", else: "blocked"),
        in_flight_action: action,
        mutation_attempt_id: attempt.id
      )
    )

    attempt
  end

  defp intents_of(commitment) do
    Repo.all(
      from intent in Intent,
        where:
          intent.fleet_commitment_id == ^commitment.id and intent.type == "acquire_intelligence",
        order_by: intent.id
    )
  end

  defp stall_episodes do
    Repo.all(
      from e in StrategyDecisionEpisode,
        where: e.selection_kind == :structural_stall,
        order_by: e.id
    )
  end

  defp overdue_market_demand(fleet) do
    :ok =
      SpaceTraders.FleetIntelligence.sync_market_observation_demands(
        fleet.agent,
        fleet.revision,
        @system
      )

    Repo.update_all(
      from(d in SpaceTraders.Evidence.ObservationDemand,
        where: d.agent_id == ^fleet.agent.id and like(d.subject, "market:%")
      ),
      set: [due_at: DateTime.add(DateTime.utc_now(), -60), owner: "fleet_planning"]
    )
  end

  # The Operator activates a newer Revision: the Strategy and the live
  # Generation move to it, as `FleetGeneration.activate_strategy/2` does.
  defp activate_newer_revision(fleet) do
    supersede_revision(fleet)
    strategy = Repo.get!(Strategy, fleet.revision.fleet_strategy_id)
    newer = Repo.get!(Revision, strategy.active_revision_id)

    Repo.update_all(
      from(g in Generation, where: g.agent_id == ^fleet.agent.id),
      set: [fleet_strategy_revision_id: newer.id]
    )

    %{fleet | revision: newer}
  end

  defp complete_buy(commitment, status) do
    Repo.update_all(
      from(intent in Intent,
        where: intent.fleet_commitment_id == ^commitment.id and intent.type == "buy"
      ),
      set: [
        status: status,
        finished_at: DateTime.utc_now(:second),
        last_action_result: %{"units" => 40, "transaction" => %{"total_price" => 400}}
      ]
    )
  end

  defp intent_counts(commitment) do
    Repo.all(
      from intent in Intent,
        where: intent.fleet_commitment_id == ^commitment.id,
        group_by: intent.type,
        select: {intent.type, count(intent.id)}
    )
    |> Map.new()
  end

  describe "last-chance authority" do
    test "publication is refused when a newer Market observation superseded the planned evidence" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published, commitments: [trade]}} = reconcile(fleet)

      listing(fleet.agent, "X1-A1", 10, 9)
      listing(fleet.agent, "X1-A2", 40, 35)

      assert {:error, :stale_evidence} =
               SpaceTraders.FleetAllocation.MarketDomain.revalidate_trade_evidence(fleet.agent, [
                 trade
               ])
    end

    test "the dispatched buy cannot spend above the quote the decision was planned on" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)

      buy = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "buy")
      assert buy.parameters["max_price"] == 10
    end
  end

  defp open_market_demands(fleet) do
    fleet.agent
    |> SpaceTraders.Evidence.list_open_demands()
    |> Map.new(&{&1.subject, {&1.id, &1.due_at, &1.deadline_at, &1.strategy_revision_id}})
  end

  defp reconcile(fleet) do
    MarketDomain.reconcile(
      fleet.scope,
      fleet.agent,
      fleet.revision,
      @system,
      proceed()
    )
  end

  defp proceed, do: CapacityDispositions.proceed()

  # Persisted Commitment kind => the Ships it claims, read from the current
  # Portfolio and its dispatched root Intents.
  defp published_work(fleet) do
    case FleetAllocation.current_portfolio(fleet.scope, fleet.agent) do
      nil ->
        %{}

      portfolio ->
        portfolio.commitments
        |> Enum.group_by(&commitment_kind/1, & &1.claims)
        |> Map.new(fn {kind, claims} ->
          {kind, claims |> List.flatten() |> Enum.map(&role(fleet, &1)) |> Enum.sort()}
        end)
    end
  end

  # Test config logs errors only; info logs are captured for one call (this
  # module is synchronous, and the suite captures every log).
  defp capture_info(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log([level: :info, metadata: :all], fun)
    after
      Logger.configure(level: level)
    end
  end

  defp ship_symbol(fleet, role), do: "#{fleet.agent.symbol}-#{role}"

  defp role(fleet, symbol), do: String.replace_prefix(symbol, fleet.agent.symbol <> "-", "")

  defp commitment_kind(%Commitment{dependencies: dependencies}) do
    if Enum.any?(dependencies, &Map.has_key?(&1, "evidence_id")),
      do: "market_trade",
      else: "market_coverage"
  end

  defp selected_episodes(fleet) do
    Repo.all(
      from episode in StrategyDecisionEpisode,
        where:
          episode.operator_id == ^fleet.operator.id and episode.selection_kind == :selected_plan,
        order_by: episode.id
    )
  end

  defp commitments_of(episode) do
    Repo.all(
      from commitment in Commitment,
        join: portfolio in Portfolio,
        on: portfolio.id == commitment.fleet_commitment_portfolio_id,
        where: portfolio.strategy_decision_episode_id == ^episode.id
    )
  end

  defp commitment_for(fleet, ship_symbol) do
    fleet.scope
    |> FleetAllocation.current_portfolio(fleet.agent)
    |> Map.fetch!(:commitments)
    |> Enum.find(&(&1.claims == ["#{fleet.agent.symbol}-#{ship_symbol}"]))
  end

  defp finish_intents(commitment, finished_at \\ DateTime.utc_now()) do
    Repo.update_all(
      from(intent in Intent, where: intent.fleet_commitment_id == ^commitment.id),
      set: [status: "completed", finished_at: DateTime.truncate(finished_at, :second)]
    )
  end

  defp attach_telemetry(event) do
    handler = "domain-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler,
      event,
      fn _event, measurements, metadata, _config ->
        send(test, {:telemetry, handler, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  # A new Revision of the Fleet's Strategy, not yet active.
  defp newer_revision(fleet) do
    strategy = Repo.get!(Strategy, fleet.revision.fleet_strategy_id)

    number =
      Repo.one(
        from r in Revision, where: r.fleet_strategy_id == ^strategy.id, select: max(r.number)
      )

    Repo.insert!(%Revision{
      fleet_strategy_id: strategy.id,
      number: number + 1,
      document: fleet.revision.document,
      source: "operator",
      activated_at: DateTime.utc_now(:second)
    })
  end

  defp supersede_revision(fleet) do
    strategy = Repo.get!(Strategy, fleet.revision.fleet_strategy_id)

    newer =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 2,
        document: fleet.revision.document,
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: newer.id))
  end

  # A frigate with a 40-unit hold and a fuel-free probe at X1-A1. X1-A1 and
  # X1-A2 hold current Listings with a positive IRON spread deeper than the
  # hold; X1-A3 is a known Marketplace never observed.
  defp fleet(ship_symbols, leading_objectives \\ []) do
    operator = Repo.insert!(%Operator{email: "domain-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%SpaceTraders.Agent.Agent{
        symbol: "DOMAIN#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-A1",
        agent_token: "test-agent-token",
        operator_id: operator.id
      })

    for role <- ship_symbols,
        do:
          Repo.insert!(%Ship{
            symbol: "#{agent.symbol}-#{role}",
            ship_type: "SHIP_PROBE",
            agent_id: agent.id
          })

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" =>
            leading_objectives ++
              [
                %{
                  "objective" => "Grow credits",
                  "kind" => "continuous",
                  "evaluation" => "Maximize net credit growth over time",
                  "scope" => "recurring"
                }
              ],
          "hard_constraints" => ["Keep at least 500 credits available"]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    SpaceTraders.AgentFixtures.generation_fixture(%Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction,
      replacement_symbols: %{},
      objective_progress: %{}
    })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    observe_marketplace(agent, "X1-A1", 0)
    observe_marketplace(agent, "X1-A2", 3)
    observe_marketplace(agent, "X1-A3", 6)
    listing(agent, "X1-A1", 10, 9)
    listing(agent, "X1-A2", 30, 25)
    stub_game(agent, ship_symbols)

    %{operator: operator, agent: agent, revision: revision, scope: Scope.for_operator(operator)}
  end

  defp investment_fleet(opts \\ []) do
    fleet = fleet([@frigate], Keyword.get(opts, :leading_objectives, []))
    stub_game(fleet.agent, [@frigate], investment: true)
    listing(fleet.agent, "X1-A3", 50, 40)
    assert {:ok, %{action: :published}} = reconcile(fleet)
    completed_trade_sample(fleet, 1_800, 100)
    listing(fleet.agent, "X1-A1", 10, 9)
    listing(fleet.agent, "X1-A2", 30, 25)
    listing(fleet.agent, "X1-A3", 50, 24)
    stub_game(fleet.agent, [@frigate], investment: true, refuse_ship_reads: true)
    assert {:ok, %{action: :published}} = reconcile(fleet)
    trade = commitment_for(fleet, @frigate)

    body = investment_ship(ship_symbol(fleet, "PURCHASED"))

    shipyard = Keyword.get(opts, :shipyard, :fresh)

    {:ok, _} =
      if shipyard == :absent,
        do: {:ok, nil},
        else:
          Intelligence.observe_shipyard(
            fleet.agent,
            @system,
            SpaceTraders.API.Model.Shipyard.from_json(%{
              "symbol" => "X1-A1",
              "modificationsFee" => 500,
              "shipTypes" => [%{"type" => "SHIP_LIGHT_HAULER"}],
              "ships" => [
                Map.merge(
                  Map.take(body, ~w(frame reactor engine crew modules mounts)),
                  %{"type" => "SHIP_LIGHT_HAULER", "purchasePrice" => 1_000}
                )
              ]
            }),
            source: "get_shipyard",
            offers_visible: true,
            observed_at:
              DateTime.add(DateTime.utc_now(), if(shipyard == :aged, do: -301, else: 0))
          )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "status" => "online",
        "serverResets" => %{
          "next" =>
            DateTime.to_iso8601(
              DateTime.add(DateTime.utc_now(), Keyword.get(opts, :horizon_seconds, 864_000))
            )
        }
      })
    end)

    if Keyword.get(opts, :seed_status, true) do
      assert {:ok, _} =
               SpaceTraders.Evidence.get_status_binding(fleet.agent, owner: "fleet_acquisition")
    end

    Map.put(fleet, :trade, trade)
  end

  defp investment_ship(symbol) do
    body = ship(@frigate, symbol)

    Map.merge(body, %{
      "frame" => Map.put(body["frame"], "fuelCapacity", 0),
      "fuel" => %{"capacity" => 0, "current" => 0},
      "modules" => [
        %{
          "symbol" => "MODULE_CARGO_HOLD_I",
          "capacity" => 40,
          "name" => "Cargo",
          "description" => "Cargo",
          "requirements" => %{"crew" => 1, "power" => 1, "slots" => 1}
        }
      ]
    })
  end

  defp observe_marketplace(agent, symbol, x) do
    waypoint =
      Waypoint.from_json(%{
        "symbol" => symbol,
        "systemSymbol" => @system,
        "type" => "PLANET",
        "x" => x,
        "y" => 0,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")
  end

  defp listing(agent, waypoint, purchase_price, sell_price) do
    retained_market_listing(agent, @system, waypoint, [
      %{
        symbol: "IRON",
        purchase_price: purchase_price,
        sell_price: sell_price,
        trade_volume: 60,
        supply: "MODERATE",
        activity: "STATIC"
      }
    ])
  end

  defp completed_trade_sample(fleet, seconds, support_cost) do
    commitment = commitment_for(fleet, @frigate)
    portfolio = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
    buy = Repo.get_by!(Intent, fleet_commitment_id: commitment.id, type: "buy")
    now = DateTime.utc_now(:second)
    started = DateTime.add(now, -seconds - 60, :second)
    bought = DateTime.add(started, 10, :second)
    finished = DateTime.add(now, -60, :second)
    fixtures = SpaceTraders.RealizedEconomicsFixtures

    purchase = fixtures.refuel!(buy, 400, operation_id: "purchase-cargo")
    support = fixtures.refuel!(buy, support_cost)

    buy =
      Repo.update!(
        Ecto.Changeset.change(buy,
          status: "completed",
          inserted_at: started,
          finished_at: bought,
          mutation_attempt_id: purchase.id,
          last_action_result: %{
            "units" => 40,
            "transaction" => %{
              "trade_symbol" => "IRON",
              "waypoint_symbol" => "X1-A1",
              "units" => 40,
              "total_price" => 400
            }
          }
        )
      )

    sale =
      fixtures.trade_intent!(portfolio, commitment, "sell", 1_600, 40,
        ship: ship_symbol(fleet, @frigate)
      )

    sale =
      Repo.update!(
        Ecto.Changeset.change(sale,
          inserted_at: bought,
          finished_at: finished,
          last_action_result: %{
            "units" => 40,
            "transaction" => %{
              "trade_symbol" => "IRON",
              "waypoint_symbol" => "X1-A3",
              "units" => 40,
              "total_price" => 1_600
            }
          }
        )
      )

    %{buy: buy, sale: sale, support: support}
  end

  defp ship(@frigate, symbol) do
    ship_body(symbol, %{
      "nav" => nav_at("X1-A1"),
      "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
    })
  end

  defp ship(@probe, symbol) do
    body = ship_body(symbol)

    Map.merge(body, %{
      "nav" => nav_at("X1-A1"),
      "frame" => Map.put(body["frame"], "symbol", "FRAME_PROBE"),
      "fuel" => %{"capacity" => 0, "current" => 0},
      "cargo" => %{"capacity" => 0, "units" => 0, "inventory" => []}
    })
  end

  defp nav_at(waypoint) do
    nav_body("DOCKED")
    |> Map.put("systemSymbol", @system)
    |> Map.put("waypointSymbol", waypoint)
  end

  # The game answers Fleet reads; anything Ship execution attempts beyond
  # them is refused, which leaves dispatched Intents blocked but never
  # changes the allocation result under test.
  # `report_requests:` reports each request the calling test process makes
  # (reconciliation's own reads run there; Ship servers' do not);
  # `refuse_ship_reads:` refuses single-Ship reads, so activation fails;
  # `sell_at:` docks the frigate there with 40 IRON and accepts its sale.
  defp stub_game(agent, ship_symbols, opts \\ []) do
    ships =
      Enum.map(ship_symbols, fn role ->
        body =
          if Keyword.get(opts, :investment, false) and role == @frigate,
            do: investment_ship("#{agent.symbol}-#{role}"),
            else: ship(role, "#{agent.symbol}-#{role}")

        if role == @frigate,
          do: Map.merge(body, Keyword.get(opts, :ship_changes, %{})),
          else: body
      end)

    sell_at = Keyword.get(opts, :sell_at)
    trader = "#{agent.symbol}-#{@frigate}"
    sell_market = "#{sell_at}/market"

    ships =
      if sell_at,
        do: Enum.map(ships, &if(&1["symbol"] == trader, do: holding_iron(&1, sell_at), else: &1)),
        else: ships

    ships =
      if Keyword.get(opts, :owned_purchase),
        do: ships ++ [investment_ship("#{agent.symbol}-PURCHASED")],
        else: ships

    observer = if Keyword.get(opts, :report_requests, false), do: self()
    refuse_ship_reads? = Keyword.get(opts, :refuse_ship_reads, false)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      if observer == self(), do: send(observer, {:game_request, conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/"} ->
          case Keyword.get(opts, :reset_seconds) do
            seconds when is_integer(seconds) ->
              Req.Test.json(conn, %{
                "status" => "online",
                "serverResets" => %{
                  "next" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), seconds))
                }
              })

            _ ->
              refuse(conn)
          end

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "accountId" => "ACC",
              "symbol" => agent.symbol,
              "headquarters" => agent.headquarters,
              "credits" => Keyword.get(opts, :credits, 5_000),
              "startingFaction" => "COSMIC",
              "shipCount" => length(ships)
            }
          })

        {"GET", "/v2/systems/X1/waypoints/" <> path} when path == sell_market ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => sell_at,
              "tradeGoods" => [
                %{
                  "symbol" => "IRON",
                  "purchasePrice" => 30,
                  "sellPrice" => 25,
                  "tradeVolume" => 60
                }
              ]
            }
          })

        {"POST", "/v2/my/ships/" <> path} when is_binary(sell_at) and path == trader <> "/sell" ->
          Req.Test.json(conn, %{"data" => sale(agent, trader, sell_at)})

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => ships})

        {"POST", "/v2/my/ships"} ->
          assert Keyword.get(opts, :purchase)
          body = investment_ship("#{agent.symbol}-PURCHASED")

          Req.Test.json(conn, %{
            "data" => %{
              "ship" => body,
              "agent" => %{"symbol" => agent.symbol, "credits" => 4_000},
              "transaction" => %{
                "agentSymbol" => agent.symbol,
                "shipSymbol" => body["symbol"],
                "shipType" => "SHIP_LIGHT_HAULER",
                "waypointSymbol" => "X1-A1",
                "price" => 1_000,
                "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
              }
            }
          })

        {"GET", "/v2/my/ships/" <> symbol} when symbol == agent.symbol <> "-PURCHASED" ->
          if Keyword.get(opts, :purchase) == :ready,
            do: Req.Test.json(conn, %{"data" => investment_ship(symbol)}),
            else: refuse(conn)

        {"GET", "/v2/my/ships/" <> _symbol} when refuse_ship_reads? ->
          refuse(conn)

        {"GET", "/v2/my/ships/" <> symbol} ->
          case Enum.find(ships, &(&1["symbol"] == symbol)) do
            nil -> refuse(conn)
            body -> Req.Test.json(conn, %{"data" => body})
          end

        _other ->
          refuse(conn)
      end
    end)
  end

  defp holding_iron(ship, waypoint) do
    Map.merge(ship, %{
      "nav" => nav_at(waypoint),
      "cargo" => %{
        "capacity" => 40,
        "units" => 40,
        "inventory" => [%{"symbol" => "IRON", "units" => 40}]
      }
    })
  end

  defp sale(agent, ship_symbol, waypoint) do
    %{
      "agent" => %{"symbol" => agent.symbol, "credits" => 6_000},
      "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
      "transaction" => %{
        "type" => "SELL",
        "shipSymbol" => ship_symbol,
        "tradeSymbol" => "IRON",
        "waypointSymbol" => waypoint,
        "units" => 40,
        "pricePerUnit" => 25,
        "totalPrice" => 1_000
      }
    }
  end

  defp refuse(conn) do
    conn
    |> Plug.Conn.put_status(400)
    |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "refused by test"}})
  end
end
