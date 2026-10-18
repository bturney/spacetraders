defmodule SpaceTraders.Outcomes.EarningsRecord do
  @moduledoc """
  One Earnings record: the Net Earnings of one completed piece of earning
  work, with its costs by type, what was expected at selection and the
  Ship-hours it took. Written once by `SpaceTraders.Outcomes.Earnings`.
  """

  use Ecto.Schema

  schema "earnings_records" do
    field :source, :string
    field :fleet_generation_id, :id
    field :fleet_commitment_id, :id
    field :strategy_decision_episode_id, :id
    field :ship_symbol, :string
    field :ship_type, :string
    field :good, :string
    field :source_waypoint, :string
    field :destination_waypoint, :string
    field :units, :integer
    field :jettisoned_units, :integer, default: 0
    field :revenue, :integer
    field :goods_cost, :integer
    field :fuel_cost, :integer
    field :other_cost, :integer
    field :net_earnings, :integer
    field :expected_value, :integer
    field :expected_net_per_ship_hour, :float
    field :price_age_seconds, :integer
    field :alternatives, {:array, :map}, default: []
    field :ship_seconds, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
