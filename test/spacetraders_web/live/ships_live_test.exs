defmodule SpaceTradersWeb.ShipsLiveTest do
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Ship, ShipCargo}
  alias SpaceTraders.Repo

  setup :register_and_log_in_operator

  setup %{operator: operator} do
    test_pid = self()

    # Every game request is a transport receipt; the Ships list must make none.
    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:transport_receipt, conn.method, conn.request_path})
      Req.Test.json(conn, %{"data" => []})
    end)

    %{agent: agent_fixture(operator, %{symbol: "ORBITALIST"})}
  end

  defp now, do: DateTime.utc_now(:second)

  defp ship!(agent, symbol, attrs) do
    observed = Map.get(attrs, :state_observed_at, DateTime.utc_now())

    ship =
      Repo.insert!(
        struct!(
          Ship,
          Map.merge(
            %{
              agent_id: agent.id,
              symbol: symbol,
              ship_type: "SHIP_LIGHT_HAULER",
              nav_status: "DOCKED",
              waypoint_symbol: "X1-UX81-A1",
              fuel_current: 100,
              fuel_capacity: 200,
              cargo_capacity: 40,
              route_origin: "X1-UX81-A1",
              route_destination: "X1-UX81-A1",
              route_departed_at: DateTime.add(now(), -600),
              route_arrives_at: DateTime.add(now(), -540)
            },
            Map.put(attrs, :state_observed_at, observed)
          )
        )
      )

    ship
  end

  defp in_transit(from, to, departed, arrives) do
    %{
      nav_status: "IN_TRANSIT",
      waypoint_symbol: to,
      route_origin: from,
      route_destination: to,
      route_departed_at: departed,
      route_arrives_at: arrives
    }
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/ships")
  end

  test "lists every stored Ship by name with its route and a client-side countdown, without calling the game",
       %{conn: conn, agent: agent} do
    arrives = DateTime.add(now(), 240)

    flying =
      ship!(
        agent,
        "ORBITALIST-2",
        in_transit("X1-UX81-A1", "X1-UX81-B7", DateTime.add(now(), -60), arrives)
      )

    parked = ship!(agent, "ORBITALIST-1", %{})
    Repo.insert!(%ShipCargo{ship_id: parked.id, trade_symbol: "IRON_ORE", units: 12})

    {:ok, view, html} = live(conn, ~p"/ships")

    assert [_, first, second] = String.split(html, ~r/id="ships-\d+"/)
    assert first =~ "ORBITALIST-1"
    assert second =~ "ORBITALIST-2"

    assert has_element?(view, "#ships-#{parked.id}", "Docked at A1")
    assert has_element?(view, "#ships-#{parked.id}", "12 IRON_ORE")
    assert has_element?(view, "#ships-#{flying.id}", "In transit to B7")

    assert has_element?(
             view,
             "#route-#{flying.id}[data-arrive='#{DateTime.to_unix(arrives, :millisecond)}']"
           )

    assert has_element?(view, "#countdown-#{flying.id}[phx-hook][data-until]")
    refute has_element?(view, "#ships-#{flying.id}", "as of")

    refute_received {:transport_receipt, _, _}
  end

  test "a Ship change updates its own row without calling the game", %{conn: conn, agent: agent} do
    changing = ship!(agent, "ORBITALIST-1", %{})
    steady = ship!(agent, "ORBITALIST-2", %{})

    {:ok, view, _html} = live(conn, ~p"/ships")
    steady_row = view |> element("#ships-#{steady.id}") |> render()

    departed = DateTime.add(now(), -5) |> DateTime.to_iso8601()
    arrives = DateTime.add(now(), 300) |> DateTime.to_iso8601()

    assert {:ok, %Ship{}} =
             Fleet.record_ship_state(agent.id, "ORBITALIST-1", %{
               nav: %Model.ShipNav{
                 status: "IN_TRANSIT",
                 waypoint_symbol: "X1-UX81-C3",
                 route: %Model.ShipNavRoute{
                   origin: %{symbol: "X1-UX81-A1"},
                   destination: %{symbol: "X1-UX81-C3"},
                   departure_time: departed,
                   arrival: arrives
                 }
               }
             })

    assert has_element?(view, "#ships-#{changing.id}", "In transit to C3")
    assert view |> element("#ships-#{steady.id}") |> render() == steady_row
    refute_received {:transport_receipt, _, _}
  end

  test "an overdue Ship reads \"as of HH:MM\"", %{conn: conn, agent: agent} do
    observed = ~U[2026-10-18 09:41:00.000000Z]

    late =
      ship!(
        agent,
        "ORBITALIST-1",
        in_transit(
          "X1-UX81-A1",
          "X1-UX81-B7",
          DateTime.add(now(), -900),
          DateTime.add(now(), -301)
        )
        |> Map.put(:state_observed_at, observed)
      )

    on_time =
      ship!(
        agent,
        "ORBITALIST-2",
        in_transit(
          "X1-UX81-A1",
          "X1-UX81-B7",
          DateTime.add(now(), -900),
          DateTime.add(now(), -60)
        )
      )

    {:ok, view, _html} = live(conn, ~p"/ships")

    assert has_element?(view, "#ships-#{late.id}", "as of 09:41")
    refute has_element?(view, "#ships-#{on_time.id}", "as of")
  end

  test "a Ship turns overdue while the list is open", %{conn: conn, agent: agent} do
    ship =
      ship!(
        agent,
        "ORBITALIST-1",
        in_transit(
          "X1-UX81-A1",
          "X1-UX81-B7",
          DateTime.add(now(), -900),
          DateTime.add(now(), -299)
        )
      )

    {:ok, view, _html} = live(conn, ~p"/ships")
    refute has_element?(view, "#ships-#{ship.id}", "as of")

    Process.sleep(2_100)
    assert has_element?(view, "#ships-#{ship.id}", "as of")
    refute_received {:transport_receipt, _, _}
  end
end
