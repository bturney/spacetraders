defmodule SpaceTraders.FleetAcquisitionTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.API.Model.{Shipyard, Waypoint}
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAcquisition
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence

  test "purchases from a fresh Ship Offer then bootstraps readiness before the new Ship can be claimed" do
    {scope, agent, revision} = generation()

    Intelligence.observe_waypoint(agent, Waypoint.from_json(waypoint()))

    Intelligence.observe_shipyard(
      agent,
      "X1-UX81",
      Shipyard.from_json(%{
        "symbol" => "X1-UX81-A1",
        "shipTypes" => [%{"type" => "SHIP_LIGHT_HAULER"}],
        "ships" => [
          %{
            "type" => "SHIP_LIGHT_HAULER",
            "purchasePrice" => 10_000,
            "engine" => %{"speed" => 30}
          }
        ]
      }),
      source: "get_shipyard",
      offers_visible: true
    )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 20_000}})

        {"POST", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "agent" => %{"symbol" => agent.symbol, "credits" => 10_000},
              "ship" =>
                ship_body("ACQUIRE-2", %{
                  "registration" => %{
                    "name" => "ACQUIRE-2",
                    "factionSymbol" => "COSMIC",
                    "role" => "HAULER"
                  }
                }),
              "transaction" => %{
                "agentSymbol" => agent.symbol,
                "price" => 10_000,
                "shipSymbol" => "ACQUIRE-2",
                "shipType" => "SHIP_LIGHT_HAULER",
                "waypointSymbol" => "X1-UX81-A1",
                "timestamp" => "2030-01-01T12:00:00Z"
              }
            }
          })

        {"GET", "/v2/my/ships/ACQUIRE-2"} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body("ACQUIRE-2", %{
                "registration" => %{
                  "name" => "ACQUIRE-2",
                  "factionSymbol" => "COSMIC",
                  "role" => "HAULER"
                }
              })
          })
      end
    end)

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}, readiness: %{engine: %{speed: 1}}}} =
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    assert {:error, :no_current_ship_claim} =
             FleetAllocation.current_ship_claim(agent, "ACQUIRE-2")

    assert [%{reservations: %{"credits" => 10_000}}] =
             FleetAllocation.current_portfolio(scope, agent).commitments

    assert [%{actual_outcomes: %{"ship_symbol" => "ACQUIRE-2"}}] =
             Repo.all(SpaceTraders.FleetAllocation.StrategyDecisionEpisode)
  end

  defp generation do
    operator = Repo.insert!(%Operator{email: "acquire-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%Agent{
        operator_id: operator.id,
        symbol: "ACQUIRE",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "TOKEN"
      })

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: %{
          "objectives" => [
            %{"objective" => "Grow the Fleet", "kind" => "attain", "evaluation" => "Add a Ship"}
          ],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        }
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

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

    {Scope.for_operator(operator), agent, revision}
  end

  defp waypoint,
    do: %{
      "symbol" => "X1-UX81-A1",
      "systemSymbol" => "X1-UX81",
      "type" => "PLANET",
      "x" => 0,
      "y" => 0,
      "traits" => [%{"symbol" => "SHIPYARD"}]
    }
end
