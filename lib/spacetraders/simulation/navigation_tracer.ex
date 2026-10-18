defmodule SpaceTraders.Simulation.NavigationTracer do
  @moduledoc """
  Bounded navigation-only coordinator over actual runtime owners and PG evidence.

  Coverage: synchronous Reconciler/ShipServer callbacks, DemandScheduler,
  ReadCoordinator and Outbox delivery, plus durable Arrival-owned intelligence
  roots. Other unfinished roots, timeline classes, participant death, unarmed
  durable work and unresolved mutations stop advancement. API governor/limiter
  keep their real wall pacing in this slice; no capacity-release acceleration.
  """
  alias SpaceTraders.Repo
  alias SpaceTraders.Simulation.NavigationClock

  def configuration(manifest) do
    base =
      SpaceTraders.Simulation.NativeBootstrap.configuration(
        Map.put(manifest, "schema", "native-bootstrap/v1")
      )

    base |> Keyword.put(:native_bootstrap, manifest) |> Keyword.put(:clock, NavigationClock)
  end

  def children do
    case Application.get_env(:spacetraders, :native_bootstrap) do
      %{"schema" => "navigation-tracer/v1", "initial_world" => %{"epoch_ms" => epoch}} ->
        [{NavigationClock, epoch: DateTime.from_unix!(epoch, :millisecond)}]

      _ ->
        []
    end
  end

  def prove(revision_id, deadline, manifest) do
    required = [
      SpaceTraders.FleetAllocation.Reconciler,
      SpaceTraders.Evidence.DemandScheduler,
      SpaceTraders.Evidence.ReadCoordinator,
      SpaceTraders.Outbox.Deliverer
    ]

    kinds = NavigationClock.snapshot().participants |> Map.values()
    unless Enum.all?(required, &(&1 in kinds)), do: raise("missing navigation participant")

    if manifest["negative_control"] == "incomplete_drain" do
      parent = self()

      {:ok, _pid} =
        Task.start_link(fn ->
          NavigationClock.register(self(), :negative_incomplete_drain)

          NavigationClock.work(fn ->
            send(parent, :negative_drain_started)
            receive do: (:stop -> :ok)
          end)
        end)

      receive do: (:negative_drain_started -> :ok)
    end

    loop(revision_id, deadline, manifest, 0)
  end

  defp loop(revision_id, deadline, manifest, steps) do
    ensure_deadline!(deadline)
    snapshot = drain!(min(deadline, System.monotonic_time(:millisecond) + 30_000))
    write_trace()

    case completed_chain(revision_id) do
      nil ->
        if steps >= 180, do: raise("navigation advancement bound")
        world = control!("inspect")
        epoch = manifest["initial_world"]["epoch_ms"]
        now = DateTime.to_unix(snapshot.now, :millisecond) - epoch
        true = now == world["current_time"] * 1000
        world_due = get_in(world, ["next_event", "due_time"])

        wake =
          snapshot.next_wake &&
            ceil((DateTime.to_unix(snapshot.next_wake, :millisecond) - epoch) / 1000)

        to = [world_due, wake, 180] |> Enum.reject(&is_nil/1) |> Enum.min()
        if to <= div(now, 1000) or to > 180, do: raise("no supported future navigation boundary")
        {:ok, lease} = NavigationClock.seal(snapshot.revision)
        settled = control!("advance", %{to_time: to, max_events: 256})

        :ok =
          NavigationClock.release(
            lease,
            DateTime.from_unix!(epoch + to * 1000, :millisecond),
            settled["settled_events"]
          )

        write_trace()
        loop(revision_id, deadline, manifest, steps + 1)

      chain ->
        export = control!("export")
        File.write!("/out/world-export.json", Jason.encode!(export))
        Map.put(chain, "advancements", steps)
    end
  end

  @doc "Supported closed-set barrier plus durable discovery; deadline is wall monotonic milliseconds."
  def drain!(deadline) do
    ensure_deadline!(deadline)
    before = NavigationClock.snapshot()
    if before.failed, do: raise("navigation participant coverage lost")

    # Delivery owns infrastructure notifications, not game selection. Flush its
    # durable backlog; then barrier consumers, repeating if callbacks spawned work.
    SpaceTraders.Outbox.dispatch_pending()

    participants_clear =
      Enum.all?(before.participants, fn {pid, _kind} -> barrier(pid, deadline) end)

    after_barriers = NavigationClock.snapshot()
    durable = durable_work(after_barriers)
    governor = SpaceTraders.API.CapacityGovernor.diagnostics()

    clear =
      participants_clear and durable == :clear and not is_nil(governor) and
        governor.in_flight == 0 and governor.deferred == %{}

    if clear and before.revision == after_barriers.revision and
         map_size(after_barriers.active) == 0 and map_size(after_barriers.released) == 0 do
      after_barriers
    else
      # A bounded wall retry, never itself evidence of quiescence.
      Process.sleep(5)
      drain!(deadline)
    end
  end

  defp barrier(pid, deadline) do
    reply =
      GenServer.call(
        pid,
        :simulation_barrier,
        max(1, deadline - System.monotonic_time(:millisecond))
      )

    reply.unresolved == 0
  catch
    :exit, _ -> raise("incomplete navigation participant barrier")
  end

  defp durable_work(snapshot) do
    %{rows: events} =
      Repo.query!(
        "SELECT id, owner_type, owner_id, event_type, due_at, payload->>'intent_id' FROM timeline_events WHERE status = 'pending'"
      )

    %{rows: roots} =
      Repo.query!(
        "SELECT id, type, status FROM intents WHERE status IN ('active','waiting','awaiting_confirmation','blocked')"
      )

    %{rows: [[unresolved]]} =
      Repo.query!(
        "SELECT count(*) FROM mutation_attempts WHERE state NOT IN ('succeeded','accepted','rejected','absent')"
      )

    %{rows: [[undelivered]]} =
      Repo.query!("SELECT count(*) FROM outbox_notifications WHERE delivered_at IS NULL")

    supported =
      Enum.all?(events, fn [id, owner, _symbol, kind, at, _root] ->
        owner == "ship" and kind == "arrival" and DateTime.compare(utc(at), snapshot.now) == :gt and
          id in snapshot.timeline_ids
      end)

    owned =
      Enum.all?(roots, fn [id, type, status] ->
        type == "acquire_intelligence" and status == "waiting" and
          Enum.any?(events, fn [_, _, _, _, _, root] -> root == to_string(id) end)
      end)

    if supported and owned and unresolved == 0 and undelivered == 0,
      do: :clear,
      else: :unclassified
  end

  defp completed_chain(revision_id) do
    %{columns: columns, rows: rows} =
      Repo.query!(
        """
        SELECT e.id AS episode_id, p.id AS portfolio_id, c.id AS commitment_id,
               i.id AS intent_id, i.type AS intent_type, i.target_waypoint,
               i.status AS intent_status, s.symbol AS ship_symbol,
               a.id::text AS mutation_attempt_id, a.operation_id, a.state AS mutation_state,
               t.id AS arrival_id, t.due_at AS arrival_due_at,
               i.finished_at AS continued_at, o.id::text AS continuation_observation_id,
               o.observed_at AS continuation_observed_at, o.subject AS continuation_subject,
               (SELECT count(*) FROM authoritative_observations) AS observation_count
        FROM strategy_decision_episodes e
        JOIN fleet_commitment_portfolios p ON p.strategy_decision_episode_id = e.id
        JOIN fleet_commitments c ON c.fleet_commitment_portfolio_id = p.id
        JOIN intents i ON i.fleet_commitment_id = c.id
        JOIN ships s ON s.id = i.ship_id
        JOIN mutation_attempts a ON a.provenance->>'intent_id' = i.id::text AND a.agent_id = s.agent_id
        JOIN timeline_events t ON t.payload->>'intent_id' = i.id::text
        JOIN authoritative_observations o ON o.agent_id = s.agent_id
          AND o.operation_id = 'get-market'
          AND o.subject = 'market:' || (i.parameters->>'system') || ':' || i.target_waypoint
          AND o.observed_at >= t.due_at
        WHERE e.fleet_strategy_revision_id = $1 AND e.selection_kind = 'selected_plan'
          AND a.operation_id = 'navigate-ship' AND a.state IN ('succeeded','accepted')
          AND t.event_type = 'arrival' AND t.status = 'done' AND i.status = 'completed'
        ORDER BY i.id LIMIT 1
        """,
        [revision_id]
      )

    case rows do
      [row] -> Enum.zip(columns, row) |> Map.new(fn {key, value} -> {key, utc(value)} end)
      [] -> nil
    end
  end

  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(value), do: value

  defp control!(suffix, body \\ nil) do
    count = Process.get(:navigation_control_requests, 0) + 1
    if count > 500, do: raise("navigation control request bound")
    Process.put(:navigation_control_requests, count)
    token = File.read!("/out/world-controller") |> String.trim()

    opts = [
      url: "http://127.0.0.1:4000/_control/world/" <> suffix,
      headers: [{"authorization", "Bearer " <> token}],
      retry: false,
      receive_timeout: 3_000,
      connect_options: [timeout: 3_000]
    ]

    response = if body, do: Req.post!(opts ++ [json: body]), else: Req.get!(opts)
    if response.status != 200, do: raise("world control rejected")
    Map.fetch!(response.body, "data")
  end

  defp ensure_deadline!(deadline) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: raise("incomplete navigation drain or wall deadline")
  end

  defp write_trace do
    File.write!("/out/time-trace.json.new", Jason.encode!(NavigationClock.trace()))
    File.rename!("/out/time-trace.json.new", "/out/time-trace.json")
  end

  def retain_failure do
    snapshot = NavigationClock.snapshot()
    write_trace()

    File.write!(
      "/out/drain-failure.json",
      Jason.encode!(%{
        semantic_at: snapshot.now,
        active: map_size(snapshot.active),
        released_unacknowledged: map_size(snapshot.released),
        coverage_lost: not is_nil(snapshot.failed),
        disposition: "incomplete_drain_no_further_advancement"
      })
    )

    File.write!("/out/world-export.json", Jason.encode!(control!("export")))
  end
end
