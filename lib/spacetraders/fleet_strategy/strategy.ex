defmodule SpaceTraders.FleetStrategy.Strategy do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias SpaceTraders.FleetStrategy.Revision

  schema "fleet_strategies" do
    field :draft_document, :map
    field :draft_source, :string
    field :draft_version, :integer, default: 0
    field :revision_number, :integer, default: 0
    field :active_revision_id, :integer
    field :emergency_stopped_at, :utc_datetime_usec
    field :emergency_resume_prepared_at, :utc_datetime_usec
    field :emergency_stop_version, :integer, default: 0

    belongs_to :operator, SpaceTraders.Agent.Operator
    has_many :revisions, Revision, foreign_key: :fleet_strategy_id

    timestamps(type: :utc_datetime)
  end

  def changeset(strategy, attrs) do
    strategy
    |> cast(attrs, [
      :operator_id,
      :draft_document,
      :draft_source,
      :draft_version,
      :revision_number,
      :active_revision_id,
      :emergency_stopped_at,
      :emergency_resume_prepared_at,
      :emergency_stop_version
    ])
    |> validate_required([:operator_id])
    |> unique_constraint(:operator_id)
  end
end
