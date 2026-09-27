defmodule SpaceTradersWeb.WorldLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest

  alias SpaceTraders.API.Model.{Construction, Market, Shipyard, Waypoint}
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo

  setup :register_and_log_in_operator

  test "requires authentication", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/world")
  end

  test "shows known Waypoints separately from stale or unknown Listings without game reads", %{
    conn: conn,
    operator: operator
  } do
    agent =
      Repo.insert!(%AgentRecord{
        operator_id: operator.id,
        symbol: "ATLAS",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    waypoint =
      Waypoint.from_json(%{
        "symbol" => "X1-A1",
        "systemSymbol" => "X1",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    market = Market.from_json(%{"symbol" => "X1-A1", "exports" => [%{"symbol" => "IRON"}]})

    {:ok, _} =
      Intelligence.observe_waypoint(agent, waypoint,
        source: "get_waypoints",
        observed_at: ~U[2020-01-01 00:00:00Z]
      )

    {:ok, _} =
      Intelligence.observe_market(agent, "X1", market,
        source: "get_market",
        observed_at: ~U[2020-01-01 00:00:00Z]
      )

    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("World must not request gameplay") end)

    {:ok, view, html} = live(conn, ~p"/world")
    assert has_element?(view, "#world-waypoint-X1-A1")
    assert has_element?(view, "a[href='/world/systems/X1?agent=#{agent.id}']", "X1")

    assert has_element?(
             view,
             "a[href='/world/systems/X1/waypoints/X1-A1?agent=#{agent.id}']",
             "Open page"
           )

    assert html =~ "Known waypoint"
    assert html =~ "Stale"
    assert html =~ "Unknown"
    assert html =~ "IRON"
    refute html =~ "get_market"
  end

  test "deep links to known System and Waypoint intelligence without game reads", %{
    conn: conn,
    operator: operator
  } do
    agent =
      Repo.insert!(%AgentRecord{
        operator_id: operator.id,
        symbol: "ATLAS",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    waypoint =
      Waypoint.from_json(%{
        "symbol" => "X1-A1",
        "systemSymbol" => "X1",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} =
      Intelligence.observe_waypoint(agent, waypoint,
        source: "get_waypoints",
        observed_at: ~U[2020-01-01 00:00:00Z]
      )

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("Entity pages must not request gameplay")
    end)

    system_path = "/world/systems/X1"
    waypoint_path = "#{system_path}/waypoints/X1-A1"

    {:ok, system_view, system_html} = live(conn, system_path)
    assert has_element?(system_view, "#system-X1", "System X1")
    assert has_element?(system_view, "a[href='#{waypoint_path}?agent=#{agent.id}']", "X1-A1")
    assert system_html =~ "Known waypoint"

    {:ok, waypoint_view, waypoint_html} = live(conn, waypoint_path)
    assert has_element?(waypoint_view, "#waypoint-X1-A1", "Waypoint X1-A1")
    assert waypoint_html =~ "PLANET"
    assert waypoint_html =~ "MARKETPLACE"
  end

  test "links Market, Shipyard, and Construction pages to their governed intelligence", %{
    conn: conn,
    operator: operator
  } do
    agent =
      Repo.insert!(%AgentRecord{
        operator_id: operator.id,
        symbol: "ATLAS",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    waypoint =
      Waypoint.from_json(%{
        "symbol" => "X1-A1",
        "systemSymbol" => "X1",
        "type" => "JUMP_GATE",
        "traits" => [%{"symbol" => "MARKETPLACE"}],
        "modifiers" => [%{"symbol" => "RADIATION_LEAK", "name" => "Radiation leak"}]
      })

    market = Market.from_json(%{"symbol" => "X1-A1", "exports" => [%{"symbol" => "IRON"}]})

    shipyard =
      Shipyard.from_json(%{"symbol" => "X1-A1", "shipTypes" => [%{"type" => "SHIP_PROBE"}]})

    construction =
      Construction.from_json(%{
        "symbol" => "X1-A1",
        "isComplete" => false,
        "materials" => [%{"tradeSymbol" => "IRON", "required" => 20, "fulfilled" => 7}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoint")
    {:ok, _} = Intelligence.observe_market(agent, "X1", market, source: "get_market")
    {:ok, _} = Intelligence.observe_shipyard(agent, "X1", shipyard, source: "get_shipyard")

    {:ok, _} =
      Intelligence.observe_construction(agent, "X1", construction, source: "get_construction")

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("Entity pages must not request gameplay")
    end)

    waypoint_path = "/world/systems/X1/waypoints/X1-A1"

    {:ok, waypoint_view, _html} = live(conn, waypoint_path)

    assert has_element?(
             waypoint_view,
             "a[href='#{waypoint_path}/market?agent=#{agent.id}']",
             "Market"
           )

    assert has_element?(
             waypoint_view,
             "a[href='#{waypoint_path}/shipyard?agent=#{agent.id}']",
             "Shipyard"
           )

    assert has_element?(
             waypoint_view,
             "a[href='#{waypoint_path}/construction?agent=#{agent.id}']",
             "Construction"
           )

    assert has_element?(waypoint_view, "#waypoint-cautions", "Radiation leak")

    {:ok, _market_view, market_html} = live(conn, "#{waypoint_path}/market")
    assert market_html =~ "Market X1-A1"
    assert market_html =~ "IRON"

    {:ok, _shipyard_view, shipyard_html} = live(conn, "#{waypoint_path}/shipyard")
    assert shipyard_html =~ "Shipyard X1-A1"
    assert shipyard_html =~ "SHIP_PROBE"

    {:ok, _construction_view, construction_html} = live(conn, "#{waypoint_path}/construction")
    assert construction_html =~ "Construction X1-A1"
    assert construction_html =~ "13"
  end

  test "keeps a World link scoped to the Agent whose evidence it references", %{
    conn: conn,
    operator: operator
  } do
    first =
      Repo.insert!(%AgentRecord{
        operator_id: operator.id,
        symbol: "FIRST",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    second =
      Repo.insert!(%AgentRecord{
        operator_id: operator.id,
        symbol: "SECOND",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    {:ok, _} =
      Intelligence.observe_waypoint(
        first,
        Waypoint.from_json(%{"symbol" => "X1-A1", "systemSymbol" => "X1", "type" => "PLANET"}),
        source: "get_waypoint"
      )

    {:ok, _} =
      Intelligence.observe_waypoint(
        second,
        Waypoint.from_json(%{"symbol" => "X1-A1", "systemSymbol" => "X1", "type" => "JUMP_GATE"}),
        source: "get_waypoint"
      )

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("Entity pages must not request gameplay")
    end)

    {:ok, _view, html} = live(conn, "/world/systems/X1/waypoints/X1-A1?agent=#{second.id}")
    assert html =~ "JUMP_GATE"
    refute html =~ "PLANET"
  end
end
