defmodule SpaceTradersWeb.RetiredGameplayLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Job}

  alias SpaceTraders.{
    FleetStrategy,
    LegacyGameplayHistory,
    ManualIntervention,
    Repo,
    ShipReservation
  }

  alias SpaceTraders.Agent.Scope

  setup :register_and_log_in_operator

  test "history is authenticated and retains legacy owner and type", %{
    conn: conn,
    operator: operator
  } do
    agent = agent_fixture(operator, %{agent_token: nil})
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")

    Repo.insert!(%Job{
      ship_id: ship.id,
      type: "survey",
      status: "stopped",
      extraction_waypoint: "X1-UX81-A1",
      market_waypoint: "SURVEY-NONE",
      cargo_threshold: 1
    })

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "manual",
      type: "navigate",
      target_waypoint: "X1-UX81-A1",
      status: "completed"
    })

    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/gameplay-history")

    {:ok, _view, html} = live(conn, ~p"/gameplay-history")
    assert html =~ "survey Job"
    assert html =~ "Legacy Manual Control"
    assert html =~ "stopped"
  end

  test "history remains Operator-scoped after a Stale Agent is retired", %{
    conn: conn,
    operator: operator
  } do
    agent = agent_fixture(operator, %{agent_token: nil})
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")

    Repo.insert!(%Job{
      ship_id: ship.id,
      type: "survey",
      status: "stopped",
      extraction_waypoint: "X1-UX81-A1",
      market_waypoint: "SURVEY-NONE",
      cargo_threshold: 1
    })

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "manual",
      type: "navigate",
      target_waypoint: "X1-UX81-A2",
      status: "completed"
    })

    scope = Scope.for_operator(operator)
    assert {:ok, reservation} = ShipReservation.reserve(scope, ship.id, "Reset recovery")

    intervention_intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "intervention",
        status: "waiting",
        target_waypoint: "X1-UX81-A3"
      })

    Repo.insert!(%ManualIntervention{
      ship_reservation_id: reservation.id,
      intent_id: intervention_intent.id,
      reason: "Recover route",
      target_waypoint: "X1-UX81-A3"
    })

    assert {:ok, _} =
             Repo.transaction(fn ->
               :ok = LegacyGameplayHistory.archive_agent!(agent)
               :ok = ShipReservation.release_for_agent!(agent.id)
               Repo.delete!(agent)
             end)

    assert ShipReservation.list(scope) == []
    assert [%ManualIntervention{final_status: "reset_censored"}] = ManualIntervention.list(scope)

    {:ok, _view, html} = live(conn, ~p"/gameplay-history")
    assert html =~ "Retired Fleet Generation"
    assert html =~ "survey Job"
    assert html =~ "Legacy Manual Control"
    assert html =~ "X1-UX81-A2"
    assert html =~ "Manual Intervention"
    assert html =~ "reset_censored"
  end

  test "active Strategy redirects old dashboard and offers a separate Ship reservation", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    agent = agent_fixture(operator, %{agent_token: nil})
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")
    assert {:ok, _} = FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, _} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    assert {:error, {:redirect, %{to: "/mission-control"}}} = live(conn, ~p"/")

    {:ok, view, _html} = live(conn, ~p"/intervention")
    assert has_element?(view, "#ship-reservations")

    view
    |> form("#ship-reservations article form", %{ship_id: to_string(ship.id), reason: "Recovery"})
    |> render_submit()

    assert has_element?(view, "#ship-reservations", "Reserved: Recovery")
  end
end
