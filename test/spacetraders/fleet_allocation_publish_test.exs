defmodule SpaceTraders.FleetAllocationPublishTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio, StrategyDecisionEpisode}
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Outbox
  alias SpaceTraders.Outbox.Notification
  alias SpaceTraders.ShipReservation

  @as_of ~U[2030-01-01 12:00:00Z]

  test "fenced Fleet contribution owners refuse resource discovery and admission" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    revision =
      Repo.update!(
        Ecto.Changeset.change(revision,
          document: %{
            "objectives" => [%{"objective" => "Mine resources and fulfill Contracts"}],
            "hard_constraints" => revision.document["hard_constraints"]
          }
        )
      )

    assert {:ok, _} = SpaceTraders.FleetGeneration.current_fleet()
    Repo.update!(Ecto.Changeset.change(generation, fenced_at: DateTime.utc_now()))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      flunk(
        "Fenced Fleet must not acquire or mutate resources: #{conn.method} #{conn.request_path}"
      )
    end)

    for result <- [
          SpaceTraders.FleetResources.reconcile(scope, agent, revision, "X1-A"),
          SpaceTraders.FleetAcquisition.reconcile(scope, agent),
          SpaceTraders.FleetRefit.reconcile(scope, agent, revision, "X1-A"),
          SpaceTraders.FleetConstruction.reconcile(scope, agent, revision),
          SpaceTraders.FleetContracts.reconcile(scope, agent, revision),
          SpaceTraders.FleetContracts.accept_if_admissible(agent, revision, "CONTRACT", %{}),
          SpaceTraders.FleetContracts.negotiate_if_available(agent, revision, "SHIP-1"),
          SpaceTraders.FleetContracts.fulfill_if_ready(agent, revision, "CONTRACT"),
          SpaceTraders.FleetAllocation.MarketDomain.reconcile(scope, agent, revision, "X1-A", %{})
        ] do
      assert result == {:error, :current_fleet_unavailable}
    end

    assert :ok = SpaceTraders.FleetAllocation.Reconciler.observe_market_evidence(agent.id, "X1-A")
    assert :ok = SpaceTraders.FleetAllocation.Reconciler.wake_due_demands(agent.id)
    assert is_nil(FleetAllocation.current_portfolio(scope))
    assert SpaceTraders.MissionControl.availability(scope) == %{}
  end

  test "an allocation Scope authenticates the deployment Operator rather than selecting resources" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    portfolio = publish!(scope, generation, revision)
    forged_scope = %Scope{operator: %{id: scope.operator.id}}

    assert is_nil(FleetAllocation.current_portfolio(forged_scope))

    assert {:error, :invalid_publication} =
             FleetAllocation.publish_portfolio(
               forged_scope,
               generation.id,
               selection(revision, 1),
               decision()
             )

    assert {:error, :unauthenticated} =
             FleetAllocation.unwind_current_portfolio(forged_scope, generation.id)

    assert FleetAllocation.current_portfolio(scope).id == portfolio.id
    assert {:ok, claim} = FleetAllocation.current_ship_claim(agent, "SHIP-1")
    assert claim.portfolio_id == portfolio.id
  end

  test "a bootstrapped successor is not allocatable until current Fleet publication" do
    %{scope: scope, agent: predecessor, generation: old, revision: revision} =
      allocation_fixture()

    assert {:ok, %{generation: %{id: old_id}}} = SpaceTraders.FleetGeneration.current_fleet()
    assert old_id == old.id
    Repo.update!(Ecto.Changeset.change(old, retired_at: DateTime.utc_now()))

    successor = agent_fixture(scope.operator, %{publish: false})
    {:ok, _ship} = Fleet.record_ship(successor, "SHIP-2", "SHIP_COMMAND_FRIGATE")
    selected = selection(revision)
    [commitment] = selected.commitments
    selected = %{selected | commitments: [%{commitment | claims: ["SHIP-2"], pledges: []}]}

    pending =
      Repo.insert!(%Generation{
        operator_id: scope.operator.id,
        agent_id: successor.id,
        fleet_strategy_revision_id: revision.id,
        number: 2,
        symbol: successor.symbol,
        faction: successor.faction
      })

    assert {:error, %{reason: :ambiguous_current_fleet}} =
             SpaceTraders.FleetGeneration.current_fleet()

    assert is_nil(FleetAllocation.active_generation(successor))
    assert is_nil(FleetAllocation.current_portfolio(scope))

    assert {:error, :stale_source} =
             FleetAllocation.publish_portfolio(scope, pending.id, selected, decision())

    assert {:error, :no_current_ship_claim} =
             FleetAllocation.current_ship_claim(predecessor, "SHIP-1")

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               SpaceTraders.FleetGeneration.Identity.publish_generation!(
                 scope.operator.id,
                 pending.id
               )
             end)

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(scope, pending.id, selected, decision())

    assert FleetAllocation.current_portfolio(scope).id == portfolio.id
    assert FleetAllocation.current_portfolio(scope, successor).id == portfolio.id
    assert is_nil(FleetAllocation.current_portfolio(scope, predecessor))
    assert portfolio.strategy_decision_episode.fleet_generation_id == pending.id

    assert portfolio.strategy_decision_episode.evidence_references ==
             decision().evidence_references
  end

  test "publishes protections, Decision Episode, and notification as one version" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    SpaceTraders.MissionControl.Channels.subscribe_allocation()

    selection = selection(revision)

    decision = %{
      evidence_references: [
        %{"kind" => "market", "id" => "market:X1-A1", "fingerprint" => "abc123"}
      ],
      expectations: %{"credit_change" => 100, "horizon_seconds" => 300},
      calibration_version: "market-v1"
    }

    assert {:ok, %Portfolio{} = portfolio} =
             FleetAllocation.publish_portfolio(scope, generation.id, selection, decision)

    assert portfolio.version == 1
    assert portfolio.fleet_generation_id == generation.id
    assert portfolio.fleet_strategy_revision_id == revision.id

    assert [%Commitment{} = commitment] = portfolio.commitments
    assert commitment.candidate_id == "candidate-1"
    assert commitment.claims == ["SHIP-1"]
    assert commitment.reservations == %{"credits" => 50}
    assert {:ok, claim} = FleetAllocation.current_ship_claim(agent, "SHIP-1")
    assert claim.commitment_id == commitment.id
    assert claim.portfolio_id == portfolio.id
    assert claim.portfolio_version == 1

    assert %StrategyDecisionEpisode{} = episode = portfolio.strategy_decision_episode
    assert episode.evidence_references == decision.evidence_references
    assert [alternative] = episode.alternatives
    assert alternative["candidate_id"] == "candidate-2"
    assert alternative["reasons"] == ["claim_conflict"]
    assert alternative["alternative"]["expected_value"] == 50
    assert episode.binding_constraints == revision.document["hard_constraints"]
    assert episode.expectations == decision.expectations
    assert episode.calibration_version == "market-v1"
    assert episode.classification == :still_evaluating

    assert %Notification{
             event: "fleet_commitment_portfolio_published",
             payload: %{
               "portfolio_id" => portfolio_id,
               "decision_episode_id" => episode_id,
               "version" => 1
             }
           } = Repo.one!(Notification)

    assert portfolio_id == portfolio.id
    assert episode_id == episode.id

    assert_receive {:outbox, notification_id, "fleet_commitment_portfolio_published", payload}
    assert is_integer(notification_id)
    assert payload["portfolio_id"] == portfolio.id

    Outbox.dispatch_pending()
    refute_receive {:outbox, ^notification_id, "fleet_commitment_portfolio_published", _payload}
  end

  test "cannot publish a hauler Pledge after its producer is removed" do
    %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
    selection = selection(revision)
    [commitment] = selection.commitments

    dangling = %{
      commitment
      | dependencies: [%{id: "cargo", kind: :acquisition, candidate_id: "producer", amount: 4}],
        pledges: [
          %{outcome: {:construction, "X1-A2", "IRON"}, amount: 4, backing: {:dependency, "cargo"}}
        ]
    }

    assert {:error, :invalid_publication} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               %{selection | commitments: [dangling]},
               decision()
             )

    assert Repo.aggregate(Portfolio, :count) == 0
  end

  test "failed dependency replans only its subgraph while unrelated Ship execution stays claimed" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    {:ok, independent_ship} = Fleet.record_ship(agent, "SHIP-2", "SHIP_PROBE")
    {:ok, _hauler_ship} = Fleet.record_ship(agent, "SHIP-3", "SHIP_PROBE")
    original = selection(revision)
    [original_changed] = original.commitments

    changed = %{
      original_changed
      | pledges: [
          %{
            outcome: {:cargo_transfer, "SHIP-1", "SHIP-3", "IRON"},
            amount: 4,
            backing: {:claim, "SHIP-1"}
          }
        ]
    }

    dependent = %{
      changed
      | id: {revision.id, "dependent"},
        candidate_id: "dependent",
        claims: ["SHIP-3"],
        pledges: [
          %{
            outcome: {:construction, "X1-A2", "IRON"},
            amount: 4,
            backing: {:dependency, "cargo"}
          }
        ],
        dependencies: [
          %{id: "cargo", kind: :acquisition, candidate_id: changed.candidate_id, amount: 4}
        ]
    }

    independent = %{
      changed
      | id: {revision.id, "independent"},
        candidate_id: "independent",
        claims: ["SHIP-2"],
        pledges: []
    }

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               %{original | commitments: [changed, dependent, independent]},
               decision()
             )

    retained = Enum.find(portfolio.commitments, &(&1.candidate_id == "independent"))

    running =
      Repo.insert!(%Intent{
        ship_id: independent_ship.id,
        caller: "commitment",
        fleet_commitment_id: retained.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        type: "navigate",
        status: "waiting",
        target_waypoint: "X1-A2"
      })

    assert {:ok, updated} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{original | source_version: 1, commitments: [independent]},
               [changed.candidate_id],
               decision()
             )

    assert updated.id == portfolio.id
    assert updated.version == portfolio.version
    assert [%{id: retained_id}] = updated.commitments
    assert retained_id == retained.id

    assert {:ok, %{commitment_id: ^retained_id}} =
             FleetAllocation.current_ship_claim(agent, "SHIP-2")

    assert {:error, :no_current_ship_claim} = FleetAllocation.current_ship_claim(agent, "SHIP-1")
    assert {:error, :no_current_ship_claim} = FleetAllocation.current_ship_claim(agent, "SHIP-3")
    assert Repo.get!(Intent, running.id).status == "waiting"
    assert Enum.count(Repo.all(Commitment), &(&1.unwind_state == :released)) == 2

    assert {:ok, restored} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{original | source_version: 2, commitments: [changed, dependent, independent]},
               [changed.candidate_id],
               decision()
             )

    assert Enum.sort(Enum.map(restored.commitments, & &1.candidate_id)) ==
             ["candidate-1", "dependent", "independent"]

    assert Enum.all?(
             Enum.reject(restored.commitments, &(&1.candidate_id == "independent")),
             fn c ->
               %StrategyDecisionEpisode{source_version: 2} =
                 Repo.get!(StrategyDecisionEpisode, c.replan_decision_episode_id)
             end
           )

    assert {:ok, %{commitment_id: ^retained_id}} =
             FleetAllocation.current_ship_claim(agent, "SHIP-2")

    restored_producer = Enum.find(restored.commitments, &(&1.candidate_id == "candidate-1"))

    assert {:ok, %{decision_episode_id: episode_id}} =
             FleetAllocation.current_ship_claim(agent, "SHIP-1")

    assert episode_id == restored_producer.replan_decision_episode_id

    restored_hauler = Enum.find(restored.commitments, &(&1.candidate_id == "dependent"))
    hauler_ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: agent.id, symbol: "SHIP-3")

    Repo.insert!(%Intent{
      ship_id: hauler_ship.id,
      caller: "commitment",
      fleet_commitment_id: restored_hauler.id,
      fleet_commitment_portfolio_id: restored.id,
      fleet_commitment_portfolio_version: restored.version,
      type: "deliver",
      status: "completed",
      target_waypoint: "X1-A2",
      last_action_result: %{"units" => 4, "kind" => "deliver"}
    })

    assert :ok = FleetAllocation.reconcile_completed_outcomes()

    assert Repo.get!(StrategyDecisionEpisode, episode_id).classification == :partially_realized

    assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
             :still_evaluating

    assert {:ok, unwound} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{original | source_version: 3, commitments: [independent]},
               ["dependent"],
               decision()
             )

    assert [%{id: ^retained_id}] = unwound.commitments
    assert {:error, :no_current_ship_claim} = FleetAllocation.current_ship_claim(agent, "SHIP-1")
    assert {:error, :no_current_ship_claim} = FleetAllocation.current_ship_claim(agent, "SHIP-3")
  end

  test "boot recovery leaves upstream sales for authoritative market-effect reconciliation" do
    %{agent: agent, generation: generation, revision: revision, scope: scope} =
      allocation_fixture()

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision),
               decision()
             )

    ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: agent.id, symbol: "SHIP-1")
    [commitment] = portfolio.commitments

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      fleet_commitment_id: commitment.id,
      fleet_commitment_portfolio_id: portfolio.id,
      fleet_commitment_portfolio_version: portfolio.version,
      type: "sell",
      status: "completed",
      target_waypoint: "X1-A3",
      parameters: %{"market_trade" => %{"construction_upstream" => %{"part_symbol" => "IRON"}}}
    })

    assert :ok = FleetAllocation.reconcile_completed_outcomes()

    assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
             :still_evaluating
  end

  test "rejects a stale source version without partially replacing the current portfolio" do
    %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
    selection = selection(revision)
    decision = decision()

    assert {:ok, first} =
             FleetAllocation.publish_portfolio(scope, generation.id, selection, decision)

    assert {:error, :stale_source} =
             FleetAllocation.publish_portfolio(scope, generation.id, selection, decision)

    assert Repo.aggregate(Portfolio, :count) == 1
    assert Repo.aggregate(Commitment, :count) == 1
    assert Repo.aggregate(StrategyDecisionEpisode, :count) == 1
    assert Repo.aggregate(Notification, :count) == 1

    assert %Portfolio{id: first_id, version: 1, superseded_at: nil} =
             FleetAllocation.current_portfolio(scope)

    assert first_id == first.id
  end

  test "an Operator reservation prevents a stale selection from claiming the Ship" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: agent.id, symbol: "SHIP-1")
    assert {:ok, _} = ShipReservation.reserve(scope, ship.id, "Recovery")

    assert {:error, :ship_reserved} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision),
               decision()
             )

    refute Repo.exists?(Portfolio)
    assert Repo.get!(Generation, generation.id).allocation_version == 0

    assert :ok = ShipReservation.release(scope, ship.id)

    assert {:ok, %Portfolio{}} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision),
               decision()
             )
  end

  test "a captured acquisition source version rejects atomically after an unrelated additive replan" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    {:ok, market} =
      FleetAllocation.publish_portfolio(scope, generation.id, selection(revision), decision())

    [original] = selection(revision).commitments

    acquisition = %{
      original
      | id: {revision.id, "purchase"},
        candidate_id: "purchase",
        claims: [],
        pledges: [],
        reservations: %{credits: 300}
    }

    captured = %{selection(revision, 1) | commitments: [acquisition]}
    unrelated = %{acquisition | id: {revision.id, "other"}, candidate_id: "other"}

    assert {:ok, current} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{captured | commitments: [unrelated]},
               ["other"],
               decision()
             )

    before_ids = Enum.map(current.commitments, & &1.id)

    counts =
      {Repo.aggregate(StrategyDecisionEpisode, :count), Repo.aggregate(Notification, :count)}

    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("stale publication cannot dispatch") end)

    assert {:error, :stale_source} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               captured,
               ["purchase"],
               decision()
             )

    assert Enum.map(FleetAllocation.current_portfolio(scope, agent).commitments, & &1.id) ==
             before_ids

    assert {Repo.aggregate(StrategyDecisionEpisode, :count), Repo.aggregate(Notification, :count)} ==
             counts

    assert FleetAllocation.current_portfolio(scope, agent).strategy_decision_episode_id ==
             market.strategy_decision_episode_id

    assert SpaceTraders.MutationAttempts.list_for_agent(agent) == []

    assert {:ok, rejected} =
             FleetAllocation.record_publication_rejection(
               scope,
               generation.id,
               captured,
               decision(),
               :stale_source
             )

    assert rejected.selection_kind == :publication_rejected

    assert {:ok, _} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{captured | source_version: 2},
               ["purchase"],
               decision()
             )
  end

  test "additive acquisition publication revalidates the active Strategy even with a matching Generation version" do
    %{scope: scope, generation: generation, revision: revision} = allocation_fixture()

    {:ok, _} =
      FleetAllocation.publish_portfolio(scope, generation.id, selection(revision), decision())

    [original] = selection(revision).commitments

    acquisition = %{
      original
      | id: {revision.id, "purchase"},
        candidate_id: "purchase",
        claims: [],
        pledges: []
    }

    newer =
      Repo.insert!(%Revision{
        fleet_strategy_id: revision.fleet_strategy_id,
        number: 2,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: revision.document
      })

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Strategy, revision.fleet_strategy_id),
        active_revision_id: newer.id
      )
    )

    assert {:error, :stale_source} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{selection(revision, 1) | commitments: [acquisition]},
               ["purchase"],
               decision()
             )

    assert Repo.aggregate(Commitment, :count) == 1
    assert Repo.get!(Generation, generation.id).allocation_version == 1
  end

  test "an Operator reservation also blocks an in-place subgraph admission" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    [original] = selection(revision).commitments

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision),
               decision()
             )

    {:ok, ship} = Fleet.record_ship(agent, "SHIP-2", "SHIP_PROBE")
    assert {:ok, _} = ShipReservation.reserve(scope, ship.id, "Operator intervention")

    additional = %{
      original
      | id: {revision.id, "extra"},
        candidate_id: "extra",
        claims: ["SHIP-2"],
        pledges: []
    }

    assert {:error, :ship_reserved} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{selection(revision, 1) | commitments: [additional]},
               ["extra"],
               decision()
             )

    assert [%{candidate_id: "candidate-1"}] =
             FleetAllocation.current_portfolio(scope, agent).commitments

    assert Repo.get!(Generation, generation.id).allocation_version == portfolio.version
  end

  test "atomically supersedes the prior portfolio for readers" do
    %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
    selection = selection(revision)

    assert {:ok, first} =
             FleetAllocation.publish_portfolio(scope, generation.id, selection, decision())

    assert {:ok, second} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision, 1),
               decision()
             )

    assert second.version == 2

    assert %Portfolio{id: second_id, version: 2, commitments: [_]} =
             FleetAllocation.current_portfolio(scope)

    assert second_id == second.id
    assert Repo.get!(Portfolio, first.id).superseded_at

    assert [%Commitment{unwind_state: :released}] =
             first |> Repo.preload(:commitments, force: true) |> Map.fetch!(:commitments)

    assert Repo.aggregate(Portfolio, :count) == 2
    assert Repo.aggregate(StrategyDecisionEpisode, :count) == 2
    assert Repo.aggregate(Notification, :count) == 2
  end

  test "superseding a portfolio classifies its Decision Episode with recorded economics" do
    %{scope: scope, generation: generation, revision: revision} = allocation_fixture()

    assert {:ok, first} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision),
               decision()
             )

    assert {:ok, second} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision, 1),
               decision()
             )

    episode = Repo.get!(StrategyDecisionEpisode, first.strategy_decision_episode_id)

    assert episode.classification == :superseded
    assert episode.expectations == %{"credit_change" => 100}

    assert episode.actual_outcomes["receipts"] == []
    assert episode.actual_outcomes["credits_spent"] == "unknown"
    assert episode.actual_outcomes["credits_received"] == "unknown"
    assert episode.actual_outcomes["trade_margin"] == "unknown"
    assert episode.actual_outcomes["net_earnings"] == "unknown"
    refute Map.has_key?(episode.actual_outcomes, "credit_change")

    assert Repo.get!(Portfolio, second.id).superseded_at == nil

    assert {:error, :decision_episode_not_evaluating} =
             FleetAllocation.record_decision_outcome(
               scope,
               first.strategy_decision_episode_id,
               :superseded,
               %{credit_change: 0}
             )
  end

  test "unwinds the current portfolio and records its uneventful realized economics" do
    %{scope: scope, generation: generation, revision: revision} = allocation_fixture()

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision),
               decision()
             )

    assert {:ok, unwound} = FleetAllocation.unwind_current_portfolio(scope, generation.id)
    assert unwound.id == portfolio.id
    assert unwound.superseded_at
    assert is_nil(FleetAllocation.current_portfolio(scope))

    assert %Commitment{unwind_state: :released} =
             Repo.get!(Commitment, hd(portfolio.commitments).id)

    assert %StrategyDecisionEpisode{classification: :superseded, actual_outcomes: outcomes} =
             Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id)

    assert outcomes["credits_spent"] == "unknown"
    assert outcomes["net_earnings"] == "unknown"
  end

  describe "receipt-backed trade progress" do
    test "reports receipts, known subtotals and a margin, never a net" do
      %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
      portfolio = publish!(scope, generation, revision)
      commitment = hd(portfolio.commitments)

      buy = trade_intent!(portfolio, commitment, "buy", 50, 10)
      sell = trade_intent!(portfolio, commitment, "sell", 150, 10)

      assert {:ok, _} = FleetAllocation.unwind_current_portfolio(scope, generation.id)

      episode = Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id)
      outcomes = episode.actual_outcomes

      assert [%{"intent_id" => buy_id, "type" => "buy"}, %{"intent_id" => sell_id}] =
               outcomes["receipts"]

      assert {buy_id, sell_id} == {buy.id, sell.id}
      assert outcomes["credits_spent"] == 50
      assert outcomes["credits_received"] == 150
      assert outcomes["units_bought"] == 10
      assert outcomes["units_sold"] == 10
      assert outcomes["completed_round_trips"] == 1
      assert outcomes["trade_margin"] == 100
      assert outcomes["net_earnings"] == "unknown"
      assert Enum.any?(outcomes["unknown"], &(&1["item"] == "net_earnings"))
      assert episode.evidence_references == decision().evidence_references
    end

    test "repeated reads never double-count a receipt" do
      %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
      portfolio = publish!(scope, generation, revision)
      commitment = hd(portfolio.commitments)
      trade_intent!(portfolio, commitment, "buy", 50, 10)
      trade_intent!(portfolio, commitment, "sell", 150, 10)
      episode_id = portfolio.strategy_decision_episode_id

      first = FleetAllocation.trade_progress(episode_id)
      FleetAllocation.reconcile_completed_outcomes()
      FleetAllocation.reconcile_completed_outcomes()

      assert FleetAllocation.trade_progress(episode_id) == first
      assert first.credits_spent == 50
      assert Repo.get!(StrategyDecisionEpisode, episode_id).actual_outcomes["credits_spent"] == 50
    end

    test "a purchase without a sale reports spend and leaves margin unknown" do
      %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
      portfolio = publish!(scope, generation, revision)
      trade_intent!(portfolio, hd(portfolio.commitments), "buy", 50, 10)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert progress.credits_spent == 50
      assert progress.credits_received == "unknown"
      assert progress.trade_margin == "unknown"
      assert progress.completed_round_trips == 0
      assert Enum.any?(progress.unknown, &(&1.reason == "no sale receipt yet"))
    end

    test "an unproven trip keeps per-trip margins and leaves the Episode margin unknown" do
      %{agent: agent, scope: scope, generation: generation, revision: revision} =
        allocation_fixture()

      portfolio = publish_two!(agent, scope, generation, revision)
      [first, second] = Enum.sort_by(portfolio.commitments, & &1.candidate_id)

      trade_intent!(portfolio, first, "buy", 50, 10)
      trade_intent!(portfolio, first, "sell", 150, 10)
      trade_intent!(portfolio, second, "buy", 40, 10)
      trade_intent!(portfolio, second, "sell", nil, 10)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert [%{commitment_id: first_id, trade_margin: 100}] = progress.round_trips
      assert first_id == first.id
      assert progress.trade_margin == "unknown"
    end

    test "a sale that precedes its purchase proves no round trip" do
      %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
      portfolio = publish!(scope, generation, revision)
      commitment = hd(portfolio.commitments)
      trade_intent!(portfolio, commitment, "sell", 150, 10)
      trade_intent!(portfolio, commitment, "buy", 50, 10)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert progress.completed_round_trips == 0
      assert progress.trade_margin == "unknown"
      assert Enum.any?(progress.unknown, &(&1.reason == "the sale does not follow the purchase"))
    end

    test "a completed sale without a receipt manufactures no amount" do
      %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
      portfolio = publish!(scope, generation, revision)
      commitment = hd(portfolio.commitments)
      trade_intent!(portfolio, commitment, "buy", 50, 10)
      sell = trade_intent!(portfolio, commitment, "sell", nil, 10)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert progress.receipt_less_intents == [sell.id]
      assert progress.credits_received == "unknown"
      assert progress.trade_margin == "unknown"
      assert progress.completed_round_trips == 0
    end
  end

  describe "Market Decision Episode classification" do
    test "one completed sale leaves the Episode evaluating while another Commitment trades" do
      %{agent: agent, scope: scope, generation: generation, revision: revision} =
        allocation_fixture()

      portfolio = publish_two!(agent, scope, generation, revision)
      [first, second] = Enum.sort_by(portfolio.commitments, & &1.candidate_id)
      episode_id = portfolio.strategy_decision_episode_id

      trade_intent!(portfolio, first, "buy", 50, 10)
      trade_intent!(portfolio, first, "sell", 150, 10)
      trade_intent!(portfolio, second, "buy", 40, 10)
      open_sell = trade_intent!(portfolio, second, "sell", nil, 10, status: "waiting")

      FleetAllocation.record_trade_outcome(portfolio)

      assert Repo.get!(StrategyDecisionEpisode, episode_id).classification == :still_evaluating

      open_sell
      |> Ecto.Changeset.change(status: "completed", last_action_result: receipt("sell", 100, 10))
      |> Repo.update!()

      FleetAllocation.record_trade_outcome(portfolio)

      assert %{classification: :realized, actual_outcomes: outcomes} =
               Repo.get!(StrategyDecisionEpisode, episode_id)

      assert outcomes["completed_round_trips"] == 2
    end

    test "a finished Commitment without a proven round trip classifies the Episode partial" do
      %{agent: agent, scope: scope, generation: generation, revision: revision} =
        allocation_fixture()

      portfolio = publish_two!(agent, scope, generation, revision)
      [first, second] = Enum.sort_by(portfolio.commitments, & &1.candidate_id)

      trade_intent!(portfolio, first, "buy", 50, 10)
      trade_intent!(portfolio, first, "sell", 150, 10)
      trade_intent!(portfolio, second, "buy", 40, 10)
      trade_intent!(portfolio, second, "sell", nil, 10, status: "infeasible")

      FleetAllocation.record_trade_outcome(portfolio)

      assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
               :partially_realized
    end

    test "a sale completing after its Ship arrives classifies the Episode" do
      %{agent: agent, scope: scope, generation: generation, revision: revision} =
        allocation_fixture()

      portfolio = publish!(scope, generation, revision)
      commitment = hd(portfolio.commitments)
      trade_intent!(portfolio, commitment, "buy", 50, 10)

      sell =
        portfolio
        |> trade_intent!(commitment, "sell", 150, 10)
        |> Ecto.Changeset.change(parameters: %{"market_trade" => %{"trade_symbol" => "IRON_ORE"}})
        |> Repo.update!()

      assert :ok =
               SpaceTraders.FleetExecution.continue_after_intent(
                 agent,
                 commitment,
                 portfolio,
                 sell
               )

      assert %{classification: :realized, actual_outcomes: %{"trade_margin" => 100}} =
               Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id)
    end

    test "boot reconciliation applies the same classification" do
      %{agent: agent, scope: scope, generation: generation, revision: revision} =
        allocation_fixture()

      portfolio = publish_two!(agent, scope, generation, revision)
      [first, second] = Enum.sort_by(portfolio.commitments, & &1.candidate_id)

      trade_intent!(portfolio, first, "buy", 50, 10)
      trade_intent!(portfolio, first, "sell", 150, 10)
      trade_intent!(portfolio, second, "buy", 40, 10, status: "active")

      assert :ok = FleetAllocation.reconcile_completed_outcomes()

      assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
               :still_evaluating
    end
  end

  defp publish_two!(agent, scope, generation, revision) do
    {:ok, _ship} = Fleet.record_ship(agent, "SHIP-2", "SHIP_PROBE")
    original = selection(revision)
    [commitment] = original.commitments

    second = %{
      commitment
      | id: {revision.id, "candidate-b"},
        candidate_id: "candidate-b",
        claims: ["SHIP-2"],
        reservations: %{},
        pledges: []
    }

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               %{original | commitments: [commitment, second]},
               decision()
             )

    portfolio
  end

  defp receipt(type, total, units) do
    %{
      "transaction" => %{
        "type" => String.upcase(type),
        "trade_symbol" => "IRON_ORE",
        "ship_symbol" => "SHIP-1",
        "waypoint_symbol" => "X1-A-#{type}",
        "units" => units,
        "price_per_unit" => div(total, units),
        "total_price" => total
      }
    }
  end

  defp publish!(scope, generation, revision) do
    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection(revision),
               decision()
             )

    portfolio
  end

  defp trade_intent!(portfolio, commitment, type, total, units, opts \\ []) do
    ship = Repo.get_by!(Fleet.Ship, symbol: "SHIP-1")
    result = if total, do: receipt(type, total, units), else: %{"kind" => type}

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      type: type,
      target_waypoint: "X1-A-#{type}",
      status: Keyword.get(opts, :status, "completed"),
      fleet_commitment_id: commitment.id,
      fleet_commitment_portfolio_id: portfolio.id,
      fleet_commitment_portfolio_version: portfolio.version,
      last_action_result: result
    })
  end

  defp allocation_fixture do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)
    {:ok, _ship} = Fleet.record_ship(agent, "SHIP-1", "SHIP_COMMAND_FRIGATE")

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => [%{"kind" => "credit_floor", "minimum" => 1_000}]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    strategy
    |> Ecto.Changeset.change(active_revision_id: revision.id)
    |> Repo.update!()

    generation =
      %Generation{}
      |> Generation.changeset(%{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{},
        strategy_capable_at: DateTime.utc_now()
      })
      |> SpaceTraders.AgentFixtures.generation_fixture()

    %{scope: scope, agent: agent, generation: generation, revision: revision}
  end

  test "rejects forged duplicate protections before publication" do
    %{scope: scope, generation: generation, revision: revision} = allocation_fixture()
    selection = selection(revision)
    [commitment] = selection.commitments
    forged = %{selection | commitments: [commitment, commitment]}

    assert {:error, :invalid_publication} =
             FleetAllocation.publish_portfolio(scope, generation.id, forged, decision())

    refute Repo.exists?(Portfolio)
    refute Repo.exists?(StrategyDecisionEpisode)
    refute Repo.exists?(Notification)
  end

  defp selection(revision, source_version \\ 0) do
    candidate = %PortfolioCandidate{
      id: "candidate-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["SHIP-1"],
      reservations: %{credits: 50},
      pledges: [%{outcome: :credit_growth, amount: 100, backing: {:claim, "SHIP-1"}}],
      dependencies: [%{evidence_id: "market:X1-A1", state: :satisfied}],
      expected_value: 100,
      unwind_cost: 10
    }

    alternative = %{
      candidate
      | id: "candidate-2",
        expected_value: 50,
        reservations: %{},
        pledges: []
    }

    assert {:ok, selection} =
             FleetAllocation.select_portfolio(
               revision,
               [alternative, candidate],
               %{
                 as_of: @as_of,
                 source_version: source_version,
                 claims: ["SHIP-1"],
                 reservations: %{credits: 50}
               }
             )

    selection
  end

  defp decision do
    %{
      evidence_references: [%{"kind" => "market", "id" => "market:X1-A1"}],
      expectations: %{"credit_change" => 100},
      calibration_version: "market-v1"
    }
  end
end
