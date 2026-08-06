defmodule SpaceTraders.API.ModelTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.Model

  describe "Agent" do
    test "decodes a payload into a typed struct" do
      agent =
        Model.Agent.from_json(%{
          "accountId" => "account-1",
          "symbol" => "ORBITALIST",
          "headquarters" => "X1-UX81-A1",
          "credits" => 175_000,
          "startingFaction" => "COSMIC",
          "shipCount" => 2
        })

      assert %Model.Agent{} = agent
      assert agent.symbol == "ORBITALIST"
      assert agent.credits == 175_000
      assert agent.headquarters == "X1-UX81-A1"
    end
  end

  describe "Ship" do
    test "decodes nested nav, cargo, fuel and cooldown" do
      ship =
        Model.Ship.from_json(%{
          "symbol" => "ORBITALIST-1",
          "registration" => %{
            "name" => "ORBITALIST-1",
            "factionSymbol" => "COSMIC",
            "role" => "COMMAND"
          },
          "nav" => %{
            "systemSymbol" => "X1-UX81",
            "waypointSymbol" => "X1-UX81-A1",
            "status" => "IN_ORBIT",
            "flightMode" => "CRUISE",
            "route" => %{
              "destination" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "PLANET",
                "systemSymbol" => "X1-UX81",
                "x" => 1,
                "y" => 2
              },
              "origin" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "PLANET",
                "systemSymbol" => "X1-UX81",
                "x" => 1,
                "y" => 2
              },
              "departureTime" => "2026-01-01T00:00:00.000Z",
              "arrival" => "2026-01-01T00:00:00.000Z"
            }
          },
          "crew" => %{
            "current" => 1,
            "required" => 1,
            "capacity" => 1,
            "rotation" => "STRICT",
            "morale" => 100,
            "wages" => 0
          },
          "frame" => %{
            "symbol" => "FRAME_PROBE",
            "name" => "Probe",
            "description" => "A probe.",
            "condition" => 1.0,
            "integrity" => 1.0,
            "moduleSlots" => 0,
            "mountingPoints" => 0,
            "fuelCapacity" => 200,
            "requirements" => %{"power" => 1, "crew" => 1, "slots" => 1}
          },
          "reactor" => %{
            "symbol" => "REACTOR_SOLAR_I",
            "name" => "Solar",
            "description" => "A reactor.",
            "condition" => 1.0,
            "integrity" => 1.0,
            "powerOutput" => 1,
            "requirements" => %{"power" => 1, "crew" => 1, "slots" => 1}
          },
          "engine" => %{
            "symbol" => "ENGINE_IMPULSE_DRIVE_I",
            "name" => "Impulse",
            "description" => "An engine.",
            "condition" => 1.0,
            "integrity" => 1.0,
            "speed" => 1,
            "requirements" => %{"power" => 1, "crew" => 1, "slots" => 1}
          },
          "cooldown" => %{
            "shipSymbol" => "ORBITALIST-1",
            "totalSeconds" => 0,
            "remainingSeconds" => 0
          },
          "modules" => [],
          "mounts" => [],
          "cargo" => %{
            "capacity" => 0,
            "units" => 0,
            "inventory" => [
              %{
                "symbol" => "IRON_ORE",
                "name" => "Iron Ore",
                "description" => "Ore",
                "units" => 10
              }
            ]
          },
          "fuel" => %{
            "capacity" => 200,
            "current" => 200,
            "consumed" => %{"amount" => 0, "timestamp" => "2026-01-01T00:00:00.000Z"}
          }
        })

      assert ship.symbol == "ORBITALIST-1"
      assert ship.nav.status == "IN_ORBIT"
      assert ship.nav.route.destination.symbol == "X1-UX81-A1"
      assert ship.registration.role == "COMMAND"
      assert [%Model.ShipCargoItem{units: 10}] = ship.cargo.inventory
      assert ship.fuel.consumed.amount == 0
      assert ship.frame.condition == 1.0
    end
  end

  describe "Contract" do
    test "decodes terms, payment and deliverables" do
      contract =
        Model.Contract.from_json(%{
          "id" => "cl9xydc0q00000a1a1a1a1a1a",
          "factionSymbol" => "COSMIC",
          "type" => "PROCUREMENT",
          "terms" => %{
            "deadline" => "2026-01-31T00:00:00.000Z",
            "payment" => %{"onAccepted" => 150_000, "onFulfilled" => 25_000},
            "deliver" => [
              %{
                "tradeSymbol" => "IRON_ORE",
                "destinationSymbol" => "X1-UX81-A2",
                "unitsRequired" => 100,
                "unitsFulfilled" => 0
              }
            ]
          },
          "accepted" => false,
          "fulfilled" => false,
          "expiration" => "2026-02-01T00:00:00.000Z",
          "deadlineToAccept" => "2026-01-02T00:00:00.000Z"
        })

      assert contract.type == "PROCUREMENT"
      assert contract.accepted == false
      assert contract.terms.payment.on_accepted == 150_000
      assert [%Model.ContractDeliverGood{units_required: 100}] = contract.terms.deliver
    end
  end

  describe "Market" do
    test "decodes trade goods and transactions" do
      market =
        Model.Market.from_json(%{
          "symbol" => "X1-UX81-A1",
          "exports" => [%{"symbol" => "FUEL", "name" => "Fuel", "description" => "Fuel"}],
          "imports" => [],
          "exchange" => [],
          "transactions" => [],
          "tradeGoods" => [
            %{
              "symbol" => "FUEL",
              "type" => "UNIT",
              "tradeVolume" => 100,
              "supply" => "MODERATE",
              "activity" => "WEAK",
              "purchasePrice" => 80,
              "sellPrice" => 40
            }
          ]
        })

      assert market.symbol == "X1-UX81-A1"
      assert [%Model.MarketTradeGood{supply: "MODERATE"}] = market.trade_goods
    end
  end

  describe "Waypoint" do
    test "decodes traits and modifiers" do
      waypoint =
        Model.Waypoint.from_json(%{
          "symbol" => "X1-UX81-A3",
          "type" => "ENGINEERED_ASTEROID",
          "systemSymbol" => "X1-UX81",
          "x" => 1,
          "y" => 2,
          "orbitals" => [],
          "traits" => [
            %{
              "symbol" => "ENGINEERED_ASTEROID",
              "name" => "Engineered Asteroid",
              "description" => "An asteroid."
            }
          ],
          "modifiers" => [],
          "isUnderConstruction" => false
        })

      assert waypoint.type == "ENGINEERED_ASTEROID"
      assert [%Model.WaypointTrait{symbol: "ENGINEERED_ASTEROID"}] = waypoint.traits
    end
  end

  describe "enum models" do
    test "expose their valid values" do
      assert "IN_TRANSIT" in Model.ShipNavStatus.values()
      assert "ENGINEERED_ASTEROID" in Model.WaypointType.values()
      assert "COMMAND" in Model.ShipRole.values()
    end
  end
end
