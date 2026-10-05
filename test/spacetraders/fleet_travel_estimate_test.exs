defmodule SpaceTraders.FleetTravelEstimateTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.Fleet
  alias SpaceTraders.Intelligence

  setup do
    agent = agent_fixture(operator_fixture(), %{headquarters: "X1-UX81-A1"})
    {:ok, agent: agent}
  end

  defp stub_ship(body_overrides \\ %{}) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/ships"
      Req.Test.json(conn, %{"data" => [ship_body("EST-1", body_overrides)]})
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

  defp orbit_nav, do: %{"nav" => nav_body("IN_ORBIT")}

  test "estimates from the live Ship and a freshly observed destination", %{agent: agent} do
    observe(agent, "X1-UX81-B2", 31, 42, DateTime.utc_now())
    stub_ship(orbit_nav())

    assert {:ok, est} = Fleet.travel_estimate(agent, "EST-1", "X1-UX81-B2", "navigate", "CRUISE")

    assert %{status: :ok, fuel_cost: 50, current_fuel: 150, remaining_fuel: 100, seconds: 1265} =
             est

    assert est.warnings == []
  end

  test "recomputes when the Flight Mode, method, destination, or Ship state changes", %{
    agent: agent
  } do
    observe(agent, "X1-UX81-B2", 31, 42, DateTime.utc_now())
    observe(agent, "X1-UX81-B3", 4, 6, DateTime.utc_now())
    stub_ship(orbit_nav())

    assert {:ok, %{fuel_cost: 50}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-UX81-B2", "navigate", "CRUISE")

    assert {:ok, %{fuel_cost: 1}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-UX81-B2", "navigate", "DRIFT")

    assert {:ok, %{fuel_cost: 100}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-UX81-B2", "navigate", "BURN")

    assert {:ok, %{fuel_cost: 5}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-UX81-B3", "navigate", "CRUISE")

    stub_ship(%{
      "nav" => nav_body("IN_ORBIT"),
      "fuel" => %{"capacity" => 200, "current" => 20}
    })

    assert {:ok, %{status: :insufficient_fuel, remaining_fuel: -30}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-UX81-B2", "navigate", "CRUISE")
  end

  test "stale coordinates estimate with a warning; unobserved coordinates stay uncertain", %{
    agent: agent
  } do
    observe(agent, "X1-UX81-B2", 31, 42, ~U[2020-01-01 00:00:00Z])
    stub_ship(orbit_nav())

    assert {:ok, %{status: :ok, warnings: stale}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-UX81-B2", "navigate", "CRUISE")

    assert Enum.any?(stale, &(&1 =~ "stale"))

    assert {:ok, %{status: :uncertain, fuel_cost: nil, seconds: nil, warnings: missing}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-UX81-NOPE", "navigate", "CRUISE")

    assert Enum.any?(missing, &(&1 =~ "coordinates"))
  end

  test "warp to another System is explicitly uncertain without retained System coordinates", %{
    agent: agent
  } do
    stub_ship(orbit_nav())

    assert {:ok, %{status: :uncertain, warnings: warnings}} =
             Fleet.travel_estimate(agent, "EST-1", "X1-ZZ9-A1", "warp", "CRUISE")

    assert Enum.any?(warnings, &(&1 =~ "System coordinates"))
  end

  test "an unknown Ship or an unreadable fleet is an error, not an estimate", %{agent: agent} do
    stub_ship()

    assert {:error, :ship_not_found} =
             Fleet.travel_estimate(agent, "OTHER", "X1-UX81-B2", "navigate", "CRUISE")

    assert {:error, :agent_token_missing} =
             Fleet.travel_estimate(
               %{agent | agent_token: nil},
               "EST-1",
               "X1-UX81-B2",
               "navigate",
               "CRUISE"
             )
  end
end
