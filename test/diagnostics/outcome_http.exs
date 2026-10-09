defmodule SpaceTradersWeb.OutcomeHTTPDiagnostic do
  # Explicit native adapter proof. Ordinary discovery remains socket-free.
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import SpaceTraders.AgentFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Evidence, Fleet, Intelligence, Outcomes, Quiesced, Repo}

  @endpoint SpaceTradersWeb.Endpoint
  @projection [:spacetraders, :outcome, :fleet, :projection]

  setup do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, Outcomes)
    on_exit(fn -> {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, Outcomes) end)
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_PROBE")

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Quiesced.stop_ship(ship.symbol)
        Repo.delete_all(from o in Evidence.Observation, where: o.agent_id == ^agent.id)
        Repo.delete_all(from d in Evidence.ObservationDemand, where: d.agent_id == ^agent.id)
        Repo.delete!(operator)
      end)

      :ok = Sandbox.mode(Repo, :manual)
    end)

    server =
      start_supervised!(
        {Bandit, plug: @endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{agent: agent, url: "http://127.0.0.1:#{port}/metrics"}
  end

  test "native Bandit sends all outcome families from the one worker without adapter ownership errors",
       %{
         agent: agent,
         url: url
       } do
    events = [
      [:spacetraders, :outcome, :agent],
      [:spacetraders, :outcome, :contracts],
      [:spacetraders, :outcome, :transaction],
      @projection,
      [:spacetraders, :outcome, :chart],
      [:spacetraders, :outcome, :scan]
    ]

    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler, events, &__MODULE__.capture_publisher/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    owner = start_worker()
    assert Process.whereis(SpaceTraders.Outcomes.Fleet) == nil
    assert_receive {:published, @projection, ^owner}, 2_000

    stub_owned_reads(agent, 100)
    assert {:ok, _} = Evidence.get_agent(agent)
    stub_owned_reads(agent, 80)
    assert {:ok, _} = Evidence.get_agent(agent)
    assert {:ok, []} = Evidence.get_contracts(agent)
    Outcomes.transaction("navigate", "refuel", 17)

    assert {:ok, _} =
             Intelligence.observe_waypoint(
               agent,
               %{symbol: "X1-HTTP-A1", system_symbol: "X1-HTTP", x: 1, y: 2, traits: []},
               source: "scan_waypoints"
             )

    assert_receive {:charted, 1}, 2_000
    for event <- events, do: assert_receive({:published, ^event, ^owner}, 2_000)

    log =
      capture_log(fn ->
        body = scrape(url)

        assert body =~
                 ~s(spacetraders_outcome_ships_total{claim="free",intent_state="",nav_status=""} 1\n)

        assert body =~ "spacetraders_outcome_agent_credits 80\n"
        assert body =~ "spacetraders_outcome_agent_credits_previous 100\n"
        assert body =~ ~s(spacetraders_outcome_contracts{status="active"} 0\n)
        assert body =~ "spacetraders_outcome_systems_charted 1\n"

        assert body =~
                 ~s(spacetraders_outcome_credits_transactions_total{intent_type="navigate",operation="refuel"})

        assert body =~ "spacetraders_outcome_waypoints_scanned_total "

        for family <- ~w(credits contracts transactions fleet chart),
            do: assert(body =~ ~s(spacetraders_outcome_observed_at_seconds{family="#{family}"}))

        current =
          metric_value(body, ~s(spacetraders_outcome_observed_at_seconds{family="credits"}))

        previous =
          metric_value(body, "spacetraders_outcome_agent_credits_previous_observed_at_seconds")

        assert current > previous
        assert previous > 0
      end)

    refute log =~ "Adapter functions must be called by stream owner"
  end

  test "native HTTP waits for a paused vector publication before returning coherent bytes", %{
    agent: agent,
    url: url
  } do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @projection, &__MODULE__.capture_publisher/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    owner = start_worker()
    for _ <- 1..4, do: assert_receive({:published, @projection, ^owner}, 2_000)

    pause = {__MODULE__, :pause, make_ref()}

    :ok =
      :telemetry.attach(
        pause,
        [:spacetraders, :outcome, :fleet, :ships],
        &__MODULE__.pause_vector/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(pause) end)

    assert {:ok, _} = Fleet.register_ship(agent, %{symbol: "#{agent.symbol}-2"}, "SHIP_PROBE")
    assert_receive {:vector_paused, ^owner}, 2_000
    parent = self()

    scrape =
      Task.async(fn ->
        send(parent, :scrape_started)
        scrape(url)
      end)

    assert_receive :scrape_started
    partial = Task.yield(scrape, 100)
    send(owner, :resume_vector)
    body = if partial, do: elem(partial, 1), else: Task.await(scrape)
    assert is_nil(partial), "native HTTP exposed a partially rewritten vector"

    assert body =~
             ~s(spacetraders_outcome_ships_total{claim="free",intent_state="",nav_status=""} 2\n)

    assert body =~
             ~s(spacetraders_outcome_ships_total{claim="claimed",intent_state="",nav_status=""} 0\n)
  end

  def capture_publisher(
        [:spacetraders, :outcome, :chart] = event,
        %{count: count},
        _metadata,
        pid
      ) do
    send(pid, {:published, event, self()})
    send(pid, {:charted, count})
  end

  def capture_publisher(event, _measurements, _metadata, pid),
    do: send(pid, {:published, event, self()})

  def pause_vector(_event, %{count: 2}, %{claim: "free"}, parent) do
    send(parent, {:vector_paused, self()})

    receive do
      :resume_vector -> :ok
    after
      5_000 -> raise "publisher not released"
    end
  end

  def pause_vector(_event, _measurements, _metadata, _parent), do: :ok

  defp start_worker do
    start_supervised!(Quiesced.child_spec({Outcomes, db_projections: true, coalesce_ms: 30}))
    Process.whereis(Outcomes)
  end

  defp stub_owned_reads(agent, credits) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})

        "/v2/my/contracts" ->
          Req.Test.json(conn, %{"data" => []})

        path ->
          flunk("Unexpected owned read #{path}")
      end
    end)
  end

  defp scrape(url) do
    response = Req.get!(url, retry: false)
    assert response.status == 200
    response.body
  end

  defp metric_value(body, series) do
    assert [_, value] = Regex.run(~r/^#{Regex.escape(series)} ([^\n]+)$/m, body)
    assert {value, ""} = Float.parse(value)
    value
  end
end
