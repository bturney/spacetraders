defmodule SpaceTraders.FleetAllocation.StructuralStall do
  @moduledoc """
  Durable, deduplicated structural stall disposition for the Market pilot
  domain (#684, #686; ADR 0012 amendment).

  After each Market allocation decision Fleet Allocation asks whether the
  Fleet is structurally unable to progress, and why, in precedence order:

    1. `:stale_revision_portfolio` - the current Portfolio belongs to an older
       Revision than the active one (its retirement failed this boundary);
    2. `:authority_blocked_intent` - a current Commitment's Intent is blocked
       on execution authority;
    3. `:overdue_demands_without_coverage` - active-Revision Market
       Observation Demands are overdue, the decision admitted zero coverage
       candidates, and no valid current-Revision reason explains it.

  Only decisive dispositions explain (3), read from the decision and
  authoritative state: work selected or coverage admitted, every Ship
  occupied by valid work (counted, or the decision's own
  `:all_ships_occupied`), retained current-Revision coverage (single-scout),
  API Capacity Deferral, a recorded Neutral Wait, or an open credit
  Shortfall. An errored decision or missing candidate counts explain
  nothing, so they cannot hide a stall.

  A stall is one `structural_stall` Strategy Decision Episode per Fleet
  Generation, keyed by Revision, reason and stalled Portfolio. An unchanged
  stall refreshes that Episode in place; a changed one closes it and opens
  its successor; recovery closes it. Closing records `resolved_at` and
  classifies it superseded: a later decision, healthy or another stall,
  superseded it. Observation is serialized per Generation by the Generation
  row lock, so the one open stall is never inserted twice. It is never a
  selection kind, a Neutral Wait or a recovery authority, and the allocation
  result pointer never references it.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Clock
  alias SpaceTraders.CreditCalibration.Shortfall
  alias SpaceTraders.Evidence
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{JsonEvidence, Portfolio}
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Repo

  # Refusals of execution authority itself, not of the game or of spending.
  @authority_blockers ~w(
    strategy_revision_absent
    no_current_ship_claim
    intent_claim_mismatch
    recorded_dispatch_authority_stale
    fleet_generation_absent
  )

  @deferral_actions [:retained_for_capacity, :deferred_for_capacity]

  @doc """
  Evaluates the stall predicates after one decision and records the result.

  `decision` carries the decision's `result` and its candidate `counts`.
  Returns `{:stalled, episode}` or `:healthy`.
  """
  def observe(%AgentRecord{} = agent, %Revision{} = revision, portfolio, decision) do
    case FleetAllocation.active_generation(agent) do
      %Generation{} = generation ->
        stall = diagnose(agent, revision, portfolio, decision)
        record(generation, revision, stall)

      nil ->
        :healthy
    end
  end

  @doc "The decision's structural stall, or nil when it is healthy or explained."
  def diagnose(agent, %Revision{id: active}, portfolio, decision) do
    cond do
      match?(%Portfolio{}, portfolio) and portfolio.fleet_strategy_revision_id != active ->
        stall(:stale_revision_portfolio, portfolio, [
          %{"kind" => "portfolio", "id" => portfolio.id},
          %{"kind" => "revision", "id" => portfolio.fleet_strategy_revision_id}
        ])

      (blocked = authority_blocked_intents(portfolio)) != [] ->
        stall(
          :authority_blocked_intent,
          portfolio,
          Enum.map(blocked, &%{"kind" => "intent", "id" => &1.id, "reason" => &1.blocker.reason})
        )

      (overdue = unexplained_overdue_demands(agent, active, portfolio, decision)) != [] ->
        stall(
          :overdue_demands_without_coverage,
          portfolio,
          Enum.map(overdue, &%{"kind" => "observation_demand", "subject" => &1})
        )

      true ->
        nil
    end
  end

  defp stall(reason, portfolio, references),
    do: %{reason: reason, portfolio: portfolio, references: references}

  defp authority_blocked_intents(%Portfolio{id: portfolio_id}) do
    portfolio_id
    |> FleetAllocation.unfinished_commitment_intents()
    |> Enum.filter(
      &(&1.status == "blocked" and &1.blocker != nil and
          &1.blocker.reason in @authority_blockers)
    )
  end

  defp authority_blocked_intents(_portfolio), do: []

  defp unexplained_overdue_demands(agent, active, portfolio, %{result: result, counts: counts}) do
    if explained?(agent, active, portfolio, result, counts) do
      []
    else
      now = Clock.utc_now()

      agent
      |> Evidence.list_open_demands()
      |> Enum.filter(fn demand ->
        demand.owner == "fleet_planning" and demand.strategy_revision_id == active and
          String.starts_with?(demand.subject, "market:") and
          DateTime.compare(demand.due_at, now) != :gt
      end)
      |> Enum.map(& &1.subject)
      |> Enum.sort()
    end
  end

  # Only the decision's own decisive disposition explains zero coverage
  # candidates. An error or an absent count is not one.
  defp explained?(_agent, _active, _portfolio, {:error, _reason}, _counts), do: false

  defp explained?(agent, active, portfolio, {:ok, decided}, counts) do
    Map.get(decided, :action) in @deferral_actions or
      Map.get(decided, :reason) == :all_ships_occupied or
      match?(%Episode{}, Map.get(decided, :neutral_wait)) or
      positive?(counts, :coverage_candidates) or
      positive?(counts, :selected) or
      Map.fetch(counts, :claimable_ships) == {:ok, 0} or
      current_coverage?(portfolio, active) or
      open_shortfall?(agent)
  end

  defp positive?(counts, key), do: Map.get(counts, key, 0) > 0

  defp current_coverage?(%Portfolio{fleet_strategy_revision_id: active} = portfolio, active) do
    Enum.any?(portfolio.commitments, fn commitment ->
      Enum.any?(commitment.dependencies, fn dependency ->
        match?(%{"subject" => "market:" <> _}, dependency) and
          not Map.has_key?(dependency, "evidence_id")
      end)
    end)
  end

  defp current_coverage?(_portfolio, _active), do: false

  defp open_shortfall?(%AgentRecord{id: agent_id}) do
    Repo.exists?(from s in Shortfall, where: s.agent_id == ^agent_id and is_nil(s.released_at))
  end

  defp record(generation, revision, stall) do
    {:ok, result} =
      Repo.transaction(fn ->
        # One observer per Generation at a time: Generation before Episode.
        Repo.one!(from g in Generation, where: g.id == ^generation.id, lock: "FOR NO KEY UPDATE")
        now = Clock.utc_now()
        open = open_stall(generation.id)

        cond do
          is_nil(stall) ->
            if open, do: close!(open, now)
            :healthy

          unchanged?(open, revision, stall) ->
            {:stalled, refresh!(open, stall, now)}

          true ->
            if open, do: close!(open, now)
            {:stalled, open!(generation, revision, stall, now)}
        end
      end)

    result
  end

  defp unchanged?(nil, _revision, _stall), do: false

  defp unchanged?(open, revision, stall) do
    open.fleet_strategy_revision_id == revision.id and open.stall_reason == stall.reason and
      open.stalled_portfolio_id == portfolio_id(stall)
  end

  defp refresh!(open, stall, now) do
    open
    |> Ecto.Changeset.change(
      last_observed_at: now,
      observation_count: open.observation_count + 1,
      evidence_references: JsonEvidence.dump(stall.references)
    )
    |> Repo.update!()
  end

  defp open!(generation, revision, stall, now) do
    Repo.insert!(%Episode{
      operator_id: generation.operator_id,
      fleet_generation_id: generation.id,
      fleet_strategy_revision_id: revision.id,
      source_version: generation.allocation_version,
      calibration_version: FleetAllocation.market_calibration_version(),
      selection_kind: :structural_stall,
      stall_reason: stall.reason,
      stalled_portfolio_id: portfolio_id(stall),
      evidence_references: JsonEvidence.dump(stall.references),
      last_observed_at: now,
      observation_count: 1
    })
  end

  defp portfolio_id(%{portfolio: %Portfolio{id: id}}), do: id
  defp portfolio_id(_stall), do: nil

  defp close!(episode, now) do
    episode
    |> Ecto.Changeset.change(resolved_at: now, classification: :superseded)
    |> Repo.update!()
  end

  defp open_stall(generation_id) do
    Repo.one(
      from episode in Episode,
        where:
          episode.fleet_generation_id == ^generation_id and
            episode.selection_kind == :structural_stall and is_nil(episode.resolved_at)
    )
  end
end
