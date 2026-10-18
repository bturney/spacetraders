defmodule SpaceTraders.Outcomes.Fleet do
  @moduledoc """
  DB projection functions run by the single Outcomes worker.

  Every projection publishes its entire bounded vector, including zeroes.
  `fleet_ships{status,ship_type}` counts the current Ships of non-stale Agents
  by their one status (`MissionControl.ShipStatus`) and Ship type: every status
  for every Ship type present now or published before, so a complete vector
  always clears previously nonzero counts.

  Boot reconstructs the vector from the DB. Successful durable lifecycle writes
  enqueue the bounded family name only after their outer transaction commits.
  Events within the default 2000 ms window share one recompute per dirty
  family, with a fixed number of queries whatever the Fleet size. Errors log and
  drop; the next real change or worker boot can reconstruct again. There is no
  periodic recompute and no game API access. Each family's freshness is the
  epoch of its latest successful recompute, fixed during idle.

  """
  require Logger

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.MissionControl.ShipStatus
  alias SpaceTraders.Repo

  @families [:status]
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
      ship_types: MapSet.new(),
      coalesce_ms: Keyword.get(opts, :coalesce_ms, @coalesce_ms),
      repo: Keyword.get(opts, :repo, Repo)
    }
  end

  @doc false
  def dirty(change, state) do
    if MapSet.size(state.dirty) == 0,
      do: Process.send_after(self(), :recompute, state.coalesce_ms)

    %{state | dirty: MapSet.union(state.dirty, change.families)}
  end

  @doc false
  def recompute(state) do
    ship_types =
      Enum.reduce(state.dirty, state.ship_types, fn
        :status, types -> project_status(state.repo, types)
      end)

    %{state | dirty: MapSet.new(), ship_types: ship_types}
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
end
