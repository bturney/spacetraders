defmodule SpaceTraders.RefuelJumpSpendingTest do
  @moduledoc """
  Refuel and jump/antimatter spending through the production root Intent
  lifecycle (`Intents.execute_action/4`) and the shared recorded-action
  admission: explicit bounded quantity, quote before preparation, Fleet-wide
  Reservations, durable Bounded Unknown exposure, and Attention (a blocked
  Intent) instead of any spend below the credit floor.
  """
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.{Intent, Intents}
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.TestClock

  @price 72
  # ceil(72 * 1 unit * 125 / 100): one Market unit at the calibrated margin.
  @exposure 90

  setup do
    start_supervised!({TestClock, DateTime.utc_now()})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    {:ok, posts: start_supervised!({Elixir.Agent, fn -> [] end})}
  end

  for kind <- ["refuel", "jump"] do
    @kind kind
    @good if(kind == "jump", do: "ANTIMATTER", else: "FUEL")
    @operation if(kind == "jump", do: "jump-ship", else: "refuel-ship")

    test "#{kind} above the floor retains its quote and bound, then sends once", %{posts: posts} do
      {agent, [intent | _]} = claimed([0])
      stub_game(agent, posts, @good, 1_300)

      Intents.execute_action(agent, intent, live_ship(agent), action(@kind))

      assert [%{} = attempt] =
               agent
               |> MutationAttempts.list_for_agent()
               |> Enum.filter(&(&1.operation_id == @operation))

      assert attempt.state in ["succeeded", "accepted", "sent_or_unknown", "ambiguous"]
      assert attempt.sent_or_unknown_at

      assert %{
               "unit_price" => @price,
               "units" => _,
               "trade_symbol" => @good,
               "calibration_version" => "market-purchase-v1-25pct",
               "worst_case_exposure" => @exposure,
               "quote_observation_id" => quote_id
             } = attempt.prepared_evidence["spending"]

      assert {:ok, _} = Evidence.retained_binding(agent, quote_id)
      assert [{@operation, body}] = Elixir.Agent.get(posts, & &1)

      if @kind == "refuel",
        do: assert(body == %{"units" => 50}),
        else: assert(body == %{"waypointSymbol" => "X1-UX81-A2"})
    end

    test "#{kind} below the floor never spends and raises Attention", %{posts: posts} do
      {agent, [intent | _]} = claimed([0])
      stub_game(agent, posts, @good, 900)

      Intents.execute_action(agent, intent, live_ship(agent), action(@kind))

      assert Elixir.Agent.get(posts, & &1) == []

      assert %Intent{status: "blocked", blocker: blocker} = Repo.get!(Intent, intent.id)
      assert blocker.resolver == "operator"
      assert blocker.reason == "credit_spending_paused"

      assert [%{state: "not_sent", sent_or_unknown_at: nil}] =
               agent
               |> MutationAttempts.list_for_agent()
               |> Enum.filter(&(&1.operation_id == @operation))
    end

    test "#{kind} cannot consume another Commitment's Reservation", %{posts: posts} do
      {agent, [intent | _]} = claimed([0, 100])
      # 1,150 - 100 reserved elsewhere - 90 bound = 960 < the 1,000 floor.
      stub_game(agent, posts, @good, 1_150)

      Intents.execute_action(agent, intent, live_ship(agent), action(@kind))

      assert Elixir.Agent.get(posts, & &1) == []
      assert %Intent{status: "blocked"} = Repo.get!(Intent, intent.id)
    end

    test "#{kind} without a fresh quote is refused before any attempt exists", %{posts: posts} do
      {agent, [intent | _]} = claimed([0])
      stub_game(agent, posts, "OTHER_GOOD", 1_300)

      Intents.execute_action(agent, intent, live_ship(agent), action(@kind))

      assert Elixir.Agent.get(posts, & &1) == []
      assert MutationAttempts.list_for_agent(agent) == []
      assert %Intent{status: "blocked"} = Repo.get!(Intent, intent.id)
    end

    test "#{kind} Bounded Unknown exposure stays charged until recovery releases it",
         %{posts: posts} do
      {agent, [first, second]} = claimed([0, 0])
      stub_game(agent, posts, @good, 1_100)
      assert {:ok, %{attempt: one}} = RecordedAction.prepare(agent, first, action(@kind))
      assert {:ok, %{attempt: two}} = RecordedAction.prepare(agent, second, action(@kind))
      assert {:ok, one} = RecordedAction.admit_send(one)
      TestClock.advance(1)

      assert {:ok, ship} = Evidence.get_ship_binding(agent, "SHIP-0")
      assert {:ok, credits} = Evidence.get_agent_binding(agent)

      assert {:ok, proof} =
               Evidence.recovery_proof(
                 one,
                 :bounded_unknown,
                 "At most one purchase at the retained exposure bound",
                 [ship, credits]
               )

      accounting =
        Evidence.constraint_accounting("At most #{@exposure} credits", [
          %{
            constraint: "Keep at least 1,000 credits available",
            satisfied: true,
            evidence: "1,100 minus #{@exposure} leaves #{1_100 - @exposure}"
          }
        ])

      assert {:ok, _} =
               MutationAttempts.reconcile(one, :bounded_unknown, proof,
                 constraint_accounting: accounting
               )

      Req.Test.stub(API, fn _ -> flunk("durable exposure reload acquired new facts or sent") end)

      # 1,100 - 90 (Bounded Unknown) - 90 (this request) = 920 < 1,000.
      assert {:error, :insufficient_unreserved_headroom} =
               API.dispatch_recorded(MutationAttempts.get!(two.id))

      assert %{state: "not_sent"} = MutationAttempts.get!(two.id)
      assert %{state: "bounded_unknown"} = MutationAttempts.get!(one.id)
    end
  end

  test "a refuel without explicit units is not preparable" do
    {agent, [intent | _]} = claimed([0])
    stub_game(agent, nil, "FUEL", 1_300)

    assert {:error, :invalid_recorded_action} =
             RecordedAction.prepare(agent, intent, %{
               "kind" => "refuel",
               "waypoint" => "X1-UX81-A1"
             })

    assert MutationAttempts.list_for_agent(agent) == []
  end

  defp action("refuel"),
    do: %{
      "kind" => "refuel",
      "waypoint" => "X1-UX81-A1",
      "units" => 50,
      "fuel_before" => 150,
      "expected" => %{"fuel_full" => true}
    }

  defp action("jump"),
    do: %{
      "kind" => "jump",
      "waypoint" => "X1-UX81-A2",
      "source_waypoint" => "X1-UX81-A1",
      "credits_before" => 1_300,
      "antimatter_cost" => @price,
      "expected" => %{"status" => "IN_ORBIT", "waypoint" => "X1-UX81-A2", "system" => "X1-UX81"}
    }

  defp live_ship(agent) do
    assert {:ok, binding} = Evidence.get_ship_binding(agent, "SHIP-0")
    Evidence.bound_ship(binding)
  end

  defp stub_game(agent, posts, good, credits) do
    Req.Test.stub(API, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", path} ->
          if posts, do: Elixir.Agent.update(posts, &(&1 ++ [{operation(path), body(conn)}]))
          Req.Test.json(conn, %{"data" => post_response(agent, path)})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})

        {"GET", "/v2/my/ships/" <> _} ->
          Req.Test.json(conn, %{
            "data" => ship_body("SHIP-0", %{"fuel" => %{"current" => 150, "capacity" => 200}})
          })

        {"GET", _market} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "exports" => [],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{
                  "symbol" => good,
                  "type" => "EXCHANGE",
                  "tradeVolume" => 100,
                  "purchasePrice" => @price,
                  "sellPrice" => @price - 4,
                  "supply" => "MODERATE"
                }
              ]
            }
          })
      end
    end)
  end

  defp operation(path),
    do: if(String.ends_with?(path, "/jump"), do: "jump-ship", else: "refuel-ship")

  defp body(conn) do
    {:ok, raw, _} = Plug.Conn.read_body(conn)
    if raw == "", do: %{}, else: Jason.decode!(raw)
  end

  defp post_response(agent, path) do
    base = %{
      "agent" => %{"symbol" => agent.symbol, "credits" => 1_000},
      "fuel" => %{"current" => 200, "capacity" => 200},
      "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2"),
      "cooldown" => %{"shipSymbol" => "SHIP-0", "remainingSeconds" => 0, "totalSeconds" => 0},
      "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
      "transaction" => %{
        "shipSymbol" => "SHIP-0",
        "waypointSymbol" => "X1-UX81-A1",
        "tradeSymbol" => if(String.ends_with?(path, "/jump"), do: "ANTIMATTER", else: "FUEL"),
        "type" => "PURCHASE",
        "units" => 1,
        "pricePerUnit" => @price,
        "totalPrice" => @price,
        "timestamp" => "2026-01-01T00:00:00.000Z"
      }
    }

    base
  end

  # One Ship per Reservation; every Intent is an ordinary Commitment-owned
  # navigation that selects the action under test.
  defp claimed(reservations) do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        },
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
        faction: agent.faction
      })

    candidates =
      Enum.with_index(reservations, fn credits, index ->
        symbol = "SHIP-#{index}"
        {:ok, _} = SpaceTraders.Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")

        %PortfolioCandidate{
          id: "spend-#{index}",
          strategy_revision_id: revision.id,
          objective_index: 0,
          claims: [symbol],
          reservations: %{credits: credits},
          pledges: [],
          dependencies: [],
          expected_value: 10,
          unwind_cost: 0
        }
      end)

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, candidates, %{
        as_of: SpaceTraders.Clock.utc_now(),
        source_version: 0,
        claims: Enum.flat_map(candidates, & &1.claims),
        reservations: %{credits: 2_000}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "market-purchase-v1-25pct"
      })

    intents =
      portfolio.commitments
      |> Enum.sort_by(& &1.candidate_id)
      |> Enum.map(fn commitment ->
        [symbol] = commitment.claims
        ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: agent.id, symbol: symbol)

        Repo.insert!(%Intent{
          ship_id: ship.id,
          caller: "commitment",
          type: "navigate",
          status: "active",
          target_waypoint: "X1-UX81-A2",
          parameters: %{},
          fleet_commitment_id: commitment.id,
          fleet_commitment_portfolio_id: portfolio.id,
          fleet_commitment_portfolio_version: portfolio.version
        })
      end)

    {agent, intents}
  end
end
