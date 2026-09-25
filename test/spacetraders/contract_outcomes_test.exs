defmodule SpaceTraders.ContractOutcomesTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.Model.Contract
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetStrategy.Revision

  @now ~U[2030-01-01 12:00:00Z]

  test "authoritative progress shrinks the pledged delivery instead of repeating the original quota" do
    revision = %Revision{
      id: 42,
      document: %{"objectives" => [%{"objective" => "Fulfil contracts"}]}
    }

    ship = %{symbol: "SHIP-1", cargo: %{capacity: 20, units: 0, inventory: []}}

    for {fulfilled, expected} <- [{2, 8}, {7, 3}] do
      snapshot = %{
        as_of: @now,
        contracts: [contract(fulfilled)],
        ships: [ship],
        listings: [
          %{
            waypoint: "X1-A1",
            trade_symbol: "IRON_ORE",
            purchase_price: 10,
            trade_volume: 20,
            observed_at: @now,
            evidence_id: "listing-1"
          }
        ],
        credits: 1000
      }

      assert {:ok, %{candidate_contributions: [candidate]}} =
               FleetPlanning.plan_contracts(revision, 0, snapshot)

      assert {:ok, %{commitments: [commitment]}} =
               FleetAllocation.select_portfolio(revision, [candidate], %{
                 as_of: @now,
                 claims: [
                   %{
                     resource: "SHIP-1",
                     roles: [:contract_courier],
                     capabilities: %{cargo_transport: 20, resource_ship: "SHIP-1"}
                   }
                 ],
                 reservations: %{credits: 1000}
               })

      assert [%{outcome: {:contract, "ctr-1", "X1-A2", "IRON_ORE"}, amount: ^expected}] =
               commitment.pledges
    end
  end

  test "acceptance needs strategy authority, both deadlines, feasible duration, and safe consequences" do
    revision = %Revision{
      id: 42,
      document: %{
        "objectives" => [%{"objective" => "Fulfil contracts"}],
        "hard_constraints" => ["Keep at least 500 credits available", "Never scrap ships"]
      }
    }

    offered =
      Contract.from_json(%{
        "id" => "ctr-1",
        "accepted" => false,
        "fulfilled" => false,
        "deadlineToAccept" => "2030-01-01T13:00:00Z",
        "terms" => %{
          "deadline" => "2030-01-02T12:00:00Z",
          "deliver" => [],
          "payment" => %{"onAccepted" => 100, "onFulfilled" => 200}
        }
      })

    evidence = %{
      as_of: @now,
      credits: 600,
      worst_case_cost: 250,
      estimated_seconds: 3600,
      evidence_id: "offer-1"
    }

    assert {:error, :hard_constraint} =
             FleetContracts.admit_acceptance(revision, offered, evidence)

    assert {:ok, _} =
             FleetContracts.admit_acceptance(revision, offered, %{evidence | worst_case_cost: 100})

    assert {:error, :deadline} =
             FleetContracts.admit_acceptance(revision, offered, %{
               evidence
               | estimated_seconds: 90_000
             })

    assert {:error, :deadline} =
             FleetContracts.admit_acceptance(
               revision,
               %{offered | deadline_to_accept: nil},
               evidence
             )

    assert {:error, :strategy} =
             FleetContracts.admit_acceptance(
               %{
                 revision
                 | document: %{
                     "objectives" => [%{"objective" => "Chart waypoints"}],
                     "hard_constraints" => []
                   }
               },
               offered,
               evidence
             )
  end

  test "a non-Contract objective cannot sponsor a delivery Pledge" do
    revision = %Revision{
      id: 42,
      document: %{"objectives" => [%{"objective" => "Chart waypoints"}]}
    }

    assert {:ok, %{candidate_contributions: []}} =
             FleetPlanning.plan_contracts(revision, 0, %{
               as_of: @now,
               contracts: [contract(2)],
               ships: [%{symbol: "SHIP-1", cargo: %{capacity: 20, units: 0, inventory: []}}],
               listings: [
                 %{
                   waypoint: "X1-A1",
                   trade_symbol: "IRON_ORE",
                   purchase_price: 10,
                   trade_volume: 20,
                   observed_at: @now,
                   evidence_id: "listing-1"
                 }
               ],
               credits: 1000
             })
  end

  test "already-held Cargo can satisfy outstanding delivery without buying more" do
    revision = %Revision{
      id: 42,
      document: %{"objectives" => [%{"objective" => "Fulfil contracts"}]}
    }

    assert {:ok, %{candidate_contributions: [candidate]}} =
             FleetPlanning.plan_contracts(revision, 0, %{
               as_of: @now,
               contracts: [contract(7)],
               ships: [
                 %{
                   symbol: "SHIP-1",
                   cargo: %{capacity: 20, units: 3, inventory: [%{symbol: "IRON_ORE", units: 3}]}
                 }
               ],
               listings: [],
               credits: 0
             })

    assert candidate.required_resources.credits == 0
    assert candidate.contract.batch_units == 3
    assert candidate.contract.source == :cargo
  end

  test "acceptance estimates account for repeated Cargo batches and source capacity" do
    listing = %{
      waypoint: "X1-A1",
      trade_symbol: "IRON_ORE",
      purchase_price: 10,
      trade_volume: 2,
      observed_at: @now,
      evidence_id: "listing-1"
    }

    ship = %{cargo: %{capacity: 5}, nav: %{system_symbol: "X1", status: "DOCKED"}}

    assert {:ok, %{estimated_seconds: 108_000, worst_case_cost: 3850}} =
             FleetContracts.estimate_acceptance(contract(0), [listing], [ship], 10_000, @now)

    assert {:error, :contract_sourcing_unavailable} =
             FleetContracts.estimate_acceptance(contract(0), [listing], [], 10_000, @now)
  end

  defp contract(fulfilled) do
    Contract.from_json(%{
      "id" => "ctr-1",
      "accepted" => true,
      "fulfilled" => false,
      "deadlineToAccept" => "2029-12-31T00:00:00Z",
      "terms" => %{
        "deadline" => "2030-01-02T12:00:00Z",
        "deliver" => [
          %{
            "tradeSymbol" => "IRON_ORE",
            "destinationSymbol" => "X1-A2",
            "unitsRequired" => 10,
            "unitsFulfilled" => fulfilled
          }
        ],
        "payment" => %{"onAccepted" => 100, "onFulfilled" => 200}
      }
    })
  end
end
