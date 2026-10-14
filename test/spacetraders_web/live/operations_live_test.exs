defmodule SpaceTradersWeb.OperationsLiveTest do
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Repo

  setup :register_and_log_in_operator

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/operations")
  end

  test "guides an Operator toward Strategy activation with no Endeavors", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/operations")

    assert html =~ "No active Endeavors yet"
    assert has_element?(view, "#operations-onboarding a[href='/strategy']")
  end

  test "renders Objective-grouped Endeavors from the shared projection", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    agent = agent_fixture(operator, %{agent_token: nil})

    Repo.insert!(%SpaceTraders.Fleet.Ship{
      symbol: "SHIP-1",
      ship_type: "SHIP_FRIGATE",
      agent_id: agent.id
    })

    generation =
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        starting_credits: 175_000,
        objective_progress: %{}
      })

    candidate = %SpaceTraders.FleetAllocation.PortfolioCandidate{
      id: "candidate-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["SHIP-1"],
      reservations: %{credits: 200},
      pledges: [
        %{
          outcome: {:contract, "CONTRACT-1", "X1-A1", "IRON"},
          amount: 1,
          backing: {:claim, "SHIP-1"}
        }
      ],
      dependencies: [],
      expected_value: 100,
      unwind_cost: 0
    }

    {:ok, selection} =
      SpaceTraders.FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: ["SHIP-1"],
        reservations: %{credits: 175_000}
      })

    {:ok, portfolio} =
      SpaceTraders.FleetAllocation.publish_portfolio(scope, generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "market-v1"
      })

    {:ok, view, html} = live(conn, ~p"/operations")

    assert html =~ "Grow credits"
    assert html =~ "SHIP-1"
    assert html =~ "credits: 200"
    assert html =~ "Active"
    assert html =~ "Decision Episode"

    assert has_element?(
             view,
             "a[href='/decision-episodes/#{portfolio.strategy_decision_episode_id}']"
           )

    assert has_element?(view, "a[href='/ships/SHIP-1']", "SHIP-1")
    assert has_element?(view, "a[href='/contracts/CONTRACT-1']", "Contract CONTRACT-1")

    assert html =~
             "Selected as the highest-ranked feasible contribution at its Strategic Priority."

    # A successor can have retained allocation-shaped data before lifecycle
    # publication. Neither public surface may treat that data as live authority.
    Repo.update!(Ecto.Changeset.change(generation, retired_at: DateTime.utc_now()))
    successor = agent_fixture(operator, %{publish: false})

    pending =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: successor.id,
        number: 2,
        symbol: successor.symbol,
        faction: successor.faction,
        fleet_strategy_revision_id: revision.id
      })

    episode =
      Repo.insert!(%SpaceTraders.FleetAllocation.StrategyDecisionEpisode{
        operator_id: operator.id,
        fleet_generation_id: pending.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 0,
        evidence_references: [],
        expectations: %{},
        calibration_version: "market-v1"
      })

    pending_portfolio =
      Repo.insert!(%SpaceTraders.FleetAllocation.Portfolio{
        operator_id: operator.id,
        fleet_generation_id: pending.id,
        fleet_strategy_revision_id: revision.id,
        strategy_decision_episode_id: episode.id,
        version: 1
      })

    Repo.insert!(%SpaceTraders.FleetAllocation.Commitment{
      fleet_commitment_portfolio_id: pending_portfolio.id,
      candidate_id: "not-published",
      objective_index: 0,
      claims: ["PENDING-1"],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 100.0,
      unwind_cost: 0.0,
      decisive_reason: "Pending Fleet must not be selected."
    })

    assert SpaceTraders.MissionControl.endeavors(scope).contribution.commitment_count == 0

    assert SpaceTraders.MissionControl.endeavors(
             scope,
             Repo.preload(pending_portfolio, :commitments)
           ).contribution.commitment_count == 0

    {:ok, transition_view, transition_html} = live(conn, ~p"/operations")
    assert has_element?(transition_view, "#operations-onboarding")
    refute transition_html =~ "PENDING-1"
    refute has_element?(transition_view, "#endeavor-#{hd(portfolio.commitments).id}")

    assert {:error, %{reason: :ambiguous_current_fleet}} =
             SpaceTraders.FleetGeneration.current_fleet(scope)
  end

  test "released Commitments leave the active view with reachable Decision Episode evidence", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    agent = agent_fixture(operator, %{agent_token: nil})

    Repo.insert!(%SpaceTraders.Fleet.Ship{
      symbol: "SHIP-1",
      ship_type: "SHIP_FRIGATE",
      agent_id: agent.id
    })

    generation =
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        starting_credits: 175_000,
        objective_progress: %{}
      })

    candidate = %SpaceTraders.FleetAllocation.PortfolioCandidate{
      id: "candidate-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["SHIP-1"],
      reservations: %{credits: 200},
      pledges: [],
      dependencies: [],
      expected_value: 100,
      unwind_cost: 0
    }

    {:ok, selection} =
      SpaceTraders.FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: ["SHIP-1"],
        reservations: %{credits: 175_000}
      })

    {:ok, portfolio} =
      SpaceTraders.FleetAllocation.publish_portfolio(scope, generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "market-v1"
      })

    [commitment] = portfolio.commitments

    commitment
    |> Ecto.Changeset.change(unwind_state: :released)
    |> Repo.update!()

    {:ok, view, html} = live(conn, ~p"/operations")

    assert html =~ "Released Endeavor evidence"
    assert html =~ "Decision Episode #{portfolio.strategy_decision_episode_id}"

    assert has_element?(
             view,
             "a[href='/decision-episodes/#{portfolio.strategy_decision_episode_id}']"
           )
  end
end
