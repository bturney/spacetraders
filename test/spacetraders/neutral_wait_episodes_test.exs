defmodule SpaceTraders.NeutralWaitEpisodesTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.AllocationResultPointer
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.FleetStrategy.Strategy

  @observation_reference %{
    "kind" => "observation",
    "subject" => "market:X1:X1-A1",
    "operation_id" => "get-market"
  }

  @binding_limitation %{
    "kind" => "incomplete_coverage",
    "subject" => "market_planning",
    "reason" => "incomplete_market_coverage",
    "unresolved_subjects" => ["market:X1:X1-A3"]
  }

  @reconciled_subjects ["market:X1:X1-A1", "market:X1:X1-A2"]

  @candidates [
    %{
      "candidate_id" => "market-X1-A1-X1-A2-IRON_ORE",
      "objective_index" => 0,
      "expected_value" => -4,
      "rejection_reasons" => ["non_positive_expected_value"],
      "source" => "market_route"
    }
  ]

  @rejections []
  @calibration_version "market-v1"

  describe "recording a Neutral Wait through the public reconciliation seam" do
    test "a zero-admissible result with future due evidence persists one Neutral Wait episode" do
      %{scope: scope, generation: generation, revision: revision, agent: agent} = fixture()

      {:ok, demand} =
        request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      comparison = market_comparison(action: :no_admissible_commitment)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(scope, generation, revision, comparison)

      assert %StrategyDecisionEpisode{} = episode
      assert Repo.reload!(episode).selection_kind == :neutral_wait
      assert episode.classification == :still_evaluating
      assert episode.fleet_strategy_revision_id == revision.id
      assert episode.fleet_generation_id == generation.id

      # Carries the closed-vocabulary binding limitation kind.
      assert episode.binding_limitation_kind == :incomplete_coverage
      assert episode.expectations["binding_limitation"] == @binding_limitation

      # Next observation time comes from the earliest durable future demand.
      assert episode.next_observation_at == demand.due_at

      # Evidence references retain both the allocation evidence and the durable
      # future demand that makes re-evaluation possible.
      assert episode.evidence_references == [
               @observation_reference,
               %{
                 "kind" => "observation_demand",
                 "id" => demand.id,
                 "subject" => demand.subject,
                 "due_at" => DateTime.to_iso8601(demand.due_at)
               }
             ]

      # Candidates and rejection reasons are retained as one tagged bundle,
      # distinguishing "nothing was admissible" from "these were not selected".
      assert [bundle] = episode.alternatives

      assert bundle == %{
               "kind" => "neutral_wait_candidates",
               "candidates" => @candidates,
               "rejections" => @rejections,
               "reconciled_subjects" => Enum.sort(@reconciled_subjects)
             }

      # Provenance of the mint is the market allocation reconciliation.
      assert episode.actual_outcomes["producer"] == "fleet_allocation_market_reconciliation"
      assert episode.actual_outcomes["basis"] == "fleet_allocation_reconciliation"
      assert episode.calibration_version == @calibration_version

      # O(1) current-result pointer: the wait is discoverable per generation.
      pointer = Repo.get_by!(AllocationResultPointer, fleet_generation_id: generation.id)
      assert pointer.strategy_decision_episode_id == episode.id
      assert pointer.selection_kind == :neutral_wait

      assert %DateTime{} = FleetAllocation.current_neutral_wait_since(generation.id)

      # The wait creates no Commitment or Endeavor material.
      assert Repo.aggregate(SpaceTraders.FleetAllocation.Portfolio, :count) == 0
    end

    test "an equivalent reconciliation refreshes the same episode without another row" do
      %{scope: scope, generation: generation, revision: revision, agent: agent} = fixture()

      {:ok, _first_demand} =
        request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(action: :no_admissible_commitment)
               )

      first_updated_at = episode.updated_at

      # Same enumerated result and limitation kind, with an already-later due
      # demand for the same unresolved subject: equivalent reconciliation.
      {:ok, _later_demand} =
        request_future_demand(agent, revision, "market:X1:X1-A3", 1_200)

      assert {:ok, refreshed} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(action: :no_admissible_commitment)
               )

      assert refreshed.id == episode.id
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 1
      assert refreshed.classification == :still_evaluating

      # The re-evaluation evidence is appended, not replaced.
      assert length(refreshed.actual_outcomes["re_evaluations"]) == 2

      assert Enum.all?(
               refreshed.actual_outcomes["re_evaluations"],
               &is_map(&1)
             )

      assert DateTime.diff(refreshed.updated_at, first_updated_at, :microsecond) >= 0

      # Exactly one current wait pointer remains.
      assert Repo.aggregate(AllocationResultPointer, :count) == 1
    end

    test "changed re-evaluation detail with the same limitation kind refreshes in place" do
      %{scope: scope, generation: generation, revision: revision, agent: agent} = fixture()

      {:ok, _first_demand} =
        request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(action: :no_admissible_commitment)
               )

      {:ok, second_demand} =
        request_future_demand(agent, revision, "market:X1:X1-A4", 1_200)

      changed_limitation = %{
        "kind" => "incomplete_coverage",
        "subject" => "market_planning",
        "reason" => "incomplete_market_coverage",
        "unresolved_subjects" => ["market:X1:X1-A4"]
      }

      assert {:ok, refreshed} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(
                   action: :no_admissible_commitment,
                   observation_subject: "market:X1:X1-A4",
                   binding_limitation: changed_limitation,
                   calibration_version: nil
                 )
               )

      assert refreshed.id == episode.id
      assert refreshed.next_observation_at == second_demand.due_at
      assert refreshed.expectations["binding_limitation"] == changed_limitation
      assert refreshed.calibration_version == @calibration_version
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 1
    end

    test "a superseded revision's future demand cannot mint a current Neutral Wait" do
      %{
        scope: scope,
        generation: generation,
        revision: revision,
        strategy: strategy,
        agent: agent
      } = fixture()

      {:ok, _demand} = request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      revision_two =
        Repo.insert!(%Revision{
          fleet_strategy_id: strategy.id,
          number: 2,
          document: revision.document,
          source: "operator",
          activated_at: DateTime.utc_now(:second)
        })

      strategy
      |> Ecto.Changeset.change(active_revision_id: revision_two.id)
      |> Repo.update!()

      generation
      |> Ecto.Changeset.change(fleet_strategy_revision_id: revision_two.id)
      |> Repo.update!()

      assert {:error, :no_future_observation_demand} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision_two,
                 market_comparison(action: :no_admissible_commitment)
               )

      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end

    test "a changed limitation kind supersedes the current episode truthfully" do
      %{scope: scope, generation: generation, revision: revision, agent: agent} = fixture()

      {:ok, _demand} = request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(
                   action: :no_admissible_commitment,
                   binding_limitation: incomplete_coverage_limitation()
                 )
               )

      # Coverage lands and the conclusive negative result binds the wait to
      # `no_admissible_candidate` instead.
      assert {:ok, superseded_by} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(
                   action: :no_admissible_commitment,
                   binding_limitation: no_admissible_limitation(),
                   candidates: [],
                   rejections: []
                 )
               )

      assert superseded_by.binding_limitation_kind == :no_admissible_candidate
      refute superseded_by.id == episode.id
      assert Repo.reload!(episode).classification == :superseded
      assert Repo.reload!(superseded_by).classification == :still_evaluating

      pointer = Repo.get_by!(AllocationResultPointer, fleet_generation_id: generation.id)
      assert pointer.strategy_decision_episode_id == superseded_by.id
    end

    test "a changed Fleet Strategy Revision supersedes the current episode" do
      %{
        scope: scope,
        generation: generation,
        revision: revision,
        strategy: strategy,
        agent: agent
      } =
        fixture()

      {:ok, _demand} = request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(action: :no_admissible_commitment)
               )

      revision_two =
        Repo.insert!(%Revision{
          fleet_strategy_id: strategy.id,
          number: 2,
          document: revision.document,
          source: "operator",
          activated_at: DateTime.utc_now(:second)
        })

      strategy
      |> Ecto.Changeset.change(active_revision_id: revision_two.id)
      |> Repo.update!()

      assert :ok = SpaceTraders.FleetGeneration.activate_strategy(scope, revision_two)
      assert Repo.reload!(episode).classification == :superseded
      assert Repo.get_by(AllocationResultPointer, fleet_generation_id: generation.id) == nil

      {:ok, _new_demand} =
        request_future_demand(agent, revision_two, "market:X1:X1-A3", 600)

      assert {:ok, second} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision_two,
                 market_comparison(action: :no_admissible_commitment)
               )

      refute second.id == episode.id
      assert Repo.reload!(episode).classification == :superseded
      assert Repo.reload!(second).classification == :still_evaluating

      pointer = Repo.get_by!(AllocationResultPointer, fleet_generation_id: generation.id)
      assert pointer.strategy_decision_episode_id == second.id
      assert pointer.fleet_strategy_revision_id == revision_two.id
    end

    test "a changed Fleet Generation supersedes the current episode" do
      %{
        scope: scope,
        generation: generation,
        revision: revision,
        operator: operator,
        agent: agent
      } =
        fixture()

      {:ok, _demand} = request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(action: :no_admissible_commitment)
               )

      # A replacement Fleet Generation comes with a replacement Agent
      # (FleetGeneration.mint behavior): the wait is superseded across the
      # Operator's allocation scope, not only within one generation.
      replacement_agent =
        Repo.insert!(%SpaceTraders.Agent.Agent{
          symbol: "REPLACED-#{agent.symbol}",
          faction: agent.faction,
          headquarters: agent.headquarters,
          agent_token: agent.agent_token,
          operator_id: operator.id
        })

      replacement_generation =
        Repo.insert!(%Generation{
          operator_id: operator.id,
          agent_id: replacement_agent.id,
          fleet_strategy_revision_id: revision.id,
          number: 2,
          symbol: replacement_agent.symbol,
          faction: replacement_agent.faction,
          replacement_symbols: %{},
          objective_progress: %{}
        })

      # The replacement Agent's coverage work is durably scheduled on its own
      # demands, exactly as mint syncs baseline coverage for a new Agent.
      {:ok, _replacement_demand} =
        request_future_demand(replacement_agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, second} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 replacement_generation,
                 revision,
                 market_comparison(action: :no_admissible_commitment)
               )

      refute second.id == episode.id
      assert Repo.reload!(episode).classification == :superseded
      assert second.fleet_generation_id == replacement_generation.id
    end

    test "a selected plan supersedes the current wait truthfully" do
      %{scope: scope, generation: generation, revision: revision, agent: agent} = fixture()

      {:ok, _demand} = request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(action: :no_admissible_commitment)
               )

      # The selection claims a Ship the Agent owns; publication locks it.
      Repo.insert!(%SpaceTraders.Fleet.Ship{
        symbol: "SHIP-1",
        ship_type: "SHIP_PROBE",
        agent_id: agent.id
      })

      selection = selected_portfolio_selection(revision, generation.allocation_version)

      assert {:ok, portfolio} =
               FleetAllocation.publish_portfolio(
                 scope,
                 generation.id,
                 selection,
                 decision()
               )

      assert Repo.reload!(episode).classification == :superseded
      assert portfolio.strategy_decision_episode_id != episode.id
      assert Repo.reload!(portfolio.strategy_decision_episode).selection_kind == :selected_plan

      pointer = Repo.get_by!(AllocationResultPointer, fleet_generation_id: generation.id)
      assert pointer.strategy_decision_episode_id == portfolio.strategy_decision_episode_id
      assert pointer.selection_kind == :selected_plan

      assert FleetAllocation.current_neutral_wait_since(generation.id) == nil
    end

    test "no future due evidence means no Neutral Wait is minted" do
      %{scope: scope, generation: generation, revision: revision} = fixture()

      comparison = market_comparison(action: :no_admissible_commitment)

      assert {:error, :no_future_observation_demand} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 comparison
               )

      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
      assert Repo.aggregate(AllocationResultPointer, :count) == 0
    end

    test "a non-zero-admissible action never records a Neutral Wait" do
      %{scope: scope, generation: generation, revision: revision, agent: agent} = fixture()

      {:ok, _demand} = request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      for action <- [:deferred_for_capacity, :unchanged] do
        assert {:error, :not_neutral_wait} =
                 FleetAllocation.record_neutral_wait(
                   scope,
                   generation,
                   revision,
                   market_comparison(action: action)
                 )
      end

      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
      assert Repo.aggregate(AllocationResultPointer, :count) == 0
    end

    test "records the no_admissible_candidate limitation kind without pending coverage" do
      %{scope: scope, generation: generation, revision: revision, agent: agent} = fixture()

      {:ok, _demand} = request_future_demand(agent, revision, "market:X1:X1-A3", 600)

      assert {:ok, episode} =
               FleetAllocation.record_neutral_wait(
                 scope,
                 generation,
                 revision,
                 market_comparison(
                   action: :no_admissible_commitment,
                   binding_limitation: no_admissible_limitation(),
                   candidates: [],
                   rejections: []
                 )
               )

      assert episode.binding_limitation_kind == :no_admissible_candidate
    end
  end

  defp fixture do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)

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
              "evaluation" => "Maximize net credit growth over time"
            }
          ],
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
        objective_progress: %{}
      })
      |> Repo.insert!()

    %{
      operator: operator,
      scope: scope,
      agent: agent,
      generation: generation,
      revision: revision,
      strategy: strategy
    }
  end

  defp request_future_demand(agent, revision, subject, seconds_from_now) do
    Evidence.request_demand(agent, revision, %{
      subject: subject,
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(clock_now(), seconds_from_now, :second),
      owner: "fleet_planning"
    })
  end

  defp clock_now do
    SpaceTraders.Clock.utc_now()
  end

  defp market_comparison(opts) do
    subject = Keyword.get(opts, :observation_subject, "market:X1:X1-A3")

    %{
      planning: [
        %{
          objective_index: 0,
          candidate_contributions: [],
          observation_demands: [
            %{
              subject: subject,
              required_facts: ["trade_goods"],
              due_in_seconds: 600,
              observation_demand_id: "demand-1"
            }
          ],
          limitations: [
            %{
              subject: :market_planning,
              reason: :incomplete_market_coverage,
              subjects: ["market:X1:X1-A3"]
            }
          ]
        }
      ],
      reconciled_subjects: @reconciled_subjects,
      observation_demands: [%{subject: subject, observation_demand_id: "demand-1"}],
      action: opts[:action] || :no_admissible_commitment,
      candidates: Keyword.get(opts, :candidates, @candidates),
      rejections: Keyword.get(opts, :rejections, @rejections),
      binding_limitation:
        Keyword.get(opts, :binding_limitation, incomplete_coverage_limitation()),
      evidence_references: [@observation_reference],
      calibration_version: Keyword.get(opts, :calibration_version, @calibration_version)
    }
  end

  defp incomplete_coverage_limitation do
    %{
      "kind" => "incomplete_coverage",
      "subject" => "market_planning",
      "reason" => "incomplete_market_coverage",
      "unresolved_subjects" => ["market:X1:X1-A3"]
    }
  end

  defp no_admissible_limitation do
    %{
      "kind" => "no_admissible_candidate",
      "subject" => "market_planning",
      "reason" => "no_viable_market_routes"
    }
  end

  defp selected_portfolio_selection(revision, source_version) do
    candidate = %SpaceTraders.FleetAllocation.PortfolioCandidate{
      id: "candidate-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["SHIP-1"],
      reservations: %{credits: 50},
      pledges: [%{outcome: :credit_growth, amount: 100, backing: {:claim, "SHIP-1"}}],
      dependencies: [%{evidence_id: "market:X1:X1-A1", state: :satisfied}],
      expected_value: 100,
      unwind_cost: 10
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(
        revision,
        [candidate],
        %{
          as_of: ~U[2030-01-01 12:00:00Z],
          source_version: source_version,
          claims: ["SHIP-1"],
          reservations: %{credits: 50}
        }
      )

    selection
  end

  defp decision do
    %{
      evidence_references: [%{"kind" => "market", "id" => "market:X1:X1-A1"}],
      expectations: %{"credit_change" => 100},
      calibration_version: "market-v1"
    }
  end
end
