defmodule SpaceTraders.FleetAllocation.NeutralWait do
  @moduledoc """
  Mints and maintains one current Neutral Wait Strategy Decision Episode per
  allocation scope, at the single mint site fixed by ADR 0012.

  Fleet Allocation reconciliation calls `record/4` when its authoritative
  result admits no worthwhile admissible Candidate Contribution
  (`action: :no_admissible_commitment`) and a future Observation Demand is
  durably scheduled for the selection's unresolved subjects. Every other
  allocation outcome — retained work, capacity deferral, unknown
  availability, objective infeasibility — is a disposition, never a Neutral
  Wait, and clears a stale wait instead of minting one.

  Equivalence holds while the enumerated producer outcome and the binding
  limitation kind are unchanged for the same Operator, Fleet Generation, and
  active Fleet Strategy Revision: the current episode's re-evaluation
  evidence, next observation time, and candidate records refresh in place
  rather than minting another row. Supersession happens on a changed
  limitation kind, Fleet Strategy Revision, Fleet Generation, or a selected
  plan — a superseded episode keeps its identity, and the new result starts a
  fresh episode.

  Identity-rich detail (candidates, rejection reasons, evidence references,
  unresolved subjects, demand identities) lives in the episode's durable
  evidence. Only the closed limitation-kind vocabulary
  (`incomplete_coverage`, `no_admissible_candidate`, `below_economic_threshold`,
  `awaiting_scheduled_evidence`) is exposed for metric labels.
  """

  import Ecto.Query

  alias SpaceTraders.Evidence.ObservationDemand
  alias SpaceTraders.FleetAllocation.AllocationWaitPointer
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Repo

  @producer "fleet_allocation_market_reconciliation"
  @basis "fleet_allocation_reconciliation"
  @default_calibration_version "market-v1"

  @limitation_kind_by_reason %{
    incomplete_market_coverage: :incomplete_coverage,
    unreachable_market_coverage: :incomplete_coverage,
    no_viable_market_routes: :no_admissible_candidate,
    insufficient_market_evidence: :awaiting_scheduled_evidence,
    incomplete_coverage: :incomplete_coverage,
    no_admissible_candidate: :no_admissible_candidate,
    below_economic_threshold: :below_economic_threshold,
    awaiting_scheduled_evidence: :awaiting_scheduled_evidence
  }

  @type selection :: %{
          required(:action) => :no_admissible_commitment,
          required(:planning) => list(),
          required(:reconciled_subjects) => list(String.t()),
          required(:observation_demands) => list(map()),
          required(:binding_limitation) => map(),
          required(:evidence_references) => list(map()),
          optional(:candidates) => list(map()),
          optional(:rejections) => list(),
          optional(:calibration_version) => String.t(),
          optional(:source_version) => non_neg_integer()
        }

  @doc """
  Records the Neutral Wait for one authoritative zero-admissible result.

  `selection` is the reconciliation's enumerated result binding; `scope`
  carries the owning Operator, `generation` the Fleet Generation, and
  `revision` the active Fleet Strategy Revision. Fails closed: a non-wait
  action or a missing future due Observation Demand for the unresolved
  subjects records nothing.
  """
  @spec record(SpaceTraders.Agent.Scope.t(), Generation.t(), Revision.t(), selection) ::
          {:ok, StrategyDecisionEpisode.t()}
          | {:error, :not_neutral_wait | :no_future_observation_demand | term()}
  def record(
        %SpaceTraders.Agent.Scope{operator: %{id: operator_id}},
        %Generation{} = generation,
        %Revision{} = revision,
        %{} = selection
      ) do
    with :ok <- wait_action?(selection),
         {:ok, binding_limitation} <- binding_limitation(selection),
         {:ok, limitation_kind} <- limitation_kind(binding_limitation),
         :ok <- valid_source_version?(selection) do
      calibration_version =
        Map.get(selection, :calibration_version) || @default_calibration_version

      Repo.transaction(fn ->
        with {:ok, generation} <-
               lock_current_generation(generation, operator_id, revision, selection),
             {:ok, demands} <-
               future_observation_demands(selection, generation.agent_id, revision.id) do
          pointer = lock_or_create_pointer!(generation, operator_id, revision.id)
          next_observation_at = hd(demands).due_at
          current = current_episode(pointer)

          equivalent? =
            current != nil and current.fleet_generation_id == generation.id and
              current.fleet_strategy_revision_id == revision.id and
              current.binding_limitation_kind == limitation_kind

          if equivalent? do
            refresh_episode!(current, selection, demands, calibration_version)
          else
            supersede_current_waits!(operator_id, generation.id)

            mint_episode(operator_id, generation.id, revision, selection, limitation_kind,
              demands: demands,
              next_observation_at: next_observation_at,
              calibration_version: calibration_version
            )
          end
          |> then(fn episode ->
            Repo.update!(
              Ecto.Changeset.change(pointer,
                fleet_strategy_revision_id: revision.id,
                selection_kind: :neutral_wait,
                strategy_decision_episode_id: episode.id
              )
            )

            episode
          end)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def record(_scope, _generation, _revision, _selection), do: {:error, :not_neutral_wait}

  defp wait_action?(%{action: :no_admissible_commitment}), do: :ok
  defp wait_action?(_), do: {:error, :not_neutral_wait}

  defp binding_limitation(%{binding_limitation: limitation}) when is_map(limitation),
    do: {:ok, limitation}

  defp binding_limitation(_selection), do: {:error, :invalid_binding_limitation}

  defp valid_source_version?(selection) do
    if is_integer(Map.get(selection, :source_version, 0)) and
         Map.get(selection, :source_version, 0) >= 0,
       do: :ok,
       else: {:error, :stale_allocation}
  end

  @doc """
  Clears the current Neutral Wait pointer when an allocation outcome that is
  not a wait supersedes it.

  Publication of a selected plan replaces the pointer on its own; clearing
  covers the remaining supersessions reachable through the reconciliation
  boundary.
  """
  @spec clear(integer()) :: :ok
  def clear(generation_id) when is_integer(generation_id) do
    case pointer_query(generation_id) do
      %AllocationWaitPointer{} = pointer ->
        supersede_episode!(pointer.strategy_decision_episode_id)
        Repo.delete!(pointer)

      nil ->
        :ok
    end

    :ok
  end

  @doc "The `inserted_at` of the current Neutral Wait, or nil when the fleet is not waiting."
  @spec current_since(integer()) :: DateTime.t() | nil
  def current_since(generation_id) when is_integer(generation_id) do
    pointer = Repo.get_by(AllocationWaitPointer, fleet_generation_id: generation_id)

    if pointer && pointer.selection_kind == :neutral_wait do
      case Repo.get(StrategyDecisionEpisode, pointer.strategy_decision_episode_id) do
        %{selection_kind: :neutral_wait, classification: :still_evaluating} = episode ->
          episode.inserted_at

        _other ->
          nil
      end
    end
  end

  @doc false
  def supersede_for_operator(operator_id) when is_integer(operator_id) do
    supersede_current_waits!(operator_id)
    :ok
  end

  ##
  ## Equivalence and supersession
  ##

  # The pointer is the O(1) source for the allocation scope's current result;
  # an unreferenced historical wait must never be revived by a later refresh.
  defp current_episode(%AllocationWaitPointer{
         selection_kind: :neutral_wait,
         strategy_decision_episode_id: episode_id
       })
       when is_integer(episode_id) do
    case Repo.get(StrategyDecisionEpisode, episode_id) do
      %{selection_kind: :neutral_wait, classification: :still_evaluating} = episode -> episode
      _other -> nil
    end
  end

  defp current_episode(_pointer), do: nil

  defp supersede_current_waits!(operator_id, preserve_generation_id \\ nil) do
    episode_ids =
      StrategyDecisionEpisode
      |> where(
        [episode],
        episode.operator_id == ^operator_id and episode.selection_kind == :neutral_wait and
          episode.classification == :still_evaluating
      )
      |> select([episode], episode.id)
      |> Repo.all()

    if episode_ids != [] do
      Repo.update_all(
        from(episode in StrategyDecisionEpisode, where: episode.id in ^episode_ids),
        set: [classification: :superseded, updated_at: SpaceTraders.Clock.utc_now()]
      )

      stale_pointers =
        from(pointer in AllocationWaitPointer,
          where:
            pointer.selection_kind == :neutral_wait and
              pointer.strategy_decision_episode_id in ^episode_ids
        )

      stale_pointers =
        if is_integer(preserve_generation_id) do
          where(stale_pointers, [pointer], pointer.fleet_generation_id != ^preserve_generation_id)
        else
          stale_pointers
        end

      Repo.delete_all(stale_pointers)
    end

    :ok
  end

  defp supersede_episode!(episode_id) when is_integer(episode_id) do
    Repo.update_all(
      from(episode in StrategyDecisionEpisode,
        where:
          episode.id == ^episode_id and episode.selection_kind == :neutral_wait and
            episode.classification == :still_evaluating
      ),
      set: [classification: :superseded, updated_at: SpaceTraders.Clock.utc_now()]
    )

    :ok
  end

  defp supersede_episode!(_episode_id), do: :ok

  defp refresh_episode!(current, selection, demands, calibration_version) do
    next_observation_at = hd(demands).due_at

    current
    |> Ecto.Changeset.change(
      next_observation_at: next_observation_at,
      expectations:
        episode_expectations(selection, next_observation_at, current.binding_limitation_kind),
      evidence_references: episode_evidence_references(selection, demands),
      alternatives: episode_alternatives(selection),
      calibration_version: calibration_version,
      actual_outcomes: refreshed_actual_outcomes(current, selection, next_observation_at, demands)
    )
    |> Repo.update!()
  end

  defp refreshed_actual_outcomes(current, selection, next_observation_at, demands) do
    entry = re_evaluation_entry(selection, next_observation_at, demands)
    outcomes = current.actual_outcomes || %{}
    re_evaluations = Map.get(outcomes, "re_evaluations", []) ++ [entry]

    Map.put(outcomes, "re_evaluations", re_evaluations)
  end

  defp mint_episode(
         operator_id,
         generation_id,
         revision,
         selection,
         limitation_kind,
         opts
       ) do
    Repo.insert!(%StrategyDecisionEpisode{
      operator_id: operator_id,
      fleet_generation_id: generation_id,
      fleet_strategy_revision_id: revision.id,
      source_version: Map.get(selection, :source_version, 0),
      selection_kind: :neutral_wait,
      binding_limitation_kind: limitation_kind,
      next_observation_at: Keyword.fetch!(opts, :next_observation_at),
      calibration_version: Keyword.fetch!(opts, :calibration_version),
      evidence_references: episode_evidence_references(selection, Keyword.fetch!(opts, :demands)),
      alternatives: episode_alternatives(selection),
      binding_constraints: episode_binding_constraints(selection, revision),
      expectations:
        episode_expectations(
          selection,
          Keyword.fetch!(opts, :next_observation_at),
          limitation_kind
        ),
      actual_outcomes:
        episode_actual_outcomes(
          selection,
          Keyword.fetch!(opts, :next_observation_at),
          Keyword.fetch!(opts, :demands)
        )
    })
  end

  defp episode_evidence_references(selection, demands) do
    (Map.get(selection, :evidence_references, []) ++
       Enum.map(demands, &observation_demand_reference/1))
    |> json_safe()
    |> Enum.uniq()
  end

  defp observation_demand_reference(demand) do
    %{
      "kind" => "observation_demand",
      "id" => demand.id,
      "subject" => demand.subject,
      "due_at" => DateTime.to_iso8601(demand.due_at)
    }
  end

  defp episode_alternatives(selection) do
    %{
      "candidates" => selection |> Map.get(:candidates, []) |> Enum.map(&json_safe/1),
      "rejections" => selection |> Map.get(:rejections, []) |> Enum.map(&json_safe/1),
      "reconciled_subjects" =>
        Enum.map(Map.get(selection, :reconciled_subjects, []), &to_string/1)
    }
  end

  defp episode_binding_constraints(selection, revision) do
    (Map.get(selection, :binding_constraints) ||
       revision.document
       |> Map.get("hard_constraints", [])
       |> Enum.map(fn
         rule when is_binary(rule) -> %{"rule" => rule}
         rule -> json_safe(rule)
       end))
    |> json_safe()
  end

  defp episode_expectations(selection, next_observation_at, limitation_kind) do
    %{
      "action" => "no_admissible_commitment",
      "binding_limitation" => json_safe(Map.fetch!(selection, :binding_limitation)),
      "limitation_kind" => Atom.to_string(limitation_kind),
      "producer" => @producer,
      "basis" => @basis,
      "next_observation_at" => DateTime.to_iso8601(next_observation_at)
    }
  end

  defp episode_actual_outcomes(selection, next_observation_at, demands) do
    %{
      "producer" => @producer,
      "basis" => @basis,
      "re_evaluations" => [re_evaluation_entry(selection, next_observation_at, demands)]
    }
  end

  defp re_evaluation_entry(selection, next_observation_at, demands) do
    %{
      "observed_at" => DateTime.to_iso8601(SpaceTraders.Clock.utc_now()),
      "next_observation_at" => DateTime.to_iso8601(next_observation_at),
      "unresolved_subjects" => selection |> unresolved_subjects() |> Enum.map(&to_string/1),
      "observation_demand_ids" => Enum.map(demands, & &1.id)
    }
  end

  ##
  ## Durable observation-time proof for the mint site
  ##

  defp lock_current_generation(generation, operator_id, revision, selection) do
    source_version = Map.get(selection, :source_version, 0)

    current =
      Generation
      |> where(
        [current],
        current.id == ^generation.id and current.operator_id == ^operator_id and
          current.fleet_strategy_revision_id == ^revision.id and is_nil(current.fenced_at) and
          is_nil(current.retired_at)
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    if current && current.allocation_version == source_version,
      do: {:ok, current},
      else: {:error, :stale_allocation}
  end

  defp future_observation_demands(selection, agent_id, revision_id) do
    unresolved = unresolved_subjects(selection)

    if unresolved == [] do
      {:error, :no_future_observation_demand}
    else
      now = SpaceTraders.Clock.utc_now()

      demands =
        ObservationDemand
        |> where(
          [demand],
          demand.agent_id == ^agent_id and demand.strategy_revision_id == ^revision_id and
            is_nil(demand.withdrawn_at) and is_nil(demand.fulfilled_observation_id) and
            demand.due_at > ^now and demand.subject in ^unresolved
        )
        |> order_by([demand], asc: demand.due_at, asc: demand.id)
        |> lock("FOR SHARE")
        |> Repo.all()

      if demands == [],
        do: {:error, :no_future_observation_demand},
        else: {:ok, demands}
    end
  end

  defp unresolved_subjects(%{observation_demands: demands} = selection)
       when is_list(demands) do
    reconciled = MapSet.new(Enum.map(Map.get(selection, :reconciled_subjects, []), &to_string/1))

    demands
    |> Enum.flat_map(fn demand ->
      case Map.get(demand, :subject) || Map.get(demand, "subject") do
        subject when is_binary(subject) and subject != "" -> [subject]
        _ -> []
      end
    end)
    |> MapSet.new()
    |> MapSet.difference(reconciled)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp unresolved_subjects(_selection), do: []

  defp limitation_kind(limitation) do
    reason =
      case limitation do
        %{reason: reason} -> reason
        %{"reason" => reason} -> reason
        _other -> nil
      end

    kind = reason && @limitation_kind_by_reason[limitation_reason(reason)]

    if kind in StrategyDecisionEpisode.limitation_kinds() do
      {:ok, kind}
    else
      {:error, :invalid_binding_limitation}
    end
  end

  # Planning reports Market limitation reasons as atoms; durable evidence
  # serializes them as strings. Accept both against the closed vocabulary.
  defp limitation_reason(reason) when is_atom(reason), do: reason

  defp limitation_reason(reason) when is_binary(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> nil
  end

  defp limitation_reason(_reason), do: nil

  # Mirrors the JSON-safe serialization used when persisting published portfolio
  # evidence: datetimes become ISO8601 strings, structs become plain maps.
  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp json_safe(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: nil
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value

  ##
  ## The O(1) pointer, transactionally consistent with the episode
  ##

  defp lock_or_create_pointer!(%Generation{} = generation, operator_id, revision_id) do
    Repo.insert!(
      %AllocationWaitPointer{
        fleet_generation_id: generation.id,
        operator_id: operator_id,
        fleet_strategy_revision_id: revision_id,
        selection_kind: :selected_plan
      },
      on_conflict: :nothing,
      conflict_target: :fleet_generation_id
    )

    pointer_query(generation.id)
  end

  defp pointer_query(generation_id) do
    AllocationWaitPointer
    |> where([pointer], pointer.fleet_generation_id == ^generation_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end
end
