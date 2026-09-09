defmodule SpaceTraders.Fleet.SurveyPolicy do
  @moduledoc "Chooses the next operational outcome for a Survey Job."

  alias SpaceTraders.Fleet.JobPolicy

  @spec decide(map()) :: JobPolicy.decision()
  def decide(facts) do
    cond do
      facts.in_flight_arrival? ->
        {:wait, :arrival}

      facts.pending_navigation? ->
        {:wait, :navigation}

      not facts.at_extraction? ->
        {:intent, %{type: :navigate, waypoint: facts.extraction_waypoint}}

      facts.valid_survey? ->
        {:wait, :survey_available}

      true ->
        {:intent, :survey}
    end
  end
end
