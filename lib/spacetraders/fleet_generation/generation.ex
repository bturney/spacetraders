defmodule SpaceTraders.FleetGeneration.Generation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "fleet_generations" do
    field :number, :integer
    field :symbol, :string
    field :faction, :string
    field :replacement_symbols, :map, default: %{}
    field :objective_progress, :map, default: %{}
    field :starting_credits, :integer
    field :allocation_version, :integer, default: 0
    field :strategy_capable_at, :utc_datetime_usec
    field :fenced_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec

    belongs_to :operator, SpaceTraders.Agent.Operator
    belongs_to :agent, SpaceTraders.Agent.Agent

    belongs_to :fleet_strategy_revision, SpaceTraders.FleetStrategy.Revision

    timestamps(type: :utc_datetime)
  end

  def changeset(generation, attrs) do
    generation
    |> cast(attrs, [
      :operator_id,
      :agent_id,
      :fleet_strategy_revision_id,
      :number,
      :symbol,
      :faction,
      :replacement_symbols,
      :objective_progress,
      :starting_credits,
      :allocation_version,
      :strategy_capable_at,
      :fenced_at,
      :retired_at
    ])
    |> validate_required([
      :operator_id,
      :agent_id,
      :number,
      :symbol,
      :faction,
      :replacement_symbols,
      :objective_progress
    ])
    |> unique_constraint([:operator_id, :number])
    |> unique_constraint(:agent_id)
  end
end
