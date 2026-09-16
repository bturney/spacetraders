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
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.Repo
  alias SpaceTraders.SafetyFence

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
    :job_id,
    :intent_id
  ]

  @spec prepare(Operation.t(), String.t(), keyword()) :: {:ok, Attempt.t()} | {:error, term()}
  def prepare(%Operation{classification: :mutation} = operation, path, opts) do
    context = context(Keyword.get(opts, :agent_id), path, opts)
    attempt = build_attempt(operation, path, opts, context)

    case SafetyFence.blocking_attempts(attempt.dependency_keys) do
      [] -> Repo.insert(attempt)
      blocking -> {:error, {:safety_fenced, Enum.map(blocking, & &1.id)}}
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
        current.state != "absent" or not current.retry_authorized ->
          Repo.rollback(:retry_not_authorized)

        retry.request_fingerprint != current.request_fingerprint ->
          Repo.rollback(:retry_action_mismatch)

        true ->
          case SafetyFence.blocking_attempts(retry.dependency_keys, current.id) do
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

      case SafetyFence.blocking_attempts(current.dependency_keys, current.id) do
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

  @spec reconcile(Attempt.t(), atom(), map(), keyword()) ::
          {:ok, Attempt.t()} | {:error, term()}
  def reconcile(attempt, resolution, evidence, opts \\ [])

  def reconcile(%Attempt{} = attempt, resolution, evidence, opts)
      when resolution in [:accepted, :absent, :bounded_unknown] and is_map(evidence) do
    if authoritative_evidence?(evidence) do
      action_selected = resolution == :absent and Keyword.get(opts, :action_selected, false)

      append_outcome(
        attempt,
        resolution,
        if(resolution == :absent,
          do: Map.put(evidence, :action_selected, action_selected),
          else: evidence
        ),
        retry_authorized: action_selected
      )
    else
      {:error, :authoritative_evidence_required}
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

    prepared_evidence =
      scrub(%{
        "request" => %{"path" => path, "body" => opts[:json], "query" => opts[:params]},
        "preconditions" => operation.prerequisites
      })

    %Attempt{
      operation_id: operation.id,
      operation_owner: Atom.to_string(operation.owner),
      state: "prepared",
      request_fingerprint: fingerprint(operation.id, prepared_evidence),
      prepared_evidence: prepared_evidence,
      expected_effects: operation.success_evidence,
      consequence_bounds: operation.consequences,
      dependency_keys: dependency_keys(operation, path, opts, context),
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
              job_id: intent && intent.job_id
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

  defp dependency_keys(%Operation{ambiguity: :safe_retry}, _path, _opts, _context), do: []

  defp dependency_keys(
         %Operation{ambiguity: {:reconcile_before_retry, evidence}},
         path,
         opts,
         context
       ) do
    evidence
    |> Enum.flat_map(&dependency_key(&1, path, opts, context))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> [fallback_dependency_key(context)]
      keys -> keys
    end
  end

  defp dependency_key("Agent credits", _path, _opts, context),
    do: scoped_key("agent-credits", context.agent_id)

  defp dependency_key("owned Fleet", _path, _opts, context),
    do: scoped_key("owned-fleet", context.agent_id)

  defp dependency_key("Agent existence by symbol", _path, opts, context) do
    symbol = get_in(opts, [:json, "symbol"]) || get_in(opts, [:json, :symbol])
    ["agent-symbol:#{context.operator_id || "unknown"}:#{symbol || "unknown"}"]
  end

  defp dependency_key(evidence, path, _opts, context) do
    cond do
      String.starts_with?(evidence, "Ship ") ->
        ship_dependency_keys(context)

      String.starts_with?(evidence, "Bounded Unknown") ->
        ship_dependency_keys(context)

      String.starts_with?(evidence, "Contract ") ->
        ["contract:#{path_parameter(path, "contracts") || context.agent_id || "unknown"}"]

      String.starts_with?(evidence, "Construction ") ->
        ["construction:#{path_parameter(path, "waypoints") || context.agent_id || "unknown"}"]

      String.starts_with?(evidence, "Waypoint ") ->
        ship_dependency_keys(context)

      true ->
        []
    end
  end

  defp ship_dependency_keys(%{agent_id: agent_id, ship_symbol: ship_symbol})
       when is_integer(agent_id) and is_binary(ship_symbol),
       do: ["ship:#{agent_id}:#{ship_symbol}"]

  defp ship_dependency_keys(context), do: [fallback_dependency_key(context)]

  defp fallback_dependency_key(%{agent_id: agent_id}) when is_integer(agent_id),
    do: "agent:#{agent_id}"

  defp fallback_dependency_key(%{operator_id: operator_id}) when is_integer(operator_id),
    do: "operator:#{operator_id}"

  defp fallback_dependency_key(_context), do: "global"

  defp scoped_key(scope, id) when is_integer(id), do: ["#{scope}:#{id}"]
  defp scoped_key(_scope, _id), do: []

  defp path_parameter(path, segment) do
    parts = String.split(path, "/", trim: true)

    case Enum.find_index(parts, &(&1 == segment)) do
      nil -> nil
      index -> Enum.at(parts, index + 1)
    end
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

  defp fingerprint(operation_id, prepared_evidence) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({operation_id, prepared_evidence}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp authoritative_evidence?(evidence) do
    Map.get(evidence, :authoritative) == true or Map.get(evidence, "authoritative") == true
  end

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
