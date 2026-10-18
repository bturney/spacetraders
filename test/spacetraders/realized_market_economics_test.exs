defmodule SpaceTraders.RealizedMarketEconomicsTest do
  @moduledoc """
  Charge-at-purchase attribution of realized refuel charges (#689) in
  Earnings records (#766): each refuel's realized charge belongs in full to
  the root Intent that issued it, hence to that Intent's Fleet Commitment and
  its one Earnings record.
  """
  # Mission Control's current identity is a deployment-wide singleton.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.RealizedEconomicsFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Fleet, FleetAllocation, MissionControl}
  alias SpaceTraders.FleetAllocation.{PortfolioCandidate, StrategyDecisionEpisode}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Outcomes.Earnings

  @as_of ~U[2030-01-01 12:00:00Z]

  defp record!(portfolio) do
    FleetAllocation.record_trade_outcome(portfolio)
    Earnings.for_portfolio(portfolio.id)
  end

  describe "Net Earnings of a Completed Round Trip" do
    test "deducts the realized refuel charges its own root Intents issued" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 144)
      sell = trade_intent!(portfolio, commitment, "sell", 1_200, 40)
      refuel!(sell, 72)

      assert [record] = record!(portfolio)

      assert %{revenue: 1_200, goods_cost: 400, fuel_cost: 216, other_cost: 0, net_earnings: 584} =
               record

      assert record.fleet_commitment_id == commitment.id
    end

    test "a jump charge is another cost, not fuel" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 50, operation_id: "jump-ship")
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      assert [%{fuel_cost: 0, other_cost: 50, net_earnings: 750}] = record!(portfolio)
    end

    test "several purchases sold together are one Completed Round Trip" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 200, 20)
      refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "buy", 200, 20)
      trade_intent!(portfolio, commitment, "sell", 600, 20)
      assert [] = record!(portfolio)

      trade_intent!(portfolio, commitment, "sell", 600, 20)

      assert [%{units: 40, revenue: 1_200, goods_cost: 400, net_earnings: 656}] =
               record!(portfolio)
    end
  end

  describe "charge-at-purchase ownership" do
    test "a scouting refuel is coverage's observation-only spending, not a later trade's cost" do
      %{portfolio: portfolio, commitment: commitment, scout: scout} = market_fixture()
      scouting = intent!(portfolio, scout, "acquire_intelligence", ship: "SHIP-1")
      refuel!(scouting, 300)
      # The same Ship then trades with the fuel the scout bought still aboard.
      trade_intent!(portfolio, commitment, "buy", 400, 40)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      assert [%{net_earnings: 800, fuel_cost: 0}] = record!(portfolio)
    end

    test "fuel left aboard for the next trip neither moves nor prorates the original refuel" do
      %{portfolio: first, commitment: commitment} = fixture = market_fixture()
      buy = trade_intent!(first, commitment, "buy", 400, 40)
      refuel!(buy, 500)
      trade_intent!(first, commitment, "sell", 1_200, 40)
      assert [%{net_earnings: 300}] = record!(first)

      # A later Decision Episode trades on the same Ship with no refuel of its own.
      second = publish!(fixture.scope, fixture.generation, fixture.revision, ["SHIP-1"], 1)
      [next] = second.commitments
      trade_intent!(second, next, "buy", 100, 10)
      trade_intent!(second, next, "sell", 300, 10)

      assert [%{net_earnings: 200, fuel_cost: 0}] = record!(second)
    end

    test "inherited Cargo's new-Revision disposition sale keeps the original Commitment's costs" do
      %{portfolio: old, commitment: commitment} = fixture = market_fixture()
      buy = trade_intent!(old, commitment, "buy", 400, 40)
      refuel!(buy, 144)

      # The active Revision authorizes selling the inherited Cargo; the sale
      # and its refuel stay on the old Commitment's root Intent.
      revision = activate_revision!(fixture, 2)
      sell = trade_intent!(old, commitment, "sell", 1_200, 40)
      refuel!(sell, 72, strategy_revision_id: revision.id)
      new = publish!(fixture.scope, fixture.generation, revision, ["SHIP-1"], 1)

      assert [%{goods_cost: 400, revenue: 1_200, net_earnings: 584}] = record!(old)
      assert [] = record!(new)
    end
  end

  describe "each realized charge counts once" do
    test "repeated wakes and boot reconciliation write one record and classify the Episode" do
      %{scope: scope, portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)
      episode_id = portfolio.strategy_decision_episode_id

      assert :ok = FleetAllocation.reconcile_completed_outcomes()
      assert :ok = FleetAllocation.reconcile_completed_outcomes()
      assert [%{net_earnings: 656} = record] = record!(portfolio)

      assert %{classification: :realized, actual_outcomes: outcomes} =
               Repo.get!(StrategyDecisionEpisode, episode_id)

      assert outcomes["net_earnings"] == 656
      assert outcomes["earnings_record_ids"] == [record.id]

      assert Enum.any?(
               MissionControl.activity(scope),
               &(&1[:summary] ==
                   "Fleet decision realized 800 credits trade margin; 656 credits net earnings")
             )
    end

    test "an absent attempt and its authorized retry charge only the retry's receipt" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 144, state: "absent", realized: false)
      refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      assert [%{fuel_cost: 144, net_earnings: 656}] = record!(portfolio)
    end

    test "a refuel without a realized charge is no known amount and is left out" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 144, state: "ambiguous", realized: false)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      assert [%{fuel_cost: 0, net_earnings: 800}] = record!(portfolio)
    end
  end

  describe "a trip that never finishes" do
    test "a purchase not yet sold writes nothing and keeps its Episode evaluating" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      trade_intent!(portfolio, commitment, "buy", 400, 40)

      assert [] = record!(portfolio)

      assert %{classification: :still_evaluating} =
               Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id)
    end

    test "a retired Generation's sale is cut off by the reset and writes nothing" do
      %{portfolio: portfolio, commitment: commitment, generation: generation} = market_fixture()
      trade_intent!(portfolio, commitment, "buy", 400, 40)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      Generation
      |> Repo.get!(generation.id)
      |> Ecto.Changeset.change(retired_at: DateTime.utc_now())
      |> Repo.update!()

      assert :ok = FleetAllocation.reconcile_completed_outcomes()
      assert [] = Earnings.list(generation.id)
    end
  end

  describe "Mission Control realized economics" do
    test "reports Net Earnings from the Portfolio's Earnings records" do
      %{scope: scope, portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)
      record!(portfolio)

      realized = MissionControl.market_execution(scope).realized

      assert realized.completed_round_trips == 1
      assert realized.realized_trade_margin == 800
      assert realized.fuel_cost == 144
      assert realized.net_earnings == 656
    end

    test "reports nothing realized before a trip completes" do
      %{scope: scope, portfolio: portfolio, commitment: commitment} = market_fixture()
      trade_intent!(portfolio, commitment, "buy", 400, 40)

      realized = MissionControl.market_execution(scope).realized

      assert realized.completed_round_trips == 0
      assert realized.net_earnings == nil
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp activate_revision!(%{revision: previous, generation: generation}, number) do
    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: previous.fleet_strategy_id,
        number: number,
        document: previous.document,
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Strategy
    |> Repo.get!(previous.fleet_strategy_id)
    |> Ecto.Changeset.change(active_revision_id: revision.id, revision_number: number)
    |> Repo.update!()

    Generation
    |> Repo.get!(generation.id)
    |> Ecto.Changeset.change(fleet_strategy_revision_id: revision.id)
    |> Repo.update!()

    revision
  end

  defp market_fixture do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)
    {:ok, _ship} = Fleet.record_ship(agent, "SHIP-1", "SHIP_COMMAND_FRIGATE")
    {:ok, _ship} = Fleet.record_ship(agent, "SHIP-2", "SHIP_PROBE")

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => [%{"kind" => "credit_floor", "minimum" => 1_000}]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    strategy |> Ecto.Changeset.change(active_revision_id: revision.id) |> Repo.update!()

    generation =
      %Generation{}
      |> Generation.changeset(%{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{},
        strategy_capable_at: DateTime.utc_now()
      })
      |> SpaceTraders.AgentFixtures.generation_fixture()

    portfolio = publish!(scope, generation, revision, ["SHIP-1", "SHIP-2"])
    [commitment, scout] = Enum.sort_by(portfolio.commitments, & &1.candidate_id)

    %{
      scope: scope,
      agent: agent,
      generation: generation,
      revision: revision,
      portfolio: portfolio,
      commitment: commitment,
      scout: scout
    }
  end

  defp publish!(scope, generation, revision, ships, source_version \\ 0) do
    candidates =
      ships
      |> Enum.with_index()
      |> Enum.map(fn {ship, index} ->
        %PortfolioCandidate{
          id: "candidate-#{index}",
          strategy_revision_id: revision.id,
          objective_index: 0,
          claims: [ship],
          reservations: %{},
          pledges: [],
          dependencies: [%{evidence_id: "market:X1-A1", state: :satisfied}],
          expected_value: 100 - index,
          unwind_cost: 10
        }
      end)

    assert {:ok, selection} =
             FleetAllocation.select_portfolio(revision, candidates, %{
               as_of: @as_of,
               source_version: source_version,
               claims: ships,
               reservations: %{}
             })

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(scope, generation.id, selection, %{
               evidence_references: [%{"kind" => "market", "id" => "market:X1-A1"}],
               expectations: %{"credit_change" => 100},
               calibration_version: "market-v1"
             })

    portfolio
  end
end
