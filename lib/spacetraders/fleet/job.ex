defmodule :"Elixir.SpaceTraders.Fleet.Job" do
  defstruct [
    :id,
    :ship_id,
    :type,
    :gather_mode,
    :extraction_waypoint,
    :market_waypoint,
    :cargo_threshold,
    :desired_mode,
    :status,
    :blocked_reason,
    :blocker,
    :last_validated_at,
    :in_flight_action,
    :last_action_result,
    :progress,
    :recovery_attempts,
    :recovery_started_at,
    :sellable_goods,
    :contract_deliverables,
    :finished_at,
    :predecessor_job_id,
    :inserted_at,
    :updated_at
  ]

  def unfinished_states, do: ["active", "waiting", "blocked", "paused"]
  def terminal_states, do: ["completed", "failed", "stopped", "replaced"]
  def running_states, do: ["active", "waiting"]
  def running?(%__MODULE__{status: status}), do: status in running_states()
  def running?(_job), do: false
end
