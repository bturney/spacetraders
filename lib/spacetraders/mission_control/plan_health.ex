defmodule SpaceTraders.MissionControl.PlanHealth do
  @moduledoc """
  Plan Health (#769, spec #757): whether the Fleet is succeeding at its Fleet
  Strategy, as one of four states with one plain reason line and four checks
  (Earning, Ships moving, Prices fresh, Trades as expected). It never asks the
  Operator to act.

  In precedence order:

    * `:unknown` (Can't tell right now) - no current Fleet or Ships, the
      engine or the game overdue, or more than half of Ships overdue; says
      why and since when;
    * `:off` (Off plan) - spending paused (Shortfall), allocation stalled
      (Degraded Operation), more than 10% of traders Stuck, or any Ship Stuck
      with 2 or fewer Ships;
    * `:setback` (Small setback) - a loss over 5,000 in the last hour, earning
      below 40% of the 6 h average (not during a Neutral Wait), more than 20%
      of traders Busy not earning, a Market behind an open trade past the
      engine's trade-freshness limit, or the last 20 trades realizing under
      80% of expected;
    * `:unknown` - an open trade 50% past its estimate with no sale: earnings
      evidence too old to judge (stale evidence is never on plan);
    * `:on` (On plan) - all four checks pass; a Neutral Wait is on plan.

  "Old" is overdue against each thing's own next expected update, never one
  clock: a Ship 5 min past its next known event (`ShipRow`), Market prices
  past `Intelligence.market_freshness_seconds/0`, an open trade 50% past its
  estimated duration, the engine 60 s without a heartbeat, the game failing
  5 min after its last answer. `next_change_at` is the earliest moment one of these would flip
  with no new data, so one timer covers silent staleness.

  Thresholds are the spec's prototype values, held here as named constants.
  Facts come from `read/2` (bounded queries, no game request); `evaluate/2`
  is pure.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Intelligence.{Fact, Observation}
  alias SpaceTraders.Liveness
  alias SpaceTraders.MissionControl.{MarketDisposition, ShipRow, ShipStatus}
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.Repo

  # Off plan
  @stuck_share 0.10
  @small_fleet 2
  # Small setback
  @loss_limit 5_000
  @earning_ratio 0.40
  @busy_share 0.20
  @expected_ratio 0.80
  @recent_trades 20
  # Old
  @engine_silence_seconds 60
  @game_silence_seconds 5 * 60
  @trade_overrun 0.5
  @hour 3600
  @average_window_seconds 6 * 3600

  @checks [:earning, :ships_moving, :prices_fresh, :trades_as_expected]

  @doc "Thresholds, by name."
  def thresholds,
    do: %{
      stuck_share: @stuck_share,
      small_fleet: @small_fleet,
      loss_limit: @loss_limit,
      earning_ratio: @earning_ratio,
      hour_seconds: @hour,
      average_window_seconds: @average_window_seconds,
      busy_share: @busy_share,
      expected_ratio: @expected_ratio,
      recent_trades: @recent_trades,
      engine_silence_seconds: @engine_silence_seconds,
      game_silence_seconds: @game_silence_seconds,
      trade_overrun: @trade_overrun,
      ship_overdue_seconds: ShipRow.overdue_after_seconds(),
      price_freshness_seconds: Intelligence.market_freshness_seconds()
    }

  ## Read

  @doc "Plan Health of the current Fleet as of `now`, from stored and in-memory facts."
  def read(%Scope{} = scope, %DateTime{} = now), do: scope |> facts(now) |> evaluate(now)

  @doc """
  Plan Health of an already-read current Fleet: `%{agent, generation, ships,
  statuses}` as `Fleet.current_ships/1` and `ShipStatus.for_ships/3` give them,
  and optionally its current `portfolio`.
  """
  def read(%Scope{} = scope, %DateTime{} = now, %{} = fleet),
    do: scope |> fleet_facts(fleet, now) |> evaluate(now)

  @doc "The facts `evaluate/2` judges; no game request, a fixed number of queries."
  def facts(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, %{state: :current, agent: agent, generation: %{} = generation}} <-
           FleetGeneration.current_fleet(scope) do
      ships = Fleet.current_ships(agent.id)

      fleet_facts(
        scope,
        %{
          agent: agent,
          generation: generation,
          ships: ships,
          statuses: ShipStatus.for_ships(agent, ships, now)
        },
        now
      )
    else
      _ -> %{fleet?: false}
    end
  end

  defp fleet_facts(_scope, %{generation: nil}, _now), do: %{fleet?: false}

  defp fleet_facts(scope, fleet, now) do
    %{agent: agent, generation: generation, ships: ships, statuses: statuses} = fleet
    portfolio = Map.get_lazy(fleet, :portfolio, &FleetAllocation.current_portfolio/0)
    disposition = disposition(scope, agent, portfolio)
    open = open_trades(generation, portfolio)

    %{
      fleet?: true,
      engine: Liveness.engine(),
      game_failing_since: Liveness.game_failing_since(),
      ships:
        Enum.map(ships, fn ship ->
          status = statuses[ship.id]

          %{
            symbol: ship.symbol,
            status: status.kind,
            reason: status.reason,
            overdue_at: ShipRow.overdue_at(ship, status)
          }
        end),
      neutral_wait: neutral_wait(disposition),
      shortfall:
        disposition && disposition.spending_pause &&
          Map.take(disposition.spending_pause, [:floor, :detected_at]),
      stall: disposition && stall(disposition.stall),
      earnings: earnings(generation, now),
      recent_trades: recent_trades(generation),
      open_trades: open,
      markets: markets(agent, open)
    }
  end

  defp disposition(scope, agent, portfolio) do
    case FleetStrategy.get(scope).active_revision do
      nil -> nil
      active -> MarketDisposition.for_agent(agent, active, portfolio)
    end
  end

  # The Neutral Wait holds whether or not other Ships still trade.
  defp neutral_wait(%{neutral_wait: %{next_observation_at: at}}), do: %{next_check_at: at}
  defp neutral_wait(_disposition), do: nil

  defp stall(nil), do: nil

  defp stall(stall), do: %{reason: stall.reason, since: stall.last_observed_at}

  defp earnings(generation, now) do
    age = DateTime.diff(now, generation.inserted_at)
    window = min(age, @average_window_seconds)
    last_hour = DateTime.add(now, -@hour)
    since = DateTime.add(now, -window)

    {hour_net, window_net} =
      Repo.one(
        from r in EarningsRecord,
          where: r.fleet_generation_id == ^generation.id and r.finished_at >= ^since,
          select:
            {type(
               coalesce(filter(sum(r.net_earnings), r.finished_at >= ^last_hour), 0),
               :integer
             ), type(coalesce(sum(r.net_earnings), 0), :integer)}
      )

    %{
      last_hour: hour_net,
      window_net: window_net,
      window_hours: if(age >= @hour, do: window / @hour)
    }
  end

  defp recent_trades(generation) do
    recent =
      from r in EarningsRecord,
        where: r.fleet_generation_id == ^generation.id and not is_nil(r.expected_value),
        order_by: [desc: r.finished_at, desc: r.id],
        limit: @recent_trades,
        select: %{net: r.net_earnings, expected: r.expected_value}

    Repo.one(
      from r in subquery(recent),
        select: %{
          count: count(),
          net: type(coalesce(sum(r.net), 0), :integer),
          expected: type(coalesce(sum(r.expected), 0), :integer)
        }
    )
  end

  # Trades taken and not yet recorded: each is due by its estimated duration
  # plus the allowed overrun, counted from its first step.
  defp open_trades(_generation, nil), do: []

  defp open_trades(generation, %Portfolio{} = portfolio) do
    trades =
      for %Commitment{unwind_state: :not_required} = commitment <- portfolio.commitments,
          not Commitment.coverage?(commitment),
          do: commitment

    ids = Enum.map(trades, & &1.id)

    if ids == [] do
      []
    else
      recorded =
        Repo.all(
          from r in EarningsRecord,
            where: r.fleet_generation_id == ^generation.id and r.fleet_commitment_id in ^ids,
            select: r.fleet_commitment_id
        )
        |> MapSet.new()

      started =
        Repo.all(
          from i in Intent,
            where: i.fleet_commitment_id in ^ids,
            group_by: i.fleet_commitment_id,
            select: {i.fleet_commitment_id, min(i.inserted_at)}
        )
        |> Map.new()

      seconds = estimated_seconds(portfolio)

      for trade <- trades, not MapSet.member?(recorded, trade.id) do
        due_at =
          with %{} = start <- started[trade.id],
               duration when is_number(duration) <- seconds[trade.candidate_id] do
            start
            |> to_datetime()
            |> DateTime.add(round(duration * (1 + @trade_overrun)))
          else
            _ -> nil
          end

        %{
          ship_symbol: List.first(trade.claims),
          due_at: due_at,
          markets: market_waypoints(trade)
        }
      end
    end
  end

  defp estimated_seconds(%Portfolio{strategy_decision_episode_id: nil}), do: %{}

  defp estimated_seconds(%Portfolio{strategy_decision_episode: %Episode{} = episode}),
    do: selected_seconds(episode.expectations)

  defp estimated_seconds(%Portfolio{strategy_decision_episode_id: id}),
    do: selected_seconds(Repo.one(from e in Episode, where: e.id == ^id, select: e.expectations))

  defp selected_seconds(%{"selected_trades" => trades}) when is_list(trades),
    do: Map.new(trades, &{&1["candidate_id"], get_in(&1, ["trade_estimate", "seconds"])})

  defp selected_seconds(_expectations), do: %{}

  defp market_waypoints(%Commitment{dependencies: dependencies}) do
    for %{"subject" => "market:" <> tail} <- dependencies do
      tail |> String.split(":") |> List.last()
    end
  end

  # The newest priced Listing of each Market behind an open trade.
  defp markets(agent, open) do
    waypoints = open |> Enum.flat_map(& &1.markets) |> Enum.uniq()

    if waypoints == [] do
      []
    else
      Repo.all(
        from f in Fact,
          join: o in Observation,
          on: o.id == f.observation_id,
          where:
            f.agent_id == ^agent.id and f.subject_type == "market" and
              f.field == "trade_goods" and f.state == "known" and
              f.subject_symbol in ^waypoints,
          group_by: f.subject_symbol,
          select: %{waypoint: f.subject_symbol, observed_at: max(o.observed_at)}
      )
    end
  end

  defp to_datetime(%DateTime{} = at), do: at
  defp to_datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  ## Evaluate

  @doc """
  Judges facts as of `now`: `%{state, reason, since, checks, next_change_at}`,
  where each check is `%{name, state, detail}` with state `:ok`, `:amber`,
  `:red` or `:unknown`. A reason or detail is a `{kind, params}` term, worded
  for the Operator by `SpaceTradersWeb.PlanHealthText`.
  """
  def evaluate(%{fleet?: false}, %DateTime{}) do
    %{
      state: :unknown,
      reason: {:no_fleet, %{}},
      since: nil,
      checks: for(name <- @checks, do: check(name, :unknown, {:none, %{}})),
      next_change_at: nil
    }
  end

  def evaluate(%{ships: []} = facts, %DateTime{} = now) do
    facts
    |> Map.put(:fleet?, false)
    |> evaluate(now)
    |> Map.put(:reason, {:no_ships, %{}})
  end

  def evaluate(facts, %DateTime{} = now) do
    traders = Enum.reject(facts.ships, &(&1.status == :scouting))

    findings =
      List.flatten([
        blind(facts, now),
        earning(facts, now),
        ships_moving(facts, traders),
        prices(facts, now),
        trades(facts)
      ])

    {state, reason, since} = verdict(facts, findings)

    %{
      state: state,
      reason: reason,
      since: since,
      checks:
        for name <- @checks do
          case worst(Enum.filter(findings, &(&1.check == name))) do
            nil -> check(name, :ok, ok_detail(name, facts, now))
            finding -> check(name, finding.level, finding.reason)
          end
        end,
      next_change_at: next_change_at(facts, now)
    }
  end

  defp check(name, state, detail), do: %{name: name, state: state, detail: detail}

  @rank %{blind: 0, red: 1, amber: 2, unknown: 3}

  defp verdict(facts, findings) do
    case Enum.min_by(findings, &@rank[&1.level], fn -> nil end) do
      nil -> {:on, on_reason(facts), nil}
      %{level: :blind} = f -> {:unknown, f.reason, f.since}
      %{level: :red} = f -> {:off, f.reason, f.since}
      %{level: :amber} = f -> {:setback, f.reason, f.since}
      %{level: :unknown} = f -> {:unknown, f.reason, f.since}
    end
  end

  # A check shows its worst finding; a blind finding reads as unknown.
  defp worst([]), do: nil

  defp worst(findings) do
    finding = Enum.min_by(findings, &@rank[&1.level])
    if finding.level == :blind, do: %{finding | level: :unknown}, else: finding
  end

  defp on_reason(%{neutral_wait: %{next_check_at: at}}),
    do: {:waiting_on_purpose, %{next_check_at: at}}

  defp on_reason(_facts), do: {:all_pass, %{}}

  defp finding(check, level, reason, since \\ nil),
    do: %{check: check, level: level, reason: reason, since: since}

  # Can't tell: the evidence behind every check is overdue.
  defp blind(facts, now) do
    engine =
      case facts.engine do
        %{expected?: true, last_beat_at: at} ->
          if past?(DateTime.add(at, @engine_silence_seconds), now),
            do: finding(:ships_moving, :blind, {:engine_silent, %{since: at}}, at)

        _ ->
          nil
      end

    game =
      case facts.game_failing_since do
        %DateTime{} = at ->
          if past?(DateTime.add(at, @game_silence_seconds), now),
            do: finding(:ships_moving, :blind, {:game_silent, %{since: at}}, at)

        _ ->
          nil
      end

    [engine, game, ships_blind(facts.ships, now)] |> Enum.reject(&is_nil/1)
  end

  defp ships_blind(ships, now) do
    overdue = overdue(ships, now)

    if length(overdue) * 2 > length(ships) do
      # Since the moment the majority went quiet.
      since = Enum.at(overdue, div(length(ships), 2))

      finding(
        :ships_moving,
        :blind,
        {:ships_silent, %{overdue: length(overdue), total: length(ships), since: since}},
        since
      )
    end
  end

  defp overdue(ships, now) do
    ships
    |> Enum.map(& &1.overdue_at)
    |> Enum.filter(&(&1 && past?(&1, now)))
    |> Enum.sort(DateTime)
  end

  defp earning(facts, now) do
    shortfall =
      if s = facts.shortfall do
        finding(
          :earning,
          :red,
          {:spending_paused, %{floor: s.floor, at: s.detected_at}},
          s.detected_at
        )
      end

    %{last_hour: hour, window_net: window_net, window_hours: hours} = facts.earnings

    loss =
      if hour < -@loss_limit,
        do: finding(:earning, :amber, {:lost, %{amount: -hour}})

    average = hours && window_net / hours

    slow =
      if is_nil(facts.neutral_wait) and is_number(average) and average > 0 and
           hour < @earning_ratio * average,
         do:
           finding(
             :earning,
             :amber,
             {:earning_slowly, %{last_hour: hour, average: average, hours: hours}}
           )

    late = for %{due_at: %DateTime{} = due} <- facts.open_trades, past?(due, now), do: due

    stale =
      if late != [] do
        since = Enum.min(late, DateTime)
        finding(:earning, :unknown, {:trades_late, %{count: length(late), since: since}}, since)
      end

    [shortfall, loss, slow, stale] |> Enum.reject(&is_nil/1)
  end

  defp ships_moving(facts, traders) do
    stuck = Enum.filter(traders, &(&1.status == :stuck))
    busy = Enum.count(traders, &(&1.status == :busy_not_earning))
    total = length(traders)

    stall =
      if s = facts.stall do
        finding(:ships_moving, :red, {:stalled, %{reason: s.reason, since: s.since}}, s.since)
      end

    stuck_finding =
      cond do
        stuck != [] and length(facts.ships) <= @small_fleet ->
          [ship | _] = stuck
          finding(:ships_moving, :red, {:ship_stuck, %{ship: ship.symbol, reason: ship.reason}})

        total > 0 and length(stuck) > @stuck_share * total ->
          finding(:ships_moving, :red, {:traders_stuck, %{count: length(stuck), total: total}})

        true ->
          nil
      end

    busy_finding =
      if total > 0 and busy > @busy_share * total,
        do: finding(:ships_moving, :amber, {:traders_busy, %{count: busy, total: total}})

    [stall, stuck_finding, busy_finding] |> Enum.reject(&is_nil/1)
  end

  defp prices(facts, now) do
    limit = Intelligence.market_freshness_seconds()

    facts.markets
    |> Enum.filter(&past?(DateTime.add(&1.observed_at, limit), now))
    |> Enum.min_by(& &1.observed_at, DateTime, fn -> nil end)
    |> case do
      nil ->
        []

      market ->
        finding(
          :prices_fresh,
          :amber,
          {:prices_old,
           %{
             waypoint: market.waypoint,
             minutes: div(DateTime.diff(now, market.observed_at), 60),
             limit_minutes: div(limit, 60)
           }},
          DateTime.add(market.observed_at, limit)
        )
    end
  end

  defp trades(%{recent_trades: %{count: count, net: net, expected: expected}})
       when count > 0 and expected > 0 do
    if net < @expected_ratio * expected,
      do:
        finding(
          :trades_as_expected,
          :amber,
          {:trades_short, %{count: count, percent: round(net * 100 / expected)}}
        ),
      else: []
  end

  defp trades(_facts), do: []

  defp ok_detail(:earning, %{neutral_wait: %{}}, _now), do: {:waiting, %{}}

  defp ok_detail(:earning, %{earnings: %{last_hour: hour}}, _now),
    do: {:earned, %{amount: hour}}

  defp ok_detail(:ships_moving, facts, now) do
    case overdue(facts.ships, now) do
      [] -> {:ships_reporting, %{count: length(facts.ships)}}
      [since | _] = late -> {:ships_not_reported, %{count: length(late), since: since}}
    end
  end

  defp ok_detail(:prices_fresh, %{markets: []}, _now), do: {:no_prices_needed, %{}}

  defp ok_detail(:prices_fresh, _facts, _now),
    do: {:prices_within, %{minutes: div(Intelligence.market_freshness_seconds(), 60)}}

  defp ok_detail(:trades_as_expected, %{recent_trades: %{count: 0}}, _now),
    do: {:no_finished_trades, %{}}

  defp ok_detail(:trades_as_expected, %{recent_trades: r}, _now) when r.expected > 0,
    do: {:trades_met, %{count: r.count, percent: round(r.net * 100 / r.expected)}}

  defp ok_detail(:trades_as_expected, _facts, _now), do: {:no_estimate, %{}}

  # The earliest future moment an "old" rule flips without new data.
  defp next_change_at(facts, now) do
    engine =
      case facts.engine do
        %{expected?: true, last_beat_at: at} -> DateTime.add(at, @engine_silence_seconds)
        _ -> nil
      end

    game =
      facts.game_failing_since && DateTime.add(facts.game_failing_since, @game_silence_seconds)

    limit = Intelligence.market_freshness_seconds()

    [engine, game]
    |> Enum.concat(Enum.map(facts.ships, & &1.overdue_at))
    |> Enum.concat(Enum.map(facts.open_trades, & &1.due_at))
    |> Enum.concat(Enum.map(facts.markets, &DateTime.add(&1.observed_at, limit)))
    |> Enum.filter(&(&1 && not past?(&1, now)))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp past?(at, now), do: DateTime.compare(at, now) != :gt
end
