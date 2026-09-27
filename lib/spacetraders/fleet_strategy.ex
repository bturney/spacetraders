defmodule SpaceTraders.FleetStrategy do
  @moduledoc """
  Owns durable Operator-authored Fleet Strategy drafts and immutable revisions.

  Draft and recommendation changes never change active intent. Only an explicit
  call to `activate/1` snapshots the current draft and advances the active
  Fleet Strategy Revision.
  """

  import Ecto.Query, warn: false

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.EmergencyStopAdmission
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet

  alias SpaceTraders.FleetStrategy.{
    ObjectiveEvaluation,
    PreferenceEvaluation,
    Revision,
    StandingAuthority,
    Strategy
  }

  alias SpaceTraders.Repo

  @comparison_objective_fields ["kind", "evaluation", "scope"]

  @presets [
    %{
      id: "steady_growth",
      name: "Steady growth",
      summary: "Grow the Fleet economy while protecting operating capital.",
      objectives: [
        %{
          "objective" => "Grow credits",
          "kind" => "continuous",
          "evaluation" => "Maximize net credit growth over time",
          "scope" => "recurring"
        }
      ],
      hard_constraints: ["Keep at least 50,000 credits available"],
      preferences: ["Prefer lower-risk routes when expected returns are similar"],
      consequences:
        "The Fleet may spend credits and accept bounded trading losses while preserving the credit floor."
    },
    %{
      id: "charted_expansion",
      name: "Charted expansion",
      summary: "Prioritize useful map coverage without exhausting operating capital.",
      objectives: [
        %{
          "objective" => "Chart useful waypoints",
          "kind" => "attain",
          "evaluation" => "Increase newly charted waypoint coverage",
          "scope" => "fleet_generation"
        },
        %{
          "objective" => "Grow credits",
          "kind" => "continuous",
          "evaluation" => "Maximize net credit growth after charting needs are protected",
          "scope" => "recurring"
        }
      ],
      hard_constraints: ["Keep at least 75,000 credits available"],
      preferences: ["Prefer nearby uncharted systems when expected coverage is similar"],
      consequences:
        "The Fleet may favor exploration over near-term earnings and spend credits above the protected floor."
    }
  ]

  @doc "Returns fully disclosed built-in Fleet Strategy presets."
  def presets, do: @presets

  @doc "Evaluates one Strategic Objective from an immutable revision."
  defdelegate evaluate_objective(revision, objective_index, facts),
    to: ObjectiveEvaluation,
    as: :evaluate

  defdelegate evaluate_persisted_objective(revision, objective_index, facts),
    to: ObjectiveEvaluation,
    as: :evaluate_persisted

  @doc "Binds one planner-supplied score to a Preference in an immutable revision."
  defdelegate evaluate_preference(revision, preference_index, score),
    to: PreferenceEvaluation,
    as: :evaluate

  @doc "Starts a new instance of one recurring Strategic Objective."
  defdelegate advance_recurrence(revision, progress, objective_index, next_recurrence_id),
    to: ObjectiveEvaluation

  @doc "Checks possible consequence bounds against the active revision's Standing Authority."
  def authorize(%Scope{} = scope, consequence_bounds) do
    with :ok <- mutation_allowed?(scope) do
      case get(scope).active_revision do
        %Revision{} = revision -> StandingAuthority.authorize(revision, consequence_bounds)
        nil -> {:error, :strategy_not_active}
      end
    end
  end

  @doc "Durably suppresses every new gameplay mutation for the authenticated Operator."
  def engage_emergency_stop(%Scope{operator: %Operator{id: operator_id}} = scope) do
    :global.trans({{__MODULE__, :emergency_stop, operator_id}, self()}, fn ->
      do_engage_emergency_stop(scope, operator_id)
    end)
  end

  defp do_engage_emergency_stop(scope, operator_id) do
    now = DateTime.utc_now()
    admission_guard = EmergencyStopAdmission.block(operator_id)

    result =
      Repo.transaction(fn ->
        %Strategy{}
        |> Strategy.changeset(%{operator_id: operator_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :operator_id)

        Repo.update_all(
          from(strategy in Strategy, where: strategy.operator_id == ^operator_id),
          inc: [emergency_stop_version: 1],
          set: [
            emergency_stopped_at: now,
            emergency_resume_prepared_at: nil,
            updated_at: DateTime.utc_now(:second)
          ]
        )

        get(scope)
      end)

    if match?({:ok, _projection}, result) do
      {:ok, projection} = result

      :ok =
        EmergencyStopAdmission.engage(
          operator_id,
          projection.emergency_stop_version,
          admission_guard
        )

      broadcast_update(scope)
    else
      EmergencyStopAdmission.cancel_block(operator_id, admission_guard)
    end

    result
  end

  @doc "Refreshes game truth and retires stale work while mutation admission remains stopped."
  def resume(
        %Scope{operator: %Operator{id: operator_id}} = scope,
        expected_emergency_stop_version
      )
      when is_integer(expected_emergency_stop_version) do
    :global.trans({{__MODULE__, :emergency_stop, operator_id}, self()}, fn ->
      do_resume(scope, operator_id, expected_emergency_stop_version)
    end)
  end

  defp do_resume(scope, operator_id, expected_emergency_stop_version) do
    with :ok <- Evidence.refresh_for_emergency_stop_resume(scope) do
      result =
        Repo.transaction(fn ->
          prepared_at = DateTime.utc_now()
          now = DateTime.truncate(prepared_at, :second)

          {updated, _rows} =
            Repo.update_all(
              from(strategy in Strategy,
                where:
                  strategy.operator_id == ^operator_id and
                    strategy.emergency_stop_version == ^expected_emergency_stop_version and
                    not is_nil(strategy.emergency_stopped_at)
              ),
              inc: [emergency_stop_version: 1],
              set: [emergency_resume_prepared_at: prepared_at, updated_at: now]
            )

          if updated != 1, do: Repo.rollback(:stale_emergency_stop)

          if Fleet.prepare_emergency_stop_resume(operator_id, now) != :ok,
            do: Repo.rollback(:reconciliation_required)

          get(scope)
        end)

      if match?({:ok, _projection}, result) do
        broadcast_update(scope)
      end

      result
    end
  end

  @doc false
  def complete_emergency_stop_resume(
        %Scope{operator: %Operator{id: operator_id}} = scope,
        expected_emergency_stop_version
      ) do
    :global.trans({{__MODULE__, :emergency_stop, operator_id}, self()}, fn ->
      now = DateTime.utc_now(:second)

      {updated, _rows} =
        Repo.update_all(
          from(strategy in Strategy,
            where:
              strategy.operator_id == ^operator_id and
                strategy.emergency_stop_version == ^expected_emergency_stop_version and
                not is_nil(strategy.emergency_stopped_at) and
                not is_nil(strategy.emergency_resume_prepared_at)
          ),
          inc: [emergency_stop_version: 1],
          set: [
            emergency_stopped_at: nil,
            emergency_resume_prepared_at: nil,
            updated_at: now
          ]
        )

      if updated == 1 do
        projection = get(scope)
        :ok = EmergencyStopAdmission.resume(operator_id, projection.emergency_stop_version)
        _ = SpaceTraders.FleetGeneration.replace_stale_agents(scope)
        broadcast_update(scope)
        {:ok, projection}
      else
        {:error, :stale_emergency_stop}
      end
    end)
  end

  @doc "Returns whether Emergency Stop permits a new gameplay mutation."
  def mutation_allowed?(%Scope{operator: %Operator{id: operator_id}}),
    do: mutation_allowed_for_operator?(operator_id)

  def mutation_allowed?(%Agent{operator_id: operator_id}),
    do: mutation_allowed_for_operator?(operator_id)

  defp mutation_allowed_for_operator?(nil), do: :ok

  defp mutation_allowed_for_operator?(operator_id) do
    if Repo.exists?(
         from(strategy in Strategy,
           where:
             strategy.operator_id == ^operator_id and not is_nil(strategy.emergency_stopped_at)
         )
       ) do
      {:error, :emergency_stopped}
    else
      :ok
    end
  end

  @doc "Returns the authenticated Operator's current draft and active revision."
  def get(%Scope{operator: %Operator{id: operator_id}}) do
    case Repo.get_by(Strategy, operator_id: operator_id) do
      nil ->
        %{
          draft: nil,
          draft_source: nil,
          draft_version: 0,
          active_revision: nil,
          emergency_stopped_at: nil,
          emergency_resume_prepared_at: nil,
          emergency_stop_version: 0
        }

      strategy ->
        %{
          draft: strategy.draft_document,
          draft_source: strategy.draft_source,
          draft_version: strategy.draft_version,
          active_revision: active_revision(strategy),
          emergency_stopped_at: strategy.emergency_stopped_at,
          emergency_resume_prepared_at: strategy.emergency_resume_prepared_at,
          emergency_stop_version: strategy.emergency_stop_version
        }
    end
  end

  @doc """
  Compares the active revision's document with a draft document.

  Reports added, removed, changed, and reordered Strategic Objectives, added
  and removed Hard Constraints and Preferences, and changed consequence text.
  A draft identical to the active revision reports no changes.
  """
  def compare_documents(active_document, draft_document)
      when is_map(active_document) and is_map(draft_document) do
    objectives =
      compare_objectives(
        Map.get(active_document, "objectives", []),
        Map.get(draft_document, "objectives", [])
      )

    hard_constraints = document_list_changes(active_document, draft_document, "hard_constraints")
    preferences = document_list_changes(active_document, draft_document, "preferences")
    consequences = document_consequence_change(active_document, draft_document)

    %{
      changed?:
        objectives.added != [] or objectives.removed != [] or objectives.changed != [] or
          objectives.reordered? or hard_constraints.added != [] or
          hard_constraints.removed != [] or preferences.added != [] or
          preferences.removed != [] or not is_nil(consequences),
      objectives: objectives,
      hard_constraints: hard_constraints,
      preferences: preferences,
      consequences: consequences
    }
  end

  @doc "Persists an Operator-authored draft without changing active intent."
  def save_draft(%Scope{} = scope, document, expected_draft_version) do
    put_draft(scope, document, "operator", expected_draft_version)
  end

  @doc "Opens a recommendation as a reviewable draft without changing active intent."
  def recommend(%Scope{} = scope, document), do: open_draft(scope, document, "recommendation")

  @doc "Copies a disclosed preset into a reviewable draft."
  def select_preset(%Scope{} = scope, preset_id) do
    case Enum.find(@presets, &(&1.id == preset_id)) do
      nil -> {:error, :preset_not_found}
      preset -> open_draft(scope, preset_document(preset), "preset:#{preset.id}")
    end
  end

  @doc "Discards the draft without changing active intent."
  def discard_draft(
        %Scope{operator: %Operator{id: operator_id}} = scope,
        expected_draft_version
      ) do
    case Repo.get_by(Strategy, operator_id: operator_id) do
      nil ->
        {:ok, get(scope)}

      strategy ->
        update_strategy(
          strategy,
          scope,
          %{draft_document: nil, draft_source: nil},
          expected_draft_version
        )
    end
  end

  @doc "Explicitly activates the current draft as a new immutable revision."
  def activate(%Scope{operator: %Operator{id: operator_id}} = scope, expected_draft_version)
      when is_integer(expected_draft_version) do
    result =
      Repo.transaction(fn ->
        with %Strategy{} = strategy <- Repo.get_by(Strategy, operator_id: operator_id),
             document when is_map(document) <- strategy.draft_document,
             true <- strategy.draft_version == expected_draft_version,
             :ok <- validate_document(document) do
          next_revision_number = strategy.revision_number + 1

          {claimed, _rows} =
            Repo.update_all(
              from(candidate in Strategy,
                where:
                  candidate.id == ^strategy.id and
                    candidate.draft_version == ^expected_draft_version and
                    candidate.revision_number == ^strategy.revision_number
              ),
              inc: [draft_version: 1, revision_number: 1],
              set: [
                draft_document: nil,
                draft_source: nil,
                updated_at: DateTime.utc_now(:second)
              ]
            )

          if claimed != 1, do: Repo.rollback(:stale_draft)

          revision =
            %Revision{}
            |> Revision.create_changeset(%{
              fleet_strategy_id: strategy.id,
              number: next_revision_number,
              document: document,
              source: strategy.draft_source || "operator",
              activated_at: DateTime.utc_now(:second)
            })
            |> Repo.insert!()

          Repo.update_all(
            from(candidate in Strategy, where: candidate.id == ^strategy.id),
            set: [active_revision_id: revision.id]
          )

          revision
        else
          nil -> Repo.rollback(:draft_not_found)
          :error -> Repo.rollback(:draft_not_found)
          false -> Repo.rollback(:stale_draft)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    if match?({:ok, %Revision{}}, result) do
      {:ok, revision} = result
      :ok = SpaceTraders.FleetGeneration.activate_strategy(scope, revision)
      broadcast_update(scope)
    end

    result
  end

  defp put_draft(
         %Scope{operator: %Operator{id: operator_id}} = scope,
         document,
         source,
         expected_draft_version
       )
       when is_map(document) do
    with :ok <- validate_draft_document(document) do
      strategy =
        Repo.get_by(Strategy, operator_id: operator_id) || %Strategy{operator_id: operator_id}

      update_strategy(
        strategy,
        scope,
        %{draft_document: document, draft_source: source},
        expected_draft_version
      )
    end
  end

  defp put_draft(_scope, _document, _source, _expected_draft_version),
    do: {:error, :invalid_document}

  defp open_draft(
         %Scope{operator: %Operator{id: operator_id}} = scope,
         document,
         source
       )
       when is_map(document) do
    with :ok <- validate_draft_document(document) do
      case Repo.get_by(Strategy, operator_id: operator_id) do
        nil ->
          case %Strategy{}
               |> Strategy.changeset(%{
                 operator_id: operator_id,
                 draft_document: document,
                 draft_source: source,
                 draft_version: 1
               })
               |> Repo.insert() do
            {:ok, strategy} ->
              broadcast_update(scope)
              {:ok, projection(strategy)}

            {:error,
             %{errors: [operator_id: {_message, constraint: :unique, constraint_name: _}]}} ->
              {:error, :draft_exists}

            error ->
              error
          end

        %Strategy{draft_document: nil} = strategy ->
          {claimed, _rows} =
            Repo.update_all(
              from(candidate in Strategy,
                where:
                  candidate.id == ^strategy.id and
                    candidate.draft_version == ^strategy.draft_version
              ),
              inc: [draft_version: 1],
              set: [
                draft_document: document,
                draft_source: source,
                updated_at: DateTime.utc_now(:second)
              ]
            )

          if claimed == 1 do
            broadcast_update(scope)

            {:ok,
             projection(strategy, %{
               draft_document: document,
               draft_source: source,
               draft_version: strategy.draft_version + 1
             })}
          else
            {:error, :draft_exists}
          end

        %Strategy{} ->
          {:error, :draft_exists}
      end
    end
  end

  defp open_draft(_scope, _document, _source), do: {:error, :invalid_document}

  defp update_strategy(strategy, scope, attrs, expected_draft_version) do
    result =
      if strategy.id do
        {updated, _rows} =
          Repo.update_all(
            from(candidate in Strategy,
              where:
                candidate.id == ^strategy.id and
                  candidate.draft_version == ^expected_draft_version
            ),
            inc: [draft_version: 1],
            set: [
              draft_document: attrs[:draft_document],
              draft_source: attrs[:draft_source],
              updated_at: DateTime.utc_now(:second)
            ]
          )

        if updated == 1, do: {:ok, strategy}, else: {:error, :stale_draft}
      else
        if expected_draft_version == 0 do
          strategy
          |> Strategy.changeset(Map.put(attrs, :draft_version, 1))
          |> Repo.insert()
        else
          {:error, :stale_draft}
        end
      end

    case result do
      {:ok, %Strategy{} = strategy} ->
        broadcast_update(scope)

        {:ok,
         projection(strategy, %{
           draft_document: attrs[:draft_document],
           draft_source: attrs[:draft_source],
           draft_version: expected_draft_version + 1
         })}

      {:error, %Ecto.Changeset{}} when is_nil(strategy.id) ->
        {:error, :stale_draft}

      error ->
        error
    end
  end

  defp active_revision(%Strategy{active_revision_id: nil}), do: nil

  defp active_revision(%Strategy{id: strategy_id, active_revision_id: revision_id}) do
    Repo.one(
      from revision in Revision,
        where: revision.id == ^revision_id and revision.fleet_strategy_id == ^strategy_id
    )
  end

  defp projection(strategy, overrides \\ %{}) do
    %{
      draft: Map.get(overrides, :draft_document, strategy.draft_document),
      draft_source: Map.get(overrides, :draft_source, strategy.draft_source),
      draft_version: Map.get(overrides, :draft_version, strategy.draft_version),
      active_revision: active_revision(strategy),
      emergency_stopped_at: strategy.emergency_stopped_at,
      emergency_resume_prepared_at: strategy.emergency_resume_prepared_at,
      emergency_stop_version: strategy.emergency_stop_version
    }
  end

  defp validate_document(%{
         "objectives" => [_ | _] = objectives,
         "hard_constraints" => [_ | _] = constraints,
         "preferences" => preferences,
         "consequences" => consequences
       })
       when is_list(preferences) and is_binary(consequences) and consequences != "" do
    with true <- Enum.all?(objectives, &valid_objective?/1),
         true <- Enum.all?(constraints ++ preferences, &(is_binary(&1) and &1 != "")),
         :ok <- StandingAuthority.validate_constraints(constraints) do
      :ok
    else
      false -> {:error, :invalid_document}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_document(_document), do: {:error, :invalid_document}

  defp validate_draft_document(document) do
    allowed_keys = ["objectives", "hard_constraints", "preferences", "consequences"]

    with true <- Enum.all?(Map.keys(document), &(&1 in allowed_keys)),
         objectives when is_list(objectives) <- Map.get(document, "objectives"),
         constraints when is_list(constraints) <- Map.get(document, "hard_constraints"),
         preferences when is_list(preferences) <- Map.get(document, "preferences"),
         consequences when is_binary(consequences) <- Map.get(document, "consequences"),
         true <- Enum.all?(objectives, &valid_draft_objective?/1),
         true <- Enum.all?(constraints ++ preferences, &is_binary/1) do
      :ok
    else
      _ -> {:error, :invalid_document}
    end
  end

  defp valid_draft_objective?(objective) when is_map(objective) do
    allowed_keys = ["objective", "kind", "evaluation", "scope"]

    Enum.all?(Map.keys(objective), &(&1 in allowed_keys)) and
      Enum.all?(Map.values(objective), &is_binary/1)
  end

  defp valid_draft_objective?(_objective), do: false

  defp valid_objective?(%{
         "objective" => objective,
         "kind" => kind,
         "evaluation" => evaluation,
         "scope" => scope
       }) do
    is_binary(objective) and objective != "" and
      is_binary(evaluation) and evaluation != "" and
      kind in ["attain", "maintain", "continuous"] and
      scope in ["fleet_generation", "strategy_lifetime", "recurring"]
  end

  defp valid_objective?(_objective), do: false

  defp preset_document(preset) do
    %{
      "objectives" => preset.objectives,
      "hard_constraints" => preset.hard_constraints,
      "preferences" => preset.preferences,
      "consequences" => preset.consequences
    }
  end

  defp compare_objectives(active_objectives, draft_objectives) do
    active_by_name = Enum.group_by(active_objectives, &comparison_objective_name/1)
    draft_by_name = Enum.group_by(draft_objectives, &comparison_objective_name/1)

    changed =
      active_by_name
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(draft_by_name, &1))
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        active_by_name
        |> Map.fetch!(name)
        |> Enum.zip(Map.fetch!(draft_by_name, name))
        |> Enum.flat_map(fn {active, draft} ->
          case objective_field_changes(active, draft) do
            [] -> []
            changes -> [%{objective: name, changes: changes}]
          end
        end)
      end)

    %{
      added: extra_objectives(draft_by_name, active_by_name),
      removed: extra_objectives(active_by_name, draft_by_name),
      changed: changed,
      reordered?:
        shared_names_in_order(active_objectives, draft_objectives) !=
          shared_names_in_order(draft_objectives, active_objectives)
    }
  end

  defp comparison_objective_name(%{"objective" => name}) when is_binary(name), do: name
  defp comparison_objective_name(objective) when is_binary(objective), do: objective
  defp comparison_objective_name(_objective), do: nil

  defp extra_objectives(objectives_by_name, other_by_name) do
    objectives_by_name
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, objectives} ->
      extra = length(objectives) - length(Map.get(other_by_name, name, []))
      Enum.take(objectives, max(extra, 0))
    end)
  end

  defp objective_field_changes(active, draft) when is_map(active) and is_map(draft) do
    for field <- @comparison_objective_fields,
        from = Map.get(active, field),
        to = Map.get(draft, field),
        from != to do
      %{field: field, from: from, to: to}
    end
  end

  defp objective_field_changes(_active, _draft), do: []

  defp shared_names_in_order(objectives, other_objectives) do
    remaining = other_objectives |> Enum.map(&comparison_objective_name/1) |> Enum.frequencies()

    {shared, _remaining} =
      objectives
      |> Enum.map(&comparison_objective_name/1)
      |> Enum.reduce({[], remaining}, fn name, {shared, remaining} ->
        case Map.get(remaining, name, 0) do
          0 -> {shared, remaining}
          count -> {[name | shared], Map.put(remaining, name, count - 1)}
        end
      end)

    Enum.reverse(shared)
  end

  defp document_list_changes(active_document, draft_document, key) do
    active = Map.get(active_document, key, [])
    draft = Map.get(draft_document, key, [])

    %{added: draft -- active, removed: active -- draft}
  end

  defp document_consequence_change(active_document, draft_document) do
    from = Map.get(active_document, "consequences") || ""
    to = Map.get(draft_document, "consequences") || ""

    if from == to, do: nil, else: %{from: from, to: to}
  end

  defp broadcast_update(%Scope{operator: %Operator{id: operator_id}}) do
    Phoenix.PubSub.broadcast(
      SpaceTraders.PubSub,
      "fleet_strategy:#{operator_id}",
      {:fleet_strategy_updated, operator_id}
    )
  end
end
