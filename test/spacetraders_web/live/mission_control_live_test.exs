defmodule SpaceTradersWeb.MissionControlLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.{FleetStrategy, Repo}
  alias SpaceTraders.FleetGeneration.Generation

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
      objective_progress: %{},
      strategy_capable_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/mission-control")

    assert html =~ agent.symbol
    assert html =~ "Generation 1"
    assert html =~ "Strategy-capable"
  end
end
