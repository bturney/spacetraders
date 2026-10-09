defmodule SpaceTraders.MarketInterpretationTest do
  @moduledoc """
  The shared read-only Operational Intelligence Market interpretation:
  `Intelligence.market_interpretation/3` at one fixed decision time.
  """

  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures
  import SpaceTraders.EvidenceFixtures

  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.Evidence
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence

  @t0 ~U[2030-01-01 12:00:00Z]

  setup do
    operator = operator_fixture()
    %{operator: operator, agent: agent_fixture(operator, %{headquarters: "X1-A1"})}
  end

  test "usable Listing keeps its exact namespaced source, original time and Generation", %{
    agent: agent
  } do
    {source, _} = retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)], observed_at: @t0)

    interpretation = Intelligence.market_interpretation(agent, "X1", at(60))

    assert interpretation.as_of == at(60)
    assert interpretation.freshness_seconds == 300

    assert [market] = interpretation.markets
    assert market.subject == "market:X1:X1-A1"
    assert market.state == :current
    assert market.evidence_id == "evidence-observation:#{source.id}"
    assert market.source == "get-market"
    assert DateTime.compare(market.observed_at, source.observed_at) == :eq
    assert market.fleet_generation_id == source.fleet_generation_id
    assert [%{"symbol" => "IRON_ORE", "purchase_price" => 10}] = market.trade_goods
  end

  test "a newer partial response keeps the older Listing at its own source time", %{
    agent: agent
  } do
    {source, _} = retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)], observed_at: @t0)

    # Composition-only read (no Ship present) and a Ship read that omitted
    # trade goods: neither refreshes nor erases the Listing.
    assert {:ok, _} =
             Intelligence.observe_market(
               agent,
               "X1",
               %{symbol: "X1-A1", exports: [], imports: [], exchange: []},
               source: "get_market",
               observed_at: at(30)
             )

    assert {:ok, _} =
             Intelligence.observe_market(
               agent,
               "X1",
               %{symbol: "X1-A1", exports: [], imports: [], exchange: [], trade_goods: nil},
               source: "get_market",
               observing_ship_symbol: "S-1",
               observed_at: at(40)
             )

    assert [market] = Intelligence.market_interpretation(agent, "X1", at(60)).markets
    assert market.state == :current
    assert DateTime.compare(market.observed_at, @t0) == :eq
    assert market.evidence_id == "evidence-observation:#{source.id}"
  end

  test "equal observation times select the later retained record deterministically", %{
    agent: agent
  } do
    retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)], observed_at: @t0)
    {later, _} = retained_market_listing(agent, "X1", "X1-A1", [good(11, 12)], observed_at: @t0)

    first = Intelligence.market_interpretation(agent, "X1", at(60))
    assert [%{evidence_id: evidence_id}] = first.markets
    assert evidence_id == "evidence-observation:#{later.id}"
    assert Intelligence.market_interpretation(agent, "X1", at(60)) == first
  end

  test "explicit invalidation blocks fallback from its invalidation time on", %{agent: agent} do
    now = DateTime.utc_now(:second)

    retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)],
      observed_at: DateTime.add(now, -20)
    )

    retained_market_listing(agent, "X1", "X1-A1", [good(11, 12)],
      observed_at: DateTime.add(now, -10)
    )

    assert {:ok, 2} = Intelligence.invalidate(agent, :market, "X1", "X1-A1", [:trade_goods])

    assert [%{state: :invalidated, evidence_id: nil, trade_goods: nil}] =
             Intelligence.market_interpretation(agent, "X1", DateTime.add(now, 2)).markets
  end

  test "an invalidation after the decision time does not change that decision", %{agent: agent} do
    decision_time = DateTime.add(DateTime.utc_now(:second), -60)

    retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)],
      observed_at: DateTime.add(decision_time, -10)
    )

    assert {:ok, _} = Intelligence.invalidate(agent, :market, "X1", "X1-A1", [:trade_goods])

    assert [%{state: :current}] =
             Intelligence.market_interpretation(agent, "X1", decision_time).markets
  end

  test "legacy Listings without a linked governed source are untraceable", %{agent: agent} do
    assert {:ok, _} =
             Intelligence.observe_market(
               agent,
               "X1",
               %{
                 symbol: "X1-A1",
                 exports: [],
                 imports: [],
                 exchange: [],
                 trade_goods: [good(10, 12)]
               },
               source: "get_market",
               observing_ship_symbol: "S-1",
               observed_at: @t0
             )

    assert [market] = Intelligence.market_interpretation(agent, "X1", at(60)).markets
    assert market.state == :untraceable
    assert market.evidence_id == nil
    # The retained Listing is preserved for inspection, never as support.
    assert [%{"symbol" => "IRON_ORE"}] = market.trade_goods
  end

  test "evidence after the decision time is invisible; only-future evidence is reported", %{
    agent: agent
  } do
    retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)], observed_at: @t0)
    retained_market_listing(agent, "X1", "X1-A1", [good(99, 12)], observed_at: at(120))
    retained_market_listing(agent, "X1", "X1-A2", [good(10, 12)], observed_at: at(120))

    assert [a1, a2] = Intelligence.market_interpretation(agent, "X1", at(60)).markets
    assert %{subject: "market:X1:X1-A1", state: :current} = a1
    assert [%{"purchase_price" => 10}] = a1.trade_goods
    assert %{subject: "market:X1:X1-A2", state: :future, evidence_id: nil, trade_goods: nil} = a2
  end

  test "evidence from another Fleet Generation cannot support the current one", %{
    operator: operator,
    agent: agent
  } do
    retired = generation(operator, agent, retired_at: DateTime.utc_now())

    retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)],
      observed_at: @t0,
      fleet_generation_id: retired.id
    )

    assert [%{state: :wrong_generation, fleet_generation_id: id}] =
             Intelligence.market_interpretation(agent, "X1", at(60)).markets

    assert id == retired.id
  end

  test "malformed and aged-out Listings are distinct dispositions", %{agent: agent} do
    retained_market_listing(agent, "X1", "X1-A1", [Map.delete(good(10, 12), :purchase_price)],
      observed_at: @t0
    )

    retained_market_listing(agent, "X1", "X1-A2", [good(10, 12)], observed_at: @t0)

    assert [%{state: :malformed}, %{state: :current}] =
             Intelligence.market_interpretation(agent, "X1", at(300)).markets

    assert [_, %{state: :stale}] =
             Intelligence.market_interpretation(agent, "X1", at(301)).markets
  end

  test "known Marketplaces include never-observed gaps without claiming System discovery", %{
    agent: agent
  } do
    observe_waypoint(agent, "X1-A1", ["MARKETPLACE"], @t0)
    observe_waypoint(agent, "X1-A2", ["MARKETPLACE"], @t0)
    observe_waypoint(agent, "X1-A3", ["SHIPYARD"], @t0)
    # Discovered only after the decision time.
    observe_waypoint(agent, "X1-A4", ["MARKETPLACE"], at(120))

    retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)], observed_at: @t0)

    interpretation = Intelligence.market_interpretation(agent, "X1", at(60))

    assert interpretation.baseline_subjects == ["market:X1:X1-A1", "market:X1:X1-A2"]

    assert interpretation.coverage_gaps == [
             %{subject: "market:X1:X1-A2", reason: :never_observed}
           ]

    assert interpretation.system_discovery == :unproven
  end

  test "the read boundary acquires and publishes nothing", %{agent: agent} do
    observe_waypoint(agent, "X1-A1", ["MARKETPLACE"], @t0)
    retained_market_listing(agent, "X1", "X1-A1", [good(10, 12)], observed_at: @t0)
    counts = fn -> {Repo.aggregate(Evidence.Observation, :count), demand_count()} end
    before = counts.()

    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("the read boundary sent a request") end)
    _ = Intelligence.market_interpretation(agent, "X1", at(60))

    assert counts.() == before
  end

  defp demand_count, do: Repo.aggregate(Evidence.ObservationDemand, :count)

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  defp good(purchase_price, sell_price) do
    %{
      symbol: "IRON_ORE",
      purchase_price: purchase_price,
      sell_price: sell_price,
      trade_volume: 20,
      supply: "MODERATE",
      activity: "STATIC"
    }
  end

  defp observe_waypoint(agent, symbol, traits, observed_at) do
    waypoint =
      Waypoint.from_json(%{
        "symbol" => symbol,
        "systemSymbol" => "X1",
        "type" => "PLANET",
        "x" => 0,
        "y" => 0,
        "traits" => Enum.map(traits, &%{"symbol" => &1})
      })

    assert {:ok, _} =
             Intelligence.observe_waypoint(agent, waypoint,
               source: "get_waypoint",
               observed_at: observed_at
             )
  end

  defp generation(operator, agent, attrs) do
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{"objectives" => []},
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.insert!(
      struct(
        %Generation{
          operator_id: operator.id,
          agent_id: agent.id,
          fleet_strategy_revision_id: revision.id,
          number: 1,
          symbol: agent.symbol,
          faction: agent.faction
        },
        attrs
      )
    )
  end
end
