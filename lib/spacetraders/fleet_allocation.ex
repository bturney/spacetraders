defmodule SpaceTraders.FleetAllocation do
  @moduledoc """
  Applies Fleet Strategy ordering to evidence-bound candidate plans.

  This module ranks candidates only. It does not create Fleet Commitments or
  claim resources; those remain later Fleet Allocation activation work.
  """

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetStrategy

  alias SpaceTraders.FleetStrategy.{
    ObjectiveEvaluation,
    PreferenceEvaluation,
    Revision,
    StandingAuthority
  }

  def rank_plans(%Scope{} = scope, plans) do
    case FleetStrategy.get(scope).active_revision do
      %Revision{} = revision -> {:ok, rank(revision, plans)}
      nil -> {:error, :strategy_not_active}
    end
  end

  defp rank(%Revision{document: %{"objectives" => objectives}} = revision, plans)
       when is_list(objectives) and is_list(plans) do
    {admissible, rejected} =
      Enum.reduce(plans, {[], []}, fn plan, {admitted, denied} ->
        reasons = plan_rejections(revision, plan)

        if reasons == [] do
          {[plan | admitted], denied}
        else
          {admitted, [%{plan: plan, reasons: reasons} | denied]}
        end
      end)

    ordered = Enum.sort(admissible, &plan_before?(&1, &2, length(objectives)))
    %{revision_id: revision.id, admissible: ordered, rejected: Enum.reverse(rejected)}
  end

  defp plan_rejections(%Revision{document: document} = revision, plan) do
    if is_map(plan) do
      objectives = Map.fetch!(document, "objectives")
      preferences = Map.fetch!(document, "preferences")

      cond do
        not ObjectiveEvaluation.matching_objectives?(
          revision.id,
          objectives,
          Map.get(plan, :objective_evaluations)
        ) ->
          ["Every Strategic Objective requires one complete matching evaluation."]

        not PreferenceEvaluation.matching?(
          revision.id,
          preferences,
          Map.get(plan, :preference_evaluations)
        ) ->
          ["Every Preference requires one complete revision-bound evaluation."]

        true ->
          case StandingAuthority.authorize(revision, Map.get(plan, :safety, %{})) do
            {:ok, _authorization} -> []
            {:error, reasons} -> reasons
          end
      end
    else
      ["A plan must provide complete revision-bound evaluations and safety evidence."]
    end
  end

  defp plan_before?(left, right, objective_count) do
    case compare_keys(plan_keys(left, objective_count), plan_keys(right, objective_count)) do
      :equal -> preference_scores(left) >= preference_scores(right)
      :left -> true
      :right -> false
    end
  end

  defp plan_keys(plan, objective_count) do
    plan
    |> Map.fetch!(:objective_evaluations)
    |> Enum.take(objective_count)
    |> Enum.map(&ObjectiveEvaluation.comparison_key/1)
  end

  defp preference_scores(plan) do
    plan
    |> Map.fetch!(:preference_evaluations)
    |> Enum.map(&Map.fetch!(&1, :score))
  end

  defp compare_keys([], []), do: :equal
  defp compare_keys([same | left], [same | right]), do: compare_keys(left, right)
  defp compare_keys([left | _], [right | _]) when left > right, do: :left
  defp compare_keys([_left | _], [_right | _]), do: :right
end
