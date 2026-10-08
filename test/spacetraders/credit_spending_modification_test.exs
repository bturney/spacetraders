defmodule SpaceTraders.CreditSpendingModificationTest do
  @moduledoc """
  Module installation and removal owe the Shipyard's published modification
  fee (ADR 0013, #579 c3). The recorded-action admission bounds that charge
  from fresh Shipyard evidence at the calibrated margin, records the realized
  charge, and withdraws work whose fee is no longer fresh for replanning.
  """
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.CreditCalibration
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.TestClock

  @waypoint "X1-UX81-A1"
  @fee 100
  # ceil(100 * 125 / 100): one modification fee at the calibrated 25% margin.
  @bound 125

  setup do
    start_supervised!({TestClock, DateTime.utc_now()})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    {:ok, game: start_supervised!({Elixir.Agent, fn -> %{posts: [], shipyard_reads: 0} end})}
  end

  for kind <- ["install_module", "remove_module"] do
    @kind kind
    @operation if(kind == "install_module", do: "install-ship-module", else: "remove-ship-module")

    test "#{kind} is bounded by the fresh Shipyard fee and its charge is realized", %{game: game} do
      {agent, [intent | _]} = claimed([0])
      stub_game(agent, game, credits: 1_300)

      assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, action(@kind))

      assert %{
               "kind" => "modification",
               "waypoint" => @waypoint,
               "unit_price" => @fee,
               "units" => 1,
               "calibration_version" => "market-purchase-v1-25pct",
               "worst_case_exposure" => @bound,
               "quote_observation_id" => quote_id
             } = attempt.prepared_evidence["spending"]

      assert {:ok, _} = Evidence.retained_binding(agent, quote_id)
      assert {:ok, _} = API.dispatch_recorded(MutationAttempts.get!(attempt.id))
      assert [{@operation, _body}] = posts(game)

      assert %{unit_price: @fee, realized_charge: @fee, within_bound: true} =
               CreditCalibration.realization(attempt)
    end
  end

  test "an unresolved refit is charged at its bound instead of failing other spending closed",
       %{game: game} do
    {agent, [first, second]} = claimed([0, 0])
    # 1,300 - 125 (unresolved refit) - 125 (this refit) = 1,050 >= the 1,000 floor.
    stub_game(agent, game, credits: 1_300)

    assert {:ok, %{attempt: one}} = RecordedAction.prepare(agent, first, action("install_module"))

    assert {:ok, %{attempt: two}} =
             RecordedAction.prepare(agent, second, action("install_module"))

    assert {:ok, %{state: "sent_or_unknown"}} = RecordedAction.admit_send(one)

    assert {:ok, %{state: "sent_or_unknown"}} = RecordedAction.admit_send(two)
  end

  test "Shipyard fee evidence older than two minutes is read again before preparation",
       %{game: game} do
    {agent, [first, second, third]} = claimed([0, 0, 0])
    stub_game(agent, game, credits: 1_300)

    assert {:ok, %{attempt: one}} = RecordedAction.prepare(agent, first, action("install_module"))
    TestClock.advance(60)

    assert {:ok, %{attempt: reused}} =
             RecordedAction.prepare(agent, third, action("install_module"))

    assert Elixir.Agent.get(game, & &1.shipyard_reads) == 1

    assert reused.prepared_evidence["spending"]["quote_observation_id"] ==
             one.prepared_evidence["spending"]["quote_observation_id"]

    TestClock.advance(61)

    assert {:ok, %{attempt: two}} =
             RecordedAction.prepare(agent, second, action("install_module"))

    assert Elixir.Agent.get(game, & &1.shipyard_reads) == 2

    refute one.prepared_evidence["spending"]["quote_observation_id"] ==
             two.prepared_evidence["spending"]["quote_observation_id"]
  end

  test "a refit whose fee went stale before send is withdrawn for replanning", %{game: game} do
    {agent, [intent | _]} = claimed([0])
    stub_game(agent, game, credits: 1_300)

    assert {:ok, %{attempt: attempt}} =
             RecordedAction.prepare(agent, intent, action("install_module"))

    TestClock.advance(121)

    assert {:error, :modification_fee_stale_or_missing} =
             API.dispatch_recorded(MutationAttempts.get!(attempt.id))

    assert posts(game) == []
    assert %{state: "not_sent"} = MutationAttempts.get!(attempt.id)

    assert %Intent{
             status: "superseded",
             last_action_result: %{"outcome" => "spending_replan_required"}
           } = Repo.get!(Intent, intent.id)
  end

  test "a Shipyard without a published fee is refused before any attempt exists",
       %{game: game} do
    {agent, [intent | _]} = claimed([0])
    stub_game(agent, game, credits: 1_300, fee: nil)

    assert {:error, :modification_fee_unavailable} =
             RecordedAction.prepare(agent, intent, action("install_module"))

    assert MutationAttempts.list_for_agent(agent) == []
    assert posts(game) == []
  end

  test "a fee charged above its bound is a pricing-model miss", %{game: game} do
    {agent, [intent | _]} = claimed([0])
    stub_game(agent, game, credits: 1_300, charge: 200)

    assert {:ok, %{attempt: attempt}} =
             RecordedAction.prepare(agent, intent, action("install_module"))

    assert {:ok, _} = API.dispatch_recorded(MutationAttempts.get!(attempt.id))

    assert %{realized_charge: 200, within_bound: false} = CreditCalibration.realization(attempt)
    assert [%{kind: "pricing_model_miss"}] = CreditCalibration.shortfalls(agent)
  end

  defp action(kind),
    do: %{
      "kind" => kind,
      "module_symbol" => "MODULE_CARGO_HOLD_I",
      "quantity" => 1,
      "waypoint" => @waypoint,
      "installed_before" => 0,
      "cargo_before" => 1
    }

  defp posts(game), do: Elixir.Agent.get(game, & &1.posts)

  defp stub_game(agent, game, opts) do
    credits = Keyword.fetch!(opts, :credits)
    fee = Keyword.get(opts, :fee, @fee)
    charge = Keyword.get(opts, :charge, @fee)

    Req.Test.stub(API, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", path} ->
          operation =
            if String.ends_with?(path, "/install"),
              do: "install-ship-module",
              else: "remove-ship-module"

          Elixir.Agent.update(game, &%{&1 | posts: &1.posts ++ [{operation, body(conn)}]})
          Req.Test.json(conn, %{"data" => post_response(agent, credits - charge, charge)})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})

        {"GET", "/v2/my/ships/" <> _} ->
          Req.Test.json(conn, %{"data" => ship_body("SHIP-0")})

        {"GET", "/v2/systems/X1-UX81/waypoints/" <> _shipyard} ->
          Elixir.Agent.update(game, &%{&1 | shipyard_reads: &1.shipyard_reads + 1})

          Req.Test.json(conn, %{
            "data" =>
              %{"symbol" => @waypoint, "shipTypes" => [], "modificationsFee" => fee}
              |> Map.reject(fn {_key, value} -> is_nil(value) end)
          })
      end
    end)
  end

  defp body(conn) do
    {:ok, raw, _} = Plug.Conn.read_body(conn)
    if raw == "", do: %{}, else: Jason.decode!(raw)
  end

  defp post_response(agent, credits_after, charge) do
    %{
      "agent" => %{"symbol" => agent.symbol, "credits" => credits_after},
      "modules" => [],
      "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
      "transaction" => %{
        "shipSymbol" => "SHIP-0",
        "waypointSymbol" => @waypoint,
        "tradeSymbol" => "MODULE_CARGO_HOLD_I",
        "totalPrice" => charge,
        "timestamp" => "2026-01-01T00:00:00.000Z"
      }
    }
  end

  # One Ship per Reservation; every Intent is an ordinary Commitment-owned
  # Intent that selects the module action under test.
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
          id: "refit-#{index}",
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
          type: "install_module",
          status: "active",
          target_waypoint: @waypoint,
          parameters: %{"module_symbol" => "MODULE_CARGO_HOLD_I"},
          fleet_commitment_id: commitment.id,
          fleet_commitment_portfolio_id: portfolio.id,
          fleet_commitment_portfolio_version: portfolio.version
        })
      end)

    {agent, intents}
  end
end
