defmodule SpaceTraders.ShipReservationTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.ShipReservation

  test "an Operator reserves and releases only their own Ship" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")
    scope = Scope.for_operator(operator)

    assert {:error, :reason_required} = ShipReservation.reserve(scope, ship.id, " ")
    assert {:ok, reservation} = ShipReservation.reserve(scope, ship.id, "  emergency  ")
    assert reservation.reason == "emergency"
    assert ship.symbol in ShipReservation.reserved_symbols(agent.id)
    assert {:error, :already_reserved} = ShipReservation.reserve(scope, ship.id, "again")

    other = Scope.for_operator(operator_fixture())
    assert {:error, :ship_not_found} = ShipReservation.reserve(other, ship.id, "other")
    assert {:error, :reservation_not_found} = ShipReservation.release(other, ship.id)
    assert :ok = ShipReservation.release(scope, ship.id)
    assert ShipReservation.reserved_symbols(agent.id) == []
  end
end
