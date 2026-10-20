defmodule SpaceTradersWeb.StatsLiveTest do
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.{FleetAllocation, Repo}
  alias SpaceTraders.Outcomes.EarningsRecord

  setup :register_and_log_in_operator

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/stats")
  end

  test "an empty Generation says no trades yet", %{conn: conn, operator: operator} do
    agent_fixture(operator, %{symbol: "EMPTY", agent_token: nil})
    {:ok, view, _html} = live(conn, ~p"/stats")

    assert has_element?(view, "#stat-best-trade", "No trades completed yet")
    assert has_element?(view, "#stat-trades", "0")
  end

  test "renders from Earnings records alone and a new best appears without reload", %{
    conn: conn,
    operator: operator
  } do
    agent_fixture(operator, %{symbol: "STATS", agent_token: nil})
    generation = FleetAllocation.current_generation()
    record(generation, "IRON_ORE", 1_200, "STATS-1")
    record(generation, "IRON_ORE", 800, "STATS-2")
    record(generation, "COPPER", 1_500, "STATS-3")

    {:ok, view, _html} = live(conn, ~p"/stats")

    assert has_element?(view, "#stat-best-trade", "+1,500")
    assert has_element?(view, "#stat-best-trade", "STATS-3")
    assert has_element?(view, "#stat-best-good", "Iron ore")
    assert has_element?(view, "#stat-best-good", "+2,000")
    assert has_element?(view, "#stat-trades", "3")

    new_best = record(generation, "GOLD", 9_000, "STATS-4")
    GenServer.cast(SpaceTraders.Outcomes, {:earnings, new_best})

    assert render_async_wait(view, "#stat-best-trade", "STATS-4")
    assert has_element?(view, "#stat-best-trade", "+9,000")
    assert has_element?(view, "#stat-best-good", "Gold")
    assert has_element?(view, "#stat-trades", "4")
  end

  # The worker broadcasts after its cast is handled; poll briefly for the patch.
  defp render_async_wait(view, selector, text, tries \\ 50) do
    cond do
      has_element?(view, selector, text) ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        render_async_wait(view, selector, text, tries - 1)
    end
  end

  defp record(generation, good, net, ship) do
    now = DateTime.utc_now()

    Repo.insert!(%EarningsRecord{
      source: "trade",
      fleet_generation_id: generation.id,
      ship_symbol: ship,
      ship_type: "SHIP_LIGHT_HAULER",
      good: good,
      source_waypoint: "X1-A-B1",
      destination_waypoint: "X1-A-C2",
      units: 10,
      revenue: net + 100,
      goods_cost: 100,
      fuel_cost: 0,
      other_cost: 0,
      net_earnings: net,
      ship_seconds: 600,
      started_at: now,
      finished_at: now
    })
  end
end
