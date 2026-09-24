defmodule SpaceTradersWeb.WorldLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest

  alias SpaceTraders.API.Model.{Market, Waypoint}
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
    assert html =~ "Known waypoint"
    assert html =~ "Stale"
    assert html =~ "Unknown"
    assert html =~ "IRON"
    refute html =~ "get_market"
  end
end
