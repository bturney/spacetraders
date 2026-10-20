defmodule SpaceTraders.MissionControl.Glance do
  @moduledoc """
  One Glance recompute (spec #757): Plan Health, credits, Ships in motion and
  the Just happened feed of the current Fleet, read once as of `now`.

  The current Fleet, its Ships, their statuses and the current Portfolio are
  read once and shared by every card. Stored facts only: a fixed number of queries whatever the number
  of Ships, and no game request.
  """

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Fleet, FleetAllocation, FleetGeneration}
  alias SpaceTraders.MissionControl.{Credits, Happenings, Motion, PlanHealth, ShipStatus}

  @doc "`%{agent, health, credits, motion, events}`; nil parts when there is no current Fleet."
  def read(%Scope{} = scope, %DateTime{} = now) do
    case FleetGeneration.current_fleet(scope) do
      {:ok, %{state: :current, agent: agent} = current} ->
        generation = current[:generation]
        ships = Fleet.current_ships(agent.id)
        portfolio = generation && FleetAllocation.current_portfolio()
        statuses = ShipStatus.for_ships(agent, ships, now, portfolio: portfolio)

        fleet = %{
          agent: agent,
          generation: generation,
          ships: ships,
          statuses: statuses,
          portfolio: portfolio
        }

        %{
          agent: agent,
          health: PlanHealth.read(scope, now, fleet),
          credits: generation && Credits.build(agent, generation, now),
          motion: Motion.build(ships, statuses, now),
          events: Happenings.read(agent)
        }

      _ ->
        %{
          agent: nil,
          health: PlanHealth.evaluate(%{fleet?: false}, now),
          credits: nil,
          motion: nil,
          events: []
        }
    end
  end
end
