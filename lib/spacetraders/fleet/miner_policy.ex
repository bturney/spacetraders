defmodule SpaceTraders.Fleet.MinerPolicy do
  @moduledoc "Chooses the next operational outcome for a Miner Job."

  alias SpaceTraders.Fleet.JobPolicy

  @spec decide(map()) :: JobPolicy.decision()
  def decide(facts) do
    cond do
      facts.in_flight_arrival? -> {:wait, :arrival}
      facts.pending_navigation? -> {:wait, :navigation}
      facts.at_extraction? -> {:intent, :gather}
      facts.at_market? and facts.market_leg? -> {:intent, :settle_market}
      true -> {:intent, %{type: :navigate, waypoint: facts.extraction_waypoint}}
    end
  end
end
