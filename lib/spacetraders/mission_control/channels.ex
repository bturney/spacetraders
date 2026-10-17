defmodule SpaceTraders.MissionControl.Channels do
  @moduledoc """
  Deployment-wide Mission Control notification channels.

  Strategy changes are deployment events: one
  subscription serves every authenticated surface, with no tenant in the topic
  or payload. Messages are prompts to re-read the shared projection, never
  authority or data.

  Allocation outbox notifications use the same deployment-wide subscription,
  including setup and fenced transitions where there is no allocatable Fleet.
  """

  @pubsub SpaceTraders.PubSub
  @strategy "fleet_strategy"

  @doc "Subscribes the caller to deployment Fleet Strategy and Emergency Stop changes."
  def subscribe_strategy, do: Phoenix.PubSub.subscribe(@pubsub, @strategy)

  @doc "Announces a deployment Fleet Strategy or Emergency Stop change."
  def broadcast_strategy,
    do: Phoenix.PubSub.broadcast(@pubsub, @strategy, :fleet_strategy_updated)

  @doc "Subscribes the caller to current-Fleet allocation outbox notifications."
  def subscribe_allocation, do: Phoenix.PubSub.subscribe(@pubsub, "fleet_allocation")
end
