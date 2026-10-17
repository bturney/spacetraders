defmodule SpaceTraders.MissionControlDispositionsTest do
  @moduledoc """
  Mission Control projects the Agent's actual Market allocation disposition
  from durable facts, without minting status or mutating the game (#688).
  Seam: `MissionControl.market_execution/1` `:dispositions`.
  """
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.CreditSpendingFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.CapacityGovernor
  alias SpaceTraders.CreditCalibration
  alias SpaceTraders.CreditCalibration.Shortfall
  alias SpaceTraders.Evidence.ObservationDemand
  alias SpaceTraders.FleetAllocation.AllocationResultPointer
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MissionControl

  setup tags do
    fleet(Map.get(tags, :reservations, [0]))
  end

  defp fleet(reservations) do
    {agent, intents, portfolio} = claimed_purchases(reservations)
    scope = Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))
    generation = Repo.get_by!(Generation, agent_id: agent.id)
    revision = Repo.get!(Revision, portfolio.fleet_strategy_revision_id)

    %{
      agent: agent,
      intents: intents,
      scope: scope,
      portfolio: portfolio,
      generation: generation,
      revision: revision
    }
  end

  test "one Ship trading under the active Revision while Market Demands are overdue is healthy busy",
       ctx do
    overdue_demands(ctx, 27)

    assert [disposition] = dispositions(ctx)
    assert disposition.state == :busy_trade
    assert disposition.healthy?
    assert disposition.stall == nil
    assert disposition.overdue_demand_count == 27
    assert disposition.operator_action == :none
    assert disposition.active_revision.number == 1
    assert [_] = disposition.portfolio.commitment_ids
  end

  test "retained current-Revision coverage is its own healthy state", ctx do
    [commitment] = ctx.portfolio.commitments

    commitment
    |> Ecto.Changeset.change(dependencies: [%{"subject" => "market:X1-A3"}])
    |> Repo.update!()

    overdue_demands(ctx, 3)

    assert [%{state: :retained_coverage, healthy?: true, overdue_demand_count: 3}] =
             dispositions(ctx)
  end

  test "a Portfolio of a superseded Revision is a non-healthy stall with causal identity", ctx do
    newer = activate_newer_revision(ctx)
    before = Repo.aggregate(Episode, :count)

    assert [%{state: :stalled, healthy?: false, degraded?: true, stall: stall} = disposition] =
             dispositions(ctx)

    assert stall.reason == :stale_revision_portfolio
    assert stall.portfolio_id == ctx.portfolio.id
    assert stall.portfolio_revision_number == 1
    assert stall.decision_episode_id == ctx.portfolio.strategy_decision_episode_id
    assert stall.commitment_ids == Enum.map(ctx.portfolio.commitments, & &1.id)
    assert stall.release =~ "Revision #{newer.number}"
    assert disposition.active_revision.number == 2

    # Reading mints nothing: no Episode or status row.
    assert Repo.aggregate(Episode, :count) == before
  end

  test "a recorded authority-blocked stall shows its Episode and clears once resolved", ctx do
    episode =
      stall_episode(ctx, :authority_blocked_intent, [
        %{"kind" => "intent", "id" => 41, "reason" => "no_current_ship_claim"}
      ])

    assert [%{state: :stalled, stall: stall}] = dispositions(ctx)
    assert stall.reason == :authority_blocked_intent
    assert stall.stall_episode_id == episode.id

    assert stall.references == [
             %{"kind" => "intent", "id" => 41, "reason" => "no_current_ship_claim"}
           ]

    assert stall.release =~ "Claim is released"

    episode |> Ecto.Changeset.change(resolved_at: DateTime.utc_now()) |> Repo.update!()

    assert [%{state: :busy_trade, healthy?: true, stall: nil}] = dispositions(ctx)
  end

  @tag reservations: [0, 0]
  test "an authority-blocked stall names only the blocked Intent and its Commitment", ctx do
    [blocked, _trading] = ctx.intents

    stall_episode(ctx, :authority_blocked_intent, [
      %{"kind" => "intent", "id" => blocked.id, "reason" => "no_current_ship_claim"}
    ])

    assert [%{state: :stalled, stall: stall}] = dispositions(ctx)
    assert stall.intent_ids == [blocked.id]
    assert stall.commitment_ids == [blocked.fleet_commitment_id]
  end

  test "a stall naming a replaced Portfolio is not shown as current", ctx do
    stall_episode(ctx, :authority_blocked_intent, [], stalled_portfolio_id: nil)

    assert [%{state: :busy_trade, stall: nil}] = dispositions(ctx)
  end

  test "an open Shortfall is a spending pause with balance, floor and release predicate", ctx do
    shortfall = open_shortfall(ctx, 900)
    stub_quote(ctx.agent, 10, 900)
    assert {:ok, %{credits: 900}} = SpaceTraders.Agent.agent_overview(ctx.agent)

    assert [%{state: :spending_paused, healthy?: true, spending_pause: pause}] =
             dispositions(ctx)

    assert pause.shortfall_id == shortfall.id
    assert pause.balance == 900
    assert pause.floor == 1_000
    assert pause.kind == "revision_floor"
    assert pause.release =~ "at or above the 1000 credit floor"
  end

  test "a released Shortfall no longer appears as an active pause", ctx do
    shortfall = open_shortfall(ctx, 900)

    shortfall
    |> Ecto.Changeset.change(released_at: DateTime.utc_now())
    |> Repo.update!()

    assert [%{state: :busy_trade, spending_pause: nil}] = dispositions(ctx)
    assert [%{released_at: %DateTime{}}] = CreditCalibration.shortfalls(ctx.agent)
  end

  test "a genuine Neutral Wait shows its limitation and next observation, never a pause", ctx do
    retire_portfolio(ctx)
    next = DateTime.add(DateTime.utc_now(), 600, :second)

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

    assert [%{state: :neutral_wait, neutral_wait: wait, spending_pause: nil}] = dispositions(ctx)
    assert wait.limitation_kind == :below_economic_threshold
    assert wait.coverage == nil
    assert wait.next_observation_at == next
    assert wait.decision_episode_id == episode.id
  end

  test "an incomplete-coverage Neutral Wait reports coverage and its last evaluation", ctx do
    retire_portfolio(ctx)
    next = DateTime.add(DateTime.utc_now(), 600, :second)
    evaluated = ~U[2026-10-11 09:30:00Z]

    episode =
      Repo.insert!(%Episode{
        operator_id: ctx.generation.operator_id,
        fleet_generation_id: ctx.generation.id,
        fleet_strategy_revision_id: ctx.revision.id,
        source_version: 1,
        calibration_version: "market-v1",
        selection_kind: :neutral_wait,
        binding_limitation_kind: :incomplete_coverage,
        next_observation_at: next,
        expectations: %{
          "binding_limitation" => %{
            "reason" => "incomplete_market_coverage",
            "coverage" => %{"completed" => 3, "required" => 5}
          }
        },
        actual_outcomes: %{
          "re_evaluations" => [
            %{"observed_at" => "2026-10-11T09:00:00Z"},
            %{"observed_at" => DateTime.to_iso8601(evaluated)}
          ]
        }
      })

    Repo.update_all(
      from(p in AllocationResultPointer, where: p.fleet_generation_id == ^ctx.generation.id),
      set: [selection_kind: :neutral_wait, strategy_decision_episode_id: episode.id]
    )

    assert [%{state: :neutral_wait, neutral_wait: wait}] = dispositions(ctx)
    assert wait.coverage == %{completed: 3, required: 5}
    assert wait.last_evaluated_at == evaluated
    assert wait.next_observation_at == next
  end

  test "a floor pause is not a Neutral Wait even when a stale wait pointer lingers", ctx do
    retire_portfolio(ctx)
    open_shortfall(ctx, 900)

    assert [%{state: :spending_paused, neutral_wait: nil}] = dispositions(ctx)
  end

  test "Capacity Deferral is its own state, with the governor's retry guidance", ctx do
    retire_portfolio(ctx)
    throttle_get_market()

    assert [%{state: :capacity_deferred, healthy?: true, capacity_deferral: deferral}] =
             dispositions(ctx)

    assert %DateTime{} = deferral.retry_at
  end

  test "a trading Ship stays busy while get-market is throttled", ctx do
    throttle_get_market()

    assert [%{state: :busy_trade, healthy?: true, capacity_deferral: %{retry_at: %DateTime{}}}] =
             dispositions(ctx)
  end

  defp throttle_get_market do
    governor = :"mc_dispositions_governor_#{System.unique_integer([:positive])}"
    start_supervised!({CapacityGovernor, name: governor})
    previous = Application.fetch_env(:spacetraders, SpaceTraders.FleetCapacity)
    Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, governor: governor)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, value)
        :error -> Application.delete_env(:spacetraders, SpaceTraders.FleetCapacity)
      end
    end)

    CapacityGovernor.protocol_rejected(30, governor)
  end

  test "Ships outside every live Claim are listed as Unallocated", ctx do
    {:ok, _} = SpaceTraders.Fleet.record_ship(ctx.agent, "IDLE-1", "SHIP_PROBE")
    assert [%{unallocated_ships: ["IDLE-1"]}] = dispositions(ctx)
  end

  defp dispositions(ctx), do: MissionControl.market_execution(ctx.scope).dispositions

  defp overdue_demands(ctx, count) do
    for n <- 1..count do
      Repo.insert!(%ObservationDemand{
        agent_id: ctx.agent.id,
        strategy_revision_id: ctx.revision.id,
        subject: "market:X1-D#{n}",
        required_facts: ["market"],
        freshness_seconds: 300,
        due_at: DateTime.add(DateTime.utc_now(), -60, :second),
        owner: "fleet_planning"
      })
    end
  end

  defp open_shortfall(ctx, credits) do
    Repo.insert!(%Shortfall{
      agent_id: ctx.agent.id,
      kind: "revision_floor",
      credits: credits,
      credit_floor: 1_000,
      detected_at: DateTime.add(DateTime.utc_now(), -5, :second)
    })
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

  defp retire_portfolio(ctx) do
    Repo.update!(Ecto.Changeset.change(ctx.portfolio, superseded_at: DateTime.utc_now()))
  end

  defp activate_newer_revision(ctx) do
    strategy = Repo.get!(Strategy, ctx.revision.fleet_strategy_id)

    newer =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 2,
        document: ctx.revision.document,
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: newer.id))
    newer
  end
end
