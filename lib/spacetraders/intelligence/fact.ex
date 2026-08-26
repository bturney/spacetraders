defmodule SpaceTraders.Intelligence.Fact do
  use Ecto.Schema
  import Ecto.Changeset

  @states ["known", "unknown", "known_unavailable"]

  schema "intelligence_facts" do
    field :subject_type, :string
    field :subject_system_symbol, :string
    field :subject_symbol, :string
    field :field, :string
    field :state, :string
    field :value, :map
    field :invalidated_at, :utc_datetime

    belongs_to :agent, SpaceTraders.Agent.Agent
    belongs_to :observation, SpaceTraders.Intelligence.Observation

    timestamps(type: :utc_datetime)
  end

  def changeset(fact, attrs) do
    fact
    |> cast(attrs, [
      :observation_id,
      :agent_id,
      :subject_type,
      :subject_system_symbol,
      :subject_symbol,
      :field,
      :state,
      :value,
      :invalidated_at
    ])
    |> validate_required([
      :observation_id,
      :agent_id,
      :subject_type,
      :subject_symbol,
      :field,
      :state
    ])
    |> validate_inclusion(:state, @states)
  end
end
