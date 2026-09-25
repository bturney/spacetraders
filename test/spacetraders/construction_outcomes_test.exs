defmodule SpaceTraders.ConstructionOutcomesTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.Model.Construction
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetConstruction
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.Revision

  @now ~U[2030-01-01 12:00:00Z]
  @revision %Revision{
    id: 42,
    document: %{"objectives" => [%{"objective" => "Complete jump gate construction"}]}
  }
  @ship %{symbol: "SHIP-1", cargo: %{capacity: 20, units: 0, inventory: []}}
  @listing %{
    waypoint: "X1-A1",
    trade_symbol: "IRON",
    purchase_price: 10,
    trade_volume: 20,
    observed_at: @now,
    evidence_id: "listing-1"
  }

  test "Construction pledges and batches follow authoritative remaining material progress" do
    for {fulfilled, remaining} <- [{2, 8}, {7, 3}] do
      assert {:ok, %{candidate_contributions: [candidate]}} =
               FleetPlanning.plan_construction(@revision, 0, snapshot(fulfilled))

      assert candidate.kind == :construction_delivery
      assert candidate.expected_outcomes.units_remaining == remaining
      assert candidate.expected_outcomes.batch_units == remaining

      assert {:ok, %{commitments: [commitment]}} =
               FleetAllocation.select_portfolio(@revision, [candidate], availability())

      assert [%{outcome: {:construction, "X1-A2", "IRON"}, amount: ^remaining}] =
               commitment.pledges

      assert commitment.claims == ["SHIP-1"]
      assert commitment.reservations.credits == remaining * 10 + 750
    end
  end

  test "completed Construction never creates more supply, even when materials remain" do
    assert {:ok, %{candidate_contributions: []}} =
             FleetPlanning.plan_construction(@revision, 0, snapshot(2, true))
  end

  test "already held Cargo is delivered without a second purchase" do
    ship = %{@ship | cargo: %{capacity: 20, units: 3, inventory: [%{symbol: "IRON", units: 3}]}}

    assert {:ok, %{candidate_contributions: [candidate]}} =
             FleetPlanning.plan_construction(
               @revision,
               0,
               %{snapshot(7) | ships: [ship], listings: []}
             )

    assert candidate.construction.source == :cargo
    assert candidate.construction.batch_units == 3
    assert candidate.required_resources.credits == 750
  end

  test "a batch pledges only what its protected Ship and credits can supply" do
    ship = %{@ship | cargo: %{capacity: 5, units: 0, inventory: []}}

    assert {:ok, %{candidate_contributions: [candidate]}} =
             FleetPlanning.plan_construction(@revision, 0, %{snapshot(2) | ships: [ship]})

    assert candidate.expected_outcomes.units_remaining == 8
    assert candidate.expected_outcomes.batch_units == 5

    assert {:ok, %{commitments: [commitment]}} =
             FleetAllocation.select_portfolio(@revision, [candidate], %{
               availability()
               | claims: [
                   %{
                     resource: "SHIP-1",
                     roles: [:construction_courier],
                     capabilities: %{cargo_transport: 5, resource_ship: "SHIP-1"}
                   }
                 ]
             })

    assert [%{amount: 5}] = commitment.pledges
    assert commitment.reservations.credits == 800
  end

  test "unproven or stale Construction state cannot sponsor a Pledge" do
    assert {:ok,
            %{candidate_contributions: [], limitations: [%{reason: :stale_construction_evidence}]}} =
             FleetPlanning.plan_construction(
               @revision,
               0,
               %{
                 snapshot(2)
                 | constructions: [
                     %{hd(snapshot(2).constructions) | observed_at: ~U[2030-01-01 11:00:00Z]}
                   ]
               }
             )
  end

  test "upstream raw-material supply declares bounded market effect and cannot substitute for delivered parts" do
    upstream = %{
      part_symbol: "IRON",
      raw_symbol: "IRON_ORE",
      source_waypoint: "X1-A1",
      destination_waypoint: "X1-A3",
      expected_part_units: 2,
      expected_supply: "MODERATE",
      expected_purchase_price: 8,
      evidence_id: "hypothesis-1",
      observed_at: @now
    }

    snapshot = %{
      snapshot(7)
      | listings: [
          %{@listing | trade_symbol: "IRON_ORE", purchase_price: 3},
          Map.merge(@listing, %{
            waypoint: "X1-A3",
            evidence_id: "part-listing",
            trade_volume: 5,
            purchase_price: 10,
            supply: "SCARCE"
          })
        ]
    }

    snapshot = Map.put(snapshot, :upstream_opportunities, [upstream])

    assert {:ok, %{candidate_contributions: candidates}} =
             FleetPlanning.plan_construction(@revision, 0, snapshot)

    assert candidate = Enum.find(candidates, &(&1.kind == :construction_upstream))

    assert candidate.kind == :construction_upstream
    assert candidate.trade_symbol == "IRON_ORE"

    assert candidate.expected_outcomes.market_effect == %{
             part_symbol: "IRON",
             supply: "MODERATE",
             purchase_price: 8,
             expected_part_units: 2
           }

    assert candidate.required_resources.credits == 756
    assert candidate.uncertainty.market_effect == :hypothesis
    assert length(candidate.dependencies) == 4

    assert {:ok, %{commitments: [commitment]}} =
             FleetAllocation.select_portfolio(@revision, [candidate], %{
               availability()
               | claims: [
                   %{
                     resource: "SHIP-1",
                     roles: [:construction_supplier],
                     capabilities: %{cargo_transport: 20, resource_ship: "SHIP-1"}
                   }
                 ]
             })

    refute Enum.any?(commitment.pledges, &match?({:construction, _, _}, &1.outcome))
  end

  test "upstream supply can improve part availability without assuming a lower price" do
    listing =
      Map.merge(@listing, %{
        waypoint: "X1-A3",
        evidence_id: "part-listing",
        purchase_price: 10,
        supply: "SCARCE"
      })

    hypothesis = %{
      part_symbol: "IRON",
      raw_symbol: "IRON_ORE",
      source_waypoint: "X1-A1",
      destination_waypoint: "X1-A3",
      expected_part_units: 2,
      expected_supply: "MODERATE",
      expected_purchase_price: 10,
      evidence_id: "availability-hypothesis",
      observed_at: @now
    }

    evidence =
      Map.merge(snapshot(7), %{
        listings: [%{@listing | trade_symbol: "IRON_ORE", purchase_price: 3}, listing],
        upstream_opportunities: [hypothesis]
      })

    assert {:ok, %{candidate_contributions: candidates}} =
             FleetPlanning.plan_construction(@revision, 0, evidence)

    assert Enum.any?(candidates, &(&1.kind == :construction_upstream))
  end

  test "authoritative Listings and Construction decide whether an upstream effect is still useful" do
    hypothesis = %{
      part_symbol: "IRON",
      baseline_price: 10,
      expected_price: 8,
      baseline_supply: "SCARCE",
      expected_supply: "MODERATE"
    }

    project = hd(snapshot(7).constructions).construction

    assert {:realized, %{purchase_price: 8, remaining: 3}} =
             FleetConstruction.market_effect(hypothesis, project, %{
               symbol: "IRON",
               purchase_price: 8,
               supply: "MODERATE"
             })

    assert {:superseded, %{purchase_price: 10, remaining: 3}} =
             FleetConstruction.market_effect(hypothesis, project, %{
               symbol: "IRON",
               purchase_price: 10,
               supply: "SCARCE"
             })

    assert {:partially_realized, %{purchase_price: 9, remaining: 3}} =
             FleetConstruction.market_effect(hypothesis, project, %{
               symbol: "IRON",
               purchase_price: 9,
               supply: "SCARCE"
             })

    assert {:partially_realized, %{purchase_price: 8, remaining: 3}} =
             FleetConstruction.market_effect(hypothesis, project, %{
               symbol: "IRON",
               purchase_price: 8,
               supply: "SCARCE"
             })

    assert {:realized, %{purchase_price: 10, supply: "MODERATE"}} =
             FleetConstruction.market_effect(
               %{hypothesis | expected_price: 10},
               project,
               %{symbol: "IRON", purchase_price: 10, supply: "MODERATE"}
             )

    assert {:superseded, %{remaining: 0}} =
             FleetConstruction.market_effect(
               hypothesis,
               hd(snapshot(7, true).constructions).construction,
               %{symbol: "IRON", purchase_price: 8, supply: "MODERATE"}
             )
  end

  defp snapshot(fulfilled, complete \\ false) do
    %{
      as_of: @now,
      constructions: [
        %{
          system_symbol: "X1",
          evidence_id: "construction-1",
          observed_at: @now,
          construction:
            Construction.from_json(%{
              "symbol" => "X1-A2",
              "isComplete" => complete,
              "materials" => [
                %{"tradeSymbol" => "IRON", "required" => 10, "fulfilled" => fulfilled}
              ]
            })
        }
      ],
      ships: [@ship],
      listings: [@listing],
      credits: 1000
    }
  end

  defp availability do
    %{
      as_of: @now,
      claims: [
        %{
          resource: "SHIP-1",
          roles: [:construction_courier],
          capabilities: %{cargo_transport: 20, resource_ship: "SHIP-1"}
        }
      ],
      reservations: %{credits: 1000}
    }
  end
end
