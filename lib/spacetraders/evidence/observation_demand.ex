defmodule SpaceTraders.Evidence.ObservationDemand do
  @moduledoc "A durable, revocable requirement for authoritative evidence."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "observation_demands" do
    field :subject, :string
    field :required_facts, {:array, :string}
    field :freshness_seconds, :integer
    field :deadline_at, :utc_datetime_usec
    field :owner, :string
    field :withdrawn_at, :utc_datetime_usec

    belongs_to :agent, SpaceTraders.Agent.Agent
    belongs_to :strategy_revision, SpaceTraders.FleetStrategy.Revision

    belongs_to :fulfilled_observation, SpaceTraders.Evidence.Observation, type: :binary_id

    belongs_to :replaces, __MODULE__, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(demand, attrs) do
    demand
    |> cast(attrs, [
      :agent_id,
      :strategy_revision_id,
      :subject,
      :required_facts,
      :freshness_seconds,
      :deadline_at,
      :owner,
      :replaces_id
    ])
    |> update_change(:required_facts, fn
      facts when is_list(facts) -> Enum.uniq(facts)
      facts -> facts
    end)
    |> validate_required([
      :agent_id,
      :strategy_revision_id,
      :subject,
      :required_facts,
      :freshness_seconds,
      :deadline_at,
      :owner
    ])
    |> validate_length(:subject, min: 1)
    |> validate_length(:required_facts, min: 1)
    |> validate_change(:required_facts, fn :required_facts, facts ->
      if is_list(facts) and Enum.all?(facts, &(is_binary(&1) and String.trim(&1) != "")),
        do: [],
        else: [required_facts: "must contain only named facts"]
    end)
    |> validate_number(:freshness_seconds, greater_than_or_equal_to: 0)
    |> validate_length(:owner, min: 1)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:strategy_revision_id)
    |> foreign_key_constraint(:replaces_id)
    |> unique_constraint(:replaces_id)
  end
end
