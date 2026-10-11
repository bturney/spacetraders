defmodule SpaceTraders.RealizedMarketEconomicsTest do
  @moduledoc """
  Charge-at-purchase attribution of realized refuel charges (#689): each
  refuel's realized charge belongs in full to the root Intent that issued it,
  hence to that Intent's Fleet Commitment and original Decision Episode. Read
  through the receipt-backed Trade Progress projection.
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

  @as_of ~U[2030-01-01 12:00:00Z]

  describe "Net Earnings of a Completed Round Trip" do
    test "deducts the realized refuel charges its own root Intents issued" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel = refuel!(buy, 144)
      sell = trade_intent!(portfolio, commitment, "sell", 1_200, 40)
      sell_refuel = refuel!(sell, 72)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert progress.trade_margin == 800
      assert progress.net_earnings == 800 - 144 - 72
      assert [trip] = progress.round_trips
      assert trip.supporting_cost == 216
      assert trip.net_earnings == 584

      assert [
               %{
                 mutation_attempt_id: refuel_id,
                 operation_id: "refuel-ship",
                 intent_id: buy_id,
                 commitment_id: commitment_id,
                 realized_charge: 144,
                 observation_only: false
               },
               %{mutation_attempt_id: sell_refuel_id, intent_id: sell_id, realized_charge: 72}
             ] = progress.supporting_charges

      assert {refuel_id, sell_refuel_id} == {refuel.id, sell_refuel.id}
      assert {buy_id, sell_id, commitment_id} == {buy.id, sell.id, commitment.id}
      refute Enum.any?(progress.unknown, &(&1.item == "net_earnings"))
    end
  end

  describe "charge-at-purchase ownership" do
    test "a scouting refuel is coverage's observation-only spending, not a later trade's cost" do
      %{portfolio: portfolio, commitment: commitment, scout: scout} = market_fixture()
      scouting = intent!(portfolio, scout, "acquire_intelligence", ship: "SHIP-1")
      scouting_refuel = refuel!(scouting, 300)
      # The same Ship then trades with the fuel the scout bought still aboard.
      trade_intent!(portfolio, commitment, "buy", 400, 40)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert [%{net_earnings: 800, supporting_cost: 0}] = progress.round_trips
      assert progress.net_earnings == 800
      assert progress.observation_only_spending == 300
      assert progress.episode_cash_flow == 1_200 - 400 - 300

      assert [%{mutation_attempt_id: id, commitment_id: scout_id, observation_only: true}] =
               progress.supporting_charges

      assert {id, scout_id} == {scouting_refuel.id, scout.id}
    end

    test "fuel left aboard for the next trip neither moves nor prorates the original refuel" do
      %{portfolio: first, commitment: commitment} = fixture = market_fixture()
      buy = trade_intent!(first, commitment, "buy", 400, 40)
      refuel!(buy, 500)
      trade_intent!(first, commitment, "sell", 1_200, 40)

      # A later Decision Episode trades on the same Ship with no refuel of its own.
      second = publish!(fixture.scope, fixture.generation, fixture.revision, ["SHIP-1"], 1)
      [next] = second.commitments
      trade_intent!(second, next, "buy", 100, 10)
      trade_intent!(second, next, "sell", 300, 10)

      first_progress = FleetAllocation.trade_progress(first.strategy_decision_episode_id)
      second_progress = FleetAllocation.trade_progress(second.strategy_decision_episode_id)

      assert first_progress.net_earnings == 800 - 500
      assert second_progress.net_earnings == 200
      assert second_progress.supporting_charges == []
    end
  end

  describe "each realized charge counts once" do
    test "repeated reads and boot reconciliation neither duplicate nor move a charge" do
      %{scope: scope, portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)
      episode_id = portfolio.strategy_decision_episode_id

      first = FleetAllocation.trade_progress(episode_id)
      assert :ok = FleetAllocation.reconcile_completed_outcomes()
      assert :ok = FleetAllocation.reconcile_completed_outcomes()

      assert FleetAllocation.trade_progress(episode_id) == first
      assert first.net_earnings == 656

      assert %{classification: :realized, actual_outcomes: outcomes} =
               Repo.get!(StrategyDecisionEpisode, episode_id)

      assert outcomes["net_earnings"] == 656
      assert [%{"realized_charge" => 144}] = outcomes["supporting_charges"]

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
      retry = refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert [%{mutation_attempt_id: id}] = progress.supporting_charges
      assert id == retry.id
      assert progress.net_earnings == 656
    end

    test "inherited Cargo's new-Revision disposition sale keeps the original Episode's costs" do
      %{portfolio: old, commitment: commitment} = fixture = market_fixture()
      buy = trade_intent!(old, commitment, "buy", 400, 40)
      refuel!(buy, 144)

      # The active Revision authorizes selling the inherited Cargo; the sale
      # and its refuel stay on the old Commitment's root Intent.
      revision = activate_revision!(fixture, 2)
      sell = trade_intent!(old, commitment, "sell", 1_200, 40)
      refuel!(sell, 72, strategy_revision_id: revision.id)
      new = publish!(fixture.scope, fixture.generation, revision, ["SHIP-1"], 1)

      old_progress = FleetAllocation.trade_progress(old.strategy_decision_episode_id)
      new_progress = FleetAllocation.trade_progress(new.strategy_decision_episode_id)

      assert [%{purchase_cost: 400, sale_revenue: 1_200, net_earnings: 584}] =
               old_progress.round_trips

      assert old_progress.net_earnings == 584
      assert new_progress.supporting_charges == []
      assert new_progress.receipts == []
      assert new_progress.episode_cash_flow == 0
    end
  end

  describe "missing evidence stays unknown, never zero" do
    for {label, opts} <- [
          {"a succeeded refuel without a realized receipt", [realized: false]},
          {"a sent-or-unknown refuel", [state: "sent_or_unknown", realized: false]},
          {"a bounded-unknown refuel", [state: "bounded_unknown", realized: false]},
          {"an ambiguous refuel", [state: "ambiguous", realized: false]},
          {"a refuel whose provenance names only an inferred Intent",
           [inferred: true, realized: true]},
          {"a historical refuel of unknown effect",
           [operation_id: "historical-ship-action", realized: false]}
        ] do
      @opts opts
      test "#{label} leaves Net Earnings and Episode Cash Flow unknown" do
        %{portfolio: portfolio, commitment: commitment} = market_fixture()
        buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
        attempt = refuel!(buy, 144, unknown_opts(buy, @opts))
        trade_intent!(portfolio, commitment, "sell", 1_200, 40)

        progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

        assert progress.trade_margin == 800
        assert progress.net_earnings == "unknown"
        assert progress.episode_cash_flow == "unknown"
        assert [%{net_earnings: "unknown", supporting_cost: "unknown"}] = progress.round_trips

        assert Enum.any?(
                 progress.unknown,
                 &(&1.item == "supporting_charge" and &1.mutation_attempt_id == attempt.id)
               )

        assert Enum.any?(progress.unknown, &(&1.item == "net_earnings"))
      end
    end

    test "a trip whose trade attempts carry no root-Intent provenance is untraceable" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      trade_intent!(portfolio, commitment, "buy", 400, 40, attempt: false)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40, attempt: false)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert progress.trade_margin == 800
      assert progress.net_earnings == "unknown"
      assert [%{supporting_cost: "unknown"}] = progress.round_trips
      assert Enum.any?(progress.unknown, &(&1.item == "supporting_charge"))
    end

    for state <- ~w(prepared not_sent rejected absent) do
      @state state
      test "a #{state} refuel charged nothing, so a traceable trip stays exact" do
        %{portfolio: portfolio, commitment: commitment} = market_fixture()
        buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
        refuel!(buy, 144, state: @state, realized: false)
        trade_intent!(portfolio, commitment, "sell", 1_200, 40)

        progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

        assert progress.net_earnings == 800
        assert progress.supporting_charges == []
      end
    end

    test "an unproven multi-purchase trip keeps Net Earnings unknown despite known fuel" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 200, 20)
      refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "buy", 200, 20)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert progress.trade_margin == "unknown"
      assert progress.net_earnings == "unknown"
      assert progress.episode_cash_flow == 1_200 - 400 - 144
    end

    test "an unresolved purchase leaves Episode Cash Flow unknown" do
      %{portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", nil, 40, status: "active")
      refuel!(buy, 0, operation_id: "purchase-cargo", state: "sent_or_unknown", realized: false)

      progress = FleetAllocation.trade_progress(portfolio.strategy_decision_episode_id)

      assert progress.episode_cash_flow == "unknown"
      assert progress.supporting_charges == []
    end
  end

  describe "Mission Control realized economics" do
    test "reports Net Earnings with references beside observation-only spending" do
      %{scope: scope, portfolio: portfolio, commitment: commitment, scout: scout} =
        market_fixture()

      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel = refuel!(buy, 144)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)
      scouting = intent!(portfolio, scout, "acquire_intelligence", ship: "SHIP-2")
      refuel!(scouting, 300)

      realized = MissionControl.market_execution(scope).realized

      assert realized.realized_trade_margin == 800
      assert realized.net_earnings == 656
      assert realized.supporting_cost == 144
      assert realized.observation_only_spending == 300
      assert realized.episode_cash_flow == 1_200 - 400 - 144 - 300
      assert realized.generation_observation_only_spending == 300

      assert [%{mutation_attempt_id: id, intent_id: buy_id, commitment_id: commitment_id}] =
               Enum.reject(realized.supporting_charges, & &1.observation_only)

      assert {id, buy_id, commitment_id} == {refuel.id, buy.id, commitment.id}
    end

    test "observation-only spending stays visible once no Portfolio is current" do
      %{scope: scope, generation: generation, portfolio: portfolio, scout: scout} =
        market_fixture()

      scouting = intent!(portfolio, scout, "acquire_intelligence", ship: "SHIP-2")
      refuel!(scouting, 300)
      assert {:ok, _} = FleetAllocation.unwind_current_portfolio(scope, generation.id)

      realized = MissionControl.market_execution(scope).realized

      assert realized.net_earnings == nil
      assert realized.generation_observation_only_spending == 300
    end

    test "an untraceable refuel leaves Net Earnings unknown, not zero" do
      %{scope: scope, portfolio: portfolio, commitment: commitment} = market_fixture()
      buy = trade_intent!(portfolio, commitment, "buy", 400, 40)
      refuel!(buy, 144, realized: false)
      trade_intent!(portfolio, commitment, "sell", 1_200, 40)

      realized = MissionControl.market_execution(scope).realized

      assert realized.realized_trade_margin == 800
      assert realized.net_earnings == nil
      assert realized.supporting_cost == nil
      assert Enum.any?(realized.unknown, &(&1.item == "net_earnings"))
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp unknown_opts(intent, opts) do
    {inferred, opts} = Keyword.pop(opts, :inferred, false)

    opts =
      if Keyword.get(opts, :operation_id) == "historical-ship-action",
        do:
          Keyword.put(opts, :prepared_evidence, %{
            "selected_action" => %{"kind" => "refuel", "waypoint" => "X1-A-buy"}
          }),
        else: opts

    if inferred,
      do: Keyword.put(opts, :provenance, %{"intent_id" => intent.id, "ship_symbol" => "SHIP-1"}),
      else: opts
  end

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
      |> Repo.insert!()

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
