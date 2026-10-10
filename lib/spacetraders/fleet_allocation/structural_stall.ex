defmodule SpaceTraders.FleetAllocation.StructuralStall do
  @moduledoc """
  Durable, deduplicated structural stall disposition for the Market pilot
  domain (#684; ADR 0012 amendment).

  After each Market allocation decision Fleet Allocation asks whether the
  Fleet is structurally unable to progress, and why, in precedence order:

    1. `:stale_revision_portfolio` - the current Portfolio belongs to an older
       Revision than the active one;
    2. `:authority_blocked_intent` - a current Commitment's Intent is blocked
       on execution authority;
    3. `:overdue_demands_without_coverage` - active-Revision Market
       Observation Demands are overdue, the decision admitted zero coverage
       candidates, and no valid current-Revision reason explains it.

  Valid reasons for (3) are the decision's own dispositions, read from
  authoritative state: retained current-Revision coverage (single-scout),
  no claimable Ship because valid work occupies them, API Capacity Deferral,
  or an open credit Shortfall; a decision that selected work is busy too.
  They are busy, deferred or a spending pause,
  never a stall.

  A stall is one `structural_stall` Strategy Decision Episode per Fleet
  Generation, keyed by Revision, reason and stalled Portfolio. An unchanged
  stall refreshes that Episode in place; a changed one resolves it and opens
  its successor; recovery resolves it. It is never a selection kind, a
  Neutral Wait or a recovery authority, and the allocation result pointer
  never references it.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Clock
  alias SpaceTraders.CreditCalibration.Shortfall
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, JsonEvidence, Portfolio}
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
    case current_generation(agent) do
      %Generation{} = generation ->
        case diagnose(agent, revision, portfolio, decision) do
          nil -> resolve(generation)
          stall -> record(generation, revision, stall)
        end

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
          Enum.map(blocked, &%{"kind" => "intent", "id" => &1.id, "reason" => &1.reason})
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
    Repo.all(
      from intent in Intent,
        join: commitment in Commitment,
        on: commitment.id == intent.fleet_commitment_id,
        where:
          commitment.fleet_commitment_portfolio_id == ^portfolio_id and
            intent.caller == "commitment" and intent.status == "blocked",
        order_by: intent.id,
        select: intent
    )
    |> Enum.filter(&(&1.blocker && &1.blocker.reason in @authority_blockers))
    |> Enum.map(&%{id: &1.id, reason: &1.blocker.reason})
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

  # The decision's own disposition explains zero coverage candidates.
  defp explained?(agent, active, portfolio, result, counts) do
    case result do
      {:error, _reason} ->
        true

      {:ok, %{action: action}} when action in @deferral_actions ->
        true

      _decided ->
        Map.get(counts, :coverage_candidates, 0) > 0 or
          Map.get(counts, :selected, 0) > 0 or
          Map.get(counts, :claimable_ships, 0) == 0 or
          current_coverage?(portfolio, active) or
          open_shortfall?(agent)
    end
  end

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
    now = Clock.utc_now()
    portfolio_id = stall.portfolio && stall.portfolio.id
    references = JsonEvidence.dump(stall.references)

    {:ok, episode} =
      Repo.transaction(fn ->
        case open_stall(generation.id) do
          %Episode{
            fleet_strategy_revision_id: revision_id,
            stall_reason: reason,
            stalled_portfolio_id: ^portfolio_id
          } = open
          when revision_id == revision.id and reason == stall.reason ->
            open
            |> Ecto.Changeset.change(
              last_observed_at: now,
              observation_count: open.observation_count + 1,
              evidence_references: references
            )
            |> Repo.update!()

          open ->
            if open, do: close!(open, now)

            Repo.insert!(%Episode{
              operator_id: generation.operator_id,
              fleet_generation_id: generation.id,
              fleet_strategy_revision_id: revision.id,
              source_version: generation.allocation_version,
              calibration_version: FleetAllocation.market_calibration_version(),
              selection_kind: :structural_stall,
              stall_reason: stall.reason,
              stalled_portfolio_id: portfolio_id,
              evidence_references: references,
              last_observed_at: now,
              observation_count: 1
            })
        end
      end)

    {:stalled, episode}
  end

  defp resolve(generation) do
    if open = open_stall(generation.id), do: close!(open, Clock.utc_now())
    :healthy
  end

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
            episode.selection_kind == :structural_stall and is_nil(episode.resolved_at),
        lock: "FOR UPDATE"
    )
  end

  defp current_generation(%AgentRecord{id: agent_id}) do
    Repo.one(
      from generation in Generation,
        where:
          generation.agent_id == ^agent_id and is_nil(generation.fenced_at) and
            is_nil(generation.retired_at)
    )
  end
end
