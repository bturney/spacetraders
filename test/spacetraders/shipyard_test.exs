defmodule SpaceTraders.ShipyardTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Shipyard

  defp agent_fixture do
    Repo.insert!(%AgentRecord{
      symbol: "SHIPYARD-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN"
    })
  end

  test "refuses to spend without the retained offer evidence Fleet spending authority needs" do
    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("an unbounded purchase must not dispatch")
    end)

    assert {:error, :ship_offer_evidence_unavailable} =
             Shipyard.purchase(agent_fixture(), "SHIP_MINING_DRONE", "X1-UX81-A2")
  end
end
