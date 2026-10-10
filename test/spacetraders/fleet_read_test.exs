defmodule SpaceTraders.FleetReadTest do
  # ShipServer processes share the application registry and are stopped by this case.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.EvidenceFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intents, Ship, ShipServer}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  test "reads live Ships using the owning Agent's credentials" do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v2/my/ships"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer AGENT_TOKEN"]

      Req.Test.json(conn, %{"data" => [ship_body("READ-SHIP")]})
    end)

    assert {:ok, [%Model.Ship{symbol: "READ-SHIP", nav: %Model.ShipNav{status: "DOCKED"}}]} =
             Fleet.list_ships(agent_fixture())

    assert {:error, :agent_token_missing} = Fleet.list_ships(%AgentRecord{agent_token: nil})
  end

  test "an ownerless legacy Ship timer is not caught up during boot" do
    agent = agent_fixture()
    Repo.insert!(%Ship{symbol: "READ-SHIP", ship_type: "SHIP_PROBE", agent_id: agent.id})

    {:ok, event} =
      Timeline.schedule_event(
        :ship,
        "READ-SHIP",
        :arrival,
        DateTime.add(DateTime.utc_now(), -60, :second)
      )

    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet:#{agent.id}")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => ship_body("READ-SHIP")})
    end)

    assert :ok = Intents.rearm_on_boot()
    refute_receive {:ship_updated, _, "READ-SHIP"}, 100
    assert Repo.get!(Event, event.id).status == "pending"
    assert ShipServer.ensure_ready("READ-SHIP") == :ok
  end

  test "an Operator Market view retains a Listing linked to its governed read" do
    agent = agent_fixture()

    waypoint = %{
      symbol: "X1-UX81-A1",
      system_symbol: "X1-UX81",
      traits: [%{symbol: "MARKETPLACE"}]
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => "X1-UX81-A1",
          "exports" => [],
          "imports" => [],
          "exchange" => [],
          "tradeGoods" => [
            %{
              "symbol" => "IRON_ORE",
              "type" => "EXPORT",
              "tradeVolume" => 20,
              "supply" => "MODERATE",
              "purchasePrice" => 10,
              "sellPrice" => 12
            }
          ]
        }
      })
    end)

    listing =
      governed_market_observation(agent, "X1-UX81", "X1-UX81-A1", 10, 12,
        observed_at: DateTime.add(DateTime.utc_now(), -30)
      )

    assert {:ok, %Model.Market{symbol: "X1-UX81-A1"}} = Fleet.waypoint_market(agent, waypoint)

    # The view retains composition linked to its own governed read ...
    assert %{"exports" => %{observation: %{evidence_observation_id: view_source}}} =
             Intelligence.subject(agent, :market, "X1-UX81", "X1-UX81-A1")

    assert is_binary(view_source) and view_source != listing.id

    # ... and never displaces the governed Listing that supports trade.
    listing_id = "evidence-observation:#{listing.id}"

    assert [%{state: :current, evidence_id: ^listing_id}] =
             Intelligence.market_interpretation(agent, "X1-UX81", DateTime.utc_now()).markets
  end

  defp agent_fixture do
    operator =
      Repo.insert!(%Operator{
        email: "fleet-read-#{System.unique_integer([:positive])}@example.com"
      })

    Repo.insert!(%AgentRecord{
      symbol: "READ-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN",
      operator_id: operator.id
    })
  end
end
