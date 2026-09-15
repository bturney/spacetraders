defmodule SpaceTraders.FleetStrategy.Strategy do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias SpaceTraders.FleetStrategy.Revision

  schema "fleet_strategies" do
    field :draft_document, :map
    field :draft_source, :string
    field :active_revision_id, :integer

    belongs_to :operator, SpaceTraders.Agent.Operator
    has_many :revisions, Revision, foreign_key: :fleet_strategy_id

    timestamps(type: :utc_datetime)
  end

  def changeset(strategy, attrs) do
    strategy
    |> cast(attrs, [:operator_id, :draft_document, :draft_source, :active_revision_id])
    |> validate_required([:operator_id])
    |> unique_constraint(:operator_id)
  end
end
