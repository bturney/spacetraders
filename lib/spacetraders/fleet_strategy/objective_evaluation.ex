defmodule SpaceTraders.FleetStrategy.ObjectiveEvaluation do
  @moduledoc false

  alias SpaceTraders.FleetStrategy.Revision

  def evaluate(%Revision{} = revision, objective_index, facts)
      when is_integer(objective_index) and objective_index >= 0 and is_map(facts) do
    with {:ok, objective} <- objective_at(revision, objective_index),
         {:ok, evaluation} <- evaluate_kind(objective, facts),
         {:ok, feasible?} <- boolean(facts, :feasible?) do
      {:ok,
       Map.merge(evaluation, %{
         revision_id: revision.id,
         objective_index: objective_index,
         evaluation_rule: objective["evaluation"],
         feasible?: feasible?
       })}
    end
  end

  def evaluate(_revision, _objective_index, _facts), do: {:error, :invalid_evaluation}

  def advance_recurrence(
        %Revision{id: revision_id, document: %{"objectives" => objectives}},
        %{revision_id: revision_id, objectives: progress} = state,
        objective_index,
        next_recurrence_id
      )
      when is_map(progress) and is_integer(objective_index) and objective_index >= 0 and
             not is_nil(next_recurrence_id) do
    with %{"scope" => "recurring"} <- Enum.at(objectives, objective_index),
         true <- complete_progress?(objectives, progress) do
      {:ok,
       put_in(state, [:objectives, objective_index], %{
         recurrence_id: next_recurrence_id,
         progress: nil
       })}
    else
      _ -> {:error, :invalid_objective_progress}
    end
  end

  def advance_recurrence(_revision, _progress, _objective_index, _next_recurrence_id),
    do: {:error, :invalid_objective_progress}

  def matching_objectives?(revision_id, objectives, evaluations) when is_list(evaluations) do
    length(objectives) == length(evaluations) and
      objectives
      |> Enum.with_index()
      |> Enum.zip(evaluations)
      |> Enum.all?(fn {{objective, index}, evaluation} ->
        complete_evaluation?(evaluation, revision_id, objective, index)
      end)
  end

  def matching_objectives?(_revision_id, _objectives, _evaluations), do: false

  def comparison_key(%{
        kind: :attain,
        feasible?: feasible?,
        attained?: attained?,
        expected_seconds_to_target: seconds
      }) do
    {truth(feasible?), truth(attained?), -seconds}
  end

  def comparison_key(%{kind: :maintain, feasible?: feasible?, protected?: protected?}) do
    {truth(feasible?), truth(protected?)}
  end

  def comparison_key(%{kind: :continuous, feasible?: feasible?, rate: rate}) do
    {truth(feasible?), rate}
  end

  defp evaluate_kind(%{"kind" => "attain"}, facts) do
    with {:ok, current} <- number(facts, :current),
         {:ok, target} <- positive_number(facts, :target),
         {:ok, expected_seconds} <- non_negative_number(facts, :expected_seconds_to_target) do
      {:ok,
       %{
         kind: :attain,
         progress: min(current / target, 1.0),
         remaining: max(target - current, 0),
         attained?: current >= target,
         expected_seconds_to_target: expected_seconds
       }}
    end
  end

  defp evaluate_kind(%{"kind" => "maintain"}, facts) do
    with {:ok, current} <- number(facts, :current),
         {:ok, target} <- number(facts, :target),
         {:ok, required_margin} <- non_negative_number(facts, :required_margin) do
      margin = current - target

      {:ok,
       %{
         kind: :maintain,
         margin: margin,
         required_margin: required_margin,
         protected?: margin >= required_margin
       }}
    end
  end

  defp evaluate_kind(%{"kind" => "continuous"}, facts) do
    with {:ok, change} <- number(facts, :change),
         {:ok, elapsed_seconds} <- positive_number(facts, :elapsed_seconds),
         {:ok, horizon_seconds} <- positive_number(facts, :horizon_seconds) do
      {:ok,
       %{
         kind: :continuous,
         rate: change / elapsed_seconds * horizon_seconds,
         horizon_seconds: horizon_seconds
       }}
    end
  end

  defp evaluate_kind(_objective, _facts), do: {:error, :invalid_evaluation}

  defp complete_evaluation?(evaluation, revision_id, %{"kind" => "attain"} = objective, index) do
    common_evaluation?(evaluation, revision_id, objective, :attain, index) and
      is_number(evaluation[:progress]) and is_number(evaluation[:remaining]) and
      is_boolean(evaluation[:attained?]) and
      is_number(evaluation[:expected_seconds_to_target])
  end

  defp complete_evaluation?(evaluation, revision_id, %{"kind" => "maintain"} = objective, index) do
    common_evaluation?(evaluation, revision_id, objective, :maintain, index) and
      is_number(evaluation[:margin]) and is_number(evaluation[:required_margin]) and
      is_boolean(evaluation[:protected?])
  end

  defp complete_evaluation?(
         evaluation,
         revision_id,
         %{"kind" => "continuous"} = objective,
         index
       ) do
    common_evaluation?(evaluation, revision_id, objective, :continuous, index) and
      is_number(evaluation[:rate]) and is_number(evaluation[:horizon_seconds])
  end

  defp complete_evaluation?(_evaluation, _revision_id, _kind, _index), do: false

  defp common_evaluation?(evaluation, revision_id, objective, kind, index)
       when is_map(evaluation) do
    evaluation[:revision_id] == revision_id and evaluation[:objective_index] == index and
      evaluation[:evaluation_rule] == objective["evaluation"] and evaluation[:kind] == kind and
      is_boolean(evaluation[:feasible?])
  end

  defp common_evaluation?(_evaluation, _revision_id, _objective, _kind, _index), do: false

  defp complete_progress?(objectives, progress) do
    expected =
      objectives |> Enum.with_index() |> Map.new(fn {_objective, index} -> {index, true} end)

    MapSet.new(Map.keys(progress)) == MapSet.new(Map.keys(expected))
  end

  defp objective_at(%Revision{document: %{"objectives" => objectives}}, index) do
    case Enum.fetch(objectives, index) do
      {:ok, objective} -> {:ok, objective}
      :error -> {:error, :objective_not_found}
    end
  end

  defp objective_at(_revision, _index), do: {:error, :objective_not_found}

  defp number(facts, key) do
    case Map.fetch(facts, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      _ -> {:error, :invalid_evaluation}
    end
  end

  defp positive_number(facts, key) do
    case number(facts, key) do
      {:ok, value} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_evaluation}
    end
  end

  defp non_negative_number(facts, key) do
    case number(facts, key) do
      {:ok, value} when value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_evaluation}
    end
  end

  defp boolean(facts, key) do
    case Map.fetch(facts, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_evaluation}
    end
  end

  defp truth(true), do: 1
  defp truth(_), do: 0
end
