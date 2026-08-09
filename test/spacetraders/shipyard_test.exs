defmodule SpaceTraders.ShipyardTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Shipyard

  defp agent_fixture do
    Repo.insert!(%AgentRecord{
      symbol: "SHIPYARD-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN"
    })
  end

  test "purchases a ship through the agent token" do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/ships"

      assert conn.body_params == %{
               "shipType" => "SHIP_MINING_DRONE",
               "waypointSymbol" => "X1-UX81-A2"
             }

      Req.Test.json(conn, %{"data" => %{"agent" => %{}, "ship" => %{}, "transaction" => %{}}})
    end)

    assert {:ok, %{transaction: %Model.ShipyardTransaction{}, ship: %Model.Ship{}}} =
             Shipyard.purchase(agent_fixture(), "SHIP_MINING_DRONE", "X1-UX81-A2")
  end
end
