defmodule SpaceTradersWeb.OutcomeMetricsTest do
  use SpaceTradersWeb.ConnCase, async: false

  import SpaceTraders.AgentFixtures
  import ExUnit.CaptureLog

  alias SpaceTraders.Evidence
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.Agent.Scope

  @agent_event [:spacetraders, :outcome, :agent]
  @contracts_event [:spacetraders, :outcome, :contracts]

  setup do
    operator = operator_fixture()
    agent = agent_fixture(operator, %{agent_token: "OUTCOME_TOKEN"})
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [@agent_event, @contracts_event],
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{agent: agent, operator: operator}
  end

  test "owned Agent reads publish authoritative credits, including zero and Binding reads", %{
    agent: agent
  } do
    stub_agent(agent, 123_456)

    assert {:ok, %{credits: 123_456}} = Evidence.get_agent(agent)
    assert_receive {:outcome, @agent_event, %{credits: 123_456}, metadata}
    assert metadata == %{}
    assert_metric("spacetraders_outcome_agent_credits", 123_456)

    stub_agent(agent, 0)
    assert {:ok, %Evidence.Binding{value: %{credits: 0}}} = Evidence.get_agent_binding(agent)
    assert_receive {:outcome, @agent_event, %{credits: 0}, %{}}
    assert_metric("spacetraders_outcome_agent_credits", 0)
  end

  test "a projection failure logs and drops without interrupting the owned read", %{agent: agent} do
    stub_agent(agent, 765_432)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @agent_event, %{credits: 765_432}, %{}}

    stub_agent(agent, "invalid credits")

    log =
      capture_log(fn ->
        assert {:ok, %Evidence.Binding{value: %{credits: "invalid credits"}}} =
                 Evidence.get_agent_binding(agent)
      end)

    assert log =~ "Outcome metric emission failed; dropping observation"
    refute_receive {:outcome, @agent_event, _, _}
    assert_metric("spacetraders_outcome_agent_credits", 765_432)

    stub_agent(agent, 654_321)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @agent_event, %{credits: 654_321}, %{}}
    assert_metric("spacetraders_outcome_agent_credits", 654_321)
  end

  test "a broken telemetry subscriber cannot interrupt an owned read", %{agent: agent} do
    handler = {__MODULE__, :broken, make_ref()}
    :ok = :telemetry.attach(handler, @agent_event, &__MODULE__.broken_handler/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    stub_agent(agent, 321_654)

    log =
      capture_log(fn ->
        assert {:ok, %{credits: 321_654}} = Evidence.get_agent(agent)
      end)

    assert log =~ "has failed and has been detached"
    assert_receive {:outcome, @agent_event, %{credits: 321_654}, %{}}
    assert_metric("spacetraders_outcome_agent_credits", 321_654)
  end

  test "malformed Contracts drop the whole vector and an unsuccessful read emits no outcome", %{
    agent: agent
  } do
    stub_contracts([contract("existing", true, false, 4)])
    assert {:ok, [_]} = Evidence.get_contracts(agent)

    for _ <- 1..5 do
      assert_receive {:outcome, @contracts_event, _, _}
    end

    stub_contracts([
      contract("ready", true, false, 10),
      contract("invalid", "not a boolean", false, 0)
    ])

    log =
      capture_log(fn ->
        assert {:ok, [_, _]} = Evidence.get_contracts(agent)
      end)

    assert log =~ "Outcome metric emission failed; dropping observation"
    refute_receive {:outcome, @contracts_event, _, _}
    assert_metric(~s(spacetraders_outcome_contracts{status="active"}), 1)
    assert_metric(~s(spacetraders_outcome_contracts{status="near_delivery"}), 0)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"error" => %{"message" => "forbidden", "code" => 403}})
    end)

    assert {:error, _} = Evidence.get_contracts(agent)
    refute_receive {:outcome, @contracts_event, _, _}
    assert_metric(~s(spacetraders_outcome_contracts{status="active"}), 1)
  end

  test "owned Contract reads write every bounded status and clear previous counts", %{
    agent: agent,
    operator: operator
  } do
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, _revision} = FleetStrategy.activate(scope, strategy.draft_version)

    stub_contracts([
      contract("pending", false, false, 0),
      contract("active", true, false, 4),
      contract("ready", true, false, 10),
      contract("completed", true, true, 10),
      contract("expired-offer", false, false, 0, "2020-01-01T00:00:00Z"),
      contract("expired-accepted", true, false, 4, "2020-01-01T00:00:00Z")
    ])

    assert {:ok, contracts} = Evidence.get_contracts(agent)
    assert length(contracts) == 6

    for {status, count} <- [
          {"pending", 1},
          {"active", 1},
          {"near_delivery", 1},
          {"completed", 1},
          {"expired", 2}
        ] do
      assert_receive {:outcome, @contracts_event, %{count: ^count}, %{status: ^status}}
      assert_metric(~s(spacetraders_outcome_contracts{status="#{status}"}), count)
    end

    stub_contracts([])
    assert {:ok, %Evidence.Binding{value: []}} = Evidence.get_contracts(agent, bind: true)

    for status <- ~w(pending active near_delivery completed expired) do
      assert_receive {:outcome, @contracts_event, %{count: 0}, %{status: ^status}}
      assert_metric(~s(spacetraders_outcome_contracts{status="#{status}"}), 0)
    end
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:outcome, event, measurements, metadata})
  end

  def broken_handler(_event, _measurements, _metadata, _config), do: raise("broken subscriber")

  defp stub_agent(agent, credits) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v2/my/agent"
      Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})
    end)
  end

  defp stub_contracts(contracts) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v2/my/contracts"
      Req.Test.json(conn, %{"data" => contracts})
    end)
  end

  defp contract(id, accepted, fulfilled, delivered, deadline \\ "2099-01-01T00:00:00Z") do
    %{
      "id" => id,
      "accepted" => accepted,
      "fulfilled" => fulfilled,
      "deadlineToAccept" => deadline,
      "terms" => %{
        "deadline" => deadline,
        "deliver" => [
          %{
            "tradeSymbol" => "IRON_ORE",
            "destinationSymbol" => "X1-TEST-A1",
            "unitsRequired" => 10,
            "unitsFulfilled" => delivered
          }
        ]
      }
    }
  end

  defp assert_metric(series, value) do
    body = build_conn() |> get("/metrics") |> response(200)
    assert body =~ "#{series} #{value}\n"
    refute body =~ "OUTCOME_TOKEN"
    body
  end
end
