defmodule SpaceTradersWeb.GenerationsLiveTest do
  @moduledoc "Generations recaps, Decision Episode comparison and history access."
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.{FleetStrategy, Repo}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode

  setup :register_and_log_in_operator

  test "Generation recaps compare evidenced outcomes and do not invent missing measurements", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    first = agent_fixture(operator, %{agent_token: nil})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old =
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
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

    second_revision =
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
    |> Ecto.Changeset.change(
      fenced_at: DateTime.utc_now(),
      retired_at: DateTime.utc_now(),
      fleet_strategy_revision_id: second_revision.id
    )
    |> Repo.update!()

    second = agent_fixture(operator, %{agent_token: nil})

    SpaceTraders.AgentFixtures.generation_fixture(%Generation{
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
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
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
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
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

  test "deployment authentication, not Episode authorship, controls history access", %{
    conn: conn,
    operator: operator
  } do
    other_operator = SpaceTraders.AgentFixtures.legacy_operator_fixture()
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
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
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

    assert {:ok, view, _html} = live(logged_in, "/decision-episodes/#{episode.id}")
    assert has_element?(view, "h1", "Decision Episode #{episode.id}")

    legacy_login = SpaceTradersWeb.ConnCase.log_in_operator(conn, other_operator)

    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(legacy_login, "/decision-episodes/#{episode.id}")
  end

  defp objective_evidence(agent, credits) do
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
