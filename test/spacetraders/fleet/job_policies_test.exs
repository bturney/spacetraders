defmodule SpaceTraders.Fleet.JobPoliciesTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Fleet.{
    ConstructionSupplyPolicy,
    MinerPolicy,
    OutfittingPolicy,
    ProcurementPolicy,
    SystemExplorationPolicy
  }

  defp miner_facts(overrides) do
    Map.merge(
      %{
        in_flight_arrival?: false,
        pending_navigation?: false,
        at_extraction?: false,
        at_market?: false,
        market_leg?: false,
        extraction_waypoint: "X1-A1"
      },
      overrides
    )
  end

  test "Miner Policy waits for a persisted arrival" do
    assert {:wait, :arrival} = MinerPolicy.decide(miner_facts(%{in_flight_arrival?: true}))
  end

  test "Miner Policy waits for a pending navigation" do
    assert {:wait, :navigation} =
             MinerPolicy.decide(
               miner_facts(%{in_flight_arrival?: false, pending_navigation?: true})
             )
  end

  test "Miner Policy gathers at the extraction waypoint" do
    assert {:intent, :gather} = MinerPolicy.decide(miner_facts(%{at_extraction?: true}))
  end

  test "Miner Policy settles cargo at the market during a market leg" do
    assert {:intent, :settle_market} =
             MinerPolicy.decide(miner_facts(%{at_market?: true, market_leg?: true}))
  end

  test "Miner Policy navigates back to the extraction waypoint" do
    assert {:intent, %{type: :navigate, waypoint: "X1-A1"}} = MinerPolicy.decide(miner_facts(%{}))
  end

  test "System Exploration Policy completes when every waypoint has been covered" do
    assert {:complete, %{coverage: %{"X1-A1" => []}}} =
             SystemExplorationPolicy.decide(%{
               coverage: %{"X1-A1" => []},
               viability: %{}
             })
  end

  test "System Exploration Policy blocks unresolved baseline coverage" do
    assert {:block, {:unresolved_coverage, %{"X1-A1" => [:market]}, %{}}} =
             SystemExplorationPolicy.decide(%{
               coverage: %{"X1-A1" => [:market]},
               viability: %{}
             })
  end

  test "Procurement Policy completes when accepted units reach the target" do
    assert {:complete, %{accepted: 10}} =
             ProcurementPolicy.decide(%{accepted: 10, shared_fulfilled: 0, requested: 10})
  end

  test "Procurement Policy completes when shared fulfillment reaches the target" do
    assert {:complete, %{shared_fulfilled: 10}} =
             ProcurementPolicy.decide(%{accepted: 0, shared_fulfilled: 10, requested: 10})
  end

  test "Procurement Policy chooses the next procurement or delivery Intent" do
    assert {:intent, :procure_or_deliver} =
             ProcurementPolicy.decide(%{accepted: 5, shared_fulfilled: 0, requested: 10})
  end

  test "Construction Supply Policy completes from authoritative project state" do
    assert {:complete, %{}} = ConstructionSupplyPolicy.decide(%{construction_complete?: true})
  end

  test "Construction Supply Policy completes when no materials remain" do
    assert {:complete, %{}} =
             ConstructionSupplyPolicy.decide(%{construction_complete?: false, remaining: 0})
  end

  test "Construction Supply Policy chooses the supply Intent" do
    assert {:intent, :supply_construction} =
             ConstructionSupplyPolicy.decide(%{construction_complete?: false, remaining: 40})
  end

  defp outfitting_facts(overrides) do
    Map.merge(
      %{
        ready?: false,
        intent?: false,
        cargo_candidate: nil,
        slot_available?: false,
        authorized_removal: nil,
        sourcing?: false,
        acceptable_modules: ["MODULE_MINING_LASER_I"],
        installed_modules: []
      },
      overrides
    )
  end

  test "Outfitting Policy completes when the Ship is ready" do
    assert {:complete, %{installed_modules: ["MODULE_MINING_LASER_I"]}} =
             OutfittingPolicy.decide(
               outfitting_facts(%{ready?: true, installed_modules: ["MODULE_MINING_LASER_I"]})
             )
  end

  test "Outfitting Policy reconciles an existing Intent" do
    assert {:intent, :reconcile} = OutfittingPolicy.decide(outfitting_facts(%{intent?: true}))
  end

  test "Outfitting Policy installs a module when a slot is available" do
    assert {:intent, %{type: :install_module, module_symbol: "MODULE_MINING_LASER_I"}} =
             OutfittingPolicy.decide(
               outfitting_facts(%{
                 cargo_candidate: "MODULE_MINING_LASER_I",
                 slot_available?: true
               })
             )
  end

  test "Outfitting Policy removes a module when removal is authorized" do
    assert {:intent, %{type: :remove_module, module_symbol: "MODULE_CARGO_HOLD_I"}} =
             OutfittingPolicy.decide(
               outfitting_facts(%{
                 cargo_candidate: "MODULE_MINING_LASER_I",
                 authorized_removal: "MODULE_CARGO_HOLD_I"
               })
             )
  end

  test "Outfitting Policy blocks unauthorized module replacement" do
    assert {:block, :module_slot_removal_not_authorized} =
             OutfittingPolicy.decide(
               outfitting_facts(%{
                 cargo_candidate: "MODULE_MINING_LASER_I",
                 slot_available?: false
               })
             )
  end

  test "Outfitting Policy purchases a source module without cargo" do
    assert {:intent, :purchase_module} =
             OutfittingPolicy.decide(outfitting_facts(%{sourcing?: true}))
  end

  test "Outfitting Policy blocks when the acceptable module is missing from cargo" do
    assert {:block, {:acceptable_module_missing_from_cargo, ["MODULE_MINING_LASER_I"]}} =
             OutfittingPolicy.decide(outfitting_facts(%{}))
  end
end
