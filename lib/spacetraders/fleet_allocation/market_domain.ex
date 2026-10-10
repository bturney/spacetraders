defmodule SpaceTraders.FleetAllocation.MarketDomain do
  @moduledoc """
  Fleet Allocation's selection and publication for the Market pilot domain
  (Market trade, Marketplace coverage and compatible retained Commitments),
  as ADR 0010 assigns them.

  `select/5` turns admitted Candidate Contributions into one selection with
  every rejection recorded: Credit Reservations that would cross the credit
  floor and the capable Ships not assigned to each selected role.
  `publish/5` revalidates the trade evidence and then publishes, replans,
  releases or retains the portfolio, mints the single Neutral Wait (ADR 0012)
  or records a rejected publication. It dispatches nothing: a
  `{:published, portfolio}` result is handed back to `FleetExecution`, which
  activates the root Intents.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Clock
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo

  @doc """
  Selects one portfolio from admitted Candidates and the free Claims, keeping
  only Commitments whose Credit Reservation stays above the credit floor.
  `unavailable` rejections from admission are carried into the selection.
  """
  def select(revision, candidates, availability, claims, unavailable) do
    with {:ok, selection} <-
           FleetAllocation.select_portfolio(revision, candidates, %{availability | claims: claims}) do
      {eligible, unaffordable} =
        Enum.split_with(
          selection.commitments,
          &reservation_covers_exposure?(&1, revision, availability)
        )

      {:ok,
       %{
         selection
         | commitments: eligible,
           rejected:
             selection.rejected ++
               unavailable ++
               Enum.map(unaffordable, &credit_floor_rejection/1) ++
               role_alternatives(eligible, candidates, claims)
       }}
    end
  end

  @doc "Returns true when Credit Reservations cover worst-case exposure within the floor."
  def reservation_covers_exposure?(commitment, %Revision{} = revision, availability)
      when is_map(commitment) and is_map(availability) do
    reservation = credits(commitment)
    available = credits(availability)

    with {:ok, floor} <- StandingAuthority.credit_floor(revision),
         true <- is_number(reservation) and reservation >= 0,
         true <- is_number(available) and available >= 0 do
      available - reservation >= floor
    else
      _ -> false
    end
  end

  @doc """
  Publishes the selected plan, or explains why nothing was published.

  Returns `{:published, portfolio}` for the caller to dispatch, or
  `{:ok, result}` for retained work, a Neutral Wait (or why none was
  recordable) and a rejected publication, or `{:error, :no_current_generation}`.
  """
  def publish(scope, agent, revision, current, plan) do
    %{retained: retained, released: released, selection: selection, decision: decision} = plan

    with %Generation{} = generation <- current_generation(agent) do
      new = selection.commitments
      same_revision? = current != nil and current.fleet_strategy_revision_id == revision.id

      cond do
        revalidate_trade_evidence(agent, new) != :ok ->
          reject_publication(scope, generation, plan, :stale_evidence)

        new == [] and is_nil(current) ->
          mint_neutral_wait(scope, generation, revision, plan)

        new == [] and (released == [] or not same_revision?) ->
          {:ok,
           %{action: :retained, portfolio: current, selection: selection, planning: plan.planning}}

        not same_revision? ->
          scope
          |> FleetAllocation.publish_portfolio(generation.id, selection, decision)
          |> published(scope, generation, plan)

        new == [] and retained == [] ->
          case FleetAllocation.unwind_current_portfolio(scope, generation.id) do
            {:ok, _portfolio} -> mint_neutral_wait(scope, generation, revision, plan)
            {:error, reason} -> reject_publication(scope, generation, plan, reason)
          end

        true ->
          changed = Enum.map(new ++ released, & &1.candidate_id)

          scope
          |> FleetAllocation.replan_subgraph(generation.id, selection, changed, decision)
          |> published(scope, generation, plan)
      end
    else
      _ -> {:error, :no_current_generation}
    end
  end

  # Last-chance check immediately before publication: every Market evidence
  # version a selected trade was planned on must still be the Listing's
  # current interpretation. A newer or invalidated observation that landed
  # since planning rejects the publication with its reason (recorded as a
  # Strategy Decision Episode); that observation's own boundary replans the
  # affected work from the new version.
  @doc false
  def revalidate_trade_evidence(%AgentRecord{} = agent, commitments) do
    planned =
      for commitment <- commitments,
          dependency <- commitment.dependencies,
          "market:" <> tail <- [dependency[:subject] || dependency["subject"]],
          id = dependency[:evidence_id] || dependency["evidence_id"],
          is_binary(id),
          do: {tail, id}

    case planned |> Enum.map(fn {tail, _id} -> hd(String.split(tail, ":")) end) |> Enum.uniq() do
      [] ->
        :ok

      systems ->
        now = Clock.utc_now()

        current =
          for system <- systems,
              market <- Intelligence.market_interpretation(agent, system, now).markets,
              market.state == :current,
              into: MapSet.new(),
              do: {String.replace_prefix(market.subject, "market:", ""), market.evidence_id}

        if Enum.all?(planned, &MapSet.member?(current, &1)),
          do: :ok,
          else: {:error, :stale_evidence}
    end
  end

  defp published({:ok, portfolio}, _scope, _generation, _plan), do: {:published, portfolio}

  defp published({:error, reason}, scope, generation, plan),
    do: reject_publication(scope, generation, plan, reason)

  defp reject_publication(scope, generation, plan, reason) do
    {:ok, episode} =
      FleetAllocation.record_publication_rejection(
        scope,
        generation.id,
        plan.selection,
        plan.decision,
        reason
      )

    {:ok,
     %{
       action: :publication_rejected,
       reason: reason,
       episode: episode,
       selection: plan.selection
     }}
  end

  defp credit_floor_rejection(commitment) do
    %{
      candidate_id: commitment.candidate_id,
      claims: commitment.claims,
      reasons: [:credit_floor],
      decisive_reason:
        "Rejected because its Credit Reservation would cross the Hard Constraint credit floor."
    }
  end

  # G3: the capable Ships Fleet Allocation did not assign to each selected
  # Commitment's role, and why.
  defp role_alternatives(commitments, candidates, claims) do
    by_id = Map.new(candidates, &{&1.id, &1})

    for commitment <- commitments,
        %{required_roles: roles} <- [Map.get(by_id, commitment.candidate_id)],
        %{role: role} <- roles,
        claim <- claims,
        role in claim.roles,
        claim.resource not in commitment.claims do
      holder = Enum.find(commitments, &(claim.resource in &1.claims))

      %{
        candidate_id: commitment.candidate_id,
        kind: :ship_role_alternative,
        role: role,
        ship: claim.resource,
        selected_ships: commitment.claims,
        decisive_reason:
          if(holder,
            do: "Not assigned: the Ship serves another selected Commitment.",
            else: "Not assigned: a lower-cost capable Ship was preferred for this role."
          )
      }
    end
  end

  # The single Neutral Wait mint site (ADR 0012): only an authoritative
  # zero-admissible Allocation result with durable future evidence for its
  # unresolved subjects records the wait. Capacity deferral, unknown
  # availability and incomplete coverage never reach it; a reconciliation
  # without future evidence fails closed and says why.
  defp mint_neutral_wait(scope, generation, revision, plan) do
    comparison = %{
      planning: plan.planning,
      alternatives: plan.selection.rejected,
      source_version: plan.selection.source_version,
      calibration_version: plan.decision.calibration_version
    }

    result = %{
      action: :no_admissible_commitment,
      planning: plan.planning,
      selection: plan.selection
    }

    case FleetAllocation.record_neutral_wait(
           scope,
           generation,
           revision,
           neutral_wait_selection(comparison)
         ) do
      {:ok, episode} -> {:ok, Map.put(result, :neutral_wait, episode)}
      {:error, reason} -> {:ok, Map.merge(result, unrecorded_wait(reason, plan.planning))}
    end
  end

  # Incomplete or unusable Market evidence is not infeasibility: when no wait
  # is recordable because the binding limitation is an evidence state, the
  # result names that state (invalidated, stale, untraceable, ...) itself.
  @evidence_limitations [
    :stale_market_evidence,
    :invalidated_market_evidence,
    :untraceable_market_evidence,
    :wrong_generation_market_evidence,
    :malformed_market_evidence,
    :unavailable_market_evidence,
    :inconsistent_market_evidence
  ]

  defp unrecorded_wait(:invalid_binding_limitation, planning) do
    case planning
         |> Enum.flat_map(&Map.get(&1, :limitations, []))
         |> Enum.filter(&(Map.get(&1, :reason) in @evidence_limitations)) do
      [] ->
        %{neutral_wait: nil, reason: :invalid_binding_limitation}

      limitations ->
        %{
          neutral_wait: nil,
          reason: :market_evidence_unusable,
          evidence_limitations: limitations
        }
    end
  end

  defp unrecorded_wait(reason, _planning), do: %{neutral_wait: nil, reason: reason}

  # The reconciliation's enumerated result binding for the mint: the planning
  # entries' unresolved limitations and Observation Demands carry the binding
  # limitation, the re-evaluation evidence, and the candidate record detail.
  defp neutral_wait_selection(comparison) do
    planning = Map.get(comparison, :planning, [])

    demands =
      planning
      |> Enum.flat_map(&Map.get(&1, :observation_demands, []))
      |> Enum.reject(&is_nil(Map.get(&1, :subject)))
      |> Enum.uniq_by(&Map.get(&1, :subject))

    %{
      action: :no_admissible_commitment,
      source_version: Map.get(comparison, :source_version, 0),
      planning: planning,
      reconciled_subjects: Map.get(comparison, :reconciled_subjects, []),
      observation_demands: demands,
      binding_limitation: binding_limitation(planning),
      evidence_references: observation_references(demands),
      candidates: Enum.flat_map(planning, &Map.get(&1, :candidate_contributions, [])),
      rejections: Map.get(comparison, :alternatives, []),
      calibration_version: Map.get(comparison, :calibration_version)
    }
  end

  defp binding_limitation(planning) do
    planning
    |> Enum.flat_map(&Map.get(&1, :limitations, []))
    |> Enum.find(&neutral_wait_limitation?/1)
    |> case do
      nil -> %{}
      limitation -> limitation
    end
  end

  defp neutral_wait_limitation?(%{reason: reason})
       when reason in [
              :incomplete_market_coverage,
              :unreachable_market_coverage,
              :no_viable_market_routes,
              :insufficient_market_evidence
            ],
       do: true

  defp neutral_wait_limitation?(%{"reason" => reason})
       when reason in [
              "incomplete_market_coverage",
              "unreachable_market_coverage",
              "no_viable_market_routes",
              "insufficient_market_evidence"
            ],
       do: true

  defp neutral_wait_limitation?(_limitation), do: false

  defp observation_references(demands) do
    Enum.map(demands, fn demand ->
      %{
        "kind" => "observation",
        "subject" => to_string(demand.subject),
        "operation_id" => "get-market"
      }
    end)
  end

  defp credits(holder) do
    reservations = Map.get(holder, :reservations, %{})

    Map.get(reservations, "credits") || Map.get(reservations, :credits)
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
