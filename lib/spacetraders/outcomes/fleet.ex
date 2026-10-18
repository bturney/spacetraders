defmodule SpaceTraders.Outcomes.Fleet do
  @moduledoc """
  DB projection functions run by the single Outcomes worker.

  Every projection publishes its entire bounded vector, including zeroes.
  `fleet_ships{status,ship_type}` counts the current Ships of non-stale Agents
  by their one status (`MissionControl.ShipStatus`) and Ship type: every status
  for every Ship type present now or published before, so a complete vector
  always clears previously nonzero counts.

  Chart coverage counts distinct Systems with a known, non-invalidated Waypoint
  identity fact from a `scan_waypoints` Intelligence observation for a non-stale
  Agent. Cached coordinates, public Waypoint reads/listings, unknown facts and
  unavailable facts do not establish scanned coverage. Repeated scans of the
  same System do not increase this gauge; a Server Reset clears its old coverage.

  Boot reconstructs all vectors from the DB, including chart's deployment-time
  baseline. Successful durable lifecycle writes enqueue bounded family names
  and scan-event counts only after their outer transaction commits.
  Events within the default 2000 ms window share one recompute per dirty
  family, with a fixed number of queries whatever the Fleet size. Errors log and
  drop; the next real change or worker boot can reconstruct again. There is no
  periodic recompute and no game API access. Each family's freshness is the
  epoch of its latest successful recompute, fixed during idle.

  `waypoints_scanned_total` counts committed per-Waypoint Intelligence observations
  with source `scan_waypoints`, not scan HTTP requests, unique Waypoints, or fields.
  A scan response containing N retained Waypoints adds N; observing a previously
  scanned Waypoint adds another event. Bursts sum their events without coalescing
  them away. Boot never backfills this counter or invents a zero history; metrics
  history starts at instrumentation. Events still count if chart recompute fails.
  """
  require Logger

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.MissionControl.ShipStatus
  alias SpaceTraders.Repo

  @families [:status, :chart]
  @coalesce_ms 2_000
  @ships """
  SELECT s.id FROM ships s
  JOIN agents a ON a.id = s.agent_id WHERE a.stale_at IS NULL AND s.retired_at IS NULL
  """
  @doc false
  def init(opts) do
    Process.send_after(self(), :recompute, Keyword.get(opts, :coalesce_ms, @coalesce_ms))

    %{
      dirty: MapSet.new(@families),
      scans: 0,
      ship_types: MapSet.new(),
      coalesce_ms: Keyword.get(opts, :coalesce_ms, @coalesce_ms),
      repo: Keyword.get(opts, :repo, Repo)
    }
  end

  @doc false
  def dirty(change, state) do
    if MapSet.size(state.dirty) == 0,
      do: Process.send_after(self(), :recompute, state.coalesce_ms)

    %{
      state
      | dirty: MapSet.union(state.dirty, change.families),
        scans: state.scans + change.scans
    }
  end

  @doc false
  def recompute(state) do
    publish_scans(state.scans)

    ship_types =
      Enum.reduce(state.dirty, state.ship_types, fn
        :status, types -> project_status(state.repo, types)
        :chart, types -> project_chart(state.repo) && types
      end)

    %{state | dirty: MapSet.new(), scans: 0, ship_types: ship_types}
  end

  defp publish_scans(0), do: :ok

  defp publish_scans(count) do
    :telemetry.execute([:spacetraders, :outcome, :scan], %{count: count}, %{})
  rescue
    _ -> Logger.error("Chart outcome scan emission failed; dropping events")
  catch
    _, _ -> Logger.error("Chart outcome scan emission failed; dropping events")
  end

  defp project_chart(repo) do
    [[count]] = repo.query!(chart_query()).rows
    :telemetry.execute([:spacetraders, :outcome, :chart], %{count: count}, %{})
    observed("chart")

    :telemetry.execute(
      [:spacetraders, :outcome, :fleet, :projection],
      %{counts: %{"systems_charted" => count}, recomputes: 1},
      %{family: :chart}
    )
  rescue
    _ -> drop(:chart)
  catch
    _, _ -> drop(:chart)
  end

  defp project_status(repo, published_types) do
    ships = ships(repo)
    now = SpaceTraders.Clock.utc_now()

    statuses =
      ships
      |> Enum.group_by(& &1.agent_id)
      |> Enum.flat_map(fn {agent_id, ships} ->
        %AgentRecord{id: agent_id} |> ShipStatus.for_ships(ships, now) |> Map.to_list()
      end)
      |> Map.new()

    present = Enum.frequencies_by(ships, &{statuses[&1.id].status, &1.ship_type})
    types = MapSet.union(published_types, MapSet.new(ships, & &1.ship_type))

    for type <- types, status <- ShipStatus.statuses() do
      :telemetry.execute(
        [:fleet, :ships],
        %{count: Map.get(present, {status, type}, 0)},
        %{status: ShipStatus.metric_label(status), ship_type: type}
      )
    end

    observed("fleet")

    counts =
      Map.new(ShipStatus.statuses(), fn status ->
        {ShipStatus.metric_label(status), Enum.sum(for {{^status, _}, n} <- present, do: n)}
      end)

    :telemetry.execute(
      [:spacetraders, :outcome, :fleet, :projection],
      %{counts: counts, recomputes: 1},
      %{family: :status}
    )

    types
  rescue
    _ ->
      drop(:status)
      published_types
  catch
    _, _ ->
      drop(:status)
      published_types
  end

  # The scope reads through the projection repo; the statuses through the app's.
  defp ships(repo) do
    ids = for [id] <- repo.query!(@ships).rows, do: id
    Repo.all(from s in Ship, where: s.id in ^ids)
  end

  defp drop(family) do
    Logger.error("Fleet outcome projection failed; dropping recompute", family: family)

    :telemetry.execute([:spacetraders, :outcome, :fleet, :projection_failed], %{count: 1}, %{
      family: family
    })
  end

  defp observed(family) do
    :telemetry.execute(
      [:spacetraders, :outcome, :observed],
      %{
        observed_at_seconds:
          DateTime.to_unix(SpaceTraders.Clock.utc_now(), :microsecond) / 1_000_000
      },
      %{family: family}
    )
  end

  defp chart_query do
    """
    SELECT count(DISTINCT f.subject_system_symbol)
    FROM intelligence_facts f
    JOIN intelligence_observations o ON o.id = f.observation_id
    JOIN agents a ON a.id = f.agent_id
    WHERE f.subject_type = 'waypoint' AND f.field = 'symbol'
      AND f.state = 'known' AND f.invalidated_at IS NULL
      AND o.source = 'scan_waypoints' AND a.stale_at IS NULL
    """
  end
end
