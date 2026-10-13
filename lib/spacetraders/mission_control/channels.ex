defmodule SpaceTraders.MissionControl.Channels do
  @moduledoc """
  Deployment-wide Mission Control notification channels.

  Strategy and Operator condition changes are deployment events: one
  subscription serves every authenticated surface, with no tenant in the topic
  or payload. Messages are prompts to re-read the shared projection, never
  authority or data.

  Allocation notifications are still produced on the legacy per-Operator outbox
  topic until the Fleet Allocation migration batch moves them;
  `subscribe_allocation/0` is the compatibility adapter that resolves that topic
  from the deployment Operator, so consumers no longer name a tenant.
  """

  alias SpaceTraders.OperatorAuthority

  @pubsub SpaceTraders.PubSub
  @strategy "fleet_strategy"
  @conditions "mission_conditions"

  @doc "Subscribes the caller to deployment Fleet Strategy and Emergency Stop changes."
  def subscribe_strategy, do: Phoenix.PubSub.subscribe(@pubsub, @strategy)

  @doc "Announces a deployment Fleet Strategy or Emergency Stop change."
  def broadcast_strategy,
    do: Phoenix.PubSub.broadcast(@pubsub, @strategy, :fleet_strategy_updated)

  @doc "Subscribes the caller to deployment Attention and Intervention changes."
  def subscribe_conditions, do: Phoenix.PubSub.subscribe(@pubsub, @conditions)

  @doc "Announces a deployment Attention or Intervention change."
  def broadcast_conditions,
    do: Phoenix.PubSub.broadcast(@pubsub, @conditions, :mission_conditions_updated)

  @doc "Subscribes the caller to current-Fleet allocation outbox notifications."
  def subscribe_allocation do
    case OperatorAuthority.deployment_operator_id() do
      nil -> :ok
      operator_id -> Phoenix.PubSub.subscribe(@pubsub, "fleet_allocation:#{operator_id}")
    end
  end
end
