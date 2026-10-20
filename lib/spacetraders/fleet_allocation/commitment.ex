defmodule SpaceTraders.FleetAllocation.Commitment do
  @moduledoc false

  use Ecto.Schema

  @doc """
  True when the Commitment is Market coverage: it depends on a Market not yet
  observed. The one Commitment-level coverage definition. (Realized economics
  classifies a charge by its issuing root Intent instead, charge-at-purchase.)
  """
  def coverage?(%{dependencies: dependencies}) do
    Enum.any?(dependencies, fn dependency ->
      match?(%{"subject" => "market:" <> _}, dependency) and
        not Map.has_key?(dependency, "evidence_id")
    end)
  end

  schema "fleet_commitments" do
    field :candidate_id, :string
    field :objective_index, :integer
    field :claims, {:array, :string}, default: []
    field :reservations, :map, default: %{}
    field :pledges, {:array, :map}, default: []
    field :dependencies, {:array, :map}, default: []
    field :expected_value, :float
    field :unwind_cost, :float

    field :unwind_state, Ecto.Enum,
      values: [:not_required, :settling, :released],
      default: :not_required

    field :decisive_reason, :string

    belongs_to :fleet_commitment_portfolio, SpaceTraders.FleetAllocation.Portfolio

    belongs_to :replan_decision_episode, SpaceTraders.FleetAllocation.StrategyDecisionEpisode

    timestamps(
      type: :utc_datetime_usec,
      updated_at: false,
      autogenerate: {SpaceTraders.Clock.Timestamp, :now, []}
    )
  end
end
