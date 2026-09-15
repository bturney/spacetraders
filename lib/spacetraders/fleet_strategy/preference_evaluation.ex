defmodule SpaceTraders.FleetStrategy.PreferenceEvaluation do
  @moduledoc false

  alias SpaceTraders.FleetStrategy.Revision

  def evaluate(%Revision{} = revision, preference_index, score)
      when is_integer(preference_index) and preference_index >= 0 and is_number(score) do
    with {:ok, preference} <- preference_at(revision, preference_index) do
      {:ok,
       %{
         revision_id: revision.id,
         preference_index: preference_index,
         preference: preference,
         score: score
       }}
    end
  end

  def evaluate(_revision, _preference_index, _score),
    do: {:error, :invalid_preference_evaluation}

  def matching?(revision_id, preferences, evaluations) when is_list(evaluations) do
    length(preferences) == length(evaluations) and
      preferences
      |> Enum.with_index()
      |> Enum.zip(evaluations)
      |> Enum.all?(fn {{preference, index}, evaluation} ->
        is_map(evaluation) and evaluation[:revision_id] == revision_id and
          evaluation[:preference_index] == index and evaluation[:preference] == preference and
          is_number(evaluation[:score])
      end)
  end

  def matching?(_revision_id, _preferences, _evaluations), do: false

  defp preference_at(%Revision{document: %{"preferences" => preferences}}, index) do
    case Enum.fetch(preferences, index) do
      {:ok, preference} -> {:ok, preference}
      :error -> {:error, :preference_not_found}
    end
  end

  defp preference_at(_revision, _index), do: {:error, :preference_not_found}
end
