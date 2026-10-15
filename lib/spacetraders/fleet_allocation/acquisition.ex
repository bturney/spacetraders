defmodule SpaceTraders.FleetAllocation.Acquisition do
  @moduledoc "Allocation-owned, surplus-first Capacity Investment decision after Market work."

  alias SpaceTraders.{
    Agent,
    Clock,
    CreditCalibration,
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
    if open, do: FleetAcquisition.reconcile(scope, agent, revision, system)

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

      snapshot = %{
        as_of: now,
        credits: surplus,
        credit_margin_percent: CreditCalibration.active().margin_percent,
        ships: co_located(ships),
        shipyards: shipyards(world.waypoints, system),
        unmet_work: work,
        generation_horizon: GenerationHorizon.current(agent, now),
        realized_trade_progress: TradeProgress.for_generation(generation.id),
        waypoint_coordinates: world.waypoint_coordinates,
        fuel_stops: world.fuel_stops
      }

      plans =
        for {_, index} <- Enum.with_index(revision.document["objectives"]),
            {:ok, plan} <- [FleetPlanning.plan_ship_acquisition(revision, index, snapshot)],
            do: plan

      candidates = Enum.flat_map(plans, & &1.candidate_contributions)
      limitations = Enum.flat_map(plans, & &1.limitations)

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
          reason =
            case limitations do
              [%{reason: reason} | _] -> reason
              _ -> :insufficient_surplus
            end

          refuse(agent, revision, generation, reason, limitations, work)

        {:error, reason} ->
          refuse(agent, revision, generation, reason, limitations, work)
      end
    end
  end

  defp refuse(agent, revision, generation, reason, limitations, work) do
    Repo.insert!(%StrategyDecisionEpisode{
      operator_id: agent.operator_id,
      fleet_generation_id: generation.id,
      fleet_strategy_revision_id: revision.id,
      source_version: generation.allocation_version,
      selection_kind: :acquisition_refused,
      rejection_reason: to_string(reason),
      alternatives: JsonEvidence.dump(Enum.map(limitations, &limitation/1)),
      expectations:
        JsonEvidence.dump(%{
          domain: "ship_acquisition",
          limitations: limitations,
          considered_work: work,
          calibration: SpaceTraders.ShipAcquisitionCalibration.current()
        }),
      calibration_version: "ship-acquisition-v2",
      classification: :superseded
    })
  end

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
