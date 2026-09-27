defmodule SpaceTradersWeb.EntityLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Repo

  setup :register_and_log_in_operator

  test "renders Ship and Contract pages from existing governed evidence without game reads", %{
    conn: conn,
    operator: operator
  } do
    agent =
      Repo.insert!(%AgentRecord{
        operator_id: operator.id,
        symbol: "ATLAS",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    Repo.insert!(%Ship{agent_id: agent.id, symbol: "ATLAS-1", ship_type: "SHIP_PROBE"})

    observation!(agent, "ship:ATLAS-1", "get-my-ship", %{
      "response" => %{
        "symbol" => "ATLAS-1",
        "nav" => %{"systemSymbol" => "X1", "waypointSymbol" => "X1-A1", "status" => "IN_ORBIT"}
      }
    })

    observation!(agent, "contracts:ATLAS", "get-contracts", %{
      "response" => [
        %{
          "id" => "CONTRACT-1",
          "accepted" => true,
          "fulfilled" => false,
          "terms" => %{
            "deliver" => [
              %{
                "tradeSymbol" => "IRON",
                "destinationSymbol" => "X1-A1",
                "unitsRequired" => 20,
                "unitsFulfilled" => 7
              }
            ]
          }
        }
      ]
    })

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("Entity pages must not request gameplay")
    end)

    {:ok, ship_view, ship_html} = live(conn, "/ships/ATLAS-1")
    assert has_element?(ship_view, "#ship-ATLAS-1", "Ship ATLAS-1")
    assert ship_html =~ "SHIP_PROBE"
    assert ship_html =~ "IN_ORBIT"
    assert ship_html =~ "Last observed status"
    assert ship_html =~ "Stale"
    assert ship_html =~ "2026-09-27 12:00 UTC"

    assert has_element?(
             ship_view,
             "a[href='/world/systems/X1/waypoints/X1-A1?agent=#{agent.id}']",
             "X1-A1"
           )

    {:ok, contract_view, contract_html} = live(conn, "/contracts/CONTRACT-1")
    assert has_element?(contract_view, "#contract-CONTRACT-1", "Contract CONTRACT-1")
    assert contract_html =~ "Accepted"
    assert contract_html =~ "IRON"
    assert contract_html =~ "13 remaining"
    assert contract_html =~ "Last observed state"
    assert contract_html =~ "Stale"

    assert has_element?(
             contract_view,
             "a[href='/world/systems/X1/waypoints/X1-A1?agent=#{agent.id}']",
             "X1-A1"
           )
  end

  defp observation!(agent, subject, operation_id, facts) do
    Repo.insert!(%Observation{
      agent_id: agent.id,
      subject: subject,
      operation_id: operation_id,
      dependency_keys: [],
      facts: facts,
      response_fingerprint: "test",
      observed_at: ~U[2026-09-27 12:00:00.000000Z]
    })
  end
end
