defmodule SpaceTradersWeb.ShipsLiveTest do
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, IntentBlocker, Intents, Ship, ShipCargo}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.Outcomes.EarningsRecord
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
          DateTime.add(now(), -295)
        )
      )

    {:ok, view, _html} = live(conn, ~p"/ships")
    refute has_element?(view, "#ships-#{ship.id}", "as of")

    Process.sleep(6_100)
    assert has_element?(view, "#ships-#{ship.id}", "as of")
    refute_received {:transport_receipt, _, _}
  end

  defp intent!(ship, attrs) do
    Repo.insert!(
      struct!(
        Intent,
        Map.merge(
          %{
            ship_id: ship.id,
            caller: "commitment",
            type: "buy",
            status: "active",
            target_waypoint: "X1-UX81-A1",
            parameters: %{"units" => 5, "trade_symbol" => "IRON_ORE"}
          },
          attrs
        )
      )
    )
  end

  defp blocked(next_attempt_at, retries) do
    %{
      status: "blocked",
      retries: retries,
      next_attempt_at: next_attempt_at,
      blocker: %IntentBlocker{
        reason: "insufficient_unreserved_headroom",
        summary: "Not enough credits above the floor."
      }
    }
  end

  defp earnings!(ship, net, ship_seconds) do
    at = DateTime.utc_now()

    Repo.insert!(%EarningsRecord{
      source: "trade",
      fleet_generation_id: FleetAllocation.current_generation().id,
      ship_symbol: ship.symbol,
      ship_type: ship.ship_type,
      good: "IRON_ORE",
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-B7",
      units: 10,
      revenue: net + 100,
      goods_cost: 100,
      fuel_cost: 0,
      other_cost: 0,
      net_earnings: net,
      ship_seconds: ship_seconds,
      started_at: DateTime.add(at, -ship_seconds),
      finished_at: at
    })
  end

  test "each row shows its status, what it is doing and credits per Ship-hour",
       %{conn: conn, agent: agent} do
    next = DateTime.add(now(), 240)
    earning = ship!(agent, "ORBITALIST-1", %{})
    stuck = ship!(agent, "ORBITALIST-2", %{})
    intent!(stuck, blocked(next, 2))
    earnings!(earning, 1_500, 1_800)

    {:ok, view, _html} = live(conn, ~p"/ships")

    assert has_element?(view, "#ships-#{earning.id} [data-status=waiting]", "Waiting on purpose")
    assert has_element?(view, "#ships-#{earning.id}", "Waiting for the next allocation")
    assert has_element?(view, "#ships-#{earning.id}", "3,000/h")

    assert has_element?(view, "#ships-#{stuck.id} [data-status=stuck]", "Stuck")
    assert has_element?(view, "#ships-#{stuck.id}", "Not enough credits above the floor.")
    assert has_element?(view, "#ships-#{stuck.id}", "retry 2")

    assert has_element?(
             view,
             "#countdown-#{stuck.id}[data-until='#{DateTime.to_unix(next, :millisecond)}']"
           )

    assert has_element?(view, "#ships-#{stuck.id}", "next attempt")
    refute_received {:transport_receipt, _, _}
  end

  test "a stuck Ship is not overdue before its next attempt", %{conn: conn, agent: agent} do
    stuck =
      ship!(agent, "ORBITALIST-1", %{state_observed_at: DateTime.add(DateTime.utc_now(), -3_600)})

    intent!(stuck, blocked(DateTime.add(now(), 600), 4))

    {:ok, view, _html} = live(conn, ~p"/ships")

    refute has_element?(view, "#ships-#{stuck.id}", "as of")
  end

  test "status chips count and filter the list", %{conn: conn, agent: agent} do
    waiting = ship!(agent, "ORBITALIST-1", %{})
    stuck = ship!(agent, "ORBITALIST-2", %{})
    intent!(stuck, blocked(DateTime.add(now(), 240), 0))

    {:ok, view, _html} = live(conn, ~p"/ships")

    assert has_element?(view, "#status-filter-stuck", "1")
    assert has_element?(view, "#status-filter-waiting", "1")
    assert has_element?(view, "#status-filter-trading", "0")

    view |> element("#status-filter-stuck") |> render_click()
    assert has_element?(view, "#ships-#{stuck.id}")
    refute has_element?(view, "#ships-#{waiting.id}")

    view |> element("#status-filter-all") |> render_click()
    assert has_element?(view, "#ships-#{stuck.id}")
    assert has_element?(view, "#ships-#{waiting.id}")
    refute_received {:transport_receipt, _, _}
  end

  test "a step blocking turns its row Stuck without calling the game",
       %{conn: conn, agent: agent} do
    ship = ship!(agent, "ORBITALIST-1", %{})
    intent = intent!(ship, %{})

    {:ok, view, _html} = live(conn, ~p"/ships")
    refute has_element?(view, "#ships-#{ship.id} [data-status=stuck]")

    {:ok, _} =
      Intents.transition_intent(intent,
        status: "blocked",
        blocker: %{reason: "insufficient_unreserved_headroom", summary: "No headroom."}
      )

    Process.sleep(1_100)
    assert has_element?(view, "#ships-#{ship.id} [data-status=stuck]", "Stuck")
    assert has_element?(view, "#ships-#{ship.id}", "No headroom.")
    refute_received {:transport_receipt, _, _}
  end
end
