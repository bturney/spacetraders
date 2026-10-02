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

  test "proven objective infeasibility stays pinned after acknowledgement until evidence changes",
       %{
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
        replacement_symbols: %{"symbols" => [agent.symbol]},
        starting_credits: 175_000,
        strategy_capable_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    refute has_element?(view, "#needs-attention", "Grow credits")

    evidence = objective_evidence(agent)
    persisted_evidence = Repo.get(SpaceTraders.Evidence.Observation, evidence.id)
    assert SpaceTraders.Evidence.valid_observation?(persisted_evidence)

    assert {:ok, _} =
             SpaceTraders.FleetGeneration.record_objective_progress(scope, generation.id, 0, %{
               "change" => 0,
               "elapsed_seconds" => 60,
               "horizon_seconds" => 3600,
               "feasible?" => false,
               "evidence_id" => evidence.id
             })

    assert has_element?(view, "#needs-attention", "Grow credits")
    [condition] = SpaceTraders.OperatorConditions.unresolved(scope)
    view |> element("#needs-attention button[phx-value-id='#{condition.id}']") |> render_click()

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    assert has_element?(view, "#needs-attention", "Acknowledged")

    assert {:ok, _} =
             SpaceTraders.FleetGeneration.record_objective_progress(scope, generation.id, 0, %{
               "change" => 20,
               "elapsed_seconds" => 60,
               "horizon_seconds" => 3600,
               "feasible?" => true,
               "evidence_id" => objective_evidence(agent, 175_020).id
             })

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    refute has_element?(view, "#needs-attention", "Grow credits")
    assert SpaceTraders.OperatorConditions.unresolved(scope) == []
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

    realized_episode =
      Repo.insert!(%StrategyDecisionEpisode{
        operator_id: operator.id,
        fleet_generation_id: generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 0,
        calibration_version: "v1",
        classification: :realized,
        evidence_references: [%{"kind" => "test", "id" => "observed"}],
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
    assert html =~ "retained evidence references"
    assert html =~ "Fleet acquired a Ship"
    assert html =~ "One-off navigation stopped"
    assert html =~ "Fleet selected a new commitment portfolio"
    refute html =~ "API request"

    assert has_element?(
             view,
             "a[href='/decision-episodes/#{realized_episode.id}']",
             "Decision Episode #{realized_episode.id}"
           )

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

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: first.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: first.symbol,
        faction: first.faction,
        replacement_symbols: %{"symbols" => [first.symbol]},
        starting_credits: 175_000,
        inserted_at: DateTime.add(now, -3600)
      })

    assert {:ok, _} =
             SpaceTraders.FleetGeneration.record_objective_progress(scope, old.id, 0, %{
               "change" => 10,
               "elapsed_seconds" => 5,
               "feasible?" => false,
               "horizon_seconds" => 10,
               "evidence_id" => objective_evidence(first, 175_010).id
             })

    _second_revision =
      SpaceTraders.FleetStrategy.Revision.create_changeset(
        %SpaceTraders.FleetStrategy.Revision{},
        %{
          fleet_strategy_id: revision.fleet_strategy_id,
          number: 2,
          document: revision.document,
          source: "operator",
          activated_at: DateTime.add(now, -1800)
        }
      )
      |> Repo.insert!()

    old
    |> Ecto.Changeset.change(fenced_at: DateTime.utc_now(), retired_at: DateTime.utc_now())
    |> Repo.update!()

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
      evidence_references: [%{"kind" => "test", "id" => "observed"}],
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
    assert html =~ "Grow credits is not feasible under current evidence."
    assert html =~ "Strategy revision 2"
    assert html =~ "Unknown — no realized credit evidence"
    assert html =~ "Strategy revision 1"
    assert html =~ "Server Reset"
    assert html =~ "Decision partly realized"
    assert html =~ "Strategy-capable"
    assert has_element?(view, "#generation-comparison", "Generation 1")
    assert has_element?(view, "#generation-comparison", "Generation 2")
  end

  test "Generations compares Decision Episodes and opens every retained evidence reference",
       %{
         conn: conn,
         operator: operator,
         scope: scope
       } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    first_agent = agent_fixture(operator, %{agent_token: nil})
    second_agent = agent_fixture(operator, %{agent_token: nil})
    now = DateTime.utc_now()

    first_generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: first_agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: first_agent.symbol,
        faction: first_agent.faction,
        replacement_symbols: %{"symbols" => [first_agent.symbol]},
        inserted_at: now |> DateTime.add(-7_200) |> DateTime.truncate(:second),
        retired_at: DateTime.add(now, -3_600)
      })

    second_generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: second_agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 2,
        symbol: second_agent.symbol,
        faction: second_agent.faction,
        replacement_symbols: %{"symbols" => [second_agent.symbol]},
        inserted_at: now |> DateTime.add(-1_800) |> DateTime.truncate(:second),
        strategy_capable_at: DateTime.add(now, -1_700)
      })

    first_episode =
      Repo.insert!(%StrategyDecisionEpisode{
        operator_id: operator.id,
        fleet_generation_id: first_generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 0,
        calibration_version: "market-v1",
        classification: :realized,
        evidence_references: [
          %{"kind" => "market", "id" => "market:X1-A1", "fingerprint" => "abc"},
          %{"kind" => "market", "id" => "market:X1-A2", "fingerprint" => "def"}
        ],
        expectations: %{"credit_change" => 100, "horizon_seconds" => 300},
        actual_outcomes: %{"credit_change" => 75}
      })

    second_episode =
      Repo.insert!(%StrategyDecisionEpisode{
        operator_id: operator.id,
        fleet_generation_id: second_generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 0,
        calibration_version: "market-v2",
        classification: :partially_realized,
        evidence_references: [%{"kind" => "market", "id" => "market:X1-B1"}],
        expectations: %{"credit_change" => 150, "horizon_seconds" => 300},
        actual_outcomes: %{"credit_change" => 125}
      })

    {:ok, generations, _html} = live(conn, ~p"/generations")

    assert has_element?(generations, "#decision-episode-comparison", "market-v1")
    assert has_element?(generations, "#decision-episode-comparison", "market-v2")
    assert has_element?(generations, "#decision-episode-comparison", "100")
    assert has_element?(generations, "#decision-episode-comparison", "75")

    assert has_element?(
             generations,
             "#decision-episode-comparison a[href='/decision-episodes/#{first_episode.id}']",
             "Episode #{first_episode.id}"
           )

    assert has_element?(
             generations,
             "#decision-episode-comparison a[href='/decision-episodes/#{second_episode.id}']",
             "Episode #{second_episode.id}"
           )

    {:ok, episode, html} = live(conn, "/decision-episodes/#{first_episode.id}")

    assert html =~ "Generation 1"
    assert html =~ "Revision 1"
    assert html =~ "market-v1"
    assert html =~ "market:X1-A1"
    assert html =~ "market:X1-A2"
    assert html =~ "credit change"
    assert html =~ "100"
    assert html =~ "75"

    assert has_element?(
             episode,
             "a[href*='/d/spacetraders-strategy-outcomes/strategy-outcomes'][href*='var-decision_episode=#{first_episode.id}'][href*='var-fleet_generation=#{first_generation.id}']",
             "Strategy outcome evidence"
           )

    assert has_element?(
             episode,
             "a[href*='/d/spacetraders-economics-capital/economics-capital'][href*='var-decision_episode=#{first_episode.id}'][href*='var-fleet_generation=#{first_generation.id}']",
             "Economic and capital evidence"
           )
  end

  test "another Operator cannot open a Decision Episode by identity", %{
    conn: conn,
    operator: operator
  } do
    other_operator = SpaceTraders.AgentFixtures.operator_fixture()
    other_agent = SpaceTraders.AgentFixtures.agent_fixture(other_operator, %{agent_token: nil})

    strategy =
      Repo.insert!(%SpaceTraders.FleetStrategy.Strategy{
        operator_id: other_operator.id,
        revision_number: 1
      })

    revision =
      Repo.insert!(%SpaceTraders.FleetStrategy.Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{},
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    generation =
      Repo.insert!(%Generation{
        operator_id: other_operator.id,
        agent_id: other_agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: other_agent.symbol,
        faction: other_agent.faction,
        replacement_symbols: %{}
      })

    episode =
      Repo.insert!(%StrategyDecisionEpisode{
        operator_id: other_operator.id,
        fleet_generation_id: generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 0,
        calibration_version: "market-v1"
      })

    logged_in = SpaceTradersWeb.ConnCase.log_in_operator(conn, operator)

    assert {:error, {:live_redirect, %{to: "/generations"}}} =
             live(logged_in, "/decision-episodes/#{episode.id}")
  end

  test "Mission Control opens the Grafana family that answers each originating question", %{
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
        replacement_symbols: %{"symbols" => [agent.symbol]},
        strategy_capable_at: DateTime.utc_now()
      })

    {:ok, _condition} =
      SpaceTraders.OperatorConditions.raise(
        scope,
        "credit-floor",
        :attention,
        "Protected credit floor cannot be maintained",
        fleet_generation_id: generation.id,
        fleet_strategy_revision_id: revision.id
      )

    {:ok, view, html} = live(conn, ~p"/mission-control")

    assert has_element?(
             view,
             "#objective-evaluations a[href*='/d/spacetraders-strategy-outcomes/strategy-outcomes'][href*='var-fleet_generation=#{generation.id}'][href*='var-strategy_revision=#{revision.id}'][href*='from='][href*='to=now']",
             "Inspect Strategy outcomes"
           )

    assert has_element?(
             view,
             "#needs-attention a[href*='/d/spacetraders-economics-capital/economics-capital'][href*='var-fleet_generation=#{generation.id}'][href*='var-strategy_revision=#{revision.id}'][href*='from='][href*='to=now']",
             "Inspect Economics and Capital"
           )

    refute html =~ "token="
    refute html =~ "password="
  end

  defp objective_evidence(agent, credits \\ 175_000) do
    observation =
      SpaceTraders.Evidence.authoritative_observation(
        "get-my-agent",
        ["agent:#{agent.id}"],
        %{"response" => %{"credits" => credits}}
      )

    %SpaceTraders.Evidence.Observation{
      agent_id: agent.id,
      subject: "agent:#{agent.id}",
      operation_id: observation.operation_id,
      dependency_keys: observation.dependency_keys,
      facts: observation.facts,
      response_fingerprint: observation.response_fingerprint,
      observed_at: observation.observed_at
    }
    |> Repo.insert!()
  end
end
