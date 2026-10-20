defmodule SpaceTraders.MissionControl.ShipStatusTest do
  @moduledoc """
  Every Ship has one of the five statuses, derived from stored facts only
  (#767). Seam: `MissionControl.ShipStatus.for_ships/3`.
  """
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.CreditSpendingFixtures

  alias SpaceTraders.Evidence.ObservationDemand
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation.AllocationResultPointer
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.MissionControl.ShipStatus
  alias SpaceTraders.Outcomes.EarningsRecord

  setup do
    {agent, [intent], portfolio} = claimed_purchases([0])
    generation = Repo.get_by!(Generation, agent_id: agent.id)
    revision = Repo.get!(Revision, portfolio.fleet_strategy_revision_id)
    ship = Repo.get!(Ship, intent.ship_id)

    %{
      agent: agent,
      intent: intent,
      ship: ship,
      portfolio: portfolio,
      generation: generation,
      revision: revision,
      now: DateTime.utc_now(:second)
    }
  end

  test "a Ship working a trade is Trading, with what it is doing and the expected value", ctx do
    status = status(ctx)

    assert status.kind == :trading
    assert status.phrase == "Buying IRON_ORE at #{short(ctx.agent.headquarters)}"
    assert status.estimate == 10
  end

  test "a Ship flying to sell is Trading with the leg it is on", ctx do
    ctx.intent
    |> Ecto.Changeset.change(type: "sell", target_waypoint: "X1-UX81-C3")
    |> Repo.update!()

    assert %{kind: :trading, phrase: "Selling IRON_ORE at C3"} = status(ctx)
  end

  test "a Ship on Market refresh is Scouting, with markets refreshed and overdue", ctx do
    [commitment] = ctx.portfolio.commitments

    commitment
    |> Ecto.Changeset.change(dependencies: [%{"subject" => "market:X1-A3"}])
    |> Repo.update!()

    scouting = ctx.intent |> Ecto.Changeset.change(type: "acquire_intelligence") |> Repo.update!()

    # Each refresh is its own Commitment, so the count follows the Ship over
    # the last hour rather than its current assignment.
    for minutes_ago <- [5, 40] do
      Repo.insert!(%{
        scouting
        | id: nil,
          fleet_commitment_id: nil,
          status: "completed",
          finished_at: DateTime.add(ctx.now, -minutes_ago * 60)
      })
    end

    Repo.insert!(%{
      scouting
      | id: nil,
        fleet_commitment_id: nil,
        status: "completed",
        finished_at: DateTime.add(ctx.now, -61 * 60)
    })

    overdue_demands(ctx, 3)

    status = status(ctx)
    assert status.kind == :scouting
    assert status.markets_refreshed == 2
    assert status.markets_overdue == 3
    assert status.phrase == "Refreshing markets: 2 refreshed in the last hour, 3 overdue"
  end

  test "an unassigned Ship during a Neutral Wait is Waiting on purpose until the next check",
       ctx do
    next = usec(DateTime.add(ctx.now, 600))
    neutral_wait(ctx, next)

    status = status(ctx)
    assert status.kind == :waiting
    assert status.next_check_at == next
    assert status.phrase == "Waiting for better trades; next check"
  end

  test "a blocked step is Stuck with its plain reason, retries and next attempt", ctx do
    next = DateTime.add(ctx.now, 240)

    ctx.intent
    |> Ecto.Changeset.change(status: "blocked", retries: 2, next_attempt_at: next)
    |> Ecto.Changeset.put_embed(:blocker, %SpaceTraders.Fleet.IntentBlocker{
      reason: "insufficient_unreserved_headroom",
      summary: "Not enough credits above the floor."
    })
    |> Repo.update!()

    status = status(ctx)
    assert status.kind == :stuck
    assert status.reason == "Not enough credits above the floor."
    assert status.retries == 2
    assert status.next_attempt_at == next
  end

  test "a Ship in a stalled allocation is Stuck and checked every minute", ctx do
    stall_episode(ctx, :authority_blocked_intent, [
      %{"kind" => "intent", "id" => ctx.intent.id, "reason" => "no_current_ship_claim"}
    ])

    status = status(ctx)
    assert status.kind == :stuck
    assert status.reason == "Fleet planning stalled: a Ship may no longer act on its step"
    assert status.next_attempt_at == nil
    assert status.phrase =~ "checks every minute"
  end

  test "an unassigned Ship while allocation stalls on overdue markets is Stuck", ctx do
    retire_portfolio(ctx)
    stall_episode(ctx, :overdue_demands_without_coverage, [], stalled_portfolio_id: nil)

    assert %{
             kind: :stuck,
             reason: "Fleet planning stalled: markets are overdue and nobody refreshes them"
           } =
             status(ctx)
  end

  test "three skipped buys in 30 minutes make a Ship with an hour of history Busy not earning",
       ctx do
    aged(ctx, 2 * 3600)
    skipped_buys(ctx, 3, 20 * 60)

    status = status(ctx)
    assert status.kind == :busy_not_earning
    assert status.phrase == "3 skipped buys in 30 min"
  end

  test "skipped buys older than 30 minutes do not count", ctx do
    aged(ctx, 2 * 3600)
    skipped_buys(ctx, 2, 10 * 60)
    skipped_buys(ctx, 1, 40 * 60)

    assert %{kind: :trading} = status(ctx)
  end

  test "last-hour Net Earnings below 40% of the 6 h average is Busy not earning", ctx do
    aged(ctx, 7 * 3600)
    # 6 000 over 6 h: 1 000 per hour on average; 300 in the last hour.
    earnings(ctx, 5_700, 3 * 3600)
    earnings(ctx, 300, 30 * 60)

    status = status(ctx)
    assert status.kind == :busy_not_earning
    assert status.phrase == "Last hour 300 vs 1,000/h over 6 h"
  end

  test "last-hour Net Earnings at 40% of the average or better stay Trading", ctx do
    aged(ctx, 7 * 3600)
    earnings(ctx, 3_600, 3 * 3600)
    earnings(ctx, 2_400, 30 * 60)

    assert %{kind: :trading} = status(ctx)
  end

  test "a Ship with less than an hour of its own history is never Busy not earning", ctx do
    aged(ctx, 50 * 60)
    skipped_buys(ctx, 4, 5 * 60)
    earnings(ctx, -500, 10 * 60)

    assert %{kind: :trading} = status(ctx)
  end

  test "a young Ship averages over its own history, not a full 6 h", ctx do
    # Two hours old: 2 000 earned 90 minutes ago is 1 000/h; nothing since.
    aged(ctx, 2 * 3600)
    earnings(ctx, 2_000, 90 * 60)

    assert %{kind: :busy_not_earning, phrase: "Last hour 0 vs 1,000/h over 2 h"} = status(ctx)
  end

  test "credits per Ship-hour come from the Ship's own Earnings records", ctx do
    earnings(ctx, 1_500, 600, 1_800)
    earnings(ctx, 500, 300, 1_800)

    # 2 000 net over two half-hour trips.
    assert status(ctx).credits_per_hour == 2_000
  end

  test "a Ship without Earnings records has no rate yet", ctx do
    assert status(ctx).credits_per_hour == nil
  end

  test "statuses for many Ships come from a fixed number of queries", ctx do
    ships =
      for n <- 1..30 do
        {:ok, ship} = SpaceTraders.Fleet.record_ship(ctx.agent, "MANY-#{n}", "SHIP_PROBE")
        ship
      end

    count = fn ships ->
      ref = make_ref()
      parent = self()
      handler = "ship-status-queries-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        SpaceTraders.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _, _, _, _ ->
          send(parent, {ref, :query})
        end,
        nil
      )

      ShipStatus.for_ships(ctx.agent, ships, ctx.now)
      :telemetry.detach(handler)

      Stream.repeatedly(fn -> receive do: ({^ref, :query} -> 1), after: (0 -> nil) end)
      |> Enum.take_while(& &1)
      |> length()
    end

    assert count.(Enum.take(ships, 2)) == count.(ships)
  end

  defp status(ctx) do
    ctx.agent
    |> ShipStatus.for_ships([Repo.get!(Ship, ctx.ship.id)], ctx.now)
    |> Map.fetch!(ctx.ship.id)
  end

  defp usec(%DateTime{} = at), do: %{at | microsecond: {0, 6}}

  defp short(symbol), do: symbol |> String.split("-") |> List.last()

  defp aged(ctx, seconds) do
    Repo.update_all(from(s in Ship, where: s.id == ^ctx.ship.id),
      set: [inserted_at: DateTime.add(ctx.now, -seconds)]
    )
  end

  defp skipped_buys(ctx, count, seconds_ago) do
    for _ <- 1..count do
      Repo.insert!(%{
        ctx.intent
        | id: nil,
          status: "infeasible",
          finished_at: DateTime.add(ctx.now, -seconds_ago)
      })
    end
  end

  defp earnings(ctx, net, seconds_ago, ship_seconds \\ 600) do
    at = usec(DateTime.add(ctx.now, -seconds_ago))

    Repo.insert!(%EarningsRecord{
      source: "trade",
      fleet_generation_id: ctx.generation.id,
      ship_symbol: ctx.ship.symbol,
      ship_type: ctx.ship.ship_type,
      good: "IRON_ORE",
      source_waypoint: "X1-A-B1",
      destination_waypoint: "X1-A-C2",
      units: 10,
      revenue: max(net, 0) + 100,
      goods_cost: 100 + max(-net, 0),
      fuel_cost: 0,
      other_cost: 0,
      net_earnings: net,
      ship_seconds: ship_seconds,
      started_at: DateTime.add(at, -ship_seconds),
      finished_at: at
    })
  end

  defp overdue_demands(ctx, count) do
    for n <- 1..count do
      Repo.insert!(%ObservationDemand{
        agent_id: ctx.agent.id,
        strategy_revision_id: ctx.revision.id,
        subject: "market:X1-D#{n}",
        required_facts: ["market"],
        freshness_seconds: 300,
        due_at: usec(DateTime.add(ctx.now, -60)),
        owner: "fleet_planning"
      })
    end
  end

  defp retire_portfolio(ctx) do
    Repo.update!(Ecto.Changeset.change(ctx.portfolio, superseded_at: DateTime.utc_now()))
  end

  defp neutral_wait(ctx, next) do
    retire_portfolio(ctx)

    episode =
      Repo.insert!(%Episode{
        operator_id: ctx.generation.operator_id,
        fleet_generation_id: ctx.generation.id,
        fleet_strategy_revision_id: ctx.revision.id,
        source_version: 1,
        calibration_version: "market-v1",
        selection_kind: :neutral_wait,
        binding_limitation_kind: :below_economic_threshold,
        next_observation_at: next,
        expectations: %{"binding_limitation" => %{"reason" => "below_economic_threshold"}}
      })

    Repo.update_all(
      from(p in AllocationResultPointer, where: p.fleet_generation_id == ^ctx.generation.id),
      set: [selection_kind: :neutral_wait, strategy_decision_episode_id: episode.id]
    )
  end

  defp stall_episode(ctx, reason, references, opts \\ []) do
    Repo.insert!(%Episode{
      operator_id: ctx.generation.operator_id,
      fleet_generation_id: ctx.generation.id,
      fleet_strategy_revision_id: ctx.revision.id,
      source_version: 1,
      calibration_version: "market-v1",
      selection_kind: :structural_stall,
      stall_reason: reason,
      stalled_portfolio_id: Keyword.get(opts, :stalled_portfolio_id, ctx.portfolio.id),
      evidence_references: references,
      last_observed_at: DateTime.utc_now(),
      observation_count: 3
    })
  end
end
