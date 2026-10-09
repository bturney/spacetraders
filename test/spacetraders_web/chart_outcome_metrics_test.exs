defmodule SpaceTradersWeb.ChartOutcomeMetricsTest do
  # The coalescing worker reads independently committed Intelligence facts.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import SpaceTraders.AgentFixtures
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Intelligence, Quiesced, Repo}
  alias SpaceTraders.Outcomes.Fleet, as: Worker

  @endpoint SpaceTradersWeb.Endpoint
  @projection [:spacetraders, :outcome, :fleet, :projection]
  @failure [:spacetraders, :outcome, :fleet, :projection_failed]
  @scan [:spacetraders, :outcome, :scan]

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    operator = operator_fixture()
    agent = agent_fixture(operator, %{agent_token: "chart-token-#{System.unique_integer()}"})
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [@projection, @failure, @scan],
        &__MODULE__.handle_event/4,
        self()
      )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      flunk("Chart projection called game: #{conn.request_path}")
    end)

    on_exit(fn ->
      :telemetry.detach(handler)
      Sandbox.unboxed_run(Repo, fn -> Repo.delete!(operator) end)
      SpaceTraders.FleetGenerationAdmission.clear()
      :ok = Sandbox.mode(Repo, :manual)
    end)

    %{agent: agent}
  end

  test "boot restores distinct Systems with durable scanned facts, not cached coordinates", %{
    agent: agent
  } do
    observe(agent, "X1-SCAN", "A1", "scan_waypoints")
    observe(agent, "X1-SCAN", "A1", "scan_waypoints")
    observe(agent, "X1-SCAN", "A2", "scan_waypoints")
    observe(agent, "X1-OTHER", "A1", "scan_waypoints")
    observe(agent, "X1-LIST", "A1", "get_waypoints")
    observe(agent, "X1-READ", "A1", "get_waypoint")

    # Explicitly unavailable observations are not scanned facts.
    assert {:ok, _} =
             Intelligence.mark_unavailable(
               agent,
               :waypoint,
               "X1-UNKNOWN",
               "X1-UNKNOWN-A1",
               [:symbol],
               source: "scan_waypoints"
             )

    before = System.system_time(:microsecond) / 1_000_000
    start_worker()
    assert_chart(2)
    refute_receive {:scans, _}, 100
    observed = metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"}))
    assert observed >= before
    refute_receive {:projection, :chart, _}, 150
    assert metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"})) == observed

    stop_supervised!(Worker)
    start_worker()
    assert_chart(2)
    refute_receive {:scans, _}, 100
  end

  test "scan observations coalesce chart writes without losing repeated waypoint events", %{
    agent: agent
  } do
    start_worker(coalesce_ms: 200)
    assert_chart(0)
    recomputes = metric_value(~s(spacetraders_outcome_fleet_recomputes_total{family="chart"}))
    previous_scans = metric_value("spacetraders_outcome_waypoints_scanned_total", 0)
    observed = metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"}))

    observe(agent, "X1-LIST", "A1", "get_waypoints")
    observe(agent, "X1-READ", "A1", "get_waypoint")

    assert {:ok, _} =
             Intelligence.observe_market(agent, "X1-READ", %{
               symbol: "X1-READ-A1",
               exports: [],
               imports: [],
               exchange: []
             })

    assert {:ok, _} = Intelligence.invalidate(agent, :market, "X1-READ", "X1-READ-A1")
    refute_receive {:scans, _}, 250
    refute_receive {:projection, :chart, _}, 100
    assert metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"})) == observed

    observe(agent, "X1-SCAN", "A1", "scan_waypoints")
    observe(agent, "X1-SCAN", "A1", "scan_waypoints")
    observe(agent, "X1-SCAN", "A2", "scan_waypoints")
    observe(agent, "X1-OTHER", "A1", "scan_waypoints")

    assert_chart(2)
    assert_receive {:scans, 4}
    assert metric_value("spacetraders_outcome_waypoints_scanned_total") == previous_scans + 4

    assert metric_value(~s(spacetraders_outcome_fleet_recomputes_total{family="chart"})) ==
             recomputes + 1

    assert metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"})) > observed
    refute_receive {:projection, :chart, _}, 250
    refute_receive {:scans, _}, 100
  end

  test "outer commit publishes scanned facts and events; rollback publishes neither", %{
    agent: agent
  } do
    start_worker()
    assert_chart(0)
    previous_scans = metric_value("spacetraders_outcome_waypoints_scanned_total", 0)
    observed = metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"}))
    parent = self()

    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          observe(agent, "X1-COMMIT", "A1", "scan_waypoints")
          send(parent, :scan_retained)

          receive do
            :commit -> :ok
          after
            5_000 -> Repo.rollback(:writer_not_released)
          end
        end)
      end)

    assert_receive :scan_retained
    refute_receive {:projection, :chart, _}, 150
    refute_receive {:scans, _}, 100
    assert metric_value("spacetraders_outcome_systems_charted") == 0
    assert metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"})) == observed
    send(writer.pid, :commit)
    assert {:ok, :ok} = Task.await(writer)
    assert_chart(1)
    assert_receive {:scans, 1}
    assert metric_value("spacetraders_outcome_waypoints_scanned_total") == previous_scans + 1

    assert {:error, :discard} =
             Repo.transaction(fn ->
               observe(agent, "X1-DISCARD", "A1", "scan_waypoints")
               Repo.rollback(:discard)
             end)

    refute_receive {:projection, :chart, _}, 150
    refute_receive {:scans, _}, 100
    assert metric_value("spacetraders_outcome_waypoints_scanned_total") == previous_scans + 1
    observe(agent, "X1-NEXT", "A1", "scan_waypoints")
    assert_chart(2)
    assert_receive {:scans, 1}
    assert metric_value("spacetraders_outcome_waypoints_scanned_total") == previous_scans + 2
  end

  test "Server Reset clears a previously nonzero chart gauge", %{agent: agent} do
    observe(agent, "X1-RESET", "A1", "scan_waypoints")
    start_worker()
    assert_chart(1)

    # A real owned Agent read supplies definitive reset evidence.
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/agent"

      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{
          "code" => 4113,
          "message" =>
            "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
        }
      })
    end)

    assert {:error, :stale_agent} = SpaceTraders.FleetGeneration.agent_overview(agent)
    assert_chart(0)
    refute_receive {:scans, _}, 100
  end

  defmodule UnavailableDatabase do
    def query!(_query), do: raise(DBConnection.ConnectionError, "chart database unavailable")
  end

  test "failed chart projection drops without blocking Intelligence or refreshing freshness", %{
    agent: agent
  } do
    start_worker()
    assert_chart(0)
    observed = metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"}))
    previous_scans = metric_value("spacetraders_outcome_waypoints_scanned_total", 0)
    stop_supervised!(Worker)

    log =
      capture_log(fn ->
        start_worker(repo: UnavailableDatabase)
        assert_receive {:projection_failed, :chart}, 2_000
        observe(agent, "X1-FAIL", "A1", "scan_waypoints")
        assert_receive {:scans, 1}, 2_000
        assert_receive {:projection_failed, :chart}, 2_000
        assert Process.alive?(Process.whereis(Worker))
        refute_receive {:projection, :chart, _}, 100
      end)

    assert log =~ "Fleet outcome projection failed; dropping recompute"
    assert metric_value(~s(spacetraders_outcome_observed_at_seconds{family="chart"})) == observed
    assert metric_value("spacetraders_outcome_waypoints_scanned_total") == previous_scans + 1
    stop_supervised!(Worker)
    start_worker()
    assert_chart(1)
    refute_receive {:scans, _}, 100
    assert metric_value("spacetraders_outcome_waypoints_scanned_total") == previous_scans + 1
  end

  test "production window waits a couple seconds before the DB baseline", %{agent: agent} do
    observe(agent, "X1-BOOT", "A1", "scan_waypoints")
    start_supervised!(Quiesced.child_spec({Worker, []}))
    refute_receive {:projection, :chart, _}, 1_500
    assert_chart(1)
    refute_receive {:scans, _}, 100
  end

  def handle_event(@projection, %{counts: counts}, %{family: :chart}, pid),
    do: send(pid, {:projection, :chart, counts})

  def handle_event(@failure, _measurements, %{family: family}, pid),
    do: send(pid, {:projection_failed, family})

  def handle_event(@scan, %{count: count}, _metadata, pid), do: send(pid, {:scans, count})

  def handle_event(_event, _measurements, _metadata, _pid), do: :ok

  defp start_worker(opts \\ []) do
    start_supervised!(Quiesced.child_spec({Worker, Keyword.merge([coalesce_ms: 30], opts)}))
  end

  defp observe(agent, system, suffix, source) do
    assert {:ok, observation} =
             Intelligence.observe_waypoint(
               agent,
               %{symbol: "#{system}-#{suffix}", system_symbol: system, x: 1, y: 2, traits: []},
               source: source
             )

    observation
  end

  defp assert_chart(expected) do
    assert_receive {:projection, :chart, %{"systems_charted" => ^expected}}, 2_000
    assert metric_value("spacetraders_outcome_systems_charted") == expected
  end

  defp metric_value(series, default \\ nil) do
    body = build_conn() |> get("/metrics") |> response(200)

    case Regex.run(~r/^#{Regex.escape(series)} ([^\n]+)$/m, body) do
      [_, value] ->
        {value, ""} = Float.parse(value)
        value

      nil ->
        assert not is_nil(default), "Missing metric #{series} in:\n#{body}"
        default
    end
  end
end
