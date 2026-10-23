defmodule SpaceTraders.ShipyardPayback do
  @moduledoc """
  Test-only #837 economics for the bounded Shipyard proof. Not runtime policy:
  the incumbent admission valuation is unchanged and never consulted here.

  `stress/1` is the frozen contract's deterministic falsifier: lower of the
  recorded enabled and complete-cycle achievable rate, 50% lower repeat
  throughput, 25% higher future operating costs and one extra hour of lead,
  bounded by the capped admission horizon, announced reset, funded inputs and
  obtainable finite demand. `classify/2` reports N(T), Delta(T) and P1 without
  a cash-superiority or repay-inside-T gate.
  """

  @extra_lead_seconds 3600
  @cycle_units 40
  @replenish_seconds 1800

  def stress(%{} = input) do
    %{
      capital: capital,
      revenue: revenue,
      operating_cost: cost,
      complete_seconds: complete,
      enabled_rate: enabled,
      lead_seconds: lead,
      horizon_seconds: horizon,
      reset_seconds: reset
    } = input

    achievable = div((revenue - cost) * 3600, complete)
    lower = min(enabled, achievable)
    stressed_cost = ceil_div(cost * 5, 4)
    profit = revenue - stressed_cost

    if lower <= 0 or profit <= 0 do
      %{classification: :inconclusive, reason: :nonpositive_stressed_return}
    else
      # A lower enabled rate can only slow a COMPLETE cycle further.
      period = max(complete * 2, ceil_div((revenue - cost) * 3600 * 2, lower))
      cycles = ceil_div(capital, profit)
      completion = lead + @extra_lead_seconds + cycles * period
      window = min(horizon, reset)
      throughput_units = max(0, div(window - lead - @extra_lead_seconds, period)) * @cycle_units
      obtainable = min(obtainable_units(input, period, window), throughput_units)
      # One stressed cycle's inputs must be funded at the 25% calibration margin.
      funding_needed = ceil_div(stressed_cost * 5, 4)

      checks = %{
        funded: input.available_cash >= funding_needed,
        finite_demand: cycles * @cycle_units <= obtainable,
        within_cap_and_reset: completion <= window
      }

      %{
        classification: if(Enum.all?(Map.values(checks)), do: :supported, else: :inconclusive),
        checks: checks,
        achievable_rate: achievable,
        recorded_enabled_rate: enabled,
        lower_rate: lower,
        stressed_profit_per_cycle: profit,
        stressed_complete_cycle_seconds: period,
        lead_seconds: lead + @extra_lead_seconds,
        cycles_needed: cycles,
        completion_seconds: completion,
        future_outlays: cycles * stressed_cost,
        future_receipts: cycles * revenue,
        capital_loaded_surplus: cycles * revenue - capital - cycles * stressed_cost,
        funding_needed: funding_needed,
        obtainable_units: obtainable,
        shared_route_assumption:
          "incumbent repeats on the same route at its fastest observed period"
      }
    end
  end

  @doc "Arm summaries carry net_cash, acquisitions, new_ship_cycles (net earnings), unknown_effects and V's payback."
  def classify(b, v) do
    path = productive_path(v)
    payback = get_in(v, [:payback, :classification])

    p1 =
      cond do
        v.acquisitions == 0 -> :no_acquisition
        path == :fail -> :fail
        path == :inconclusive or v.unknown_effects != [] -> :inconclusive
        productive_path(b) == :pass -> :current_policy_success
        payback != :supported -> :inconclusive
        true -> :attributed_productive_acquisition
      end

    %{
      n_b: b.net_cash,
      n_v: v.net_cash,
      delta: v.net_cash - b.net_cash,
      delta_attribution:
        if(Map.get(b, :contradictions, []) == [], do: :measured, else: :inconclusive),
      productive_path: path,
      payback: payback,
      p1: p1
    }
  end

  @doc """
  One arm's T account and, when it acquired and cycled, the stressed payback
  inputs measured from its own receipts. `result` is `ShipyardProofRuntime`'s
  finite-control map. Unknown monetary effects and open work stay separate.
  """
  def arm(result, ship \\ "PROOF824-3") do
    as_of = result.as_of
    requests = Enum.filter(result.request_effects, &before?(&1.completed_at, as_of))
    purchases = Enum.filter(requests, &(&1.method == "POST" and &1.path == "/v2/my/ships"))

    cycles =
      result.earnings
      |> Enum.filter(&(&1.ship_symbol == ship and before?(&1.finished_at, as_of)))
      |> Enum.sort_by(& &1.finished_at, DateTime)

    episode =
      Enum.find(result.decisions, &(get_in(&1, [:actual_outcomes, "ship_symbol"]) == ship))

    valuation = episode && episode.expectations["valuation"]

    summary = %{
      preset: result.preset,
      code_revision: result.code_revision,
      as_of: as_of,
      net_cash: result.account.net_cash,
      account:
        Map.take(
          result.account,
          ~w(credits receipts all_outlays goods_outlays fuel_outlays acquisition_outlays low_credits unexplained_cash cargo_basis fuel stock open_travel)a
        ),
      unknown_effects: result.account.unknown_monetary_effects,
      closure_tail_effects: length(result.account.closure_tail),
      acquisitions: length(purchases),
      cycles_by_ship: Enum.frequencies_by(result.earnings, & &1.ship_symbol),
      new_ship_cycles: Enum.map(cycles, & &1.net_earnings),
      requests: length(requests),
      unsettled_attempts:
        Enum.count(result.attempts, &(&1.state in ~w(sent_or_unknown ambiguous bounded_unknown))),
      unfinished_intents:
        Enum.count(
          result.intents,
          &(&1.status in ~w(active waiting blocked awaiting_confirmation))
        ),
      contradictions: send_clock_contradictions(result),
      valuation:
        valuation &&
          %{
            rate_basis: valuation["rate_basis"],
            enabled_rate: valuation["enabled_rate"],
            horizon_seconds: get_in(valuation, ["horizon", "duration_seconds"]),
            total_exposure: valuation["total_exposure"]
          }
    }

    payback =
      case {purchases, cycles, valuation} do
        {[purchase], [_, _ | _], %{}} ->
          stress(payback_inputs(result, purchase, cycles, valuation, ship))

        _ ->
          %{classification: :not_applicable}
      end

    Map.put(summary, :payback, payback)
  end

  defp payback_inputs(result, purchase, cycles, valuation, ship) do
    preparation =
      result.request_effects
      |> Enum.filter(&String.starts_with?(&1.path, "/v2/my/ships/#{ship}/"))
      |> Enum.reject(&String.ends_with?(&1.path, ~w(/purchase /refuel /sell)))
      |> Enum.sum_by(&max(-&1.signed_cash, 0))

    incumbent =
      result.earnings
      |> Enum.reject(&(&1.ship_symbol == ship))
      |> Enum.group_by(& &1.ship_symbol)
      |> Map.values()
      |> Enum.flat_map(&periods/1)

    complete = Enum.max(periods(cycles))
    stock = purchase.before.routes |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.min()
    # Worst sustained quote movement: depletion at purchase plus both Ships'
    # bursts and one lagging refill (3 x 40), at 10 credits per 40 units.
    movement = @cycle_units * div(1600 - stock + 3 * @cycle_units, 4)

    %{
      capital: -purchase.signed_cash + preparation,
      revenue: Enum.min_by(cycles, & &1.revenue).revenue - movement,
      operating_cost:
        Enum.max(Enum.map(cycles, &(&1.goods_cost + &1.fuel_cost + &1.other_cost))) + movement,
      complete_seconds: complete,
      enabled_rate: trunc(valuation["enabled_rate"]),
      lead_seconds: DateTime.diff(hd(cycles).started_at, purchase.started_at),
      horizon_seconds: get_in(valuation, ["horizon", "duration_seconds"]),
      reset_seconds: DateTime.diff(result.reset_at, purchase.started_at),
      available_cash:
        purchase.after.credits - result.floor - result.manifest.selected_work_initial_reservation,
      stock_units: stock,
      incumbent_period_seconds: Enum.min(incumbent, fn -> complete end)
    }
  end

  defp periods(earnings) do
    earnings
    |> Enum.sort_by(& &1.finished_at, DateTime)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> DateTime.diff(b.finished_at, a.finished_at) end)
  end

  # A sent attempt whose send marker matches no request start on the world's
  # clock: the application and world disagree about time in this arm.
  defp send_clock_contradictions(result) do
    starts =
      MapSet.new(result.request_effects, &{&1.path, DateTime.truncate(&1.started_at, :second)})

    for attempt <- result.attempts,
        sent = attempt.sent_or_unknown_at,
        path = get_in(attempt.prepared_evidence, ["request", "path"]),
        not MapSet.member?(starts, {"/v2" <> path, DateTime.truncate(sent, :second)}),
        do: attempt.id
  end

  defp before?(at, as_of), do: DateTime.compare(at, as_of) != :gt

  # Shared finite stock: if the incumbent and the stressed hauler together
  # consume no faster than the 40-per-1800 s refill and the stock covers both
  # bursts, every stressed cycle is obtainable. Otherwise grant no refill.
  defp obtainable_units(
         %{stock_units: stock, incumbent_period_seconds: incumbent},
         period,
         window
       ) do
    sustainable =
      stock >= 2 * @cycle_units and
        @replenish_seconds * (period + incumbent) <= incumbent * period

    if sustainable,
      do: stock + div(window, @replenish_seconds) * @cycle_units,
      else: max(0, stock - (div(window, incumbent) + 1) * @cycle_units)
  end

  defp productive_path(%{acquisitions: 0}), do: :fail

  defp productive_path(%{new_ship_cycles: cycles}) do
    cond do
      Enum.any?(cycles, &(not is_integer(&1))) -> :inconclusive
      Enum.count(cycles, &(&1 > 0)) >= 2 and Enum.sum(cycles) > 0 -> :pass
      true -> :fail
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
