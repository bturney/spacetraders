defmodule SpaceTraders.Intelligence.Survey do
  @moduledoc "Agent-scoped, expiration-aware Survey Operational Intelligence."

  use Ecto.Schema
  import Ecto.Changeset

  schema "surveys" do
    field :waypoint_symbol, :string
    field :signature, :string
    field :symbol, :string
    field :size, :string
    field :expiration, :utc_datetime
    field :deposits, {:array, :map}, default: []
    field :source, :string
    field :observing_ship_symbol, :string
    field :observed_at, :utc_datetime
    field :exhausted_at, :utc_datetime

    belongs_to :agent, SpaceTraders.Agent.Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(survey, attrs) do
    survey
    |> cast(attrs, [
      :agent_id,
      :waypoint_symbol,
      :signature,
      :symbol,
      :size,
      :expiration,
      :deposits,
      :source,
      :observing_ship_symbol,
      :observed_at,
      :exhausted_at
    ])
    |> validate_required([
      :agent_id,
      :waypoint_symbol,
      :signature,
      :symbol,
      :size,
      :expiration,
      :source,
      :observed_at
    ])
    |> unique_constraint(:signature, name: :surveys_agent_signature_index)
  end
end
