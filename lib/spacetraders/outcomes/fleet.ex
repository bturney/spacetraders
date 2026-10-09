defmodule SpaceTraders.Outcomes.Fleet do
  @moduledoc """
  DB projection functions run by the single Outcomes worker.

  Every projection publishes its entire bounded vector, including zeroes. The
  independent dimensions share `ships_total`; unused dimension labels are empty.
  Sum only one dimension (for example `claim!=""`) to count Ships once.

  The scope is all registered Ships of non-stale Agents, without identity labels.
  Claim counts use current, unfenced, unreleased Fleet Commitment authority;
  Intent counts use each Ship's latest root lifecycle, including terminal states
  and `none`. Nav counts use the newest retained whole-Ship/Fleet read or
  successful recorded mutation nav fact; missing or unsupported facts are
  `unknown`. A complete vector always clears previously nonzero state counts.

  Chart coverage counts distinct Systems with a known, non-invalidated Waypoint
  identity fact from a `scan_waypoints` Intelligence observation for a non-stale
  Agent. Cached coordinates, public Waypoint reads/listings, unknown facts and
  unavailable facts do not establish scanned coverage. Repeated scans of the
  same System do not increase this gauge; a Server Reset clears its old coverage.

  Boot reconstructs all vectors from the DB, including chart's deployment-time
  baseline. Successful durable lifecycle writes enqueue bounded family names
  and scan-event counts only after their outer transaction commits.
  Events within the default 2000 ms window share one aggregate SQL query per dirty
  family. Errors log and drop; the next real change or worker boot can reconstruct
  again. There is no periodic recompute and no game API access. Each family's
  freshness is the epoch of its latest successful recompute, fixed during idle.

  `waypoints_scanned_total` counts committed per-Waypoint Intelligence observations
  with source `scan_waypoints`, not scan HTTP requests, unique Waypoints, or fields.
  A scan response containing N retained Waypoints adds N; observing a previously
  scanned Waypoint adds another event. Bursts sum their events without coalescing
  them away. Boot never backfills this counter or invents a zero history; metrics
  history starts at instrumentation. Events still count if chart recompute fails.
  """
  require Logger

  alias SpaceTraders.Repo
  alias SpaceTraders.Fleet.Intent

  @fleet_families [:claim, :intent_state, :nav_status]
  @families @fleet_families ++ [:chart]
  @coalesce_ms 2_000
  @states %{
    claim: ~w(claimed free),
    intent_state: ["none", "unknown"] ++ Intent.unfinished_states() ++ Intent.terminal_states(),
    nav_status: ~w(DOCKED IN_ORBIT IN_TRANSIT unknown)
  }
  @ships """
  SELECT s.id, s.symbol, s.agent_id FROM ships s
  JOIN agents a ON a.id = s.agent_id WHERE a.stale_at IS NULL
  """
  @doc false
  def init(opts) do
    Process.send_after(self(), :recompute, Keyword.get(opts, :coalesce_ms, @coalesce_ms))

    %{
      dirty: MapSet.new(@families),
      scans: 0,
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
    Enum.each(state.dirty, &project(&1, state.repo))
    %{state | dirty: MapSet.new(), scans: 0}
  end

  defp publish_scans(0), do: :ok

  defp publish_scans(count) do
    :telemetry.execute([:spacetraders, :outcome, :scan], %{count: count}, %{})
  rescue
    _ -> Logger.error("Chart outcome scan emission failed; dropping events")
  catch
    _, _ -> Logger.error("Chart outcome scan emission failed; dropping events")
  end

  defp project(:chart, repo) do
    [[count]] = repo.query!(query(:chart)).rows
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

  defp project(family, repo) do
    counts = Map.new(@states[family], &{&1, 0})

    counts =
      repo.query!(query(family)).rows
      |> Enum.reduce(counts, fn [label, count], counts ->
        label = if label in @states[family], do: label, else: "unknown"
        Map.update!(counts, label, &(&1 + count))
      end)

    Enum.each(counts, fn {label, count} ->
      metadata = %{claim: "", intent_state: "", nav_status: ""} |> Map.put(family, label)
      :telemetry.execute([:spacetraders, :outcome, :fleet, :ships], %{count: count}, metadata)
    end)

    observed("fleet")

    :telemetry.execute(
      [:spacetraders, :outcome, :fleet, :projection],
      %{counts: counts, recomputes: 1},
      %{family: family}
    )
  rescue
    _ -> drop(family)
  catch
    _, _ -> drop(family)
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

  defp query(:chart) do
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

  defp query(:claim) do
    """
    WITH ships AS (#{@ships})
    SELECT CASE WHEN EXISTS (
      SELECT 1 FROM fleet_commitment_claims c
      JOIN fleet_commitments k ON k.id = c.fleet_commitment_id
      JOIN fleet_commitment_portfolios p ON p.id = c.fleet_commitment_portfolio_id
      JOIN fleet_generations g ON g.id = p.fleet_generation_id
      WHERE c.resource = s.symbol AND g.agent_id = s.agent_id
        AND p.superseded_at IS NULL AND g.fenced_at IS NULL AND g.retired_at IS NULL
        AND k.unwind_state = 'not_required'
    ) THEN 'claimed' ELSE 'free' END, count(*)
    FROM ships s GROUP BY 1
    """
  end

  defp query(:intent_state) do
    """
    WITH ships AS (#{@ships}), latest AS (
      SELECT DISTINCT ON (i.ship_id) i.ship_id, i.status
      FROM intents i JOIN ships s ON s.id = i.ship_id
      ORDER BY i.ship_id, i.inserted_at DESC, i.id DESC
    )
    SELECT COALESCE(i.status, 'none'), count(*)
    FROM ships s LEFT JOIN latest i ON i.ship_id = s.id GROUP BY 1
    """
  end

  defp query(:nav_status) do
    """
    WITH ships AS (#{@ships}), latest_reads AS (
      SELECT DISTINCT ON (o.agent_id, o.subject)
        o.agent_id, o.subject, o.operation_id, o.facts, o.observed_at, o.id
      FROM authoritative_observations o
      WHERE o.operation_id IN ('get-my-ship', 'get-my-ships')
        AND o.agent_id IN (SELECT agent_id FROM ships)
      ORDER BY o.agent_id, o.subject, o.observed_at DESC, o.id DESC
    ), reads AS (
      SELECT s.id AS ship_id, o.facts #>> '{response,nav,status}' AS status,
        o.observed_at AS at, o.id::text AS tie
      FROM latest_reads o JOIN ships s ON s.agent_id = o.agent_id
        AND o.subject = 'ship:' || s.symbol AND o.operation_id = 'get-my-ship'
      UNION ALL
      SELECT s.id, item #>> '{nav,status}', o.observed_at, o.id::text
      FROM latest_reads o
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(o.facts->'response') = 'array' THEN o.facts->'response' ELSE '[]'::jsonb END
      ) item
      JOIN ships s ON s.agent_id = o.agent_id AND s.symbol = item->>'symbol'
      WHERE o.operation_id = 'get-my-ships'
    ), mutations AS (
      SELECT DISTINCT ON (s.id) s.id AS ship_id, o.evidence->>'nav_status' AS status,
        o.recorded_at AS at, o.id::text AS tie
      FROM mutation_attempt_outcomes o
      JOIN mutation_attempts m ON m.id = o.mutation_attempt_id
      JOIN ships s ON s.agent_id = m.agent_id AND s.symbol = m.provenance->>'ship_symbol'
      WHERE o.classification = 'succeeded' AND o.evidence->>'nav_status' IS NOT NULL
      ORDER BY s.id, o.recorded_at DESC, o.id DESC
    ), latest AS (
      SELECT DISTINCT ON (ship_id) ship_id, status
      FROM (SELECT * FROM reads UNION ALL SELECT * FROM mutations) facts
      ORDER BY ship_id, at DESC, tie DESC
    )
    SELECT COALESCE(n.status, 'unknown'), count(*)
    FROM ships s LEFT JOIN latest n ON n.ship_id = s.id GROUP BY 1
    """
  end
end
