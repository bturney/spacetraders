defmodule SpaceTradersWeb.InterventionLiveTest do
  # Reservation touches the shared Fleet allocation state.
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.{Fleet, FleetStrategy, Intelligence, Repo, ShipReservation}

  setup :register_and_log_in_operator

  setup %{operator: operator, scope: scope} do
    agent = agent_fixture(operator, %{headquarters: "X1-UX81-A1"})
    symbol = "#{agent.symbol}-1"
    {:ok, ship} = Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")

    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    Repo.insert!(%SpaceTraders.FleetGeneration.Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction
    })

    {:ok, _} = ShipReservation.reserve(scope, ship.id, "Estimate check")
    %{agent: agent, symbol: symbol, ship: ship}
  end

  defp stub_ship(symbol, overrides) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => [ship_body(symbol, overrides)]})
    end)
  end

  defp observe(agent, symbol, x, y, observed_at) do
    waypoint =
      Waypoint.from_json(%{
        "symbol" => symbol,
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => x,
        "y" => y
      })

    {:ok, _} =
      Intelligence.observe_waypoint(agent, waypoint,
        source: "get_waypoints",
        observed_at: observed_at
      )
  end

  defp change(view, ship, params) do
    view
    |> form("#intervene-#{ship.id}", params)
    |> render_change()
  end

  test "shows no estimate until a destination is entered", %{conn: conn, ship: ship} do
    stub_ship(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})
    {:ok, view, _html} = live(conn, ~p"/intervention")

    refute has_element?(view, "#travel-estimate-#{ship.id}")
    assert has_element?(view, "#intervene-#{ship.id} select[name=method]")
    assert has_element?(view, "#intervene-#{ship.id} select[name=flight_mode]")
  end

  test "renders fuel, remaining fuel, fit, and duration before dispatch and follows selections",
       %{conn: conn, agent: agent, ship: ship} do
    observe(agent, "X1-UX81-B2", 31, 42, DateTime.utc_now())
    stub_ship(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})
    {:ok, view, _html} = live(conn, ~p"/intervention")
    est = "#travel-estimate-#{ship.id}"

    change(view, ship, %{"waypoint" => "X1-UX81-B2"})

    assert has_element?(view, "#{est} [data-field=method]", "navigate")
    assert has_element?(view, "#{est} [data-field=flight_mode]", "CRUISE")
    assert has_element?(view, "#{est} [data-field=distance]", "50.0")
    assert has_element?(view, "#{est} [data-field=current_fuel]", "150")
    assert has_element?(view, "#{est} [data-field=fuel_cost]", "50")
    assert has_element?(view, "#{est} [data-field=remaining_fuel]", "100")
    assert has_element?(view, "#{est} [data-field=fits_tank]", "yes")
    assert has_element?(view, "#{est} [data-field=duration]", "1265 s")
    assert has_element?(view, est, "game response at dispatch is final")

    change(view, ship, %{"flight_mode" => "DRIFT"})
    assert has_element?(view, "#{est} [data-field=fuel_cost]", "1")
    assert has_element?(view, "#{est} [data-field=flight_mode]", "DRIFT")

    change(view, ship, %{"flight_mode" => "BURN"})
    assert has_element?(view, "#{est} [data-field=fuel_cost]", "100")

    # Draft survives later re-renders (form_drafts pattern).
    assert has_element?(view, "#intervene-#{ship.id} input[name=waypoint][value='X1-UX81-B2']")
  end

  test "insufficient fuel is a visible blocker, not a dispatch", %{
    conn: conn,
    agent: agent,
    ship: ship
  } do
    observe(agent, "X1-UX81-B2", 31, 42, DateTime.utc_now())

    stub_ship(ship.symbol, %{
      "nav" => nav_body("IN_ORBIT"),
      "fuel" => %{"capacity" => 200, "current" => 10}
    })

    {:ok, view, _html} = live(conn, ~p"/intervention")
    change(view, ship, %{"waypoint" => "X1-UX81-B2"})

    est = "#travel-estimate-#{ship.id}"
    assert has_element?(view, "#{est} [role=alert]", "estimated fuel exceeds the current tank")
    assert has_element?(view, "#{est} [data-field=fits_tank]", "no")
    assert has_element?(view, "#{est} li", "refuel")
    assert Repo.all(SpaceTraders.ManualIntervention) == []
  end

  test "missing and stale coordinates and unreadable capability data stay explicit", %{
    conn: conn,
    agent: agent,
    ship: ship
  } do
    observe(agent, "X1-UX81-OLD", 31, 42, ~U[2020-01-01 00:00:00Z])
    stub_ship(ship.symbol, %{"nav" => nav_body("IN_ORBIT"), "engine" => nil})
    {:ok, view, _html} = live(conn, ~p"/intervention")
    est = "#travel-estimate-#{ship.id}"

    change(view, ship, %{"waypoint" => "X1-UX81-GONE"})
    assert has_element?(view, "#{est} [data-field=fuel_cost]", "unknown")
    assert has_element?(view, "#{est} [data-field=duration]", "unknown")
    assert has_element?(view, "#{est} li", "coordinates are missing")

    change(view, ship, %{"waypoint" => "X1-UX81-OLD"})
    assert has_element?(view, "#{est} li", "stale")
    assert has_element?(view, "#{est} li", "Engine speed is unavailable")
    assert has_element?(view, "#{est} [data-field=duration]", "unknown")
  end

  test "warp is explicit about missing System coordinates", %{conn: conn, ship: ship} do
    stub_ship(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})
    {:ok, view, _html} = live(conn, ~p"/intervention")
    est = "#travel-estimate-#{ship.id}"

    change(view, ship, %{"waypoint" => "X1-ZZ9-A1", "method" => "warp"})
    assert has_element?(view, "#{est} [data-field=method]", "warp")
    assert has_element?(view, "#{est} li", "System coordinates are not retained")
  end

  test "an unreadable Ship degrades to an unavailable notice", %{conn: conn, ship: ship} do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
    end)

    {:ok, view, _html} = live(conn, ~p"/intervention")
    change(view, ship, %{"waypoint" => "X1-UX81-B2"})

    assert has_element?(view, "#travel-estimate-#{ship.id}", "Estimate unavailable")
  end
end
