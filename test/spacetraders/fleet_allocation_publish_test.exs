defmodule SpaceTraders.FleetAllocationPublishTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio, StrategyDecisionEpisode}
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Outbox
  alias SpaceTraders.Outbox.Notification

  @as_of ~U[2030-01-01 12:00:00Z]

  test "publishes protections, Decision Episode, and notification as one version" do
    %{scope: scope, agent: agent, generation: generation, revision: revision} =
      allocation_fixture()

    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_allocation:#{scope.operator.id}")

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

  defp allocation_fixture do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)

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
      |> Repo.insert!()

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
