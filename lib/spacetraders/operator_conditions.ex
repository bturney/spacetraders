defmodule SpaceTraders.OperatorConditions do
  @moduledoc "Durable Operator-facing Attention and Intervention lifecycle."

  import Ecto.Query

  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.OperatorConditions.Condition
  alias SpaceTraders.Repo

  @doc "Records an idempotent condition; resolution preserves the past occurrence."
  def raise(%Scope{operator: %{id: operator_id}}, key, kind, summary, opts \\ [])
      when is_binary(key) and kind in [:attention, :intervention] and is_binary(summary) do
    attrs = %{operator_id: operator_id, key: key, kind: kind, summary: summary}

    result =
      Repo.transaction(fn ->
        Repo.one!(
          from operator in Operator, where: operator.id == ^operator_id, lock: "FOR UPDATE"
        )

        case Repo.one(
               from condition in Condition,
                 where:
                   condition.operator_id == ^operator_id and condition.key == ^key and
                     is_nil(condition.resolved_at)
             ) do
          nil ->
            {%Condition{} |> Condition.changeset(attrs) |> Repo.insert!(), true}

          %{kind: ^kind, summary: ^summary} = condition ->
            {condition, false}

          condition ->
            condition
            |> Condition.changeset(Map.put(attrs, :acknowledged_at, nil))
            |> Repo.update!()
            |> then(&{&1, true})
        end
      end)

    case result do
      {:ok, {condition, changed?}} ->
        if changed? and Keyword.get(opts, :notify?, true), do: broadcast(operator_id)
        {:ok, condition}

      error ->
        error
    end
  end

  @doc "Records a verified Objective evaluation as Attention, or resolves it when feasible."
  def objective_evaluation(%Scope{} = scope, generation, revision, index, evaluation, opts \\ [])
      when is_integer(index) and index >= 0 do
    key = "objective-infeasible:#{generation.id}:#{revision.id}:#{index}"

    case evaluation do
      %{feasible?: false} ->
        objective = revision.document["objectives"] |> Enum.at(index)

        raise(
          scope,
          key,
          :attention,
          "#{objective["objective"]} is not feasible under current evidence.",
          opts
        )

      %{feasible?: true} ->
        resolve(scope, key, opts)
    end
  end

  @doc "Supersedes conditions from the previous Fleet Generation or Strategy Revision."
  def resolve_objective_conditions(%Scope{} = scope) do
    scope
    |> unresolved()
    |> Enum.filter(&String.starts_with?(&1.key, "objective-infeasible:"))
    |> Enum.each(&resolve(scope, &1.key))

    :ok
  end

  @doc "Marks a condition as seen without resolving it."
  def acknowledge(%Scope{operator: %{id: operator_id}}, id) when is_integer(id) do
    {count, _} =
      Repo.update_all(
        from(condition in Condition,
          where:
            condition.id == ^id and condition.operator_id == ^operator_id and
              is_nil(condition.resolved_at) and is_nil(condition.acknowledged_at)
        ),
        set: [acknowledged_at: DateTime.utc_now()]
      )

    if count == 1 or
         Repo.exists?(
           from c in Condition,
             where: c.id == ^id and c.operator_id == ^operator_id and is_nil(c.resolved_at)
         ) do
      if count == 1, do: broadcast(operator_id)
      :ok
    else
      {:error, :condition_unavailable}
    end
  end

  @doc "Resolves the condition after its producer establishes the underlying change."
  def resolve(%Scope{operator: %{id: operator_id}}, key, opts \\ []) when is_binary(key) do
    {count, _} =
      Repo.update_all(
        from(condition in Condition,
          where:
            condition.operator_id == ^operator_id and condition.key == ^key and
              is_nil(condition.resolved_at)
        ),
        set: [resolved_at: DateTime.utc_now()]
      )

    if count > 0 and Keyword.get(opts, :notify?, true), do: broadcast(operator_id)
    :ok
  end

  @doc "Returns unresolved conditions in first-observed order, even after acknowledgement."
  def unresolved(%Scope{operator: %{id: operator_id}}) do
    Repo.all(
      from condition in Condition,
        where: condition.operator_id == ^operator_id and is_nil(condition.resolved_at),
        order_by: [asc: condition.inserted_at, asc: condition.id]
    )
  end

  @doc "Returns retained condition occurrences, including resolved ones."
  def history(%Scope{operator: %{id: operator_id}}) do
    Repo.all(
      from condition in Condition,
        where: condition.operator_id == ^operator_id,
        order_by: [desc: condition.inserted_at, desc: condition.id],
        limit: 100
    )
  end

  @doc false
  def notify(%Scope{operator: %{id: operator_id}}), do: broadcast(operator_id)

  defp broadcast(operator_id) do
    Phoenix.PubSub.broadcast(
      SpaceTraders.PubSub,
      "mission_conditions:#{operator_id}",
      :mission_conditions_updated
    )
  end
end
