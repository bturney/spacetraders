defmodule SpaceTraders.Intelligence.Observation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "intelligence_observations" do
    field :observing_ship_symbol, :string
    field :source, :string
    field :subject_type, :string
    field :subject_system_symbol, :string
    field :subject_symbol, :string
    field :observed_at, :utc_datetime

    belongs_to :agent, SpaceTraders.Agent.Agent
    has_many :facts, SpaceTraders.Intelligence.Fact

    timestamps(type: :utc_datetime)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :agent_id,
      :observing_ship_symbol,
      :source,
      :subject_type,
      :subject_system_symbol,
      :subject_symbol,
      :observed_at
    ])
    |> validate_required([:agent_id, :source, :subject_type, :subject_symbol, :observed_at])
  end
end
