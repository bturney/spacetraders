defmodule SpaceTradersWeb.OutcomeMetricsTest do
  use SpaceTradersWeb.ConnCase, async: false

  import SpaceTraders.AgentFixtures
  import ExUnit.CaptureLog

  alias SpaceTraders.Evidence
  alias SpaceTraders.TestClock

  @agent_event [:agent, :credits]
  @now ~U[2030-01-01 00:00:00.000000Z]

  setup do
    restart_outcomes()
    on_exit(&restart_outcomes/0)
    start_supervised!({TestClock, @now})
    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous_clock,
        do: Application.put_env(:spacetraders, :clock, previous_clock),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    operator = operator_fixture()
    agent = agent_fixture(operator, %{agent_token: "OUTCOME_TOKEN"})
    handler = {__MODULE__, make_ref()}

    :ok = :telemetry.attach_many(handler, [@agent_event], &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    %{agent: agent, operator: operator}
  end

  test "owned Agent reads publish agent_credits, including zero and Binding reads", %{
    agent: agent
  } do
    stub_agent(agent, 123_456)

    assert {:ok, %{credits: 123_456}} = Evidence.get_agent(agent)
    assert_receive {:outcome, @agent_event, %{credits: 123_456}, metadata}
    assert metadata == %{}
    body = assert_metric("agent_credits", 123_456)

    # The retired Outcome families are gone: nothing reads them.
    refute body =~ "spacetraders_outcome_"

    stub_agent(agent, 0)
    TestClock.advance(1)
    assert {:ok, %Evidence.Binding{value: %{credits: 0}}} = Evidence.get_agent_binding(agent)
    assert_receive {:outcome, @agent_event, %{credits: 0}, %{}}
    assert_metric("agent_credits", 0)
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

        refute_receive {:outcome, @agent_event, _, _}
      end)

    assert log =~ "Outcome metric emission failed; dropping observation"
    assert_metric("agent_credits", 765_432)

    stub_agent(agent, 654_321)
    TestClock.advance(1)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @agent_event, %{credits: 654_321}, %{}}
    assert_metric("agent_credits", 654_321)
  end

  test "a broken telemetry subscriber cannot interrupt an owned read", %{agent: agent} do
    handler = {__MODULE__, :broken, make_ref()}
    :ok = :telemetry.attach(handler, @agent_event, &__MODULE__.broken_handler/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    stub_agent(agent, 321_654)

    log =
      capture_log(fn ->
        assert {:ok, %{credits: 321_654}} = Evidence.get_agent(agent)
        assert_receive {:outcome, @agent_event, %{credits: 321_654}, %{}}, 2_000
        # A scrape queues behind the worker's publication, which logs the failure.
        assert_metric("agent_credits", 321_654)
      end)

    assert log =~ "has failed and has been detached"
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

  defp assert_metric(series, value) do
    body = build_conn() |> get("/metrics") |> response(200)
    assert [_, sample] = Regex.run(~r/^#{Regex.escape(series)} ([^\n]+)$/m, body)
    assert {actual, ""} = Float.parse(sample)
    assert actual == value
    refute body =~ "OUTCOME_TOKEN"
    body
  end

  defp restart_outcomes do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    {:ok, _pid} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    :ok
  end
end
