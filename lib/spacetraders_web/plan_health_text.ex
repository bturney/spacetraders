defmodule SpaceTradersWeb.PlanHealthText do
  @moduledoc """
  Operator wording of `MissionControl.PlanHealth`: check labels, the reason
  line and check details, in game vocabulary. Numbers use the design-system
  formatters; times read `HH:MM` (UTC).
  """

  import SpaceTradersWeb.MissionControlComponents, only: [format_int: 1, format_signed: 1]

  alias SpaceTraders.MissionControl.{ShipRow, ShipStatus}

  @labels %{
    earning: "Earning",
    ships_moving: "Ships moving",
    prices_fresh: "Prices fresh",
    trades_as_expected: "Trades as expected"
  }

  @doc "Plan Health with its reason and check details worded, and each check labelled."
  def word(%{reason: reason, checks: checks} = health) do
    %{
      health
      | reason: text(reason),
        checks:
          Enum.map(checks, &Map.merge(&1, %{label: @labels[&1.name], detail: text(&1.detail)}))
    }
  end

  @doc "One reason or detail term as a sentence."
  def text({:no_fleet, _}), do: "No current Fleet yet."
  def text({:no_ships, _}), do: "No Ships reported yet."
  def text({:none, _}), do: "—"
  def text({:all_pass, _}), do: "All four checks pass."

  def text({:waiting_on_purpose, %{next_check_at: at}}),
    do: "Waiting on purpose for a trade worth making; next check #{clock(at)}."

  def text({:engine_silent, %{since: at}}), do: "The engine has been silent since #{clock(at)}."
  def text({:game_silent, %{since: at}}), do: "The game has not answered since #{clock(at)}."

  def text({:ships_silent, p}),
    do: "#{p.overdue} of #{p.total} Ships have not reported since #{clock(p.since)}."

  def text({:spending_paused, p}),
    do: "Spending paused: credits fell below the #{format_int(p.floor)} floor at #{clock(p.at)}."

  def text({:lost, %{amount: amount}}), do: "Lost #{format_int(amount)} in the last hour."

  def text({:earning_slowly, p}),
    do:
      "Earned #{format_int(p.last_hour)} in the last hour against " <>
        "#{format_int(p.average)}/h over #{hours(p.hours)} h."

  def text({:trades_late, %{count: n, since: since}}),
    do:
      "#{n} #{plural(n, "trade is", "trades are")} well past #{plural(n, "its", "their")} estimate; " <>
        "no sale recorded since #{clock(since)}."

  def text({:stalled, %{reason: reason, since: since}}),
    do: "#{ShipStatus.stall_reason(reason)}, since #{clock(since)}."

  def text({:ship_stuck, %{ship: ship, reason: reason}}), do: "#{ship} is stuck: #{reason}"
  def text({:traders_stuck, p}), do: "#{p.count} of #{p.total} traders are stuck."
  def text({:traders_busy, p}), do: "#{p.count} of #{p.total} traders are busy, not earning."

  def text({:prices_old, p}),
    do:
      "Prices at #{ShipRow.waypoint_code(p.waypoint)} are #{p.minutes} min old " <>
        "(trusted up to #{p.limit_minutes})."

  def text({:trades_short, p}),
    do: "The last #{p.count} trades made #{p.percent}% of what was expected."

  def text({:waiting, _}), do: "Waiting on purpose"
  def text({:earned, %{amount: amount}}), do: "#{format_signed(amount)} in the last hour"
  def text({:ships_reporting, %{count: n}}), do: "#{n} #{plural(n, "Ship", "Ships")} reporting"

  def text({:ships_not_reported, %{count: n, since: since}}),
    do: "#{n} #{plural(n, "Ship has", "Ships have")} not reported since #{clock(since)}."

  def text({:no_prices_needed, _}), do: "No open trade relies on prices"
  def text({:prices_within, %{minutes: minutes}}), do: "Within #{minutes} min"
  def text({:no_finished_trades, _}), do: "No finished trades yet"
  def text({:trades_met, p}), do: "Last #{p.count}: #{p.percent}% of expected"
  def text({:no_estimate, _}), do: "No estimate to compare"

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp clock(_), do: "—"

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  defp hours(hours) do
    rounded = Float.round(hours / 1, 1)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: "#{rounded}"
  end
end
