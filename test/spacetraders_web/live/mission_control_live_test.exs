defmodule SpaceTradersWeb.MissionControlLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.{FleetStrategy, Repo}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode

  setup :register_and_log_in_operator

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/mission-control")
  end

  test "guides an Operator through Strategy and Agent onboarding", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/mission-control")

    assert html =~ "Set the Fleet direction"
    assert has_element?(view, "#mission-onboarding a[href='/strategy']", "Review Fleet Strategy")
    assert has_element?(view, "#mission-onboarding a[href='/agents/new']", "Mint an Agent")
    assert html =~ "No active revision"
    assert html =~ "No current Fleet Generation"
  end

  test "shows active Strategy intent and truthful unknown objective evaluation", %{
    conn: conn,
    scope: scope
  } do
    assert {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")

    assert {:ok, _revision} =
             FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    {:ok, _view, html} = live(conn, ~p"/mission-control")

    assert html =~ "Revision 1"
    assert html =~ "Grow credits"
    assert html =~ "Unknown: no complete, authoritative evaluation is available yet."
    assert html =~ "Objective status: Unknown"
  end

  test "identifies the active Agent, Fleet Generation, and Strategy-capable state", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    assert {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    agent = agent_fixture(operator, %{agent_token: nil})

    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction,
      replacement_symbols: %{"symbols" => [agent.symbol]},
      objective_progress: %{
        "0" => %{
          "change" => 10,
          "elapsed_seconds" => 5,
          "feasible?" => true,
          "horizon_seconds" => 10
        }
      },
      strategy_capable_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/mission-control")

    assert html =~ agent.symbol
    assert html =~ "Generation 1"
    assert html =~ "Strategy-capable"
    assert html =~ "Measured outcome rate: 20.0 per horizon."
    assert html =~ "Growing"
  end

  test "shows observed credit growth from authoritative starting and current Agent state", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    agent = agent_fixture(operator, %{agent_token: "AGENT_TOKEN"})

    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction,
      replacement_symbols: %{"symbols" => [agent.symbol]},
      starting_credits: 175_000,
      strategy_capable_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "accountId" => "ACC",
              "symbol" => agent.symbol,
              "headquarters" => agent.headquarters,
              "credits" => 175_120,
              "startingFaction" => agent.faction,
              "shipCount" => 0
            }
          })

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => []})

        "/v2/my/contracts" ->
          Req.Test.json(conn, %{"data" => []})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    assert has_element?(view, "#objective-evaluations", "Observed net change: +120 credits")
    assert has_element?(view, "#objective-evaluations", "Growing")
  end

  test "Emergency Stop takes precedence over a previously Strategy-capable Fleet", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, _revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    assert has_element?(view, "#operating-health", "STOPPED")
  end

  test "acknowledging Attention does not remove it from the briefing", %{
    conn: conn,
    scope: scope
  } do
    {:ok, condition} =
      SpaceTraders.OperatorConditions.raise(
        scope,
        "credit-floor",
        :attention,
        "Protected credit floor cannot be maintained"
      )

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    assert has_element?(view, "#needs-attention", "Protected credit floor cannot be maintained")

    view |> element("#needs-attention button[phx-value-id='#{condition.id}']") |> render_click()

    assert has_element?(view, "#needs-attention", "Protected credit floor cannot be maintained")
    assert has_element?(view, "#needs-attention", "Acknowledged")

    {:ok, _another_view, html} = live(conn, ~p"/mission-control")
    assert html =~ "Protected credit floor cannot be maintained"
    assert html =~ "Acknowledged"

    :ok = SpaceTraders.OperatorConditions.resolve(scope, "credit-floor")
    {:ok, resolved_view, _html} = live(conn, ~p"/mission-control")

    refute has_element?(
             resolved_view,
             "#needs-attention",
             "Protected credit floor cannot be maintained"
           )

    {:ok, reopened} =
      SpaceTraders.OperatorConditions.raise(
        scope,
        "credit-floor",
        :attention,
        "Protected credit floor cannot be maintained"
      )

    assert reopened.id != condition.id
    assert is_nil(reopened.acknowledged_at)
    {:ok, _activity, html} = live(conn, ~p"/activity")
    assert html |> String.split("Protected credit floor cannot be maintained") |> length() == 4
  end

  test "new Intervention appears in the connected briefing without reopening the page", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/mission-control")

    {:ok, _} =
      SpaceTraders.OperatorConditions.raise(
        scope,
        "external-authority",
        :intervention,
        "AccountToken needed for replacement"
      )

    assert render(view) =~ "AccountToken needed for replacement"
  end

  test "Activity distinguishes decisions from routine Ship traffic", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    agent = agent_fixture(operator, %{agent_token: nil})

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{"symbols" => [agent.symbol]}
      })

    ship =
      Repo.insert!(%SpaceTraders.Fleet.Ship{
        agent_id: agent.id,
        symbol: "#{agent.symbol}-1",
        ship_type: "SHIP_PROBE"
      })

    :ok = SpaceTraders.Fleet.record_activity(agent, ship, "retry", "API request retrying")

    :ok =
      SpaceTraders.Fleet.record_activity(
        agent,
        ship,
        "manual_intervention_stopped",
        "One-off navigation stopped"
      )

    Repo.insert!(%StrategyDecisionEpisode{
      operator_id: operator.id,
      fleet_generation_id: generation.id,
      fleet_strategy_revision_id: revision.id,
      source_version: 0,
      calibration_version: "v1",
      classification: :realized,
      actual_outcomes: %{"net_credit_change" => 250}
    })

    routine_episode =
      Repo.insert!(%StrategyDecisionEpisode{
        operator_id: operator.id,
        fleet_generation_id: generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 1,
        calibration_version: "v1",
        classification: :still_evaluating
      })

    now = DateTime.utc_now()

    attempt =
      Repo.insert!(%SpaceTraders.MutationAttempts.Attempt{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_generation_id: generation.id,
        operation_id: "purchase-ship",
        operation_owner: "fleet",
        state: "succeeded",
        request_fingerprint: "purchase-ship-test",
        prepared_at: now
      })

    Repo.insert!(%SpaceTraders.MutationAttempts.Outcome{
      mutation_attempt_id: attempt.id,
      classification: "succeeded",
      recorded_at: now
    })

    {:ok, view, html} = live(conn, ~p"/activity")
    assert html =~ "Decision"
    assert html =~ "250 credits"
    assert html =~ "Fleet acquired a Ship"
    assert html =~ "One-off navigation stopped"
    assert html =~ "Fleet selected a new commitment portfolio"
    refute html =~ "API request"

    view |> element("nav[aria-label='Activity filters'] button", "Notable") |> render_click()
    refute render(view) =~ "One-off navigation stopped"
    refute has_element?(view, "#activity-history li#decision-#{routine_episode.id}")

    {:ok, _briefing, html} = live(conn, ~p"/mission-control")
    assert html =~ "Notable activity"
    assert html =~ "Fleet decision realized 250 credits net change"
  end

  test "Generation recaps compare evidenced outcomes and do not invent missing measurements", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    first = agent_fixture(operator, %{agent_token: nil})
    second = agent_fixture(operator, %{agent_token: nil})

    old =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: first.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: first.symbol,
        faction: first.faction,
        replacement_symbols: %{"symbols" => [first.symbol]},
        objective_progress: %{
          "0" => %{
            "change" => 10,
            "elapsed_seconds" => 5,
            "feasible?" => true,
            "horizon_seconds" => 10
          }
        },
        fenced_at: DateTime.utc_now(),
        retired_at: DateTime.utc_now()
      })

    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: second.id,
      fleet_strategy_revision_id: revision.id,
      number: 2,
      symbol: second.symbol,
      faction: second.faction,
      replacement_symbols: %{"symbols" => [second.symbol]},
      strategy_capable_at: DateTime.utc_now()
    })

    Repo.insert!(%StrategyDecisionEpisode{
      operator_id: operator.id,
      fleet_generation_id: old.id,
      fleet_strategy_revision_id: revision.id,
      source_version: 0,
      calibration_version: "v1",
      classification: :realized,
      actual_outcomes: %{"net_credit_change" => 250}
    })

    Repo.insert!(%StrategyDecisionEpisode{
      operator_id: operator.id,
      fleet_generation_id: old.id,
      fleet_strategy_revision_id: revision.id,
      source_version: 1,
      calibration_version: "v1",
      classification: :partially_realized
    })

    {:ok, view, html} = live(conn, ~p"/generations")
    assert html =~ "Generation 1"
    assert html =~ "Generation 2"
    assert html =~ "250 credits"
    assert html =~ "Grow credits: 20.0 per horizon"
    assert html =~ "Unknown — no realized credit evidence"
    assert html =~ "Strategy revision 1"
    assert html =~ "Server Reset"
    assert html =~ "Decision partly realized"
    assert html =~ "Strategy-capable"
    assert has_element?(view, "#generation-comparison", "Generation 1")
    assert has_element?(view, "#generation-comparison", "Generation 2")
  end
end
