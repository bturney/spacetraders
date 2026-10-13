defmodule SpaceTraders.ShipReservationTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.{Repo, ShipReservation}

  test "the deployment Operator reserves and releases a current-Fleet Ship" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")
    scope = Scope.for_operator(operator)

    assert {:error, :reason_required} = ShipReservation.reserve(scope, ship.id, " ")
    assert {:ok, reservation} = ShipReservation.reserve(scope, ship.id, "  emergency  ")
    assert reservation.reason == "emergency"
    assert reservation.operator_id == operator.id
    assert ship.symbol in ShipReservation.reserved_symbols(agent.id)
    assert {:error, :already_reserved} = ShipReservation.reserve(scope, ship.id, "again")

    other = Scope.for_operator(legacy_operator_fixture())
    assert {:error, :not_deployment_operator} = ShipReservation.reserve(other, ship.id, "other")
    assert {:error, :not_deployment_operator} = ShipReservation.release(other, ship.id)
    assert ShipReservation.list(other) == []
    assert [%{id: id}] = ShipReservation.list(scope)
    assert id == reservation.id
    assert :ok = ShipReservation.release(scope, ship.id)
    assert ShipReservation.reserved_symbols(agent.id) == []
  end

  test "a retained predecessor Generation's Ship cannot be reserved" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    predecessor = agent_fixture(operator, %{symbol: "PARALLAX"})

    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: predecessor.id,
      number: 1,
      symbol: "PARALLAX",
      faction: "COSMIC",
      fenced_at: DateTime.utc_now(),
      retired_at: DateTime.utc_now()
    })

    {:ok, ship} = Fleet.record_ship(predecessor, "PARALLAX-1", "SHIP_COMMAND_FRIGATE")

    assert {:error, :generation_not_current} = ShipReservation.reserve(scope, ship.id, "history")
    assert ShipReservation.list(scope) == []
  end
end
