defmodule SpaceTraders.FleetAllocation.MarketWorkRate do
  @moduledoc """
  Evidence-bound rate annotation for Market Candidates at allocation.

  The versioned empirical model uses fresh planned spread * bounded quantity,
  minus the largest attributable supporting charge total observed on comparable
  completed work, divided by the longest observed occupied duration. Independent
  maxima deliberately avoid selecting the most optimistic historical trip.
  This is a forecast, not a guaranteed cost bound or a realized-rate comparator.

  Comparable means the same directional route, Trade Good, quantity and exact
  starting readiness/Flight Mode, location, cargo and fuel profile. Each eligible
  owned profile needs completed evidence in this Generation. Timing spans the
  first buy Intent's creation through the completed sell, including prerequisite
  work, waits and the handoff; scheduled transit alone never supplies throughput.
  Missing timing, retained starting evidence or supporting attribution is unknown.
  No extrapolation to an offered Ship is performed here.
  """

  alias SpaceTraders.Evidence
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.TradeProgress

  @model "market-observed-whole-work-v1"

  # Exact starting readiness, position, Flight Mode, load and fuel. Never match
  # by Ship symbol or extrapolate engine speed/distance into invented seconds.
  def ship_profile(
        %{
          frame: %{},
          reactor: %{},
          engine: %{},
          crew: %{},
          modules: modules,
          mounts: mounts,
          nav: %{waypoint_symbol: waypoint, status: status, flight_mode: mode},
          cargo: %{capacity: capacity, units: units},
          fuel: %{capacity: fuel_capacity, current: current},
          cooldown: %{remaining_seconds: remaining}
        } = ship
      )
      when is_list(modules) and is_list(mounts) and is_binary(waypoint) and
             status in ["DOCKED", "IN_ORBIT"] and is_binary(mode) and
             is_integer(capacity) and is_integer(units) and is_integer(fuel_capacity) and
             is_integer(current) and is_integer(remaining) do
    %{
      readiness: Map.take(ship, [:frame, :reactor, :engine, :crew, :modules, :mounts]),
      navigation: Map.take(ship.nav, [:waypoint_symbol, :status, :flight_mode]),
      cargo: Map.take(ship.cargo, [:capacity, :units]),
      fuel: Map.take(ship.fuel, [:capacity, :current]),
      cooldown: Map.take(ship.cooldown, [:remaining_seconds])
    }
    |> SpaceTraders.FleetAllocation.JsonEvidence.keys()
  end

  def ship_profile(_ship), do: nil

  def annotate(agent, candidates, availability) do
    generation = FleetAllocation.active_generation(agent)
    trips = TradeProgress.for_generation(generation.id).round_trips

    Enum.map(candidates, fn
      %{kind: :market_trade} = candidate ->
        evidence = estimate(candidate, availability.claims, trips, agent, generation.id)
        outcomes = Map.merge(candidate.expected_outcomes, evidence)
        %{candidate | expected_outcomes: outcomes}

      candidate ->
        candidate
    end)
  end

  defp estimate(candidate, claims, trips, agent, generation_id) do
    units = candidate.expected_outcomes.maximum_units
    eligible = Enum.find(candidate.required_capabilities, &(&1.capability == :fuel_reach))

    profiles =
      for claim <- claims,
          :market_trader in claim.roles,
          claim.capabilities.cargo_transport >= units,
          is_nil(eligible) or claim.resource in eligible.ships,
          profile <- [claim.capabilities[:trade_work_profile]],
          do: profile

    samples =
      Enum.filter(trips, fn trip ->
        trip.source_waypoint == candidate.source_waypoint and
          trip.destination_waypoint == candidate.destination_waypoint and
          trip.trade_symbol == candidate.trade_symbol and trip.units == units and
          is_map(trip.timing_evidence.work_start) and
          trip.timing_evidence.work_start["profile"] in profiles
      end)

    known? =
      profiles != [] and Enum.all?(profiles, &is_map/1) and samples != [] and
        Enum.all?(profiles, fn profile ->
          Enum.any?(samples, &(&1.timing_evidence.work_start["profile"] == profile))
        end) and
        Enum.all?(samples, fn trip ->
          is_integer(trip.observed_occupied_seconds) and
            is_integer(trip.supporting_cost) and
            traceable_start?(trip, agent, generation_id, candidate.validity.as_of)
        end)

    if known? do
      seconds = Enum.max_by(samples, & &1.observed_occupied_seconds).observed_occupied_seconds
      cost = Enum.max_by(samples, & &1.supporting_cost).supporting_cost

      %{
        planned_rate:
          3_600 * (candidate.expected_outcomes.maximum_credit_change - cost) / seconds,
        planned_rate_evidence: %{
          model: @model,
          state: :estimated,
          gross_credit_change: candidate.expected_outcomes.maximum_credit_change,
          bounded_units: units,
          conservative_occupied_seconds: seconds,
          planned_supporting_cost: cost,
          profiles: Enum.uniq(profiles),
          purchase_intent_ids: Enum.map(samples, & &1.purchase_intent_id),
          sale_intent_ids: Enum.map(samples, & &1.sale_intent_id),
          supporting_attempt_ids: Enum.flat_map(samples, & &1.supporting_attempt_ids),
          evidence_references: Enum.flat_map(samples, &evidence_references/1),
          samples: samples
        }
      }
    else
      %{
        planned_rate: nil,
        planned_rate_evidence: %{
          model: @model,
          state: :unknown,
          reason: :missing_comparable_whole_work_or_supporting_evidence
        }
      }
    end
  end

  defp evidence_references(trip) do
    [
      %{kind: :intent, id: trip.purchase_intent_id},
      %{kind: :intent, id: trip.sale_intent_id},
      %{kind: :observation, id: trip.timing_evidence.work_start["observation_id"]}
    ] ++ Enum.map(trip.supporting_attempt_ids, &%{kind: :mutation_attempt, id: &1})
  end

  defp traceable_start?(trip, agent, generation_id, as_of) do
    start = trip.timing_evidence.work_start

    with {:ok, binding} <- Evidence.retained_ship_binding(agent, start["observation_id"]),
         true <- binding.observation.fleet_generation_id == generation_id,
         true <- ship_profile(binding.value) == start["profile"],
         true <- DateTime.compare(trip.timing_evidence.sale_finished_at, as_of) != :gt,
         true <-
           DateTime.compare(
             DateTime.truncate(binding.observation.observed_at, :second),
             trip.timing_evidence.purchase_started_at
           ) != :gt do
      true
    else
      _ -> false
    end
  end
end
