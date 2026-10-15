defmodule SpaceTraders.FleetAllocation.Acquisition do
  @moduledoc "Allocation-owned, surplus-first Capacity Investment decision after Market work."

  import Ecto.Query

  alias SpaceTraders.{
    Agent,
    Clock,
    CreditCalibration,
    Evidence,
    Fleet,
    FleetAcquisition,
    FleetAllocation,
    FleetCapacity,
    FleetPlanning,
    GenerationHorizon,
    Repo,
    World
  }

  alias SpaceTraders.FleetAllocation.{JsonEvidence, StrategyDecisionEpisode, TradeProgress}
  alias SpaceTraders.FleetStrategy.StandingAuthority

  def reconcile(scope, agent, revision, system, capacity) do
    # Recovery is not a new investment decision. It must survive a changed
    # Revision, Stop, missing horizon or a governor deferral.
    open = FleetAcquisition.open_purchase(agent)
    if open, do: FleetAcquisition.reconcile(scope, agent)

    with {:ok, generation} <- FleetAllocation.authorize_current(scope, agent, revision) do
      now = Clock.utc_now()
      work = FleetAllocation.ship_bound_unmet_work(agent, now)

      cond do
        open ->
          refuse(agent, revision, generation, :acquisition_already_unsettled, [], work)

        work == [] ->
          refuse(agent, revision, generation, :no_claim_only_loser, [], work)

        not enabled_work_proceeds?(capacity, work) ->
          refuse(agent, revision, generation, :capacity_not_proceed, [], work)

        true ->
          plan_and_publish(scope, agent, revision, generation, system, now, work)
      end
    end
  end

  defp enabled_work_proceeds?(nil, work) do
    attrs = %{
      strategic_priority: Enum.min_by(work, & &1.objective_index).objective_index,
      expected_value:
        Enum.max(Enum.map(work, &(&1.expected_outcomes["maximum_credit_change"] || 0)))
    }

    operations = ["get-market", "navigate-ship", "purchase-cargo", "sell-cargo"]

    fuel? =
      Enum.any?(work, fn work ->
        Enum.any?(
          get_in(work.expected_outcomes, ["planned_rate_evidence", "profiles"]) || [],
          &(get_in(&1, ["fuel", "capacity"]) > 0)
        )
      end)

    operations = if fuel?, do: operations ++ ["refuel-ship"], else: operations
    Enum.all?(operations, &FleetCapacity.proceed?(FleetCapacity.disposition(&1, attrs)))
  end

  defp enabled_work_proceeds?(capacity, _work), do: FleetCapacity.proceed?(capacity)

  defp plan_and_publish(scope, agent, revision, generation, system, now, work) do
    with :ok <- SpaceTraders.FleetStrategy.mutation_allowed?(),
         {:ok, floor} <- StandingAuthority.credit_floor(revision),
         {:ok, overview} <- Agent.agent_overview(agent),
         {:ok, ships} <- Fleet.list_ships(agent) do
      portfolio = FleetAllocation.current_portfolio(scope, agent)

      retained =
        if(portfolio, do: portfolio.commitments, else: []) ++
          FleetAllocation.settling_commitments(generation.id)

      surplus =
        max(
          overview.credits - floor - Enum.sum_by(retained, &(&1.reservations["credits"] || 0)),
          0
        )

      world = World.projections(agent, system, now, 300)
      ships = co_located(ships)
      shipyards = shipyards(world.waypoints, system)
      {horizon, read_at} = investment_horizon(agent, generation, now, ships, shipyards, surplus)
      now = Clock.utc_now()

      snapshot = %{
        as_of: now,
        credits: surplus,
        credit_margin_percent: CreditCalibration.active().margin_percent,
        ships: ships,
        shipyards: shipyards,
        unmet_work: work,
        generation_horizon: horizon,
        realized_trade_progress: TradeProgress.for_generation(generation.id),
        waypoint_coordinates: world.waypoint_coordinates,
        fuel_stops: world.fuel_stops
      }

      plans =
        for {_, index} <- Enum.with_index(revision.document["objectives"]),
            {:ok, plan} <- [FleetPlanning.plan_ship_acquisition(revision, index, snapshot)],
            do: {index, plan}

      candidates = Enum.flat_map(plans, fn {_, plan} -> plan.candidate_contributions end)
      limitations = Enum.flat_map(plans, fn {_, plan} -> plan.limitations end)

      case FleetAllocation.select_portfolio(revision, candidates, %{
             as_of: now,
             source_version: generation.allocation_version,
             claims: [],
             # The common selector protects the floor itself; planning consumes the
             # already net surplus, selection receives the same balance before floor.
             reservations: %{credits: surplus + floor}
           }) do
        {:ok, %{commitments: [chosen | _]} = selection} ->
          candidate = Enum.find(candidates, &(&1.id == chosen.candidate_id))

          rejected =
            selection.rejected ++
              Enum.map(limitations, &limitation/1) ++
              for other <- candidates,
                  other.id != candidate.id,
                  do: %{
                    candidate_id: other.id,
                    reasons: [:at_most_one_acquisition],
                    alternative: other
                  }

          selection = %{selection | commitments: [chosen], rejected: rejected}

          decision = %{
            evidence_references: candidate.dependencies,
            calibration_version: candidate.expected_outcomes.valuation.calibration.version,
            expectations:
              Map.merge(candidate.expected_outcomes, %{
                domain: "ship_acquisition",
                candidate: candidate,
                limitations: limitations,
                alternatives: candidate.alternatives,
                readiness: candidate.ship.readiness,
                ship_type: candidate.ship.type,
                preparation_credits: candidate.ship.preparation_credits
              })
          }

          case FleetAllocation.replan_subgraph(
                 scope,
                 generation.id,
                 selection,
                 [chosen.candidate_id],
                 decision
               ) do
            {:ok, published} ->
              commitment =
                Enum.find(published.commitments, &(&1.candidate_id == chosen.candidate_id))

              FleetAcquisition.execute(agent, published, commitment, candidate)

            {:error, reason} ->
              FleetAllocation.record_publication_rejection(
                scope,
                generation.id,
                selection,
                decision,
                reason
              )
          end

        {:ok, _selection} ->
          reason = refusal_reason(candidates, plans, work)
          refuse(agent, revision, generation, reason, limitations, work, read_at)

        {:error, reason} ->
          refuse(agent, revision, generation, reason, limitations, work, read_at)
      end
    end
  end

  # Unselected offers lost at selection; otherwise the binding limitation is the
  # one from an objective that owns the unmet work, not an unrelated objective.
  defp refusal_reason([_ | _], _plans, _work), do: :insufficient_surplus

  defp refusal_reason([], plans, work) do
    owning = MapSet.new(work, & &1.objective_index)

    owned =
      for {index, plan} <- plans,
          MapSet.member?(owning, index),
          limit <- plan.limitations,
          do: limit.reason

    other = for {_, plan} <- plans, limit <- plan.limitations, do: limit.reason
    List.first(owned ++ other, :insufficient_surplus)
  end

  # Read only at an otherwise eligible investment boundary. A failed or unusable
  # schedule stays unknown; the refusal records the read so retries stay within
  # the owned-read freshness window rather than one GET per Market announcement.
  defp investment_horizon(agent, generation, now, ships, shipyards, surplus) do
    horizon = GenerationHorizon.current(agent, now)

    eligible? =
      surplus > 0 and
        Enum.any?(shipyards, fn yard ->
          yard.ships != [] and Enum.any?(ships, &(&1.waypoint == yard.waypoint))
        end)

    recent_read? =
      case horizon_read_at(latest_refusal(generation.id)) do
        %DateTime{} = read_at ->
          DateTime.diff(now, read_at, :second) < Evidence.owned_read_freshness_seconds()

        nil ->
          false
      end

    if horizon.status == :unknown and eligible? and not recent_read? and
         FleetCapacity.proceed?(FleetCapacity.disposition("get-status")) do
      case Evidence.get_status_binding(agent, owner: "fleet_acquisition") do
        {:ok, _binding} -> {GenerationHorizon.current(agent, Clock.utc_now()), now}
        _ -> {horizon, now}
      end
    else
      {horizon, nil}
    end
  end

  # An unchanged refusal (same Revision and reason) is one Episode refreshed in
  # place, as a structural stall is (ADR 0012); a changed one opens a successor.
  defp refuse(agent, revision, generation, reason, limitations, work, read_at \\ nil) do
    now = Clock.utc_now()
    latest = latest_refusal(generation.id)

    equivalent? =
      latest != nil and latest.fleet_strategy_revision_id == revision.id and
        latest.rejection_reason == to_string(reason)

    read_at = read_at || if(equivalent?, do: horizon_read_at(latest))

    evidence = %{
      source_version: generation.allocation_version,
      alternatives: JsonEvidence.dump(Enum.map(limitations, &limitation/1)),
      expectations:
        JsonEvidence.dump(%{
          domain: "ship_acquisition",
          limitations: limitations,
          considered_work: work,
          calibration: SpaceTraders.ShipAcquisitionCalibration.current(),
          horizon_read_at: read_at
        }),
      last_observed_at: now
    }

    if equivalent? do
      latest
      |> Ecto.Changeset.change(
        Map.put(evidence, :observation_count, (latest.observation_count || 1) + 1)
      )
      |> Repo.update!()
    else
      Repo.insert!(
        struct!(
          StrategyDecisionEpisode,
          Map.merge(evidence, %{
            operator_id: agent.operator_id,
            fleet_generation_id: generation.id,
            fleet_strategy_revision_id: revision.id,
            selection_kind: :acquisition_refused,
            rejection_reason: to_string(reason),
            calibration_version: "ship-acquisition-v2",
            classification: :superseded,
            observation_count: 1
          })
        )
      )
    end
  end

  defp latest_refusal(generation_id) do
    Repo.one(
      from e in StrategyDecisionEpisode,
        where:
          e.fleet_generation_id == ^generation_id and e.selection_kind == :acquisition_refused,
        order_by: [desc: e.id],
        limit: 1
    )
  end

  defp horizon_read_at(%StrategyDecisionEpisode{expectations: %{"horizon_read_at" => at}})
       when is_binary(at) do
    {:ok, read_at, _} = DateTime.from_iso8601(at)
    read_at
  end

  defp horizon_read_at(_episode), do: nil

  defp limitation(value), do: %{reasons: [value.reason], alternative: value}

  defp co_located(ships) do
    for ship <- ships,
        ship.nav && ship.nav.status in ["DOCKED", "IN_ORBIT"],
        do: %{symbol: ship.symbol, waypoint: ship.nav.waypoint_symbol}
  end

  defp shipyards(waypoints, system) do
    for waypoint <- waypoints,
        %{
          state: "known",
          freshness: :fresh,
          value: offers,
          observed_at: observed,
          observation_id: id
        } <- [waypoint.shipyard.facts["ships"]],
        is_list(offers) do
      fee =
        case waypoint.shipyard.facts["modifications_fee"] do
          %{state: "known", freshness: :fresh, value: fee} -> fee
          _ -> nil
        end

      %{
        system_symbol: system,
        waypoint: waypoint.symbol,
        ships: offers,
        observed_at: observed,
        evidence_id: "intelligence-observation:#{id}",
        modifications_fee: fee
      }
    end
  end
end
