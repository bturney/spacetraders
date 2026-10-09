defmodule SpaceTradersWeb.OutcomeMetricsTest do
  use SpaceTradersWeb.ConnCase, async: false

  import SpaceTraders.AgentFixtures
  import ExUnit.CaptureLog

  alias SpaceTraders.Evidence
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.TestClock

  @agent_event [:spacetraders, :outcome, :agent]
  @contracts_event [:spacetraders, :outcome, :contracts]
  @observed_event [:spacetraders, :outcome, :observed]
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

    :ok =
      :telemetry.attach_many(
        handler,
        [@agent_event, @contracts_event, @observed_event],
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{agent: agent, operator: operator}
  end

  test "family timestamps track authoritative observation time, including equal balances", %{
    agent: agent
  } do
    stub_agent(agent, 1000)
    assert {:ok, _} = Evidence.get_agent(agent)

    assert_receive {:outcome, @observed_event, %{observed_at_seconds: 1_893_456_000.0},
                    %{family: "credits"}}

    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="credits"}), 1_893_456_000)

    TestClock.advance(60)
    assert {:ok, _} = Evidence.get_agent(agent)

    assert_receive {:outcome, @observed_event, %{observed_at_seconds: 1_893_456_060.0},
                    %{family: "credits"}}

    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="credits"}), 1_893_456_060)

    TestClock.advance(30)
    stub_contracts([])
    assert {:ok, []} = Evidence.get_contracts(agent)

    assert_receive {:outcome, @observed_event, %{observed_at_seconds: 1_893_456_090.0},
                    %{family: "contracts"}}

    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="contracts"}), 1_893_456_090)
    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="credits"}), 1_893_456_060)

    TestClock.advance(600)
    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="credits"}), 1_893_456_060)
    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="contracts"}), 1_893_456_090)
    refute_receive {:outcome, @observed_event, _, _}
  end

  test "distinct equal-balance observations form a zero interval, losses stay negative and idle retains the pair",
       %{
         agent: agent
       } do
    stub_agent(agent, 1000)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert_metric("spacetraders_outcome_agent_credits_previous_observed_at_seconds", 0)
    assert last_interval_rate() == :unknown

    TestClock.advance(60)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert_metric("spacetraders_outcome_agent_credits_previous", 1000)

    assert_metric(
      "spacetraders_outcome_agent_credits_previous_observed_at_seconds",
      1_893_456_000
    )

    assert last_interval_rate() == 0

    TestClock.advance(600)
    stub_agent(agent, 900)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert_metric("spacetraders_outcome_agent_credits_previous", 1000)

    assert_metric(
      "spacetraders_outcome_agent_credits_previous_observed_at_seconds",
      1_893_456_060
    )

    assert last_interval_rate() == -600

    TestClock.advance(3600)
    assert last_interval_rate() == -600
    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="credits"}), 1_893_456_660)
    refute_receive {:outcome, @observed_event, _, _}
  end

  test "retained fact reuse and replay never advance timestamps or produce a new credit interval",
       %{
         agent: agent
       } do
    stub_agent(agent, 1000)
    assert {:ok, first} = Evidence.get_agent_binding(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    TestClock.advance(60)
    stub_agent(agent, 900)
    assert {:ok, second} = Evidence.get_agent_binding(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}

    TestClock.advance(600)
    assert {:ok, _} = Evidence.retained_binding(agent, first.observation.id)
    replay(agent, first)
    replay(agent, second)
    assert last_interval_rate() == -6000
    assert_metric(~s(spacetraders_outcome_observed_at_seconds{family="credits"}), 1_893_456_060)

    assert_metric(
      "spacetraders_outcome_agent_credits_previous_observed_at_seconds",
      1_893_456_000
    )

    refute_receive {:outcome, @observed_event, _, _}
  end

  test "same-time distinct reads keep current gauges truthful without a zero-duration credit pair",
       %{
         agent: agent
       } do
    stub_agent(agent, 1000)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}

    TestClock.advance(60)
    stub_agent(agent, 900)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}

    stub_agent(agent, 800)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_metric("spacetraders_outcome_agent_credits", 800)
    assert_metric("spacetraders_outcome_agent_credits_previous", 1000)
    assert last_interval_rate() == -12_000

    stub_contracts([contract("active", true, false, 4)])
    assert {:ok, [_]} = Evidence.get_contracts(agent)
    assert_metric(~s(spacetraders_outcome_contracts{status="active"}), 1)
    stub_contracts([])
    assert {:ok, []} = Evidence.get_contracts(agent)
    assert_metric(~s(spacetraders_outcome_contracts{status="active"}), 0)
  end

  test "a scrape cannot mix the current credits with an unfinished observation pair", %{
    agent: agent
  } do
    stub_agent(agent, 1000)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}

    handler = {__MODULE__, :pause, make_ref()}
    :ok = :telemetry.attach(handler, @agent_event, &__MODULE__.pause_publication/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    TestClock.advance(60)
    stub_agent(agent, 900)
    # Gameplay returns despite the metrics subscriber being paused.
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:publication_paused, publisher}
    parent = self()

    scrape =
      Task.async(fn ->
        send(parent, :scrape_started)
        build_conn() |> get("/metrics") |> response(200)
      end)

    assert_receive :scrape_started
    assert Task.yield(scrape, 20) == nil
    send(publisher, :continue_publication)
    body = Task.await(scrape)
    assert metric_value(body, "spacetraders_outcome_agent_credits") == 900
    assert metric_value(body, "spacetraders_outcome_agent_credits_previous") == 1000

    assert metric_value(body, ~s(spacetraders_outcome_observed_at_seconds{family="credits"})) ==
             1_893_456_060

    assert metric_value(body, "spacetraders_outcome_agent_credits_previous_observed_at_seconds") ==
             1_893_456_000
  end

  test "Agent identity changes invalidate the previous interval", %{
    agent: first_agent
  } do
    stub_agent(first_agent, 1000)
    assert {:ok, _} = Evidence.get_agent(first_agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    TestClock.advance(60)
    stub_agent(first_agent, 900)
    assert {:ok, _} = Evidence.get_agent(first_agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == -6000

    second_agent = agent_fixture(operator_fixture())
    TestClock.advance(60)
    stub_agent(second_agent, 175_000)
    assert {:ok, _} = Evidence.get_agent(second_agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == :unknown
    assert_metric("spacetraders_outcome_agent_credits", 175_000)

    TestClock.advance(60)
    stub_agent(second_agent, 175_010)
    assert {:ok, _} = Evidence.get_agent(second_agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == 600
    assert_metric("spacetraders_outcome_agent_credits_previous", 175_000)
  end

  test "establishing a Fleet Generation invalidates the unscoped credit interval", %{
    agent: agent,
    operator: operator
  } do
    stub_agent(agent, 1000)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    TestClock.advance(60)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == 0

    SpaceTraders.Repo.insert!(%SpaceTraders.FleetGeneration.Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction
    })

    TestClock.advance(60)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == :unknown

    TestClock.advance(60)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == 0
  end

  test "projection restart leaves rate unknown until two new observations and ignores pre-restart replays",
       %{
         agent: agent
       } do
    stub_agent(agent, 1000)
    assert {:ok, first} = Evidence.get_agent_binding(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    TestClock.advance(60)
    stub_agent(agent, 900)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == -6000

    TestClock.advance(600)
    restart_outcomes()
    assert last_interval_rate() == :unknown
    assert_metric("spacetraders_outcome_agent_credits", 900)
    replay(agent, first)
    refute_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert_metric("spacetraders_outcome_agent_credits", 900)

    stub_agent(agent, 800)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == :unknown

    TestClock.advance(60)
    stub_agent(agent, 700)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
    assert last_interval_rate() == -6000
    assert_metric("spacetraders_outcome_agent_credits_previous", 800)
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
    TestClock.advance(1)
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

        refute_receive {:outcome, @agent_event, _, _}
      end)

    assert log =~ "Outcome metric emission failed; dropping observation"
    refute_receive {:outcome, @agent_event, _, _}
    assert_metric("spacetraders_outcome_agent_credits", 765_432)

    stub_agent(agent, 654_321)
    TestClock.advance(1)
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
        assert_receive {:outcome, @observed_event, _, %{family: "credits"}}
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
        refute_receive {:outcome, @contracts_event, _, _}
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
    TestClock.advance(1)
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

  def pause_publication(_event, _measurements, _metadata, pid) do
    send(pid, {:publication_paused, self()})

    receive do
      :continue_publication -> :ok
    end
  end

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
    assert metric_value(body, series) == value
    refute body =~ "OUTCOME_TOKEN"
    body
  end

  defp metric_value(body, series) do
    assert [_, sample] = Regex.run(~r/^#{Regex.escape(series)} ([^\n]+)$/m, body)
    assert {actual, ""} = Float.parse(sample)
    actual
  end

  defp last_interval_rate do
    body = build_conn() |> get("/metrics") |> response(200)

    current_at =
      metric_value(body, ~s(spacetraders_outcome_observed_at_seconds{family="credits"}))

    previous_at =
      metric_value(body, "spacetraders_outcome_agent_credits_previous_observed_at_seconds")

    if previous_at > 0 and current_at > previous_at do
      current = metric_value(body, "spacetraders_outcome_agent_credits")
      previous = metric_value(body, "spacetraders_outcome_agent_credits_previous")
      3600 * (current - previous) / (current_at - previous_at)
    else
      :unknown
    end
  end

  defp replay(agent, binding) do
    source = binding.observation

    fact =
      Evidence.authoritative_observation(
        source.operation_id,
        source.dependency_keys,
        source.facts,
        source.observed_at
      )

    assert {:ok, _} = Evidence.fulfil_demands(agent, source.subject, fact)
  end

  defp restart_outcomes do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    {:ok, _pid} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    :ok
  end
end
