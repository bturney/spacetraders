defmodule SpaceTraders.MissionControl.MarketDisposition do
  @moduledoc """
  Read projection of one Agent's actual Market allocation disposition (#688).

  Reuses durable facts only: the open `structural_stall` Decision Episode,
  the Portfolio and its Commitments, the current Neutral Wait, credit
  Shortfalls and retained authoritative credits, Observation Demands and the
  advisory Capacity Disposition. It stores nothing, mints no Neutral Wait and
  requests no gameplay mutation.

  `state` is one distinct disposition, in precedence order: `:stalled`,
  `:spending_paused`, `:busy_trade`, `:capacity_deferred`, `:neutral_wait`,
  `:retained_coverage`, `:unallocated`. Only `:stalled` is non-healthy
  (Degraded Operation). `operator_action` stays `:none`: a stall releases
  through reconciliation. `FleetAllocation.StructuralStall` records the stall,
  never this read.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.CreditCalibration
  alias SpaceTraders.CreditSpending
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{AllocationResultPointer, Commitment, Portfolio}
  alias SpaceTraders.FleetAllocation.StructuralStall
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.Repo

  @doc "The Agent's disposition, or nil without an active Fleet Generation or Revision."
  def for_agent(%AgentRecord{} = agent, %Revision{} = active, portfolio) do
    case FleetAllocation.active_generation(agent) do
      nil -> nil
      generation -> build(agent, generation, active, portfolio)
    end
  end

  def for_agent(_agent, _active, _portfolio), do: nil

  defp build(agent, generation, active, portfolio) do
    stall = stall(generation, active, portfolio)
    pause = spending_pause(agent, active)
    deferral = capacity_deferral()
    wait = neutral_wait(generation, active)
    work = work(active, portfolio)
    overdue = StructuralStall.overdue_demands(agent, active.id)

    state =
      cond do
        stall -> :stalled
        pause -> :spending_paused
        # A trading Ship is busy whatever get-market's capacity; deferral
        # only explains Ships waiting on Market reads.
        work == :busy_trade -> :busy_trade
        deferral -> :capacity_deferred
        wait -> :neutral_wait
        work -> work
        true -> :unallocated
      end

    %{
      agent_symbol: agent.symbol,
      state: state,
      healthy?: state != :stalled,
      degraded?: state == :stalled,
      operator_action: :none,
      active_revision: %{id: active.id, number: active.number},
      portfolio: portfolio_identity(portfolio),
      stall: stall,
      spending_pause: pause,
      capacity_deferral: deferral,
      neutral_wait: wait,
      overdue_demand_count: length(overdue),
      unallocated_ships: unallocated_ships(agent, portfolio)
    }
  end

  ## Stall

  defp stall(generation, active, portfolio) do
    live = live_stale(active, portfolio)
    open = open_stall(generation.id, portfolio)

    cond do
      live -> identity(:stale_revision_portfolio, portfolio, open, active, live)
      open -> identity(open.stall_reason, portfolio, open, active, nil)
      true -> nil
    end
  end

  # The Portfolio's Revision against the active one is read live, so a
  # mismatch is visible before the next allocation boundary records it.
  defp live_stale(active, portfolio) do
    if StructuralStall.stale_revision?(portfolio, active),
      do: Repo.get(Revision, portfolio.fleet_strategy_revision_id)
  end

  # An open stall belongs to the current Portfolio (or to none); one naming a
  # Portfolio that has since been replaced is a recovery in progress.
  defp open_stall(generation_id, portfolio) do
    portfolio_id = portfolio && portfolio.id

    Repo.one(
      from episode in Episode,
        where:
          episode.fleet_generation_id == ^generation_id and
            episode.selection_kind == :structural_stall and is_nil(episode.resolved_at),
        limit: 1
    )
    |> case do
      %Episode{stalled_portfolio_id: ^portfolio_id} = episode -> episode
      _ -> nil
    end
  end

  defp identity(reason, portfolio, open, active, portfolio_revision) do
    references = (open && open.evidence_references) || []
    {intent_ids, commitment_ids} = stalled_work(reason, portfolio, references)

    %{
      reason: reason,
      stall_episode_id: open && open.id,
      portfolio_id: portfolio && portfolio.id,
      portfolio_revision_number: portfolio_revision && portfolio_revision.number,
      intent_ids: intent_ids,
      commitment_ids: commitment_ids,
      decision_episode_id: portfolio && portfolio.strategy_decision_episode_id,
      references: references,
      observation_count: open && open.observation_count,
      last_observed_at: open && open.last_observed_at,
      release: StructuralStall.release_condition(reason, active)
    }
  end

  # The work the stall names: a superseded Portfolio stalls all of its
  # Commitments; an authority block only the blocked Intents' Commitments.
  defp stalled_work(:stale_revision_portfolio, portfolio, _references),
    do: {[], commitment_ids(portfolio)}

  defp stalled_work(:authority_blocked_intent, _portfolio, references) do
    ids = for %{"kind" => "intent", "id" => id} <- references, do: id

    commitments =
      Repo.all(
        from intent in Intent,
          where: intent.id in ^ids and not is_nil(intent.fleet_commitment_id),
          distinct: true,
          order_by: intent.fleet_commitment_id,
          select: intent.fleet_commitment_id
      )

    {ids, commitments}
  end

  defp stalled_work(_reason, _portfolio, _references), do: {[], []}

  ## Spending pause

  defp spending_pause(%AgentRecord{} = agent, active) do
    agent
    |> CreditCalibration.oldest_open_shortfall()
    |> case do
      nil ->
        nil

      shortfall ->
        floor =
          case StandingAuthority.credit_floor(active) do
            {:ok, floor} -> floor
            _ -> shortfall.credit_floor
          end

        balance =
          case CreditSpending.authoritative_credits(agent) do
            {:ok, %{value: %{credits: credits}}} -> credits
            _ -> nil
          end

        %{
          shortfall_id: shortfall.id,
          kind: shortfall.kind,
          credits_at_detection: shortfall.credits,
          balance: balance,
          floor: floor,
          detected_at: shortfall.detected_at,
          release:
            "An authoritative credit balance observed after " <>
              "#{Calendar.strftime(shortfall.detected_at, "%Y-%m-%d %H:%M:%S UTC")} " <>
              "at or above the #{floor} credit floor."
        }
    end
  end

  ## Capacity

  defp capacity_deferral do
    case FleetCapacity.disposition("get-market") do
      %{status: :proceed} -> nil
      disposition -> %{reason: disposition.reason, retry_at: disposition.retry_at}
    end
  end

  ## Neutral Wait

  defp neutral_wait(generation, active) do
    with %AllocationResultPointer{selection_kind: :neutral_wait, strategy_decision_episode_id: id} <-
           Repo.get_by(AllocationResultPointer, fleet_generation_id: generation.id),
         %Episode{fleet_strategy_revision_id: revision_id} = episode when revision_id == active.id <-
           Repo.get(Episode, id) do
      # ADR 0012: the summary's facts; the Episode id is click-through only.
      %{
        decision_episode_id: episode.id,
        limitation_kind: episode.binding_limitation_kind,
        coverage: wait_coverage(episode),
        last_evaluated_at: last_evaluated_at(episode),
        next_observation_at: episode.next_observation_at
      }
    else
      _ -> nil
    end
  end

  defp wait_coverage(%Episode{binding_limitation_kind: :incomplete_coverage} = episode) do
    case get_in(episode.expectations, ["binding_limitation", "coverage"]) do
      %{"completed" => completed, "required" => required}
      when is_integer(completed) and is_integer(required) ->
        %{completed: completed, required: required}

      _ ->
        nil
    end
  end

  defp wait_coverage(_episode), do: nil

  # The wait's latest re-evaluation, else when the Episode last changed.
  defp last_evaluated_at(episode) do
    with [_ | _] = entries <- get_in(episode.actual_outcomes || %{}, ["re_evaluations"]),
         %{"observed_at" => at} <- List.last(entries),
         {:ok, at, _offset} <- DateTime.from_iso8601(at) do
      at
    else
      _ -> episode.updated_at
    end
  end

  ## Authorized work

  defp work(active, %Portfolio{fleet_strategy_revision_id: id, commitments: commitments})
       when id == active.id do
    live = live_commitments(commitments)

    cond do
      live == [] -> nil
      Enum.any?(live, &(not Commitment.coverage?(&1))) -> :busy_trade
      true -> :retained_coverage
    end
  end

  defp work(_active, _portfolio), do: nil

  defp portfolio_identity(%Portfolio{} = portfolio),
    do: %{
      id: portfolio.id,
      revision_id: portfolio.fleet_strategy_revision_id,
      decision_episode_id: portfolio.strategy_decision_episode_id,
      commitment_ids: commitment_ids(portfolio)
    }

  defp portfolio_identity(_portfolio), do: nil

  defp commitment_ids(%Portfolio{commitments: commitments}), do: Enum.map(commitments, & &1.id)
  defp commitment_ids(_portfolio), do: []

  defp unallocated_ships(%AgentRecord{id: agent_id}, portfolio) do
    claimed =
      case portfolio do
        %Portfolio{commitments: commitments} ->
          commitments |> live_commitments() |> Enum.flat_map(& &1.claims)

        _ ->
          []
      end

    Repo.all(from s in Ship, where: s.agent_id == ^agent_id, order_by: s.symbol, select: s.symbol)
    |> Enum.reject(&(&1 in claimed))
  end

  defp live_commitments(commitments),
    do: Enum.filter(commitments, &(&1.unwind_state == :not_required))
end
