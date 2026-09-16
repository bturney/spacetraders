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
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.Repo

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
    now = DateTime.utc_now()
    context = context(Keyword.get(opts, :agent_id))
    parameters = scrub(%{"path" => path, "body" => opts[:json], "query" => opts[:params]})

    %Attempt{
      operation_id: operation.id,
      operation_owner: Atom.to_string(operation.owner),
      state: "prepared",
      request_fingerprint: fingerprint(operation.id, parameters),
      parameters: parameters,
      expected_effects: operation.success_evidence,
      consequence_bounds: operation.consequences,
      provenance: provenance(context),
      prepared_at: now,
      operator_id: context.operator_id,
      agent_id: context.agent_id,
      fleet_generation_id: context.fleet_generation_id,
      strategy_revision_id: context.strategy_revision_id
    }
    |> Repo.insert()
  end

  @spec mark_sent_or_unknown(Attempt.t()) :: {:ok, Attempt.t()} | {:error, term()}
  def mark_sent_or_unknown(%Attempt{state: "prepared"} = attempt) do
    now = DateTime.utc_now()

    attempt
    |> Ecto.Changeset.change(state: "sent_or_unknown", sent_or_unknown_at: now)
    |> Repo.update()
  end

  @spec record_outcome(Attempt.t(), atom(), map()) :: {:ok, Attempt.t()} | {:error, term()}
  def record_outcome(%Attempt{} = attempt, classification, evidence)
      when classification in [:succeeded, :rejected, :ambiguous] and is_map(evidence) do
    append_outcome(attempt, classification, evidence)
  end

  @spec reconcile(Attempt.t(), atom(), map()) :: {:ok, Attempt.t()} | {:error, term()}
  def reconcile(%Attempt{} = attempt, resolution, evidence)
      when resolution in [:succeeded, :rejected] and is_map(evidence) do
    append_outcome(attempt, :reconciled, Map.put(evidence, :resolution, resolution))
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

  defp append_outcome(attempt, classification, evidence) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      current =
        Repo.one!(
          from current in Attempt,
            where: current.id == ^attempt.id,
            lock: "FOR UPDATE"
        )

      unless outcome_allowed?(current.state, classification) do
        Repo.rollback({:invalid_mutation_attempt_state, current.state, classification})
      end

      attempt =
        current
        |> Ecto.Changeset.change(state: Atom.to_string(classification))
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

  defp outcome_allowed?(state, :reconciled) when state in ["sent_or_unknown", "ambiguous"],
    do: true

  defp outcome_allowed?(_state, _classification), do: false

  defp context(agent_id) when is_integer(agent_id) do
    agent = Repo.get(Agent, agent_id)

    generation =
      Repo.one(
        from generation in Generation,
          where: generation.agent_id == ^agent_id and is_nil(generation.retired_at),
          limit: 1
      )

    %{
      operator_id: agent && agent.operator_id,
      agent_id: agent_id,
      fleet_generation_id: generation && generation.id,
      strategy_revision_id: generation && generation.fleet_strategy_revision_id
    }
  end

  defp context(_agent_id) do
    metadata = logger_metadata()

    %{
      operator_id: metadata[:operator_id],
      agent_id: metadata[:agent_id],
      fleet_generation_id: metadata[:fleet_generation_id],
      strategy_revision_id: metadata[:strategy_revision_id]
    }
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

  defp fingerprint(operation_id, parameters) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({operation_id, parameters}, [:deterministic]))
    |> Base.encode16(case: :lower)
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
