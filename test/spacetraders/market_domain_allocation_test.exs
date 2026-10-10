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
    Portfolio,
    Reconciler,
    StrategyDecisionEpisode,
    StructuralStall
  }

  alias SpaceTraders.FleetExecution
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

    test "reversing the evidence broadcast order selects the same portfolio" do
      # Each Fleet is decided before the next one's game stub replaces it.
      intelligence_first = fleet([@frigate, @probe])
      Reconciler.observe_waypoint_intelligence(intelligence_first.agent.id, @system, proceed())
      Reconciler.observe_market_evidence(intelligence_first.agent.id, @system, proceed())

      market_first = fleet([@frigate, @probe])
      Reconciler.observe_market_evidence(market_first.agent.id, @system, proceed())
      Reconciler.observe_waypoint_intelligence(market_first.agent.id, @system, proceed())

      assert published_work(intelligence_first) == published_work(market_first)
      assert published_work(market_first)["market_trade"] == [@frigate]
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
    end

    test "a rejected publication leaves a durable reason instead of a swallowed error" do
      fleet = fleet([@frigate, @probe])
      handler = attach_telemetry([:spacetraders, :fleet_allocation, :publication])

      # A newer Revision activates between the decision and its publication.
      stale = fleet.revision
      supersede_revision(fleet)

      assert {:ok, %{action: :publication_rejected, reason: :stale_source}} =
               FleetExecution.reconcile_market_domain(
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
               FleetExecution.reconcile_market_domain(
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
               FleetExecution.reconcile_market_domain(
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

      # A new Market observation (or a restart) reaches the same entry.
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)

      assert %{"buy" => 1, "sell" => 1} = intent_counts(trade)
      assert %Intent{} = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")

      # A later boundary neither buys nor sells again.
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      assert %{"buy" => 1, "sell" => 1} = intent_counts(trade)
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

    test "inherited Cargo is held for its sale, which the active Revision authorizes as a disposition" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      sell = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")

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

    test "an infeasible disposition sale does not fence its Ship forever" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)
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
    FleetExecution.reconcile_market_domain(
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
  defp fleet(ship_symbols) do
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
          "objectives" => [
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

    Repo.insert!(%Generation{
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
  defp stub_game(agent, ship_symbols) do
    ships = Enum.map(ship_symbols, &ship(&1, "#{agent.symbol}-#{&1}"))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "accountId" => "ACC",
              "symbol" => agent.symbol,
              "headquarters" => agent.headquarters,
              "credits" => 5_000,
              "startingFaction" => "COSMIC",
              "shipCount" => length(ships)
            }
          })

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => ships})

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

  defp refuse(conn) do
    conn
    |> Plug.Conn.put_status(400)
    |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "refused by test"}})
  end
end
