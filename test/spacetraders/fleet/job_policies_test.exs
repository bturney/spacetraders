defmodule SpaceTraders.Fleet.JobPoliciesTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Fleet.{
    ConstructionSupplyPolicy,
    ExplorerPolicy,
    MinerPolicy,
    OutfittingPolicy,
    ProcurementPolicy
  }

  test "Miner Policy waits for a persisted arrival" do
    assert {:wait, :arrival} =
             MinerPolicy.decide(%{
               in_flight_arrival?: true,
               pending_navigation?: false,
               at_extraction?: false,
               at_market?: false,
               market_leg?: false,
               extraction_waypoint: "X1-A1"
             })
  end

  test "Explorer Policy blocks unresolved baseline coverage" do
    assert {:block, {:unresolved_coverage, %{"X1-A1" => [:market]}, %{}}} =
             ExplorerPolicy.decide(%{coverage: %{"X1-A1" => [:market]}, viability: %{}})
  end

  test "Procurement Policy completes when shared fulfillment reaches the target" do
    assert {:complete, %{shared_fulfilled: 10}} =
             ProcurementPolicy.decide(%{accepted: 0, shared_fulfilled: 10, requested: 10})
  end

  test "Construction Supply Policy completes from authoritative project state" do
    assert {:complete, %{}} = ConstructionSupplyPolicy.decide(%{construction_complete?: true})
  end

  test "Outfitting Policy blocks unauthorized module replacement" do
    assert {:block, :module_slot_removal_not_authorized} =
             OutfittingPolicy.decide(%{
               ready?: false,
               intent?: false,
               cargo_candidate: "MODULE_MINING_LASER_I",
               slot_available?: false,
               authorized_removal: nil,
               sourcing?: false,
               acceptable_modules: ["MODULE_MINING_LASER_I"],
               installed_modules: []
             })
  end
end
