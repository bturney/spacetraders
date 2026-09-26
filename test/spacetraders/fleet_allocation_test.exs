defmodule SpaceTraders.FleetAllocationTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetPlanning.CandidateContribution
  alias SpaceTraders.FleetStrategy.Revision

  @as_of ~U[2030-01-01 12:00:00Z]

  test "protects higher Strategic Priority before committing remaining resources" do
    revision = revision(2)

    lower = candidate("lower", 1, claims: ["SHIP-1"], reservations: %{credits: 80})
    higher = candidate("higher", 0, claims: ["SHIP-1"], reservations: %{credits: 60})

    assert {:ok, portfolio} =
             FleetAllocation.select_portfolio(
               revision,
               [lower, higher],
               %{as_of: @as_of, claims: ["SHIP-1"], reservations: %{credits: 100}}
             )

    assert [%{candidate_id: "higher", claims: ["SHIP-1"], reservations: %{credits: 60}}] =
             portfolio.commitments

    assert [%{candidate_id: "lower", reasons: [:claim_conflict, :insufficient_reservation]}] =
             portfolio.rejected
  end

  test "accepts only Pledges backed by protections or acquisition dependencies" do
    revision = revision(1)

    protected =
      candidate("protected", 0,
        claims: ["SHIP-1"],
        reservations: %{credits: 20},
        dependencies: [%{id: "market-evidence", state: :satisfied}],
        pledges: [
          %{outcome: :delivery, amount: 10, backing: {:claim, "SHIP-1"}},
          %{outcome: :purchase, amount: 20, backing: {:reservation, :credits}}
        ]
      )

    unbacked =
      candidate("unbacked", 0,
        reservations: %{credits: 20},
        pledges: [
          %{outcome: :purchase_one, amount: 15, backing: {:reservation, :credits}},
          %{outcome: :purchase_two, amount: 15, backing: {:reservation, :credits}}
        ]
      )

    assert {:ok, portfolio} =
             FleetAllocation.select_portfolio(
               revision,
               [unbacked, protected],
               %{as_of: @as_of, claims: ["SHIP-1"], reservations: %{credits: 40}}
             )

    assert [%{candidate_id: "protected"}] = portfolio.commitments
    assert [%{candidate_id: "unbacked", reasons: [:unbacked_pledge]}] = portfolio.rejected

    acquirer = candidate("acquirer", 0, [])

    dependent =
      candidate("dependent", 0,
        expected_value: 100,
        dependencies: [
          %{id: "acquire-iron", kind: :acquisition, candidate_id: "acquirer", amount: 5}
        ],
        pledges: [
          %{outcome: :supply, amount: 5, backing: {:dependency, "acquire-iron"}}
        ]
      )

    assert {:ok, acquisition} =
             FleetAllocation.select_portfolio(
               revision,
               [dependent, acquirer],
               %{as_of: @as_of, claims: [], reservations: %{}}
             )

    assert Enum.map(acquisition.commitments, & &1.candidate_id) == ["acquirer", "dependent"]

    overpledged = %{
      dependent
      | pledges: [
          %{outcome: :supply, amount: 6, backing: {:dependency, "acquire-iron"}}
        ]
    }

    assert {:ok, %{rejected: [%{candidate_id: "dependent", reasons: reasons}]}} =
             FleetAllocation.select_portfolio(
               revision,
               [overpledged, acquirer],
               %{as_of: @as_of, claims: [], reservations: %{}}
             )

    assert :unbacked_pledge in reasons
  end

  test "transfer-dependent haulers require a selected producer and share remaining outcome" do
    revision = revision(1)

    producer =
      candidate("producer", 0,
        claims: ["PRODUCER"],
        pledges: [
          %{
            outcome: {:cargo_transfer, "PRODUCER", "HAULER", "IRON"},
            amount: 4,
            backing: {:claim, "PRODUCER"}
          }
        ],
        expected_value: 2
      )

    hauler =
      candidate("hauler", 0,
        claims: ["HAULER"],
        dependencies: [%{id: "cargo", kind: :acquisition, candidate_id: "producer", amount: 4}],
        pledges: [
          %{outcome: {:construction, "X1-A2", "IRON"}, amount: 4, backing: {:dependency, "cargo"}}
        ],
        expected_value: 3
      )

    available = %{
      as_of: @as_of,
      claims: ["PRODUCER", "HAULER"],
      reservations: %{},
      outcome_remaining: %{{:construction, "X1-A2", "IRON"} => 4}
    }

    assert {:ok, selected} =
             FleetAllocation.select_portfolio(revision, [hauler, producer], available)

    assert Enum.map(selected.commitments, & &1.candidate_id) == ["producer", "hauler"]

    assert {:ok, rejected} =
             FleetAllocation.select_portfolio(revision, [hauler], available)

    assert rejected.commitments == []
    assert [%{reasons: [:unsatisfied_dependency]}] = rejected.rejected

    second = %{hauler | id: "hauler-2", claims: ["SHIP-3"]}

    assert {:ok, capped} =
             FleetAllocation.select_portfolio(
               revision,
               [producer, hauler, second],
               %{available | claims: ["PRODUCER", "HAULER", "SHIP-3"]}
             )

    assert Enum.sum_by(capped.commitments, fn commitment ->
             commitment.pledges
             |> Enum.filter(&(&1.outcome == {:construction, "X1-A2", "IRON"}))
             |> Enum.sum_by(& &1.amount)
           end) == 4
  end

  test "stable tie-breaking and unwind cost retain explainable alternatives" do
    revision = revision(1)
    available = %{as_of: @as_of, claims: ["SHIP-1"], reservations: %{}}
    retained = candidate("retained", 0, claims: ["SHIP-1"], expected_value: 100, unwind_cost: 10)
    slight_gain = candidate("slight-gain", 0, claims: ["SHIP-1"], expected_value: 108)

    assert {:ok, initial} = FleetAllocation.select_portfolio(revision, [retained], available)

    assert {:ok, first} =
             FleetAllocation.select_portfolio(
               revision,
               [slight_gain, retained],
               available,
               initial.commitments
             )

    assert {:ok, reordered} =
             FleetAllocation.select_portfolio(
               revision,
               [retained, slight_gain],
               available,
               initial.commitments
             )

    assert first == reordered
    assert [%{candidate_id: "retained"}] = first.commitments

    assert [rejection] = first.rejected
    assert rejection.candidate_id == "slight-gain"
    assert rejection.alternative == slight_gain
    assert rejection.decisive_reason =~ "unwind cost"

    threshold_gain = candidate("a-threshold-gain", 0, claims: ["SHIP-1"], expected_value: 110)

    assert {:ok, threshold} =
             FleetAllocation.select_portfolio(
               revision,
               [threshold_gain, retained],
               available,
               initial.commitments
             )

    assert [%{candidate_id: "retained"}] = threshold.commitments

    clear_gain = candidate("clear-gain", 0, claims: ["SHIP-1"], expected_value: 111)

    assert {:ok, switched} =
             FleetAllocation.select_portfolio(
               revision,
               [retained, clear_gain],
               available,
               initial.commitments
             )

    assert [%{candidate_id: "clear-gain"}] = switched.commitments
  end

  test "rejects malformed or ambiguously identified allocation inputs" do
    revision = revision(1)
    valid = candidate("same-id", 0, [])
    negative = candidate("negative", 0, reservations: %{credits: -1})
    unknown_priority = candidate("unknown-priority", 1, [])

    assert {:error, :invalid_allocation_input} =
             FleetAllocation.select_portfolio(
               revision,
               [valid, valid],
               %{as_of: @as_of, claims: [], reservations: %{}}
             )

    assert {:error, :invalid_allocation_input} =
             FleetAllocation.select_portfolio(
               revision,
               [negative, unknown_priority],
               %{as_of: @as_of, claims: [], reservations: %{credits: 10}}
             )
  end

  test "turns an evidence-bound Candidate Contribution into a Fleet Commitment" do
    contribution = %CandidateContribution{
      id: "candidate-1",
      strategy_revision_id: 42,
      objective_index: 0,
      objective: %{"objective" => "Grow credits"},
      kind: :market_trade,
      trade_symbol: "IRON",
      source_waypoint: "X1-A1",
      destination_waypoint: "X1-A2",
      expected_outcomes: %{maximum_credit_change: 100},
      uncertainty: %{},
      required_roles: [%{role: :market_trader, count: 1}],
      required_capabilities: [
        %{capability: :cargo_transport, minimum_capacity: 10},
        %{capability: :market_access, waypoints: ["X1-A1", "X1-A2"]}
      ],
      required_resources: %{credits: 50, cargo_capacity: 10, ship_count: 1},
      dependencies: [
        %{valid_until: ~U[2030-01-01 12:05:00Z], evidence_id: "market-evidence"}
      ],
      validity: %{as_of: ~U[2030-01-01 12:00:00Z], expires_at: ~U[2030-01-01 12:05:00Z]},
      alternatives: []
    }

    availability = %{
      as_of: @as_of,
      claims: [
        %{
          resource: "SHIP-1",
          roles: [:market_trader],
          capabilities: %{cargo_transport: 10, market_access: ["X1-A1", "X1-A2"]}
        }
      ],
      reservations: %{credits: 50}
    }

    assert {:ok, %{commitments: [commitment]}} =
             FleetAllocation.select_portfolio(revision(1), [contribution], availability)

    assert commitment.candidate_id == contribution.id
    assert commitment.claims == ["SHIP-1"]
    assert commitment.reservations == %{credits: 50}

    assert commitment.pledges == [
             %{
               outcome: {:strategic_objective, 0},
               amount: 100,
               backing: {:claim, "SHIP-1"}
             }
           ]

    stale = %{
      contribution
      | id: "stale-candidate",
        dependencies: [
          %{valid_until: ~U[2030-01-01 11:59:00Z], evidence_id: "stale-market-evidence"}
        ]
    }

    assert {:ok,
            %{
              commitments: [],
              rejected: [
                %{candidate_id: "stale-candidate", reasons: [:unsatisfied_dependency]}
              ]
            }} = FleetAllocation.select_portfolio(revision(1), [stale], availability)

    wrong_revision = %{contribution | strategy_revision_id: 41}

    assert {:error, :invalid_allocation_input} =
             FleetAllocation.select_portfolio(revision(1), [wrong_revision], availability)

    lower_priority =
      candidate("lower-current", 1,
        claims: ["SHIP-1"],
        expected_value: 1,
        unwind_cost: 50
      )

    two_ship_availability = %{
      availability
      | claims: [
          hd(availability.claims),
          %{hd(availability.claims) | resource: "SHIP-2"}
        ]
    }

    assert {:ok, current} =
             FleetAllocation.select_portfolio(
               revision(2),
               [lower_priority],
               two_ship_availability
             )

    assert {:ok, %{commitments: [%{claims: ["SHIP-2"]}]}} =
             FleetAllocation.select_portfolio(
               revision(2),
               [contribution],
               two_ship_availability,
               current.commitments
             )
  end

  defp revision(objective_count) do
    %Revision{
      id: 42,
      document: %{
        "objectives" =>
          for index <- 0..(objective_count - 1) do
            %{"objective" => "Objective #{index}"}
          end
      }
    }
  end

  defp candidate(id, objective_index, overrides) do
    defaults = %{
      id: id,
      strategy_revision_id: 42,
      objective_index: objective_index,
      claims: [],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 0,
      unwind_cost: 0
    }

    struct!(PortfolioCandidate, Map.merge(defaults, Map.new(overrides)))
  end
end
