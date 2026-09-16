defmodule SpaceTraders.Evidence.Observation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "authoritative_observations" do
    field :subject, :string
    field :operation_id, :string
    field :dependency_keys, {:array, :string}
    field :facts, :map
    field :response_fingerprint, :string
    field :observed_at, :utc_datetime_usec

    belongs_to :agent, SpaceTraders.Agent.Agent

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
