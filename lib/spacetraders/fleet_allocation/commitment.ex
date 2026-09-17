defmodule SpaceTraders.FleetAllocation.Commitment do
  @moduledoc false

  use Ecto.Schema

  schema "fleet_commitments" do
    field :candidate_id, :string
    field :objective_index, :integer
    field :claims, {:array, :string}, default: []
    field :reservations, :map, default: %{}
    field :pledges, {:array, :map}, default: []
    field :dependencies, {:array, :map}, default: []
    field :expected_value, :float
    field :unwind_cost, :float
    field :unwind_state, Ecto.Enum, values: [:not_required, :released], default: :not_required
    field :decisive_reason, :string

    belongs_to :fleet_commitment_portfolio, SpaceTraders.FleetAllocation.Portfolio

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
