defmodule SpaceTraders.FleetShadowTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.API.ShadowAdmission.Snapshot, as: CapacitySnapshot
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetShadow
  alias SpaceTraders.FleetStrategy.Revision

  @as_of ~U[2030-01-01 12:00:00Z]
  @as_of_usec ~U[2030-01-01 12:00:00.000000Z]

  test "compares proposed commitments with alternatives, expectations, outcomes, and reasons" do
    assert {:ok, comparison} =
             FleetShadow.compare(snapshot(), revision(), availability(), capacity(),
               actual_outcomes: %{credit_change: 75},
               episode: %StrategyDecisionEpisode{
                 id: 12,
                 evidence_references: [%{"id" => "market:X1:X1-A1"}],
                 alternatives: [%{"candidate_id" => "prior"}],
                 expectations: %{"credit_change" => 100},
                 classification: :partially_realized,
                 calibration_version: "market-v1"
               }
             )

    assert [%{candidate_id: _candidate_id, claims: ["SHIP-1"]}] = comparison.proposed_choices

    assert Enum.all?(comparison.alternatives, fn alternative ->
             :claim_conflict in alternative.reasons
           end)

    assert comparison.expectations == %{expected_value: 280, commitment_count: 1}
    assert comparison.actual_outcomes == %{credit_change: 75}
    assert Enum.all?(comparison.decisive_reasons, &is_binary(&1.reason))
    assert comparison.strategy_decision_episode.expectations == %{"credit_change" => 100}
  end

  test "consumes persisted governed Market observations without gameplay dispatch" do
    agent = agent_fixture(operator_fixture())
    insert_market_observation(agent, "X1-A1", 10)
    insert_market_observation(agent, "X1-A2", 25)
    insert_market_observation(agent, "X1-A1", 30, DateTime.add(@as_of_usec, 1, :second))

    assert {:ok, comparison} =
             FleetShadow.compare_market(agent, revision(), "X1", availability(), capacity())

    assert [%{candidate_id: _candidate_id, claims: ["SHIP-1"]}] = comparison.proposed_choices
    assert Repo.aggregate(Commitment, :count) == 0
  end

  test "changed Listings and API pressure deterministically trigger shadow replanning" do
    assert {:ok, previous} =
             FleetShadow.compare(snapshot(), revision(), availability(), capacity())

    changed_listings = put_in(snapshot().markets, [market("X1-A1", 8), market("X1-A2", 25)])

    assert {:ok, %{replan_trigger: :listings_changed} = first} =
             FleetShadow.replan(
               previous,
               changed_listings,
               revision(),
               availability(),
               capacity()
             )

    assert {:ok, %{replan_trigger: :api_pressure_changed} = second} =
             FleetShadow.replan(
               first,
               changed_listings,
               revision(),
               availability(),
               capacity(:sustained)
             )

    assert {:ok, %{replan_trigger: :unchanged}} =
             FleetShadow.replan(
               second,
               changed_listings,
               revision(),
               availability(),
               capacity(:sustained)
             )
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

  defp snapshot do
    %{
      as_of: @as_of,
      system_symbol: "X1",
      freshness_seconds: 300,
      markets: [market("X1-A1", 10), market("X1-A2", 25), market("X1-A3", 14)]
    }
  end

  defp availability do
    %{
      as_of: @as_of,
      claims: [
        %{
          resource: "SHIP-1",
          roles: [:market_trader],
          capabilities: %{cargo_transport: 20, market_access: ["X1-A1", "X1-A2"]}
        }
      ],
      reservations: %{credits: 200}
    }
  end

  defp capacity(backpressure \\ :none) do
    %CapacitySnapshot{
      observed_at: @as_of,
      available_slots: 1,
      evidence_fingerprint: "governed-evidence",
      next_outage_probe_at: nil,
      backpressure: backpressure
    }
  end

  defp market(waypoint, purchase_price) do
    %{
      subject: "market:X1:#{waypoint}",
      observed_at: @as_of,
      evidence_id: "observation-#{waypoint}-#{purchase_price}",
      source: "get-market",
      trade_goods: [
        %{
          symbol: "IRON",
          purchase_price: purchase_price,
          sell_price: purchase_price - 1,
          trade_volume: 20,
          supply: "MODERATE",
          activity: "STATIC"
        }
      ]
    }
  end

  defp insert_market_observation(agent, waypoint, purchase_price, observed_at \\ @as_of_usec) do
    Repo.insert!(%Observation{
      agent_id: agent.id,
      subject: "market:X1:#{waypoint}",
      operation_id: "get-market",
      dependency_keys: ["market:X1:#{waypoint}"],
      facts: %{"trade_goods" => [market_good(purchase_price)]},
      response_fingerprint: "market-#{waypoint}-#{purchase_price}",
      observed_at: observed_at
    })
  end

  defp market_good(purchase_price) do
    %{
      "symbol" => "IRON",
      "purchase_price" => purchase_price,
      "sell_price" => purchase_price - 1,
      "trade_volume" => 20,
      "supply" => "MODERATE",
      "activity" => "STATIC"
    }
  end
end
