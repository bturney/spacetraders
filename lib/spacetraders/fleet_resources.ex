defmodule SpaceTraders.FleetResources do
  @moduledoc "Reconciles resource outcomes from an active Strategy Revision and game evidence."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.ShadowAdmission
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.{Repo, ShipReservation, World}

  import Ecto.Query

  @freshness_seconds 300

  @doc "Selects and dispatches a resource candidate, or returns why progress is deferred."
  def reconcile(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        system,
        capacity \\ ShadowAdmission.snapshot()
      ) do
    with index when is_integer(index) <- objective_index(revision),
         :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         %{available_slots: slots, backpressure: pressure} <- capacity,
         true <- slots > 0 and pressure != :sustained,
         true <- Intents.current(agent) == [],
         {:ok, ships} <- Fleet.list_ships(agent),
         ships <- Enum.reject(ships, &(&1.symbol in ShipReservation.reserved_symbols(agent.id))),
         {:ok, overview} <- SpaceTraders.Agent.agent_overview(agent),
         {:ok, floor} <- StandingAuthority.credit_floor(revision),
         true <- overview.credits >= floor,
         {:ok, _authorization} <-
           StandingAuthority.authorize(revision, %{
             revision_id: revision.id,
             evidence_id: Evidence.fingerprint({agent.id, overview.credits}),
             observed_at: DateTime.utc_now(),
             bounds: %{minimum_credits: overview.credits, scraps_ship: false}
           }),
         %Generation{fleet_strategy_revision_id: revision_id} = generation <-
           Repo.one(
             from g in Generation,
               where:
                 g.agent_id == ^agent.id and
                   is_nil(g.fenced_at) and is_nil(g.retired_at)
           ),
         true <- revision_id == revision.id,
         as_of = DateTime.utc_now(),
         :ok <- refresh_local_waypoints(agent, system, ships, as_of),
         waypoints = discover_resource_waypoints(agent, revision, system, as_of),
         {:ok, %{candidate_contributions: [_ | _] = candidates}} <-
           FleetPlanning.plan_resources(revision, index, %{
             as_of: as_of,
             ships: ships,
             waypoints: waypoints,
             freshness_seconds: @freshness_seconds
           }),
         {:ok, selected} <-
           FleetAllocation.select_portfolio(revision, candidates, %{
             as_of: as_of,
             claims: Enum.map(ships, &claim/1),
             reservations: %{credits: overview.credits}
           }),
         [commitment | _] <- selected.commitments,
         candidate <- Enum.find(candidates, &(&1.id == commitment.candidate_id)),
         true <- not is_nil(candidate),
         {:ok, portfolio} <-
           FleetAllocation.publish_portfolio(
             scope,
             generation.id,
             %{
               selected
               | commitments: [commitment],
                 source_version: generation.allocation_version
             },
             %{
               evidence_references:
                 Enum.map(
                   candidate.dependencies,
                   &%{"kind" => "waypoint", "id" => &1.evidence_id}
                 ),
               expectations: candidate.expected_outcomes,
               calibration_version: "resources-v1"
             }
           ),
         [persisted] <- portfolio.commitments,
         [ship_symbol] <- persisted.claims do
      Intents.request_commitment_resources(agent, persisted, portfolio, ship_symbol, candidate)
    else
      _ -> {:error, :resource_acquisition_unavailable}
    end
  end

  defp refresh_local_waypoints(agent, system, ships, as_of) do
    known = World.waypoints(agent, system, as_of, @freshness_seconds)

    Enum.each(ships, fn ship ->
      symbol = ship.nav && ship.nav.waypoint_symbol
      waypoint = Enum.find(known, &(&1.symbol == symbol))

      if is_binary(symbol) and ship.nav.system_symbol == system and
           (is_nil(waypoint) or get_in(waypoint, [:facts, "type", :freshness]) != :fresh) do
        case SpaceTraders.Agent.handle_game_result(
               agent,
               Evidence.get_waypoint(AgentTokenReference.new(agent), system, symbol,
                 owner: "fleet_planning",
                 required_facts: ["type"]
               )
             ) do
          {:ok, observed} ->
            Intelligence.observe_waypoint(agent, observed, source: "get_waypoint")

          _ ->
            :ok
        end
      end
    end)

    :ok
  end

  defp discover_resource_waypoints(agent, revision, system, as_of) do
    known = World.waypoints(agent, system, as_of, @freshness_seconds)

    if Enum.any?(known, &resource_waypoint?/1) do
      known
    else
      case SpaceTraders.Agent.handle_game_result(
             agent,
             Evidence.get_waypoints_paginated(AgentTokenReference.new(agent), system, [],
               owner: "fleet_planning",
               discovery: true,
               expected_value: 1.0,
               strategy_revision_id: revision.id,
               required_facts: ["waypoints"],
               freshness_seconds: @freshness_seconds
             )
           ) do
        {:ok, waypoints} ->
          Enum.each(waypoints, &Intelligence.observe_waypoint(agent, &1, source: "get_waypoints"))
          World.waypoints(agent, system, DateTime.utc_now(), @freshness_seconds)

        _ ->
          known
      end
    end
  end

  defp resource_waypoint?(%{facts: %{"type" => %{freshness: :fresh, value: type}}}),
    do: type in ["ASTEROID", "ENGINEERED_ASTEROID", "ASTEROID_FIELD", "DEBRIS_FIELD", "GAS_GIANT"]

  defp resource_waypoint?(_), do: false

  defp objective_index(%Revision{document: %{"objectives" => objectives}}) do
    objectives
    |> Enum.with_index()
    |> Enum.find_value(fn {objective, index} ->
      if Enum.any?([objective["objective"], objective["evaluation"]], fn text ->
           is_binary(text) and
             String.match?(
               text,
               ~r/\bextract\b|\bsiphon\b|\bmin(e|ing)\b|\brefin(e|ing)\b|\bresources?\b/i
             )
         end),
         do: index
    end)
  end

  defp claim(ship) do
    modes =
      [
        {:refine, ship.modules || [], "MODULE_MINERAL_PROCESSOR"},
        {:extract, ship.mounts || [], "MOUNT_MINING_LASER"},
        {:siphon, ship.mounts || [], "MOUNT_GAS_SIPHON"}
      ]
      |> Enum.flat_map(fn {mode, parts, prefix} ->
        if Enum.any?(parts, &String.starts_with?(&1.symbol, prefix)), do: [mode], else: []
      end)

    %{
      resource: ship.symbol,
      roles: [:resource_gatherer],
      capabilities: %{resource_ship: ship.symbol, resource_mode: modes}
    }
  end
end
