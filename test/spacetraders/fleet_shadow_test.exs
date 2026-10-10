defmodule SpaceTraders.FleetShadowTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures
  import SpaceTraders.EvidenceFixtures

  alias SpaceTraders.Test.CapacityDispositions
  alias SpaceTraders.Clock
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Intelligence
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
             compare_market(agent, revision(), availability(), capacity(), as_of: @as_of)

    assert [%{candidate_id: _candidate_id, claims: ["SHIP-1"]}] = comparison.proposed_choices
    assert Repo.aggregate(Commitment, :count) == 0
  end

  test "shadow honors explicit Listing invalidation instead of raw Evidence rows" do
    agent = agent_fixture(operator_fixture())
    now = SpaceTraders.Clock.utc_now()
    insert_market_observation(agent, "X1-A1", 10, now)
    insert_market_observation(agent, "X1-A2", 25, now)

    # A refuel receipt contradicts only transaction history; the trade stays.
    assert {:ok, _} =
             Intelligence.invalidate(agent, :market, "X1", "X1-A1", [:transactions],
               cause: :refuel_receipt
             )

    assert {:ok, %{proposed_choices: [_]}} =
             compare_market(agent, revision(), availability(now), capacity())

    assert {:ok, _} = Intelligence.invalidate(agent, :market, "X1", "X1-A1", [:trade_goods])
    later = DateTime.add(SpaceTraders.Clock.utc_now(), 1, :second)

    assert {:ok, %{proposed_choices: [], planning: [planning]}} =
             compare_market(agent, revision(), availability(later), capacity(), as_of: later)

    assert %{reason: :invalidated_market_evidence} =
             Enum.find(planning.limitations, &(&1.subject == "market:X1:X1-A1"))
  end

  test "a governed Evidence row without retained Listing lineage supports nothing" do
    agent = agent_fixture(operator_fixture())

    for {waypoint, price} <- [{"X1-A1", 10}, {"X1-A2", 25}] do
      Repo.insert!(%Observation{
        agent_id: agent.id,
        subject: "market:X1:#{waypoint}",
        operation_id: "get-market",
        dependency_keys: ["market:X1:#{waypoint}"],
        facts: %{
          "trade_goods" => [
            Map.new(market_good(price), fn {key, value} -> {to_string(key), value} end)
          ]
        },
        response_fingerprint: "market-#{waypoint}",
        observed_at: @as_of_usec
      })
    end

    assert {:ok, %{proposed_choices: []}} =
             compare_market(agent, revision(), availability(), capacity(), as_of: @as_of)
  end

  test "plans at the application clock, not the capacity disposition's governor timestamp" do
    # The governor stamps advice with its own clock. Evidence the runtime
    # observed after that advice must still bind the planning decision.
    agent = agent_fixture(operator_fixture())
    now = SpaceTraders.Clock.utc_now()
    insert_market_observation(agent, "X1-A1", 10, now)
    insert_market_observation(agent, "X1-A2", 25, now)
    governor_advice = CapacityDispositions.proceed(DateTime.add(now, -5, :second))

    assert {:ok, comparison} =
             compare_market(agent, revision(), availability(now), governor_advice, as_of: now)

    assert [%{candidate_id: _candidate_id, claims: ["SHIP-1"]}] = comparison.proposed_choices
  end

  test "shadow-evaluates a draft document with an explicit draft identity and publishes nothing" do
    agent = agent_fixture(operator_fixture())
    insert_market_observation(agent, "X1-A1", 10)
    insert_market_observation(agent, "X1-A2", 25)

    draft = %{
      "objectives" => [
        %{
          "objective" => "Grow credits",
          "kind" => "continuous",
          "evaluation" => "Maximize net credit growth over time",
          "scope" => "recurring"
        }
      ]
    }

    assert {:ok, comparison} =
             compare_draft_market(agent, draft, availability(), capacity(), as_of: @as_of)

    assert [%{candidate_id: _candidate_id, claims: ["SHIP-1"]}] = comparison.proposed_choices
    assert [%{candidate_contributions: [candidate | _]}] = comparison.planning
    assert candidate.strategy_revision_id == {:draft, agent.id}
    assert Repo.aggregate(Commitment, :count) == 0
  end

  defp compare_market(agent, revision, availability, capacity, opts \\ []) do
    agent
    |> FleetShadow.market_input("X1", Keyword.get_lazy(opts, :as_of, &Clock.utc_now/0))
    |> FleetShadow.compare(revision, availability, capacity, opts)
  end

  defp compare_draft_market(agent, document, availability, capacity, opts) do
    compare_market(
      agent,
      %Revision{id: {:draft, agent.id}, document: document},
      availability,
      capacity,
      opts
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

  defp availability(as_of \\ @as_of) do
    %{
      as_of: as_of,
      claims: [
        %{
          resource: "SHIP-1",
          roles: [:market_trader],
          capabilities: %{cargo_transport: 20, market_access: ["X1-A1", "X1-A2"]}
        }
      ],
      reservations: %{credits: 250}
    }
  end

  defp capacity(status \\ :proceed) do
    case status do
      :proceed -> CapacityDispositions.proceed(@as_of)
      :defer -> CapacityDispositions.defer(@as_of)
    end
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
    retained_market_listing(agent, "X1", waypoint, [market_good(purchase_price)],
      observed_at: observed_at
    )
  end

  defp market_good(purchase_price) do
    %{
      symbol: "IRON",
      purchase_price: purchase_price,
      sell_price: purchase_price - 1,
      trade_volume: 20,
      supply: "MODERATE",
      activity: "STATIC"
    }
  end
end
