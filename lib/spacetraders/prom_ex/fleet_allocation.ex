defmodule SpaceTraders.PromEx.FleetAllocation do
  @moduledoc """
  Bounded Fleet Allocation metrics for the Market pilot domain (#671).

  G1 counts every publish, replan or unwind outcome with its bounded reason;
  G2 counts each Market trade-versus-coverage decision and sums its candidate,
  claimable-Ship and selected counts. Agent, Generation and Episode ids are
  log metadata only, never labels.
  """

  use PromEx.Plugin

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(:spacetraders_fleet_allocation_metrics, [
      counter(
        [:spacetraders, :fleet_allocation, :publication, :total],
        event_name: [:spacetraders, :fleet_allocation, :publication],
        measurement: :count,
        tags: [:operation, :result, :reason],
        tag_values: &publication_tags/1,
        description: "Fleet Allocation publish, replan and unwind outcomes by bounded reason."
      ),
      counter(
        [:spacetraders, :fleet_allocation, :market_domain, :decisions, :total],
        event_name: [:spacetraders, :fleet_allocation, :market_domain],
        measurement: :count,
        tags: [:result, :decisive_reason],
        description: "Market pilot-domain Allocation decisions by result and decisive reason."
      ),
      sum(
        [:spacetraders, :fleet_allocation, :market_domain, :trade_candidates, :total],
        event_name: [:spacetraders, :fleet_allocation, :market_domain],
        measurement: :trade_candidates,
        tags: [:result],
        description: "Market trade Candidate Contributions compared by pilot-domain decisions."
      ),
      sum(
        [:spacetraders, :fleet_allocation, :market_domain, :coverage_candidates, :total],
        event_name: [:spacetraders, :fleet_allocation, :market_domain],
        measurement: :coverage_candidates,
        tags: [:result],
        description: "Coverage and intelligence Candidate Contributions compared."
      ),
      sum(
        [:spacetraders, :fleet_allocation, :market_domain, :claimable_ships, :total],
        event_name: [:spacetraders, :fleet_allocation, :market_domain],
        measurement: :claimable_ships,
        tags: [:result],
        description: "Claimable Ships available to pilot-domain decisions."
      ),
      sum(
        [:spacetraders, :fleet_allocation, :market_domain, :selected, :total],
        event_name: [:spacetraders, :fleet_allocation, :market_domain],
        measurement: :selected,
        tags: [:result],
        description: "Commitments selected by pilot-domain decisions."
      )
    ])
  end

  defp publication_tags(metadata) do
    %{
      operation: metadata.operation,
      result: metadata.result,
      reason: metadata.reason || :none
    }
  end
end
