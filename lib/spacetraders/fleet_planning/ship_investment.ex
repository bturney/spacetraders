defmodule SpaceTraders.FleetPlanning.ShipInvestment do
  @moduledoc false

  alias SpaceTraders.ShipAcquisitionCalibration
  alias SpaceTraders.Fleet.FuelReach

  def inputs(context) do
    %{
      calibration: ShipAcquisitionCalibration.current(),
      horizon: Map.get(context.snapshot, :generation_horizon, %{status: :unknown}),
      unmet_work: Map.get(context.snapshot, :unmet_work, []),
      realized_rate:
        realized_rate(Map.get(context.snapshot, :realized_trade_progress), context.as_of),
      credit_margin_percent: context.margin,
      available_credits: context.credits,
      waypoint_coordinates: Map.get(context.snapshot, :waypoint_coordinates, %{}),
      fuel_stops: Map.get(context.snapshot, :fuel_stops, [])
    }
  end

  def value(context, yard, offer, preparation) do
    works =
      Enum.filter(Map.get(context.snapshot, :unmet_work, []), fn work ->
        work.strategy_revision_id == context.revision.id and work.objective_index == context.index and
          work.objective == context.objective and
          DateTime.compare(work.validity.expires_at, context.as_of) == :gt
      end)

    matches =
      works
      |> Enum.sort_by(&{-(Map.get(&1, :planned_rate) || 0), &1.candidate_id})
      |> Enum.map(&{&1, match_offer(&1, yard, offer, context.snapshot)})

    {work, match} =
      Enum.find(matches, fn {_, match} -> match.status == :matched end) ||
        List.first(matches) || {nil, %{status: :unknown, reason: :no_ship_bound_unmet_work}}

    horizon = Map.get(context.snapshot, :generation_horizon, %{status: :unknown})
    calibration = ShipAcquisitionCalibration.current()
    planned = work && work.planned_rate
    realized = realized_rate(Map.get(context.snapshot, :realized_trade_progress), context.as_of)

    {rate, basis} =
      case {match.status, planned, realized} do
        {:matched, planned, %{status: :known, rate: actual}} when is_number(planned) ->
          {min(planned, actual), :minimum_planned_realized}

        {:matched, planned, %{status: :no_history}} when is_number(planned) ->
          {planned * (1 - calibration.no_history_discount), :discounted_planned}

        _ ->
          {nil, :unknown}
      end

    usable_horizon = usable_horizon?(horizon, context.as_of, calibration)
    seconds = if usable_horizon, do: horizon.duration_seconds

    Map.merge(inputs(context), %{
      calibration: calibration,
      horizon: horizon,
      usable_horizon: usable_horizon,
      enabled_work: work,
      offer_match: match,
      offered_configuration: offer.configuration,
      shipyard:
        Map.take(yard, [:system_symbol, :waypoint, :evidence_id, :observed_at, :modifications_fee]),
      preparation_override: context.override,
      planned_rate: planned,
      realized_rate: realized,
      rate_basis: basis,
      enabled_rate: rate,
      enabled_value: if(is_number(rate) and is_number(seconds), do: rate * seconds / 3_600),
      purchase_price: offer.purchase_price,
      credit_margin_percent: context.margin,
      purchase_exposure: offer.credit_exposure,
      preparation_exposure: preparation,
      total_exposure: if(is_integer(preparation), do: offer.credit_exposure + preparation)
    })
  end

  def refusal(valuation) do
    cond do
      is_nil(valuation.enabled_work) -> :no_ship_bound_unmet_work
      not valuation.usable_horizon -> :unknown_generation_horizon
      is_nil(valuation.planned_rate) -> :unknown_planned_rate
      valuation.offer_match.status != :matched -> valuation.offer_match.reason
      valuation.realized_rate.status == :unknown -> :unknown_realized_rate
      valuation.enabled_value <= valuation.total_exposure -> :enabled_value_not_above_cost
      true -> nil
    end
  end

  defp usable_horizon?(
         %{
           status: :known,
           duration_seconds: seconds,
           evidence_ref: %{
             subject: "server:status",
             observation_id: id,
             observed_at: %DateTime{} = observed
           }
         },
         now,
         calibration
       ) do
    is_integer(seconds) and seconds > 0 and seconds <= calibration.horizon_window_seconds and
      not is_nil(id) and DateTime.compare(observed, now) != :gt and
      DateTime.diff(now, observed, :microsecond) <=
        SpaceTraders.Evidence.owned_read_freshness_seconds() * 1_000_000
  end

  defp usable_horizon?(_, _, _), do: false

  defp realized_rate(
         %{
           round_trips: trips,
           receipts: receipts,
           receipt_less_intents: missing,
           unknown: gaps,
           open_commitments: open
         },
         as_of
       ) do
    monetary_gaps =
      Enum.filter(gaps, fn gap ->
        gap.item == "completed_round_trip" and
          not (gap.reason == "no sale receipt yet" and gap.commitment_id in open)
      end)

    timed? =
      Enum.all?(trips, fn trip ->
        is_integer(trip.observed_occupied_seconds) and trip.observed_occupied_seconds > 0 and
          match?(%DateTime{}, trip.timing_evidence.sale_finished_at) and
          DateTime.compare(trip.timing_evidence.sale_finished_at, as_of) != :gt
      end)

    margin =
      if trips != [] and monetary_gaps == [] and missing == [],
        do: Enum.sum_by(trips, & &1.trade_margin)

    seconds = if trips != [] and timed?, do: Enum.sum_by(trips, & &1.observed_occupied_seconds)

    cond do
      monetary_gaps != [] or missing != [] ->
        %{
          status: :unknown,
          rate: nil,
          trade_margin: nil,
          occupied_seconds: seconds,
          samples: trips,
          receipts: receipts,
          reason: :incomplete_monetary_history,
          gaps: monetary_gaps,
          receipt_less_intents: missing
        }

      trips == [] ->
        %{
          status: :no_history,
          rate: nil,
          trade_margin: nil,
          occupied_seconds: nil,
          samples: [],
          reason: :no_completed_monetary_history
        }

      not timed? ->
        %{
          status: :unknown,
          rate: nil,
          trade_margin: margin,
          occupied_seconds: nil,
          samples: trips,
          receipts: receipts,
          reason: :incomplete_occupied_time_history
        }

      true ->
        %{
          status: :known,
          rate: margin * 3_600 / seconds,
          trade_margin: margin,
          occupied_seconds: seconds,
          samples: trips,
          receipts: receipts
        }
    end
  end

  defp realized_rate(_, _as_of),
    do: %{
      status: :unknown,
      rate: nil,
      trade_margin: nil,
      occupied_seconds: nil,
      samples: [],
      reason: :missing_trade_progress
    }

  # Capability match only (#730): role, Cargo capacity, Market access and fuel
  # reach on the offered tank. Throughput is the enabled work's planned rate;
  # min(planned, realized) and the no-history discount carry the conservatism.
  # The benchmark is what registration must prove from the purchased Ship.
  defp match_offer(work, yard, offer, snapshot) do
    config = offer.configuration
    modules = config["modules"]

    capacity =
      if is_list(modules),
        do:
          Enum.sum_by(modules, fn m ->
            if String.starts_with?(m["symbol"] || "", "MODULE_CARGO_HOLD"),
              do: m["capacity"] || 0,
              else: 0
          end)

    fuel_capacity = get_in(config, ["frame", "fuel_capacity"])

    capable? =
      is_integer(capacity) and capacity >= work.required_resources["cargo_capacity"] and
        Enum.all?(work.required_roles, &(&1["role"] == "market_trader" and &1["count"] == 1)) and
        Enum.all?(work.required_capabilities, fn
          %{"capability" => "cargo_transport", "minimum_capacity" => needed} ->
            capacity >= needed

          %{"capability" => "market_access", "waypoints" => points} ->
            Enum.sort(points) == Enum.sort([work.source_waypoint, work.destination_waypoint])

          %{"capability" => "fuel_reach"} ->
            true

          _ ->
            false
        end)

    model = work.expected_outcomes["planned_rate_evidence"] || %{}

    cond do
      not capable? ->
        %{status: :unmatched, reason: :offer_capability_unmet}

      not planned_evidence?(work, model) ->
        %{status: :unknown, reason: :unknown_planned_rate}

      not reachable?(fuel_capacity, work, yard, snapshot) ->
        %{status: :unknown, reason: :offer_fuel_reach_unproven}

      true ->
        %{
          status: :matched,
          profile: %{
            "navigation" => %{"waypoint_symbol" => yard.waypoint},
            "cargo" => %{"capacity" => capacity, "units" => 0},
            "fuel" => %{"capacity" => fuel_capacity}
          }
        }
    end
  end

  defp planned_evidence?(work, model) do
    model["model"] == "market-observed-whole-work-v1" and model["state"] == "estimated" and
      is_number(work.planned_rate) and
      is_integer(model["conservative_occupied_seconds"]) and
      model["conservative_occupied_seconds"] > 0 and
      is_integer(model["planned_supporting_cost"]) and model["planned_supporting_cost"] >= 0 and
      model["bounded_units"] == work.expected_outcomes["maximum_units"] and
      is_integer(model["gross_credit_change"]) and
      work.planned_rate ==
        3_600 * (model["gross_credit_change"] - model["planned_supporting_cost"]) /
          model["conservative_occupied_seconds"]
  end

  # Yard to source to destination on a full offered tank, refuelling only at
  # retained fuel stops, flown as Ship Execution flies it.
  defp reachable?(capacity, work, yard, snapshot) when is_integer(capacity) and capacity >= 0 do
    reach =
      FuelReach.new(
        capacity,
        "CRUISE",
        Map.get(snapshot, :waypoint_coordinates, %{}),
        Map.get(snapshot, :fuel_stops, [])
      )

    with remaining when is_integer(remaining) <-
           FuelReach.arrival_fuel(reach, yard.waypoint, capacity, work.source_waypoint),
         remaining when is_integer(remaining) <-
           FuelReach.arrival_fuel(
             reach,
             work.source_waypoint,
             remaining,
             work.destination_waypoint
           ) do
      remaining >= 0
    else
      _ -> false
    end
  end

  defp reachable?(_capacity, _work, _yard, _snapshot), do: false

  def configuration(offer) do
    offer
    |> SpaceTraders.FleetAllocation.JsonEvidence.keys()
    |> Map.take(~w(frame reactor engine crew modules mounts))
    |> Map.update("crew", nil, fn crew ->
      if is_map(crew), do: Map.take(crew, ~w(required capacity))
    end)
  end
end
