defmodule SpaceTraders.CreditSpendingFixtures do
  @moduledoc "Strategy, Reservation, and Market quote setup for credit-spending admission tests."

  import ExUnit.Assertions
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.API
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Repo

  def claimed_purchases(reservations, opts \\ []) do
    operator = Keyword.get_lazy(opts, :operator, &operator_fixture/0)
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
        symbol = "BUYER-#{index}"
        {:ok, _} = SpaceTraders.Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")

        %PortfolioCandidate{
          id: "purchase-#{index}",
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
          type: "buy",
          status: "active",
          target_waypoint: agent.headquarters,
          parameters: %{"units" => 5, "trade_symbol" => "IRON_ORE"},
          fleet_commitment_id: commitment.id,
          fleet_commitment_portfolio_id: portfolio.id,
          fleet_commitment_portfolio_version: portfolio.version
        })
      end)

    {agent, intents, portfolio}
  end

  def buy,
    do: %{"kind" => "buy", "trade_symbol" => "IRON_ORE", "units" => 5, "listing_price" => 10}

  def stub_quote(agent, price, credits) do
    Req.Test.stub(API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})

        _ ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.headquarters,
              "exports" => [],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{"symbol" => "IRON_ORE", "purchasePrice" => price, "tradeVolume" => 5}
              ]
            }
          })
      end
    end)
  end

  def stub_purchase(agent, ship_symbol, unit_price, credits_after) do
    Req.Test.stub(API, fn
      %{method: "GET", request_path: "/v2/my/agent"} = conn ->
        Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits_after}})

      conn ->
        purchase_response(conn, agent, ship_symbol, unit_price, credits_after)
    end)
  end

  defp purchase_response(conn, agent, ship_symbol, unit_price, credits_after) do
    assert conn.method == "POST"
    assert conn.request_path == "/v2/my/ships/#{ship_symbol}/purchase"

    Req.Test.json(conn, %{
      "data" => %{
        "agent" => %{"symbol" => agent.symbol, "credits" => credits_after},
        "cargo" => %{
          "capacity" => 40,
          "units" => 5,
          "inventory" => [%{"symbol" => "IRON_ORE", "name" => "Iron ore", "units" => 5}]
        },
        "transaction" => %{
          "waypointSymbol" => agent.headquarters,
          "shipSymbol" => ship_symbol,
          "tradeSymbol" => "IRON_ORE",
          "type" => "PURCHASE",
          "units" => 5,
          "pricePerUnit" => unit_price,
          "totalPrice" => unit_price * 5,
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }
    })
  end
end
