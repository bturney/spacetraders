defmodule SpaceTraders.FleetAllocation.Portfolio do
  @moduledoc false

  use Ecto.Schema

  schema "fleet_commitment_portfolios" do
    field :version, :integer
    field :superseded_at, :utc_datetime_usec

    belongs_to :operator, SpaceTraders.Agent.Operator
    belongs_to :fleet_generation, SpaceTraders.FleetGeneration.Generation
    belongs_to :fleet_strategy_revision, SpaceTraders.FleetStrategy.Revision

    belongs_to :strategy_decision_episode,
               SpaceTraders.FleetAllocation.StrategyDecisionEpisode

    has_many :commitments, SpaceTraders.FleetAllocation.Commitment,
      foreign_key: :fleet_commitment_portfolio_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
