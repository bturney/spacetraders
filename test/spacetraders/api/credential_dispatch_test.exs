defmodule SpaceTraders.API.CredentialDispatchTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.API
  alias SpaceTraders.API.AgentTokenReference

  import Plug.Conn, only: [get_req_header: 2]
  import SpaceTraders.AgentFixtures

  test "resolves the AgentToken reference immediately before dispatch" do
    operator = operator_fixture()
    agent = agent_fixture(operator, %{agent_token: "OLD_TOKEN"})
    reference = AgentTokenReference.new(agent)

    agent
    |> Ecto.Changeset.change(agent_token: "CURRENT_TOKEN")
    |> Repo.update!()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer CURRENT_TOKEN"]
      Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol}})
    end)

    assert {:ok, %SpaceTraders.API.Model.Agent{symbol: symbol}} = API.get_agent(reference)
    assert symbol == agent.symbol
    refute inspect(reference) =~ "CURRENT_TOKEN"
  end

  test "does not dispatch when the AgentToken reference cannot be resolved" do
    reference = %AgentTokenReference{agent_id: -1}

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("request dispatched without an AgentToken")
    end)

    assert {:error, :agent_token_missing} = API.get_agent(reference)
  end

  test "uses an opaque process-local reference while importing an AgentToken" do
    reference = AgentTokenReference.temporary("IMPORTED_TOKEN")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer IMPORTED_TOKEN"]
      Req.Test.json(conn, %{"data" => %{"symbol" => "IMPORTED"}})
    end)

    assert {:ok, %SpaceTraders.API.Model.Agent{symbol: "IMPORTED"}} = API.get_agent(reference)
    refute inspect(reference) =~ "IMPORTED_TOKEN"
    assert {:error, :agent_token_missing} = API.get_agent(reference)
  end

  test "authenticated API calls reject raw AgentToken strings" do
    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("request dispatched with a raw AgentToken")
    end)

    assert_raise FunctionClauseError, fn -> API.get_agent("RAW_AGENT_TOKEN") end
  end
end
