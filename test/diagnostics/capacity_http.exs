defmodule SpaceTraders.CapacityHTTPDiagnostic do
  # Authored protocol faults, not a gameplay simulator or a qualification run.
  # Opt-in: owns a tiny loopback listener; ordinary test discovery binds no port.
  use SpaceTraders.DataCase, async: false
  @moduletag timeout: 10_000
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.{API, Clock, Evidence, FleetStrategy, TestClock}
  alias SpaceTraders.API.{CapacityGovernor, OperationInventory, RateLimiter}
  alias SpaceTraders.Agent.Scope

  defmodule FaultEndpoint do
    def init(store), do: store

    def call(conn, store) do
      {mode, body} =
        Agent.get_and_update(store, fn state ->
          if state.count >= 8, do: raise("bounded fault diagnostic request cap exceeded")
          {{state.mode, state.body}, %{state | count: state.count + 1}}
        end)

      case mode do
        :throttle ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "2")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            429,
            Jason.encode!(%{"error" => %{"code" => 429, "message" => "limited"}})
          )

        :outage ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        :clean ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => body}))
      end
    end
  end

  setup do
    previous =
      Map.new(
        [:clock, :semantic_api_scarcity, API, RateLimiter],
        &{&1, Application.fetch_env(:spacetraders, &1)}
      )

    start_supervised!({TestClock, DateTime.utc_now()})
    Application.put_env(:spacetraders, :clock, TestClock)
    Application.put_env(:spacetraders, :semantic_api_scarcity, true)
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    body = %{
      "accountId" => "diagnostic",
      "symbol" => agent.symbol,
      "headquarters" => "X1-UX81-A1",
      "credits" => 100_000,
      "startingFaction" => "COSMIC",
      "shipCount" => 1
    }

    store = start_supervised!({Agent, fn -> %{mode: :throttle, body: body, count: 0} end})

    server =
      start_supervised!(
        {Bandit, plug: {FaultEndpoint, store}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    # Deliberately remove Req.Test. No native-world launch, private source or
    # live target is used, and redirects cannot be emitted by this endpoint.
    Application.put_env(:spacetraders, API, base_url: "http://127.0.0.1:#{port}/v2")
    Application.put_env(:spacetraders, RateLimiter, enabled: true)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, CapacityGovernor)
    start_supervised!({CapacityGovernor, probe_base_ms: 1_000})
    start_supervised!({RateLimiter, burst: 1, pool_burst: 0, rate: 2.0})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:spacetraders, key, value)
        {key, :error} -> Application.delete_env(:spacetraders, key)
      end)

      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, CapacityGovernor)
    end)

    %{agent: agent, revision: revision, store: store}
  end

  test "real 429 yields to a retained PG demand, then actual admission and finite tokens permit progress",
       ctx do
    subject = "agent:#{ctx.agent.symbol}"

    {:ok, demand} =
      Evidence.request_demand(ctx.agent, ctx.revision, %{
        subject: subject,
        required_facts: ["response"],
        freshness_seconds: 30,
        due_at: Clock.utc_now(),
        deadline_at: DateTime.add(Clock.utc_now(), 60),
        owner: "capacity_http_diagnostic"
      })

    assert {:error, _} = Evidence.get_agent(ctx.agent)
    assert count(ctx.store) == 1
    assert {:error, :evidence_pending} = Evidence.evidence_for_demand(demand)
    assert Enum.any?(Evidence.list_open_demands(ctx.agent), &(&1.id == demand.id))
    assert %{in_flight: 0, protocol_rejections: 1} = CapacityGovernor.diagnostics()

    TestClock.advance(1_999, :millisecond)
    assert {:error, :capacity_unavailable} = Evidence.get_agent(ctx.agent)
    assert count(ctx.store) == 1
    TestClock.advance(1, :millisecond)
    Agent.update(ctx.store, &%{&1 | mode: :clean})
    assert {:ok, %{credits: 100_000}} = Evidence.get_agent(ctx.agent)
    assert count(ctx.store) == 2
    refute Enum.any?(Evidence.list_open_demands(ctx.agent), &(&1.id == demand.id))
    assert {:ok, observation} = Evidence.evidence_for_demand(demand)
    assert DateTime.compare(observation.observed_at, Clock.utc_now()) == :eq
    # A second immediate read gets no free token, even after a clean response.
    assert {:error, :capacity_unavailable} = Evidence.get_agent(ctx.agent)
    assert count(ctx.store) == 2
  end

  test "sustained real HTTP outage uses bounded semantic probes, not Req wall sleeps", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :outage})
    assert {:error, :capacity_unavailable} = API.get_status()
    assert count(ctx.store) == 1
    assert {:error, :capacity_unavailable} = API.get_status()
    assert count(ctx.store) == 1
    TestClock.advance(1)
    assert {:error, :capacity_unavailable} = API.get_status()
    assert count(ctx.store) == 2
    TestClock.advance(1_999, :millisecond)
    assert {:error, :capacity_unavailable} = API.get_status()
    assert count(ctx.store) == 2
    TestClock.advance(1, :millisecond)
    Agent.update(ctx.store, &%{&1 | mode: :clean})
    assert {:ok, _} = API.get_status()
    assert count(ctx.store) == 3
  end

  test "no governor and no refill capacity each suppress real HTTP", ctx do
    stop_supervised!(CapacityGovernor)
    assert {:error, :capacity_unavailable} = API.get_status()
    assert count(ctx.store) == 0
    start_supervised!({CapacityGovernor, probe_base_ms: 1_000})
    stop_supervised!(RateLimiter)
    start_supervised!({RateLimiter, burst: 0, pool_burst: 0, rate: 0, pool_rate: 0})
    assert {:error, :capacity_unavailable} = API.get_status()
    assert count(ctx.store) == 0
    assert %{in_flight: 0, admitted_capacity: 2} = CapacityGovernor.diagnostics()
    assert TestClock.next_due_at() == nil

    assert %{status: :proceed} =
             CapacityGovernor.disposition(OperationInventory.fetch!("get-status"))

    # Advisory proceed did not bypass the still-empty protocol budget.
    assert {:error, :capacity_unavailable} = API.get_status()
    assert count(ctx.store) == 0
  end

  defp count(store), do: Agent.get(store, & &1.count)
end
