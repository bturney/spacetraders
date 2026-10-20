defmodule SpaceTraders.MissionControl.ShipStatus do
  @moduledoc """
  The one per-Ship status read (#767): each Ship gets exactly one of five
  statuses from stored facts, never from the game or the Agent balance.

  In precedence order:

    * `:stuck` - its execution step is blocked (plain reason, retries, next
      attempt), or Fleet Allocation's open structural stall names its work
      (the allocation is re-checked every minute);
    * `:waiting` (Waiting on purpose) - unassigned during a Neutral Wait, with
      the wait's next check; an unassigned Ship outside a Neutral Wait waits
      for new orders with no check time;
    * `:busy_not_earning` - with at least an hour of its own history, 3 or
      more skipped buys in 30 minutes, or last-hour Net Earnings below 40% of
      its average per hour over the last 6 h (or its whole history if younger);
    * `:trading` - a trade assignment, with the leg in progress;
    * `:scouting` - a Market-refresh assignment, with markets it refreshed
      and the Agent's overdue Markets.

  A skipped buy is a buy step that ended infeasible. Net Earnings and the
  credits-per-Ship-hour rate come from the Ship's Earnings records in the
  current Fleet Generation. The read issues a fixed number of queries
  whatever the number of Ships.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{AllocationResultPointer, Commitment, Portfolio}
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Evidence.ObservationDemand
  alias SpaceTraders.MissionControl.{PlanHealth, ShipRow}
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.Repo

  @statuses [:trading, :scouting, :waiting, :stuck, :busy_not_earning]

  # Prototype thresholds (spec #757); tuning them does not change the rules.
  # The earning ratio and its windows are Plan Health's (`PlanHealth.thresholds/0`).
  @history_seconds 3600
  @skipped_buy_window_seconds 30 * 60
  @skipped_buys 3

  @stall_reasons %{
    stale_revision_portfolio: "Fleet planning stalled: its trades follow an old plan",
    authority_blocked_intent: "Fleet planning stalled: a Ship may no longer act on its step",
    overdue_demands_without_coverage:
      "Fleet planning stalled: markets are overdue and nobody refreshes them"
  }

  @doc "The five statuses, in display order."
  def statuses, do: @statuses

  @doc "Number of Ships of each status (every status present, zero or more)."
  def counts(statuses) do
    Enum.reduce(statuses, Map.new(@statuses, &{&1, 0}), fn %{kind: kind}, acc ->
      Map.update!(acc, kind, &(&1 + 1))
    end)
  end

  @doc "Plain wording of an allocation stall reason."
  def stall_reason(reason), do: Map.get(@stall_reasons, reason, "Fleet planning stalled")

  @doc "Metric label value of a status."
  def metric_label(status), do: Atom.to_string(status)

  @doc """
  Status of each given Ship of the Agent as of `now`, keyed by Ship id.
  Pass `portfolio:` when the current Portfolio is already read.
  """
  def for_ships(%AgentRecord{} = agent, ships, %DateTime{} = now, opts \\ [])
      when is_list(ships) do
    if ships == [] do
      %{}
    else
      facts = facts(agent, ships, now, opts)
      Map.new(ships, &{&1.id, status(&1, facts, now)})
    end
  end

  ## Facts

  defp facts(agent, ships, now, opts) do
    generation = FleetAllocation.active_generation(agent)

    portfolio =
      generation && Keyword.get_lazy(opts, :portfolio, &FleetAllocation.current_portfolio/0)

    assignments = assignments(portfolio)
    ship_ids = Enum.map(ships, & &1.id)
    symbols = Enum.map(ships, & &1.symbol)
    scouting? = Enum.any?(symbols, &match?(%{coverage?: true}, assignments[&1]))

    thresholds =
      Map.take(PlanHealth.thresholds(), ~w(earning_ratio hour_seconds average_window_seconds)a)

    %{
      thresholds: thresholds,
      assignments: assignments,
      intents: intents(ship_ids),
      neutral_wait: generation && neutral_wait(generation),
      stall: generation && stall(generation, portfolio),
      skipped: skipped_buys(ship_ids, now),
      earnings: earnings(generation, symbols, now, thresholds),
      refreshed: if(scouting?, do: refreshed(ship_ids, now, thresholds.hour_seconds), else: %{}),
      overdue: if(scouting?, do: overdue_markets(agent, now), else: 0)
    }
  end

  defp assignments(%Portfolio{commitments: commitments}) do
    for %Commitment{unwind_state: :not_required} = commitment <- commitments,
        symbol <- commitment.claims,
        into: %{} do
      {symbol,
       %{
         id: commitment.id,
         coverage?: Commitment.coverage?(commitment),
         expected_value: commitment.expected_value
       }}
    end
  end

  defp assignments(_portfolio), do: %{}

  defp intents(ship_ids) do
    from(i in Intent,
      where: i.ship_id in ^ship_ids and i.status in ^Intent.unfinished_states(),
      order_by: [asc: i.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.ship_id, &1})
  end

  defp neutral_wait(%Generation{id: generation_id}) do
    Repo.one(
      from p in AllocationResultPointer,
        join: e in Episode,
        on: e.id == p.strategy_decision_episode_id,
        where: p.fleet_generation_id == ^generation_id and p.selection_kind == :neutral_wait,
        select: %{next_check_at: e.next_observation_at}
    )
  end

  # The open stall of the current Portfolio (or of none), as MarketDisposition reads it.
  defp stall(%Generation{id: generation_id}, portfolio) do
    portfolio_id = portfolio && portfolio.id

    Repo.one(
      from e in Episode,
        where:
          e.fleet_generation_id == ^generation_id and e.selection_kind == :structural_stall and
            is_nil(e.resolved_at),
        limit: 1
    )
    |> case do
      %Episode{stalled_portfolio_id: ^portfolio_id} = episode ->
        %{
          reason: episode.stall_reason,
          intent_ids:
            for(%{"kind" => "intent", "id" => id} <- episode.evidence_references || [], do: id)
        }

      _ ->
        nil
    end
  end

  defp skipped_buys(ship_ids, now) do
    since = DateTime.add(now, -@skipped_buy_window_seconds)

    from(i in Intent,
      where:
        i.ship_id in ^ship_ids and i.type == "buy" and i.status == "infeasible" and
          i.finished_at >= ^since,
      group_by: i.ship_id,
      select: {i.ship_id, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp earnings(nil, _symbols, _now, _thresholds), do: %{}

  defp earnings(%Generation{id: generation_id}, symbols, now, thresholds) do
    last_hour = DateTime.add(now, -thresholds.hour_seconds)
    window = DateTime.add(now, -thresholds.average_window_seconds)

    from(r in EarningsRecord,
      where: r.fleet_generation_id == ^generation_id and r.ship_symbol in ^symbols,
      group_by: r.ship_symbol,
      select:
        {r.ship_symbol,
         %{
           net: type(sum(r.net_earnings), :integer),
           seconds: type(sum(r.ship_seconds), :integer),
           last_hour: type(filter(sum(r.net_earnings), r.finished_at >= ^last_hour), :integer),
           records:
             fragment(
               "array_agg(ARRAY[extract(epoch from ?)::bigint, ?::bigint])
                              FILTER (WHERE ? >= ?)",
               r.finished_at,
               r.net_earnings,
               r.finished_at,
               ^window
             )
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Every Market refresh is its own Commitment, so a count keyed by the
  # current assignment only ever reads 0 or 1. Count the Ship's own refreshes.
  defp refreshed(ship_ids, now, window_seconds) do
    since = DateTime.add(now, -window_seconds)

    from(i in Intent,
      where:
        i.ship_id in ^ship_ids and i.type == "acquire_intelligence" and
          i.status == "completed" and i.finished_at > ^since,
      group_by: i.ship_id,
      select: {i.ship_id, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp overdue_markets(agent, now) do
    Repo.aggregate(
      from(d in ObservationDemand,
        where:
          d.agent_id == ^agent.id and is_nil(d.withdrawn_at) and
            is_nil(d.fulfilled_observation_id) and d.owner == "fleet_planning" and
            like(d.subject, "market:%") and d.due_at <= ^now
      ),
      :count
    )
  end

  ## Derivation

  defp status(%Ship{} = ship, facts, now) do
    assignment = facts.assignments[ship.symbol]
    intent = facts.intents[ship.id]
    earned = Map.get(facts.earnings, ship.symbol, %{})

    base = %{
      ship_id: ship.id,
      credits_per_hour: rate(earned),
      # An execution step is running (not blocked): the Ship acts at once.
      acting?: match?(%Intent{}, intent) and intent.status != "blocked",
      reason: nil,
      retries: nil,
      next_attempt_at: nil,
      next_check_at: nil,
      estimate: nil,
      markets_refreshed: nil,
      markets_overdue: nil
    }

    {status, details} =
      stuck(intent, assignment, facts.stall) ||
        waiting(assignment, facts.neutral_wait) ||
        busy_not_earning(ship, facts.skipped[ship.id] || 0, earned, facts.thresholds, now) ||
        working(assignment, intent, ship, facts)

    base
    |> Map.merge(details)
    |> Map.put(:kind, status)
  end

  defp stuck(%Intent{status: "blocked"} = intent, _assignment, _stall) do
    reason = blocked_reason(intent.blocker)

    {:stuck,
     %{
       reason: reason,
       retries: intent.retries || 0,
       next_attempt_at: intent.next_attempt_at,
       phrase: reason
     }}
  end

  defp stuck(intent, assignment, %{reason: reason} = stall) do
    if stalled?(stall, intent, assignment) do
      text = stall_reason(reason)
      {:stuck, %{reason: text, retries: nil, phrase: "#{text}; checks every minute"}}
    end
  end

  defp stuck(_intent, _assignment, _stall), do: nil

  defp stalled?(%{reason: :stale_revision_portfolio}, _intent, assignment), do: assignment != nil

  defp stalled?(%{reason: :authority_blocked_intent, intent_ids: ids}, intent, _assignment),
    do: match?(%Intent{}, intent) and intent.id in ids

  defp stalled?(%{reason: :overdue_demands_without_coverage}, _intent, assignment),
    do: assignment == nil

  defp stalled?(_stall, _intent, _assignment), do: false

  defp blocked_reason(%{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp blocked_reason(%{reason: reason}) when is_binary(reason),
    do: reason |> String.replace("_", " ") |> String.capitalize()

  defp blocked_reason(_blocker), do: "The step cannot progress"

  defp waiting(nil, %{next_check_at: at}),
    do: {:waiting, %{next_check_at: at, phrase: "Waiting for better trades; next check"}}

  defp waiting(_assignment, _wait), do: nil

  defp busy_not_earning(ship, skipped, earned, thresholds, now) do
    %{earning_ratio: ratio, hour_seconds: hour, average_window_seconds: window} = thresholds
    history = DateTime.diff(now, ship.inserted_at)

    cond do
      history < @history_seconds ->
        nil

      skipped >= @skipped_buys ->
        {:busy_not_earning, %{phrase: "#{skipped} skipped buys in 30 min"}}

      true ->
        hours = min(history, window) / hour
        since = DateTime.to_unix(now) - min(history, window)

        window_net =
          for [at, net] <- earned[:records] || [], at >= since, reduce: 0, do: (sum -> sum + net)

        average = window_net / hours
        last_hour = earned[:last_hour] || 0

        if last_hour < ratio * average do
          {:busy_not_earning,
           %{
             phrase:
               "Last hour #{format_int(last_hour)} vs #{format_int(round(average))}/h " <>
                 "over #{format_hours(hours)} h"
           }}
        end
    end
  end

  defp working(nil, _intent, _ship, _facts),
    do: {:waiting, %{phrase: "Waiting for new orders"}}

  defp working(%{coverage?: true}, _intent, ship, facts) do
    refreshed = Map.get(facts.refreshed, ship.id, 0)

    {:scouting,
     %{
       markets_refreshed: refreshed,
       markets_overdue: facts.overdue,
       phrase:
         "Refreshing markets: #{refreshed} refreshed in the last hour, #{facts.overdue} overdue"
     }}
  end

  defp working(assignment, intent, _ship, _facts) do
    {:trading,
     %{
       estimate: assignment.expected_value && round(assignment.expected_value),
       phrase: leg(intent)
     }}
  end

  defp leg(%Intent{type: "buy"} = intent),
    do:
      "Buying #{intent.parameters["trade_symbol"]} at #{ShipRow.waypoint_code(intent.target_waypoint)}"

  defp leg(%Intent{type: "sell"} = intent),
    do:
      "Selling #{intent.parameters["trade_symbol"]} at #{ShipRow.waypoint_code(intent.target_waypoint)}"

  defp leg(%Intent{target_waypoint: target}) when is_binary(target),
    do: "Flying to #{ShipRow.waypoint_code(target)}"

  defp leg(_intent), do: "Starting a trade"

  defp rate(%{net: net, seconds: seconds}) when is_integer(seconds) and seconds > 0,
    do: round(net * 3600 / seconds)

  defp rate(_earned), do: nil

  defp format_hours(hours) do
    rounded = Float.round(hours, 1)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: "#{rounded}"
  end

  defp format_int(n) when n < 0, do: "-" <> format_int(-n)

  defp format_int(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
