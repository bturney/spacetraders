defmodule SpaceTraders.FleetStrategy.Revision do
  @moduledoc "An immutable snapshot of Operator-accepted Fleet Strategy intent."

  use Ecto.Schema
  import Ecto.Changeset

  schema "fleet_strategy_revisions" do
    field :number, :integer
    field :document, :map
    field :source, :string
    field :activated_at, :utc_datetime

    belongs_to :fleet_strategy, SpaceTraders.FleetStrategy.Strategy

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def create_changeset(revision, attrs) do
    revision
    |> cast(attrs, [:fleet_strategy_id, :number, :document, :source, :activated_at])
    |> validate_required([:fleet_strategy_id, :number, :document, :source, :activated_at])
    |> validate_number(:number, greater_than: 0)
    |> unique_constraint([:fleet_strategy_id, :number])
  end
end
