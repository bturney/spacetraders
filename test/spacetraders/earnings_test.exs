defmodule SpaceTraders.EarningsTest do
  @moduledoc """
  Earnings seam (#766): a trade driven through Ship Execution against the
  stateful `RuntimeFleetGame` writes exactly one Earnings record when all its
  Cargo is gone, and the post-commit hook emits its metrics and Loki line once.
  """
  # The Outcomes worker, test clock and Logger level are application-wide.
  use SpaceTraders.DataCase, async: false

  import ExUnit.CaptureLog

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Fleet.{Intent, Intents, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning.CandidateContribution
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Outcomes.Earnings
  alias SpaceTraders.RuntimeFleetGame, as: Game
  alias SpaceTraders.TestClock

  @start ~U[2030-01-01 12:00:00.000000Z]

  setup do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    start_supervised!({TestClock, @start})
    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)
    previous_level = Logger.level()
    Logger.configure(level: :info)

    start_supervised!(
      PromEx.Storage.Peep.child_spec(
        __MODULE__.Reporter,
        SpaceTraders.PromEx.Outcome.event_metrics([]).metrics
      )
    )

    on_exit(fn ->
      Logger.configure(level: previous_level)

      if previous_clock,
        do: Application.put_env(:spacetraders, :clock, previous_clock),
        else: Application.delete_env(:spacetraders, :clock)

      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    end)

    game = start_supervised!({Game, []})
    Req.Test.stub(SpaceTraders.API, fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    {:ok, game: game}
  end

  test "buy, fly, refuel and sell writes one record with its fuel attributed", %{game: game} do
    %{agent: agent, ship: ship, portfolio: portfolio, commitment: commitment} = claimed_trade()

    log =
      capture_log([level: :info, metadata: [:ship_symbol, :route]], fn ->
        assert {:ok, %Intent{type: "buy", status: "completed"} = buy} =
                 Intents.request_commitment_round_trip(
                   agent,
                   commitment,
                   portfolio,
                   ship.symbol,
                   candidate(commitment)
                 )

        assert {:ok, %Intent{type: "sell"} = sell} =
                 SpaceTraders.FleetExecution.continue_after_intent(
                   agent,
                   commitment,
                   portfolio,
                   buy
                 )

        assert Earnings.list(portfolio.fleet_generation_id) == []
        TestClock.advance(120)
        _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, sell.id)
        assert Repo.get!(Intent, sell.id).status == "completed"

        # Repeated wakes and boot reconciliation never write a second record.
        _ = FleetAllocation.reconcile_completed_outcomes()
        _ = FleetAllocation.record_trade_outcome(portfolio)
        settle_outcomes()
      end)

    state = Game.snapshot(game)
    [refuel] = for %{transaction: %{"tradeSymbol" => "FUEL"} = t} <- state.requests, do: t
    assert refuel["totalPrice"] == 144

    assert [record] = Earnings.list(portfolio.fleet_generation_id)

    assert %{
             source: "trade",
             ship_symbol: "BASELINE-1",
             ship_type: "SHIP_COMMAND_FRIGATE",
             good: "IRON_ORE",
             source_waypoint: "X1-UX81-A1",
             destination_waypoint: "X1-UX81-A2",
             units: 40,
             jettisoned_units: 0,
             revenue: 1_200,
             goods_cost: 400,
             fuel_cost: 144,
             other_cost: 0,
             net_earnings: 656,
             expected_value: 600,
             expected_net_per_ship_hour: 10_500.0,
             price_age_seconds: 900
           } = record

    assert [%{"candidate_id" => "beaten-trade", "net_credits_per_ship_hour" => 900.0}] =
             record.alternatives

    # Ship-hours run from taking the work (the buy Intent) to the last sale.
    assert record.ship_seconds == DateTime.diff(record.finished_at, record.started_at)
    assert record.ship_seconds >= 0

    labels = ~s(good="IRON_ORE",price_age="10-30m",ship_type="SHIP_COMMAND_FRIGATE",source="trade")

    for {flow, credits} <- [
          {"revenue", 1_200},
          {"goods", 400},
          {"fuel", 144},
          {"expected", 600}
        ] do
      assert metric(~s(earnings_credits_total{flow="#{flow}",#{labels}})) == credits
    end

    # A zero flow adds nothing and makes no series.
    refute metrics() =~ ~s(earnings_credits_total{flow="other")

    assert metric(~s(earnings_trips_total{#{trip_labels("beat")}})) == 1
    assert metric(~s(earnings_ship_seconds_total{#{labels}})) == record.ship_seconds

    assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "Earnings record"))
    assert line =~ "ship_symbol=BASELINE-1"
    assert line =~ "route=X1-UX81-A1->X1-UX81-A2"
  end

  test "a jettison writes one record with the jettisoned cost and no revenue" do
    %{agent: agent, ship: ship, portfolio: portfolio, commitment: commitment} = claimed_trade()

    assert {:ok, %Intent{type: "buy", status: "completed"}} =
             Intents.request_commitment_round_trip(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               candidate(commitment)
             )

    # The Commitment's Ship jettisons the whole hold instead of selling it.
    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      type: "acquire_resources",
      target_waypoint: "X1-UX81-A1",
      status: "completed",
      parameters: %{"mode" => "jettison"},
      fleet_commitment_id: commitment.id,
      fleet_commitment_portfolio_id: portfolio.id,
      fleet_commitment_portfolio_version: portfolio.version,
      last_action_result: %{"kind" => "jettison", "trade_symbol" => "IRON_ORE", "units" => 40},
      finished_at: DateTime.utc_now(:second)
    })

    capture_log([level: :info], fn ->
      assert :ok = FleetAllocation.reconcile_completed_outcomes()
      settle_outcomes()
    end)

    assert [record] = Earnings.list(portfolio.fleet_generation_id)

    assert %{
             units: 40,
             jettisoned_units: 40,
             revenue: 0,
             goods_cost: 400,
             fuel_cost: 0,
             net_earnings: -400
           } = record

    assert metric(~s(earnings_trips_total{#{trip_labels("missed")}})) == 1
    refute metrics() =~ ~s(earnings_credits_total{flow="revenue")
  end

  test "a trip cut off before its Cargo is gone writes nothing" do
    %{agent: agent, ship: ship, portfolio: portfolio, commitment: commitment} = claimed_trade()

    assert {:ok, %Intent{status: "completed"}} =
             Intents.request_commitment_round_trip(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               candidate(commitment)
             )

    assert :ok = FleetAllocation.reconcile_completed_outcomes()
    _ = FleetAllocation.record_trade_outcome(portfolio)
    assert Earnings.list(portfolio.fleet_generation_id) == []
  end

  test "price age buckets: fresh under 10 min, 10-30, over 30, n/a when unknown" do
    assert Earnings.price_age_bucket(599) == "fresh"
    assert Earnings.price_age_bucket(600) == "10-30m"
    assert Earnings.price_age_bucket(1_800) == "10-30m"
    assert Earnings.price_age_bucket(1_801) == ">30m"
    assert Earnings.price_age_bucket(nil) == "n/a"
  end

  defp trip_labels(result),
    do:
      ~s(good="IRON_ORE",price_age="10-30m",result="#{result}",) <>
        ~s(ship_type="SHIP_COMMAND_FRIGATE",source="trade")

  defp settle_outcomes, do: :sys.get_state(SpaceTraders.Outcomes)

  defp metrics do
    SpaceTraders.Outcomes.metrics(SpaceTraders.PromEx)
    PromEx.Storage.Peep.scrape(__MODULE__.Reporter) |> IO.iodata_to_binary()
  end

  defp metric(series) do
    line = metrics() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, series <> " "))
    assert line, "missing series #{series}\n#{metrics()}"
    {value, ""} = line |> String.replace_prefix(series <> " ", "") |> Float.parse()
    value
  end

  # The selected trade: 40 IRON_ORE from A1 (10) to A2 (30), estimated at 600
  # after fuel, chosen on Listings 15 minutes old over one slower trade.
  defp candidate(commitment) do
    %CandidateContribution{
      id: commitment.candidate_id,
      strategy_revision_id: 0,
      objective_index: 0,
      objective: %{"kind" => "continuous", "objective" => "Grow credits"},
      kind: :market_trade,
      trade_symbol: "IRON_ORE",
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-A2",
      expected_outcomes: %{
        credit_change_per_unit: 20,
        maximum_credit_change: 800,
        maximum_units: 40,
        net_credits_per_ship_hour: 10_500.0,
        trade_estimate: %{net_credits: 600, fuel_credits: 200, seconds: 240}
      },
      uncertainty: %{source_evidence_age_seconds: 900, destination_evidence_age_seconds: 300},
      required_roles: [%{role: :market_trader, count: 1}],
      required_capabilities: [%{capability: :cargo_transport, minimum_capacity: 40}],
      required_resources: %{credits: 400, cargo_capacity: 40, ship_count: 1},
      dependencies: [],
      validity: %{
        as_of: @start,
        conditions: [%{fact: :source_purchase_price, operator: :equals, value: 10}]
      },
      alternatives: []
    }
  end

  defp claimed_trade do
    operator = Repo.insert!(%Operator{email: "earnings-#{System.unique_integer()}@example.com"})

    agent =
      SpaceTraders.AgentFixtures.established_agent_fixture(%AgentRecord{
        symbol: "BASELINE",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "BASELINE_AGENT_TOKEN",
        operator_id: operator.id
      })

    ship =
      Repo.insert!(%Ship{
        symbol: "BASELINE-1",
        ship_type: "SHIP_COMMAND_FRIGATE",
        agent_id: agent.id
      })

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{"objectives" => [%{"objective" => "Grow credits"}]},
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{}
      })

    selected = %PortfolioCandidate{
      id: "selected-trade",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 800,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [selected], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: [ship.symbol],
        reservations: %{}
      })

    beaten = %{
      candidate_id: "beaten-trade",
      trade_symbol: "COPPER_ORE",
      net_credits_per_ship_hour: 900.0
    }

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{
          domain: :market,
          selected_trades: [
            %{
              candidate_id: "selected-trade",
              net_credits_per_ship_hour: 10_500.0,
              alternatives: [beaten]
            }
          ]
        },
        calibration_version: "earnings-v1"
      })

    [commitment] = portfolio.commitments
    %{agent: agent, ship: ship, portfolio: portfolio, commitment: commitment}
  end
end
