defmodule SpaceTraders.FleetIntentsTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Fleet.{Intent, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning.CandidateContribution
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  test "a Market round trip persists and reloads JSON-safe market_trade data" do
    {agent, ship, portfolio, commitment} = claimed_ship("INTENTS-MARKET")
    ship_path = "/v2/my/ships/#{ship.symbol}"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"
    purchase_path = ship_path <> "/purchase"
    sell_path = ship_path <> "/sell"
    {:ok, purchased} = Elixir.Agent.start_link(fn -> false end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          cargo =
            if Elixir.Agent.get(purchased, & &1) do
              %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              }
            else
              %{"capacity" => 40, "units" => 0, "inventory" => []}
            end

          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav_body("DOCKED"), "cargo" => cargo})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

        {"GET", ^market_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "purchasePrice" => 10,
                  "sellPrice" => 20,
                  "tradeVolume" => 5
                }
              ]
            }
          })

        {"POST", ^purchase_path} ->
          Elixir.Agent.update(purchased, fn _ -> true end)
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "PURCHASE", 10, 50, 5)})

        {"POST", ^sell_path} ->
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "SELL", 20, 150, 0)})

        request ->
          flunk("unexpected request: #{inspect(request)}")
      end
    end)

    candidate = %CandidateContribution{
      id: "market-candidate-#{System.unique_integer([:positive])}",
      strategy_revision_id: portfolio.fleet_strategy_revision_id,
      objective_index: 0,
      objective: %{"kind" => "continuous", "objective" => "Grow credits"},
      kind: :market_trade,
      trade_symbol: "IRON_ORE",
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-A1",
      expected_outcomes: %{
        credit_change_per_unit: 10,
        maximum_credit_change: 50,
        maximum_units: 5
      },
      uncertainty: %{unaccounted_costs: [:fuel, :travel_time]},
      required_roles: [%{role: :market_trader, count: 1}],
      required_capabilities: [
        %{capability: :cargo_transport, minimum_capacity: 5},
        %{capability: :market_access, waypoints: ["X1-UX81-A1"]}
      ],
      required_resources: %{credits: 50, cargo_capacity: 5, ship_count: 1},
      dependencies: [],
      validity: %{as_of: ~U[2030-01-01 12:00:00Z], conditions: []},
      alternatives: []
    }

    assert {:ok, %Intent{type: "buy", status: "completed"} = buy} =
             Intents.request_commitment_round_trip(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               candidate
             )

    assert %{"market_trade" => market_trade, "trade_symbol" => "IRON_ORE", "units" => 5} =
             Repo.get!(Intent, buy.id).parameters

    refute is_struct(market_trade)
    assert market_trade["kind"] == "market_trade"
    assert market_trade["trade_symbol"] == "IRON_ORE"
    assert market_trade["source_waypoint"] == "X1-UX81-A1"
    assert market_trade["destination_waypoint"] == "X1-UX81-A1"
    assert get_in(market_trade, ["expected_outcomes", "maximum_units"]) == 5
    assert market_trade["validity"]["as_of"] == "2030-01-01T12:00:00Z"

    assert {:ok, %Intent{type: "sell", status: "completed"} = sell} =
             FleetExecution.continue_after_intent(
               agent,
               commitment,
               portfolio,
               Repo.get!(Intent, buy.id)
             )

    assert %{
             "trade_symbol" => "IRON_ORE",
             "units" => 5,
             "market_trade" => sell_market_trade
           } = Repo.get!(Intent, sell.id).parameters

    assert sell_market_trade["destination_waypoint"] == "X1-UX81-A1"
    assert get_in(sell_market_trade, ["expected_outcomes", "maximum_units"]) == 5

    [purchase, sale] = SpaceTraders.MutationAttempts.list_for_agent(agent)
    assert Enum.map([purchase, sale], & &1.operation_id) == ["purchase-cargo", "sell-cargo"]

    for {attempt, intent} <- [{purchase, buy}, {sale, sell}] do
      assert attempt.state == "succeeded"
      assert attempt.provenance["intent_id"] == intent.id
      assert attempt.provenance["commitment_id"] == commitment.id
      assert attempt.provenance["decision_episode_id"] == portfolio.strategy_decision_episode_id
      assert attempt.fleet_generation_id == portfolio.fleet_generation_id
      assert attempt.strategy_revision_id == portfolio.fleet_strategy_revision_id
      assert attempt.prepared_evidence["selected_action"]["selection_id"]
      assert [%{classification: "succeeded"}] = attempt.outcomes
    end

    assert buy.last_action_result["transaction"]["total_price"] == 50
    assert sell.last_action_result["transaction"]["total_price"] == 100
  end

  defp trade_response(agent, ship, kind, price, credits, cargo_units) do
    %{
      "agent" => %{"symbol" => agent.symbol, "credits" => credits},
      "cargo" => %{
        "capacity" => 40,
        "units" => cargo_units,
        "inventory" =>
          if(cargo_units == 0,
            do: [],
            else: [%{"symbol" => "IRON_ORE", "units" => cargo_units}]
          )
      },
      "transaction" => %{
        "type" => kind,
        "shipSymbol" => ship.symbol,
        "tradeSymbol" => "IRON_ORE",
        "waypointSymbol" => "X1-UX81-A1",
        "units" => 5,
        "pricePerUnit" => price,
        "totalPrice" => price * 5
      }
    }
  end

  defp claimed_ship(symbol) do
    operator = Repo.insert!(%Operator{email: "#{symbol}@example.com"})

    agent =
      Repo.insert!(%AgentRecord{
        symbol: symbol,
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN",
        operator_id: operator.id
      })

    ship =
      Repo.insert!(%Ship{symbol: "#{symbol}-SHIP", ship_type: "SHIP_PROBE", agent_id: agent.id})

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
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{}
      })

    candidate = %PortfolioCandidate{
      id: "fleet-intents-#{symbol}",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: [ship.symbol],
        reservations: %{}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(operator),
        generation.id,
        selection,
        %{evidence_references: [], expectations: %{}, calibration_version: "fleet-intents-v1"}
      )

    [commitment] = portfolio.commitments
    {agent, ship, portfolio, commitment}
  end
end
