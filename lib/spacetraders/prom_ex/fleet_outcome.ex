defmodule SpaceTraders.PromEx.FleetOutcome do
  use PromEx.Plugin

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(:spacetraders_fleet_outcome_metrics, [
      # The domain area is the prefix; `job` names the app (#767).
      last_value(
        [:fleet, :ships],
        event_name: [:fleet, :ships],
        measurement: :count,
        tags: [:status, :ship_type],
        description: "Current Ships by their one status and Ship type."
      )
    ])
  end
end
