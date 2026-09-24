defmodule SpaceTraders.OwnedIntentRecoveryTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.API.Model
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.Fleet.{Activity, Intent, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  test "Intent lifecycle transitions keep their correlation identifier" do
    {_agent, ship, _portfolio, _commitment} = claimed_ship("OWNED-TELEMETRY")

    intent =
      Repo.insert!(%Intent{ship_id: ship.id, caller: "commitment", target_waypoint: "X1-UX81-A2"})

    handler = "owned-transition-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :intent, :transition],
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, updated} = Intents.transition_intent(intent, status: "waiting")
    assert_receive {:telemetry, [:spacetraders, :intent, :transition], %{count: 1}, metadata}
    assert metadata.intent_id == intent.id
    assert metadata.ship_id == ship.id
    assert metadata.from_state == "active"
    assert metadata.to_state == "waiting"

    assert {:ok, _} = Intents.transition_intent(updated, recovery_attempts: 1)
    refute_receive {:telemetry, [:spacetraders, :intent, :transition], _, _}
  end

  test "current and historical Intents remain scoped to their Agent" do
    {first, ship, _portfolio, _commitment} = claimed_ship("OWNED-HISTORY")
    {other, other_ship, _other_portfolio, _other_commitment} = claimed_ship("OTHER-HISTORY")

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      target_waypoint: "X1-UX81-A1",
      status: "waiting"
    })

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      target_waypoint: "X1-UX81-A2",
      status: "completed"
    })

    Repo.insert!(%Intent{
      ship_id: other_ship.id,
      caller: "commitment",
      target_waypoint: "X1-UX81-A3",
      status: "active"
    })

    assert [%Intent{status: "waiting"}] = Intents.current(first)
    assert [%Intent{status: "completed"}] = Intents.history(first)
    assert [%Intent{status: "active"}] = Intents.current(other)
  end

  test "boot recovers a commitment wait without reading a Job or replaying navigation" do
    {agent, ship, portfolio, commitment} = claimed_ship("OWNED-BOOT")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"}
      })

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("navigate-ship"),
        "/my/ships/#{ship.symbol}/navigate",
        agent_id: agent.id,
        json: %{"waypointSymbol" => "X1-UX81-A2"}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    test_pid = self()
    Req.Test.set_req_test_to_shared(SpaceTraders.API)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/my/ships/#{ship.symbol}"}
      send(test_pid, :observed)

      Req.Test.json(conn, %{
        "data" =>
          ship_body(ship.symbol, %{
            "nav" =>
              nav_body("IN_TRANSIT",
                arrival: future_iso(),
                destination: "X1-UX81-A2"
              )
          })
      })
    end)

    handler = "owned-boot-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :repo, :query],
        &__MODULE__.handle_event/4,
        self()
      )

    assert [ship.symbol] == Intents.rearm_owned_intents_on_boot()
    :ok = :telemetry.detach(handler)
    assert_no_job_query()

    assert_receive :observed
    assert MutationAttempts.get!(attempt.id).state == "accepted"
    assert %Intent{status: "waiting"} = Repo.get!(Intent, intent.id)

    assert [%Event{payload: %{"intent_id" => intent_id}}] =
             Timeline.pending_events(:ship, ship.symbol)

    assert intent_id == intent.id
  end

  test "a commitment-owned recovery retries after an authoritative read failure" do
    {agent, ship, _portfolio, commitment} = claimed_ship("OWNED-RETRY")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"}
      })

    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/my/ships/#{ship.symbol}"}

      if Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{"code" => 4001, "message" => "temporary recovery failure"}
        })
      else
        Req.Test.json(conn, %{
          "data" =>
            ship_body(ship.symbol, %{
              "nav" => nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
            })
        })
      end
    end)

    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert Elixir.Agent.get(calls, & &1) == 2
    assert %Intent{status: "waiting"} = Repo.get!(Intent, intent.id)

    assert [
             %Activity{
               kind: "owned_intent_recovery",
               message: "Authoritative recovery read failed; retrying"
             }
           ] =
             Enum.filter(Repo.all(Activity), &(&1.kind == "owned_intent_recovery"))
  end

  test "a late commitment wake cannot resume legacy Job execution" do
    {agent, ship, _portfolio, _commitment} = claimed_ship("OWNED-LATE")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "completed"
      })

    handler = "owned-late-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :repo, :query],
        &__MODULE__.handle_event/4,
        self()
      )

    assert :ok =
             Intents.reconcile(
               agent.id,
               ship.symbol,
               ship_body(ship.symbol) |> Model.Ship.from_json(),
               :arrival,
               intent.id
             )

    :ok = :telemetry.detach(handler)
    assert_no_job_query()
  end

  test "a claimed Ship completes a governed buy and sell without a Job" do
    {agent, ship, portfolio, commitment} = claimed_ship("OWNED-TRADE")
    {:ok, purchased} = Elixir.Agent.start_link(fn -> false end)
    ship_path = "/v2/my/ships/#{ship.symbol}"
    purchase_path = ship_path <> "/purchase"
    sell_path = ship_path <> "/sell"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          cargo =
            if Elixir.Agent.get(purchased, & &1),
              do: %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              },
              else: %{"capacity" => 40, "units" => 0, "inventory" => []}

          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav_body("DOCKED"), "cargo" => cargo})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
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

    candidate = %{
      trade_symbol: "IRON_ORE",
      units: 5,
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-A1",
      purchase_price: 10,
      sell_price: 20
    }

    assert {:ok, %Intent{type: "buy", status: "completed"} = buy} =
             Intents.request_commitment_round_trip(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               candidate
             )

    assert {:ok, %Intent{type: "sell", status: "completed"} = sell} =
             SpaceTraders.FleetExecution.continue_after_intent(agent, commitment, portfolio, buy)

    assert sell.fleet_commitment_id == commitment.id
    assert [%Intent{type: "sell"}, %Intent{type: "buy"}] = Intents.history(agent)
  end

  test "boot and arrival continue an owned trade exactly once" do
    {agent, ship, portfolio, commitment} = claimed_ship("OWNED-RESTART")
    {:ok, calls} = Elixir.Agent.start_link(fn -> %{buy: 0, sell: 0, arrived: false} end)
    ship_path = "/v2/my/ships/#{ship.symbol}"
    purchase_path = ship_path <> "/purchase"
    sell_path = ship_path <> "/sell"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          state = Elixir.Agent.get(calls, & &1)

          nav =
            if state.arrived,
              do: nav_body("DOCKED"),
              else: nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A1")

          cargo =
            if state.buy > 0,
              do: %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              },
              else: %{"capacity" => 40, "units" => 0, "inventory" => []}

          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav, "cargo" => cargo})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
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
          Elixir.Agent.update(calls, &Map.update!(&1, :buy, fn count -> count + 1 end))
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "PURCHASE", 10, 50, 5)})

        {"POST", ^sell_path} ->
          Elixir.Agent.update(calls, &Map.update!(&1, :sell, fn count -> count + 1 end))
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "SELL", 20, 150, 0)})

        request ->
          flunk("unexpected request: #{inspect(request)}")
      end
    end)

    candidate = %{
      trade_symbol: "IRON_ORE",
      units: 5,
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-A1",
      purchase_price: 10,
      sell_price: 20
    }

    buy =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        type: "buy",
        target_waypoint: "X1-UX81-A1",
        status: "waiting",
        parameters: %{
          "trade_symbol" => "IRON_ORE",
          "units" => 5,
          "max_price" => 10,
          "reserve_credits" => 0,
          "market_trade" => candidate
        },
        in_flight_action: %{
          "kind" => "navigate",
          "waypoint" => "X1-UX81-A1",
          "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A1"}
        }
      })

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("navigate-ship"),
        "/my/ships/#{ship.symbol}/navigate",
        agent_id: agent.id,
        json: %{"waypointSymbol" => "X1-UX81-A1"}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    ShipServer.stop(ship.symbol)

    assert :ok = Intents.rearm_on_boot()
    assert MutationAttempts.get!(attempt.id).state == "accepted"
    assert Repo.get!(Intent, buy.id).status == "waiting"
    assert Elixir.Agent.get(calls, &{&1.buy, &1.sell}) == {0, 0}

    Elixir.Agent.update(calls, &%{&1 | arrived: true})

    live_ship =
      ship_body(ship.symbol, %{
        "nav" => nav_body("DOCKED"),
        "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
      })
      |> Model.Ship.from_json()

    assert {:ok, %Intent{type: "sell", status: "completed"}} =
             Intents.reconcile(agent.id, ship.symbol, live_ship, :arrival, buy.id)

    assert %Intent{status: "completed"} = Repo.get!(Intent, buy.id)
    assert [%Intent{type: "sell", status: "completed"} = sell | _] = Intents.history(agent)
    assert Elixir.Agent.get(calls, &{&1.buy, &1.sell}) == {1, 1}

    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, buy.id)
    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, buy.id)
    assert Repo.get!(Intent, sell.id).status == "completed"
    assert Elixir.Agent.get(calls, &{&1.buy, &1.sell}) == {1, 1}
  end

  defp trade_response(agent, ship, kind, price, credits, cargo_units) do
    %{
      "agent" => %{"symbol" => agent.symbol, "credits" => credits},
      "cargo" => %{
        "capacity" => 40,
        "units" => cargo_units,
        "inventory" =>
          if(cargo_units == 0, do: [], else: [%{"symbol" => "IRON_ORE", "units" => cargo_units}])
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

  def handle_event(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  defp assert_no_job_query do
    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:telemetry, [:spacetraders, :repo, :query], _, %{query: query}} ->
               String.contains?(query, ~s("jobs"))

             _ ->
               false
           end)
  end

  defp future_iso, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

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
        document: %{"objectives" => [%{"objective" => "Exercise Ship Execution"}]},
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
      id: "ship-execution-#{symbol}",
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
        %{evidence_references: [], expectations: %{}, calibration_version: "owned-recovery-v1"}
      )

    [commitment] = portfolio.commitments
    {agent, ship, portfolio, commitment}
  end
end
