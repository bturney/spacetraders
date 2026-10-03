defmodule SpaceTraders.ShipSpendingAdmissionProof do
  @moduledoc """
  Opt-in #505 scope-decision evidence at the existing public Intent seam.
  This is not a Fleet autonomy qualification: a current claimed portfolio is a
  fixture. Production Ship Execution selects the buy quantity and dispatches it
  against a stateful Market that changes price after the preflight observation.
  Run explicitly; the unresolved Hard Constraint assertion deliberately fails.
  """

  # This diagnostic owns shared ShipServer and admission state while it runs.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Intents}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  test "Ship purchase admission protects the active credit floor when the Market reprices" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = SpaceTraders.Fleet.record_ship(agent, "SPENDING-PROOF", "SHIP_COMMAND_FRIGATE")
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

    candidate = %PortfolioCandidate{
      id: "spending-proof",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{credits: 50},
      pledges: [],
      dependencies: [],
      expected_value: 50,
      unwind_cost: 0
    }

    # The existing Market eligibility calculation admits this reservation:
    # 2,000 - (50 + 500 fuel allowance + 250 bounded loss) = 1,200 >= 1,000.
    assert FleetExecution.reservation_covers_exposure?(candidate, revision, %{
             reservations: %{credits: 2_000}
           })

    {:ok, selected} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: [ship.symbol],
        reservations: %{credits: 2_000}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(operator),
        generation.id,
        selected,
        %{evidence_references: [], expectations: %{}, calibration_version: "spending-proof"}
      )

    [commitment] = portfolio.commitments
    game = start_supervised!({Agent, fn -> %{credits: 2_000, units: 0, purchases: 0} end})
    on_exit(fn -> SpaceTraders.Fleet.ShipServer.stop_all() end)
    ship_path = "/v2/my/ships/#{ship.symbol}"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      state = Agent.get(game, & &1)

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"cargo" => cargo(state.units)})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => state.credits}})

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

        {"POST", path} when path == ship_path <> "/purchase" ->
          # The bundled purchase schema accepts quantity, not a price ceiling.
          # Shared World State may reprice after the last authoritative read.
          assert conn.body_params == %{"symbol" => "IRON_ORE", "units" => 5}
          assert state.units == 0
          total = 5 * 220
          assert state.credits >= total
          after_purchase = %{credits: state.credits - total, units: 5, purchases: 1}
          Agent.update(game, fn _ -> after_purchase end)

          Req.Test.json(conn, %{
            "data" => %{
              "agent" => %{"symbol" => agent.symbol, "credits" => after_purchase.credits},
              "cargo" => cargo(after_purchase.units),
              "transaction" => %{
                "type" => "PURCHASE",
                "shipSymbol" => ship.symbol,
                "tradeSymbol" => "IRON_ORE",
                "waypointSymbol" => "X1-UX81-A1",
                "units" => 5,
                "pricePerUnit" => 220,
                "totalPrice" => total
              }
            }
          })

        request ->
          flunk("unexpected game request: #{inspect(request)}")
      end
    end)

    {:ok, intent} =
      Intents.request_commitment_round_trip(agent, commitment, portfolio, ship.symbol, %{
        source_waypoint: "X1-UX81-A1",
        destination_waypoint: "X1-UX81-A2",
        trade_symbol: "IRON_ORE",
        units: 5,
        purchase_price: 10,
        sell_price: 20,
        reserve_credits: 1_000
      })

    intent = Repo.get!(Intent, intent.id)
    [attempt] = SpaceTraders.MutationAttempts.list_for_agent(agent)
    state = Agent.get(game, & &1)

    IO.inspect(
      %{
        initial_credits: 2_000,
        credit_floor: 1_000,
        reserved_purchase_credits: 50,
        eligible_exposure_credits: FleetExecution.worst_case_exposure(50),
        observed_unit_price: 10,
        charged_unit_price: 220,
        requested_units: 5,
        actual_credits: state.credits,
        actual_cargo_units: state.units,
        purchases: state.purchases,
        attempt_state: attempt.state,
        selected_attempt_link: intent.mutation_attempt_id,
        intent_state: intent.status,
        returned_unit_price: intent.last_action_result["price"],
        transaction_total: get_in(intent.last_action_result, ["transaction", "total_price"])
      },
      label: "#505 public Ship spending admission evidence"
    )

    assert %Intent{status: "completed"} = intent
    assert attempt.operation_id == "purchase-cargo"

    assert state.credits >= 1_000,
           "the accepted purchase spent protected credits despite the active Hard Constraint"
  end

  defp cargo(units) do
    %{
      "capacity" => 40,
      "units" => units,
      "inventory" => if(units == 0, do: [], else: [%{"symbol" => "IRON_ORE", "units" => units}])
    }
  end
end
