defmodule SpaceTradersWeb.WorldLiveTest do
  # Current-Fleet resolution adopts with deployment-wide locks.
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SpaceTraders.API.Model.{Construction, Market, Shipyard, Waypoint}
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.FleetGeneration.Generation
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
    assert has_element?(view, "a[href='/world/systems/X1']", "X1")

    assert has_element?(
             view,
             "a[href='/world/systems/X1/waypoints/X1-A1']",
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
    assert has_element?(system_view, "a[href='#{waypoint_path}']", "X1-A1")
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
             "a[href='#{waypoint_path}/market']",
             "Market"
           )

    assert has_element?(
             waypoint_view,
             "a[href='#{waypoint_path}/shipyard']",
             "Shipyard"
           )

    assert has_element?(
             waypoint_view,
             "a[href='#{waypoint_path}/construction']",
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

  describe "the sole current Fleet" do
    setup %{operator: operator} do
      predecessor =
        Repo.insert!(%AgentRecord{
          operator_id: operator.id,
          symbol: "PARALLAX",
          faction: "COSMIC",
          headquarters: "X1-A1"
        })

      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: predecessor.id,
        number: 1,
        symbol: "PARALLAX",
        faction: "COSMIC",
        fenced_at: DateTime.utc_now(),
        retired_at: DateTime.utc_now()
      })

      current =
        Repo.insert!(%AgentRecord{
          operator_id: operator.id,
          symbol: "ORBITALIST",
          faction: "COSMIC",
          headquarters: "X2-B1"
        })

      observe!(predecessor, "X1", "X1-A1", "PLANET")
      observe!(current, "X2", "X2-B1", "JUMP_GATE")

      Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("World must not request gameplay") end)
      %{predecessor: predecessor, current: current}
    end

    test "World shows only the current Fleet, without an Agent selector", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/world")

      assert has_element?(view, "a[href='/world/systems/X2']", "X2")
      assert has_element?(view, "#world-waypoint-X2-B1")
      assert html =~ "ORBITALIST"
      refute html =~ "PARALLAX"
      refute has_element?(view, "#world-waypoint-X1-A1")
      refute html =~ "agent="
      refute has_element?(view, "[phx-value-agent]")
    end

    test "a stale Agent link reads history under its own Generation and is never current", %{
      conn: conn,
      predecessor: predecessor
    } do
      {:ok, view, html} =
        live(conn, "/world/systems/X1/waypoints/X1-A1?agent=#{predecessor.id}")

      assert html =~ "PLANET"
      assert has_element?(view, "#historical-evidence", "Historical evidence")
      assert has_element?(view, "#historical-evidence", "PARALLAX")
      assert has_element?(view, "#historical-evidence", "Generation 1")
      refute has_element?(view, "#current-fleet-evidence")

      # In-page navigation stays inside the historical context.
      assert has_element?(
               view,
               "a[href='/world/systems/X1/waypoints/X1-A1/market?agent=#{predecessor.id}']"
             )

      {:ok, current_view, current_html} = live(conn, "/world/systems/X1/waypoints/X1-A1")
      assert has_element?(current_view, "#current-fleet-evidence", "ORBITALIST")
      refute current_html =~ "PLANET"

      {:ok, bogus_view, _html} = live(conn, "/world/systems/X2/waypoints/X2-B1?agent=nonsense")
      assert has_element?(bogus_view, "#current-fleet-evidence", "ORBITALIST")
    end
  end

  test "without a current Fleet World explains the setup state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/world")
    assert html =~ "No current Fleet"
  end

  defp observe!(agent, system, symbol, type) do
    {:ok, _} =
      Intelligence.observe_waypoint(
        agent,
        Waypoint.from_json(%{"symbol" => symbol, "systemSymbol" => system, "type" => type}),
        source: "get_waypoint"
      )
  end
end
