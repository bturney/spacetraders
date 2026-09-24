defmodule SpaceTraders.MissionControl.Condition do
  @moduledoc "Durable Operator-facing Attention or Intervention, separate from acknowledgement."

  use Ecto.Schema
  import Ecto.Changeset

  schema "mission_conditions" do
    field :key, :string
    field :kind, Ecto.Enum, values: [:attention, :intervention]
    field :summary, :string
    field :acknowledged_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :operator, SpaceTraders.Agent.Operator

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(condition, attrs) do
    condition
    |> cast(attrs, [:operator_id, :key, :kind, :summary, :acknowledged_at, :resolved_at])
    |> validate_required([:operator_id, :key, :kind, :summary])
    |> unique_constraint([:operator_id, :key], name: :mission_conditions_unresolved_key_index)
  end
end
