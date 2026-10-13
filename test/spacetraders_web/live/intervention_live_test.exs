defmodule SpaceTradersWeb.InterventionLiveTest do
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.{Repo, ShipReservation}

  setup :register_and_log_in_operator

  test "offers only current-Fleet Ships and reserves with the authenticated reason", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    predecessor = agent_fixture(operator, %{symbol: "PARALLAX"})
    {:ok, old_ship} = Fleet.record_ship(predecessor, "PARALLAX-1", "SHIP_COMMAND_FRIGATE")

    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: predecessor.id,
      number: 1,
      symbol: "PARALLAX",
      faction: "COSMIC",
      fenced_at: DateTime.utc_now(),
      retired_at: DateTime.utc_now()
    })

    current = agent_fixture(operator, %{symbol: "ORBITALIST"})
    {:ok, ship} = Fleet.record_ship(current, "ORBITALIST-1", "SHIP_COMMAND_FRIGATE")

    {:ok, view, html} = live(conn, ~p"/intervention")
    assert html =~ "ORBITALIST-1"
    refute html =~ "PARALLAX-1"
    refute has_element?(view, "#reserve-#{old_ship.id}")

    view
    |> form("#reserve-#{ship.id}", %{"ship_id" => ship.id, "reason" => "Hold for inspection"})
    |> render_submit()

    assert [%{ship_id: reserved, reason: "Hold for inspection"}] = ShipReservation.list(scope)
    assert reserved == ship.id
    assert has_element?(view, "#intervene-#{ship.id}")

    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("stale Ship must never reach gameplay") end)

    assert render_submit(view, "reserve", %{"ship_id" => old_ship.id, "reason" => "Stale link"}) =~
             "generation_not_current"

    assert render_submit(view, "intervene", %{
             "ship_id" => old_ship.id,
             "reason" => "Stale link",
             "waypoint" => "X1-UX81-A2"
           }) =~ "Ship unavailable"

    assert [%{ship_id: ^reserved}] = ShipReservation.list(scope)
  end
end
