defmodule SpaceTraders.FleetPlanningTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Evidence.Demand
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetPlanning.CandidateContribution
  alias SpaceTraders.FleetStrategy.Revision

  @as_of ~U[2030-01-01 12:00:00Z]

  test "identical Strategy and evidence snapshots produce identical ordered contributions" do
    revision = revision()
    snapshot = evidence_snapshot()

    assert {:ok, first} = FleetPlanning.plan_market(revision, 0, snapshot)

    reordered = %{
      snapshot
      | markets:
          snapshot.markets
          |> Enum.reverse()
          |> Enum.map(fn market -> Map.update!(market, :trade_goods, &Enum.reverse/1) end)
    }

    assert {:ok, second} = FleetPlanning.plan_market(revision, 0, reordered)
    assert first == second

    assert [iron, copper] = first.candidate_contributions
    assert iron.expected_outcomes.maximum_credit_change == 200
    assert copper.expected_outcomes.maximum_credit_change == 96
    assert iron.alternatives == [alternative(copper)]
    assert copper.alternatives == [alternative(iron)]
  end

  test "contributions declare outcomes, uncertainty, needs, dependencies, validity, and alternatives" do
    assert {:ok, %{candidate_contributions: [candidate | _]}} =
             FleetPlanning.plan_market(revision(), 0, evidence_snapshot())

    assert %CandidateContribution{
             id: id,
             strategy_revision_id: 42,
             objective_index: 0,
             objective: %{"objective" => "Grow credits"},
             required_roles: [%{role: :market_trader, count: 1}],
             expected_outcomes: %{
               credit_change_per_unit: 10,
               maximum_credit_change: 200,
               maximum_units: 20
             },
             uncertainty: %{
               source_evidence_age_seconds: 60,
               destination_evidence_age_seconds: 120,
               source_market_signal: %{supply: "ABUNDANT", activity: "STRONG"},
               destination_market_signal: %{supply: "LIMITED", activity: "GROWING"}
             },
             required_capabilities: capabilities,
             required_resources: %{credits: 200, cargo_capacity: 20, ship_count: 1},
             dependencies: dependencies,
             validity: %{as_of: @as_of, expires_at: ~U[2030-01-01 12:03:00Z]},
             alternatives: [_]
           } = candidate

    assert is_binary(id)
    assert %{capability: :cargo_transport, minimum_capacity: 20} in capabilities
    assert %{capability: :market_access, waypoints: ["X1-A1", "X1-A2"]} in capabilities

    assert Enum.map(dependencies, & &1.subject) == [
             "market:X1:X1-A1",
             "market:X1:X1-A2"
           ]

    assert Enum.all?(dependencies, &is_binary(&1.evidence_id))
    assert Enum.all?(dependencies, &(&1.source == "get_market"))
  end

  test "stale and insufficient Market evidence produce Observation Demands and limitations" do
    snapshot = %{
      evidence_snapshot()
      | markets: [
          market("X1-A1", ~U[2030-01-01 11:00:00Z], [good("IRON", 10, 9, 20)]),
          %{subject: "market:X1:X1-A2", observed_at: @as_of, trade_goods: nil}
        ]
    }

    assert {:ok,
            %{
              candidate_contributions: [],
              observation_demands: demands,
              limitations: limitations
            }} = FleetPlanning.plan_market(revision(), 0, snapshot)

    assert Enum.map(demands, & &1.subject) == ["market:X1:X1-A1", "market:X1:X1-A2"]

    assert Enum.all?(demands, fn demand ->
             match?(
               %Demand{
                 owner: "fleet_planning",
                 required_facts: ["trade_goods"],
                 freshness_seconds: 300,
                 strategy_revision_id: 42,
                 strategic_priority: 0
               },
               demand
             )
           end)

    assert Enum.map(limitations, & &1.reason) == [
             :stale_market_evidence,
             :insufficient_market_evidence
           ]
  end

  test "planning returns proposals and demands without allocation or execution records" do
    assert {:ok, result} = FleetPlanning.plan_market(revision(), 0, evidence_snapshot())

    assert Map.keys(result) |> Enum.sort() ==
             [
               :candidate_contributions,
               :evidence_as_of,
               :limitations,
               :objective_index,
               :observation_demands,
               :strategy_revision_id
             ]

    forbidden = [:claim, :claims, :reservation, :reservations, :pledge, :pledges, :intent]

    assert Enum.all?(result.candidate_contributions, fn candidate ->
             Enum.all?(forbidden, &(not Map.has_key?(candidate, &1)))
           end)
  end

  test "Market planning explicitly limits objectives that credit growth cannot advance" do
    revision = %Revision{
      id: 43,
      document: %{
        "objectives" => [
          %{
            "objective" => "Chart useful waypoints",
            "kind" => "attain",
            "evaluation" => "Increase newly charted waypoint coverage",
            "scope" => "fleet_generation"
          }
        ]
      }
    }

    assert {:ok,
            %{
              candidate_contributions: [],
              observation_demands: [],
              limitations: [%{reason: :unsupported_market_objective}]
            }} = FleetPlanning.plan_market(revision, 0, evidence_snapshot())
  end

  test "future, malformed, and partially malformed Market evidence is insufficient" do
    snapshot = %{
      evidence_snapshot()
      | markets: [
          market("X1-A1", ~U[2030-01-01 12:01:00Z], [good("IRON", 10, 9, 20)]),
          market("X1-A2", @as_of, [good("IRON", 25, 20, 25), %{symbol: "COPPER"}])
        ]
    }

    assert {:ok, result} = FleetPlanning.plan_market(revision(), 0, snapshot)
    assert result.candidate_contributions == []

    assert Enum.map(result.limitations, & &1.reason) == [
             :inconsistent_market_evidence,
             :insufficient_market_evidence
           ]

    assert length(result.observation_demands) == 2
  end

  test "duplicate Market observations normalize deterministically to one newest observation" do
    older = market("X1-A1", ~U[2030-01-01 11:57:00Z], [good("IRON", 8, 7, 20)])
    newer = market("X1-A1", ~U[2030-01-01 11:59:00Z], [good("IRON", 10, 9, 20)])
    destination = market("X1-A2", ~U[2030-01-01 11:58:00Z], [good("IRON", 25, 20, 25)])

    first = %{evidence_snapshot() | markets: [older, destination, newer]}
    second = %{first | markets: Enum.reverse(first.markets)}

    assert FleetPlanning.plan_market(revision(), 0, first) ==
             FleetPlanning.plan_market(revision(), 0, second)
  end

  defp revision do
    %Revision{
      id: 42,
      document: %{
        "objectives" => [
          %{
            "objective" => "Grow credits",
            "kind" => "continuous",
            "evaluation" => "Maximize net credit growth over time",
            "scope" => "recurring"
          }
        ]
      }
    }
  end

  defp evidence_snapshot do
    %{
      as_of: @as_of,
      freshness_seconds: 300,
      demand_deadline_seconds: 60,
      agent_id: 7,
      markets: [
        market("X1-A1", ~U[2030-01-01 11:59:00Z], [
          good("IRON", 10, 9, 20, "ABUNDANT", "STRONG"),
          good("COPPER", 7, 6, 12, "MODERATE", "STATIC")
        ]),
        market("X1-A2", ~U[2030-01-01 11:58:00Z], [
          good("IRON", 25, 20, 25, "LIMITED", "GROWING"),
          good("COPPER", 15, 15, 20, "SCARCE", "RESTRICTED")
        ])
      ]
    }
  end

  defp market(waypoint, observed_at, trade_goods) do
    %{
      subject: "market:X1:#{waypoint}",
      observed_at: observed_at,
      evidence_id: "observation-#{waypoint}-#{DateTime.to_unix(observed_at)}",
      source: "get_market",
      trade_goods: trade_goods
    }
  end

  defp good(
         symbol,
         purchase_price,
         sell_price,
         trade_volume,
         supply \\ "MODERATE",
         activity \\ "STATIC"
       ) do
    %{
      symbol: symbol,
      purchase_price: purchase_price,
      sell_price: sell_price,
      trade_volume: trade_volume,
      supply: supply,
      activity: activity
    }
  end

  defp alternative(candidate) do
    Map.take(candidate, [
      :id,
      :trade_symbol,
      :source_waypoint,
      :destination_waypoint,
      :expected_outcomes
    ])
  end
end
