defmodule SpaceTraders.FleetReadTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intents, Ship, ShipServer}
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

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
