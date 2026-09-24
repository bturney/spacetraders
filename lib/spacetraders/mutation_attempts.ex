defmodule SpaceTraders.MutationAttempts do
  @moduledoc """
  Durable evidence for gameplay mutation dispatch and recovery.

  Preparing an attempt and marking it sent-or-unknown are separate commits. A
  caller may dispatch only after both succeed. Outcomes are append-only so an
  ambiguous result and its later reconciliation retain one causal identity.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.{Agent, Operator}
  alias SpaceTraders.API.OperationInventory.Operation
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.{AuthoritativeObservation, ConstraintAccounting}
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.Repo
  alias SpaceTraders.SafetyFence
  alias SpaceTraders.SafetyFence.DependencyKey

  @correlation_keys [
    :request_id,
    :operator_id,
    :agent_id,
    :fleet_generation_id,
    :strategy_revision_id,
    :decision_episode_id,
    :commitment_id,
    :ship_id,
    :ship_symbol,
    :intent_id
  ]

  @retry_context_key {__MODULE__, :retry_attempt_id}

  @spec prepare(Operation.t(), String.t(), keyword()) :: {:ok, Attempt.t()} | {:error, term()}
  def prepare(%Operation{classification: :mutation} = operation, path, opts) do
    context = context(Keyword.get(opts, :agent_id), path, opts)
    attempt = build_attempt(operation, path, opts, context)

    case SafetyFence.blocking_attempts(
           attempt.dependency_keys,
           nil,
           attempt.admitted_bounded_unknown_ids
         ) do
      [] -> Repo.insert(attempt)
      blocking -> {:error, {:safety_fenced, Enum.map(blocking, & &1.id)}}
    end
  end

  @doc false
  def prepare_for_dispatch(%Operation{} = operation, path, opts) do
    case Process.get(@retry_context_key) do
      nil ->
        prepare(operation, path, opts)

      {:pending, attempt_id} ->
        Process.put(@retry_context_key, :consumed)
        prepare_retry(get!(attempt_id), operation, path, opts)

      :consumed ->
        {:error, :retry_already_dispatched}
    end
  end

  @doc false
  def with_retry(%Attempt{id: attempt_id}, callback) when is_function(callback, 0) do
    case Process.get(@retry_context_key) do
      nil ->
        Process.put(@retry_context_key, {:pending, attempt_id})

        try do
          callback.()
        after
          Process.delete(@retry_context_key)
        end

      _attempt_id ->
        {:error, :nested_mutation_retry}
    end
  end

  @doc "Prepares the one retry authorized by authoritative non-occurrence evidence."
  @spec prepare_retry(Attempt.t(), Operation.t(), String.t(), keyword()) ::
          {:ok, Attempt.t()} | {:error, term()}
  def prepare_retry(%Attempt{} = original, %Operation{} = operation, path, opts) do
    context = context(Keyword.get(opts, :agent_id), path, opts)
    retry = build_attempt(operation, path, opts, context)

    Repo.transaction(fn ->
      current = locked_attempt(original.id)

      cond do
        current.state != "absent" or not current.retry_authorized or
            not action_remains_selected?(current) ->
          Repo.rollback(:retry_not_authorized)

        retry.request_fingerprint != current.request_fingerprint ->
          Repo.rollback(:retry_action_mismatch)

        true ->
          case SafetyFence.blocking_attempts(
                 retry.dependency_keys,
                 current.id,
                 retry.admitted_bounded_unknown_ids
               ) do
            [] ->
              current
              |> Ecto.Changeset.change(retry_authorized: false)
              |> Repo.update!()

              %{retry | retry_of_id: current.id}
              |> Repo.insert!()

            blocking ->
              Repo.rollback({:safety_fenced, Enum.map(blocking, & &1.id)})
          end
      end
    end)
  end

  @spec mark_sent_or_unknown(Attempt.t()) :: {:ok, Attempt.t()} | {:error, term()}
  def mark_sent_or_unknown(%Attempt{state: "prepared"} = attempt) do
    Repo.transaction(fn ->
      lock_dependencies(attempt.dependency_keys)
      current = locked_attempt(attempt.id)

      case SafetyFence.blocking_attempts(
             current.dependency_keys,
             current.id,
             current.admitted_bounded_unknown_ids
           ) do
        [] ->
          current
          |> Ecto.Changeset.change(
            state: "sent_or_unknown",
            sent_or_unknown_at: DateTime.utc_now()
          )
          |> Repo.update!()

        blocking ->
          Repo.rollback({:safety_fenced, Enum.map(blocking, & &1.id)})
      end
    end)
  end

  @spec record_outcome(Attempt.t(), atom(), map()) :: {:ok, Attempt.t()} | {:error, term()}
  def record_outcome(%Attempt{} = attempt, classification, evidence)
      when classification in [:succeeded, :rejected, :ambiguous] and is_map(evidence) do
    append_outcome(attempt, classification, evidence)
  end

  @spec reconcile(Attempt.t(), atom(), [AuthoritativeObservation.t()], keyword()) ::
          {:ok, Attempt.t()} | {:error, term()}
  def reconcile(attempt, resolution, observations, opts \\ [])

  def reconcile(%Attempt{} = attempt, resolution, observations, opts)
      when resolution in [:accepted, :absent, :bounded_unknown] and is_list(observations) do
    with {:ok, evidence} <-
           validate_reconciliation_evidence(attempt, resolution, observations, opts) do
      action_selected = resolution == :absent and action_remains_selected?(attempt)

      append_outcome(
        attempt,
        resolution,
        if(resolution == :absent,
          do:
            Map.put(evidence, :action_selection, %{
              selected: action_selected,
              intent_id: attempt.provenance["intent_id"],
              fingerprint: attempt.provenance["selected_action_fingerprint"]
            }),
          else: evidence
        ),
        retry_authorized: action_selected
      )
    end
  end

  @spec list_for_agent(Agent.t()) :: [Attempt.t()]
  def list_for_agent(%Agent{id: agent_id}) do
    list(where(Attempt, [attempt], attempt.agent_id == ^agent_id))
  end

  @spec list_for_operator(Operator.t()) :: [Attempt.t()]
  def list_for_operator(%Operator{id: operator_id}) do
    list(where(Attempt, [attempt], attempt.operator_id == ^operator_id))
  end

  @doc "Returns unresolved mutation evidence for the action currently selected by an Intent."
  @spec unresolved_for_intent(Intent.t()) :: Attempt.t() | nil
  def unresolved_for_intent(%Intent{} = intent) do
    attempt_for_intent(intent, ["sent_or_unknown", "ambiguous"])
  end

  def latest_for_intent(%Intent{} = intent) do
    attempt_for_intent(intent, [
      "prepared",
      "sent_or_unknown",
      "ambiguous",
      "succeeded",
      "rejected"
    ])
  end

  defp attempt_for_intent(%Intent{} = intent, states) do
    provenance = %{
      "intent_id" => intent.id,
      "selected_action_fingerprint" => action_fingerprint(intent.in_flight_action)
    }

    Attempt
    |> where([attempt], attempt.state in ^states)
    |> where([attempt], fragment("? @> ?", attempt.provenance, ^provenance))
    |> order_by([attempt], desc: attempt.prepared_at, desc: attempt.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      %Attempt{} = attempt -> Repo.preload(attempt, :outcomes)
      nil -> nil
    end
  end

  @spec get!(Ecto.UUID.t()) :: Attempt.t()
  def get!(attempt_id) do
    Attempt
    |> Repo.get!(attempt_id)
    |> Repo.preload(:outcomes)
  end

  defp append_outcome(attempt, classification, evidence, attempt_changes \\ []) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      current = locked_attempt(attempt.id)

      unless outcome_allowed?(current.state, classification) do
        Repo.rollback({:invalid_mutation_attempt_state, current.state, classification})
      end

      attempt =
        current
        |> Ecto.Changeset.change(
          Keyword.merge(attempt_changes, state: Atom.to_string(classification))
        )
        |> Repo.update!()

      %Outcome{
        mutation_attempt_id: attempt.id,
        classification: Atom.to_string(classification),
        evidence: scrub(evidence),
        recorded_at: now
      }
      |> Repo.insert!()

      Repo.preload(attempt, :outcomes, force: true)
    end)
  end

  defp outcome_allowed?("sent_or_unknown", classification)
       when classification in [:succeeded, :rejected, :ambiguous],
       do: true

  defp outcome_allowed?(state, classification)
       when state in ["sent_or_unknown", "ambiguous"] and
              classification in [:accepted, :absent, :bounded_unknown],
       do: true

  defp outcome_allowed?(_state, _classification), do: false

  defp locked_attempt(attempt_id) do
    Repo.one!(
      from current in Attempt,
        where: current.id == ^attempt_id,
        lock: "FOR UPDATE"
    )
  end

  defp build_attempt(operation, path, opts, context) do
    now = DateTime.utc_now()
    dependency_keys = dependency_keys(operation, path, opts, context)
    admitted_bounded_unknown_ids = admitted_bounded_unknown_ids(opts)

    prepared_evidence =
      scrub(%{
        "request" => %{"path" => path, "body" => opts[:json], "query" => opts[:params]},
        "preconditions" => operation.prerequisites
      })

    %Attempt{
      operation_id: operation.id,
      operation_owner: Atom.to_string(operation.owner),
      state: "prepared",
      request_fingerprint: fingerprint(operation.id, prepared_evidence, dependency_keys),
      prepared_evidence: prepared_evidence,
      expected_effects: operation.success_evidence,
      consequence_bounds: operation.consequences,
      dependency_keys: dependency_keys,
      admitted_bounded_unknown_ids: admitted_bounded_unknown_ids,
      provenance: provenance(context),
      prepared_at: now,
      operator_id: context.operator_id,
      agent_id: context.agent_id,
      fleet_generation_id: context.fleet_generation_id,
      strategy_revision_id: context.strategy_revision_id
    }
  end

  defp context(agent_id, path, opts) when is_integer(agent_id) do
    agent = Repo.get(Agent, agent_id)

    generation =
      Repo.one(
        from generation in Generation,
          where: generation.agent_id == ^agent_id and is_nil(generation.retired_at),
          limit: 1
      )

    execution = execution_context(agent_id, path, opts)

    %{
      operator_id: agent && agent.operator_id,
      agent_id: agent_id,
      fleet_generation_id: generation && generation.id,
      strategy_revision_id: generation && generation.fleet_strategy_revision_id
    }
    |> Map.merge(execution)
  end

  defp context(_agent_id, _path, _opts) do
    metadata = logger_metadata()

    %{
      operator_id: metadata[:operator_id],
      agent_id: metadata[:agent_id],
      fleet_generation_id: metadata[:fleet_generation_id],
      strategy_revision_id: metadata[:strategy_revision_id]
    }
  end

  defp execution_context(agent_id, path, opts) do
    case request_ship_symbol(path, opts) do
      ship_symbol when is_binary(ship_symbol) ->
        case Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol) do
          %Ship{} = ship ->
            intent =
              Repo.one(
                from intent in Intent,
                  where:
                    intent.ship_id == ^ship.id and intent.status in ^Intent.unfinished_states(),
                  order_by: [desc: intent.id],
                  limit: 1
              )

            %{
              ship_id: ship.id,
              ship_symbol: ship.symbol,
              intent_id: intent && intent.id,
              selected_action_fingerprint: intent && action_fingerprint(intent.in_flight_action)
            }
            |> Map.reject(fn {_key, value} -> is_nil(value) end)

          nil ->
            %{ship_symbol: ship_symbol}
        end

      _ ->
        %{}
    end
  end

  defp request_ship_symbol(path, opts) do
    case String.split(path, "/", trim: true) do
      ["my", "ships", ship_symbol | _rest] -> ship_symbol
      _ -> get_in(opts, [:json, "shipSymbol"])
    end
  end

  defp dependency_keys(%Operation{fence_dependencies: dependencies}, path, opts, context) do
    dependencies
    |> Enum.flat_map(&dependency_key(&1, path, opts, context))
    |> Enum.uniq()
  end

  defp dependency_key(:ship, _path, _opts, context), do: ship_dependency_keys(context)

  defp dependency_key(:agent_credits, _path, _opts, context),
    do: [DependencyKey.agent_credits(context.agent_id)]

  defp dependency_key(:owned_fleet, _path, _opts, context),
    do: [DependencyKey.owned_fleet(context.agent_id)]

  defp dependency_key(:agent_symbol, _path, opts, context) do
    symbol = get_in(opts, [:json, "symbol"]) || get_in(opts, [:json, :symbol])
    [DependencyKey.agent_symbol(context.operator_id || "unknown", symbol || "unknown")]
  end

  defp dependency_key(:contract, path, _opts, context),
    do: [DependencyKey.contract(context.agent_id, path_parameter(path, "contracts") || "unknown")]

  defp dependency_key(:construction, path, _opts, context),
    do: [
      DependencyKey.construction(context.agent_id, path_parameter(path, "waypoints") || "unknown")
    ]

  defp dependency_key(:waypoint, _path, opts, context),
    do: waypoint_dependency_keys(opts, context)

  defp dependency_key(:target_ship, _path, opts, context) do
    ship_symbol = get_in(opts, [:json, "shipSymbol"]) || get_in(opts, [:json, :shipSymbol])
    [DependencyKey.ship(context.agent_id, ship_symbol || "unknown")]
  end

  defp dependency_key(:agent, _path, _opts, context),
    do: [fallback_dependency_key(context)]

  defp ship_dependency_keys(%{agent_id: agent_id, ship_symbol: ship_symbol})
       when is_integer(agent_id) and is_binary(ship_symbol),
       do: [DependencyKey.ship(agent_id, ship_symbol)]

  defp ship_dependency_keys(context), do: [fallback_dependency_key(context)]

  defp waypoint_dependency_keys(opts, context) do
    waypoint_symbol =
      get_in(opts, [:dependency_context, :waypoint_symbol]) ||
        get_in(opts, [:dependency_context, "waypoint_symbol"])

    if is_binary(waypoint_symbol) and waypoint_symbol != "" do
      [DependencyKey.waypoint(context.agent_id || "unknown", waypoint_symbol)]
    else
      [fallback_dependency_key(context)]
    end
  end

  defp fallback_dependency_key(%{agent_id: agent_id}) when is_integer(agent_id),
    do: DependencyKey.agent(agent_id)

  defp fallback_dependency_key(%{operator_id: operator_id}) when is_integer(operator_id),
    do: DependencyKey.operator(operator_id)

  defp fallback_dependency_key(_context), do: "global"

  defp path_parameter(path, segment) do
    parts = String.split(path, "/", trim: true)

    case Enum.find_index(parts, &(&1 == segment)) do
      nil -> nil
      index -> Enum.at(parts, index + 1)
    end
  end

  defp admitted_bounded_unknown_ids(opts) do
    opts
    |> Keyword.get(:bounded_unknown_admissions, [])
    |> Enum.flat_map(fn
      {%Attempt{id: attempt_id}, %ConstraintAccounting{} = accounting} ->
        current = get!(attempt_id)

        if current.state == "bounded_unknown" and
             Evidence.validate_constraint_accounting(current, accounting) == :ok do
          [attempt_id]
        else
          []
        end

      _invalid_admission ->
        []
    end)
  end

  defp list(query) do
    query
    |> order_by([attempt], asc: attempt.prepared_at, asc: attempt.id)
    |> preload(:outcomes)
    |> Repo.all()
  end

  defp provenance(context) do
    logger_metadata()
    |> Map.merge(Map.reject(context, fn {_key, value} -> is_nil(value) end))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp logger_metadata do
    Logger.metadata()
    |> Map.new()
    |> Map.take(@correlation_keys)
  end

  defp fingerprint(operation_id, prepared_evidence, dependency_keys) do
    Evidence.fingerprint({operation_id, prepared_evidence, dependency_keys})
  end

  defp validate_reconciliation_evidence(attempt, resolution, observations, opts) do
    accounting = Keyword.get(opts, :constraint_accounting)

    with :ok <- validate_observations(attempt, resolution, observations),
         :ok <- validate_constraint_accounting(attempt, resolution, accounting) do
      evidence = %{"observations" => Enum.map(observations, &Evidence.serialize/1)}

      if accounting do
        {:ok, Map.put(evidence, "constraint_accounting", Evidence.serialize(accounting))}
      else
        {:ok, evidence}
      end
    end
  end

  defp validate_observations(attempt, resolution, observations) do
    covered_dependencies =
      observations
      |> Enum.filter(&Evidence.valid_observation?/1)
      |> Enum.filter(
        &(DateTime.compare(&1.observed_at, attempt.sent_or_unknown_at) in [:eq, :gt])
      )
      |> Enum.flat_map(& &1.dependency_keys)
      |> MapSet.new()

    proves_outcome? =
      Enum.any?(observations, &observation_proves?(&1, attempt, resolution))

    if length(observations) > 0 and proves_outcome? and
         Enum.all?(observations, &Evidence.valid_observation?/1) and
         MapSet.subset?(MapSet.new(attempt.dependency_keys), covered_dependencies) do
      :ok
    else
      {:error, :authoritative_evidence_required}
    end
  end

  defp observation_proves?(%AuthoritativeObservation{facts: facts}, attempt, resolution) do
    conclusion = Map.get(facts, :reconciliation) || Map.get(facts, "reconciliation") || %{}

    (Map.get(conclusion, :mutation_attempt_id) || conclusion["mutation_attempt_id"]) == attempt.id and
      (Map.get(conclusion, :request_fingerprint) || conclusion["request_fingerprint"]) ==
        attempt.request_fingerprint and
      (Map.get(conclusion, :outcome) || conclusion["outcome"]) == Atom.to_string(resolution) and
      is_binary(Map.get(conclusion, :basis) || conclusion["basis"])
  end

  defp observation_proves?(_observation, _attempt, _resolution), do: false

  defp validate_constraint_accounting(_attempt, resolution, nil)
       when resolution != :bounded_unknown,
       do: :ok

  defp validate_constraint_accounting(
         attempt,
         :bounded_unknown,
         %ConstraintAccounting{} = accounting
       ),
       do: Evidence.validate_constraint_accounting(attempt, accounting)

  defp validate_constraint_accounting(_attempt, :bounded_unknown, _accounting),
    do: {:error, :hard_constraint_accounting_required}

  defp action_remains_selected?(%Attempt{provenance: provenance}) do
    with intent_id when is_integer(intent_id) <- provenance["intent_id"],
         fingerprint when is_binary(fingerprint) <- provenance["selected_action_fingerprint"],
         %Intent{} = intent <- Repo.get(Intent, intent_id) do
      intent.status in Intent.unfinished_states() and
        action_fingerprint(intent.in_flight_action) == fingerprint
    else
      _missing_selection -> false
    end
  end

  defp action_fingerprint(action) when is_map(action) and map_size(action) > 0 do
    Evidence.fingerprint(action)
  end

  defp action_fingerprint(_action), do: nil

  defp lock_dependencies(dependency_keys) do
    dependency_keys
    |> Enum.sort()
    |> Enum.each(fn dependency_key ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dependency_key])
    end)
  end

  defp scrub(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> credential_key?(key) end)
    |> Map.new(fn {key, item} -> {to_string(key), scrub(item)} end)
  end

  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(value), do: value

  defp credential_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.match?(~r/(authorization|credential|password|token)/)
  end
end
