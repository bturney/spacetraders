defmodule SpaceTraders.OperatorAuthority do
  @moduledoc """
  The global Operator authority boundary (ADR 0015).

  A deployment has one authenticated Operator. A `Scope` authenticates a
  command or read; it does not select which Fleet Strategy,
  Operator conditions or history it governs. Those belong to the deployment and
  are resolved from the durable current Fleet identity, never from the caller.

  Authority here is authorship and control, not standing gameplay authority:
  callers still pass Strategy and runtime authority checks.
  """

  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Repo

  @doc """
  Admits a scope only when it authenticates the deployment Operator.

  Returns the deployment Operator's id, the durable attribution key that
  historical records retain. An Operator row that is not the
  deployment Operator, or a missing scope, is refused.
  """
  def authorize(%Scope{operator: %Operator{id: operator_id}}) when is_integer(operator_id) do
    if operator_id == deployment_operator_id(),
      do: {:ok, operator_id},
      else: {:error, :not_deployment_operator}
  end

  def authorize(_scope), do: {:error, :unauthenticated}

  @doc """
  Returns the deployment Operator's id, or nil before first-time setup.

  Only the published current Fleet identity decides. Raw unpublished Operators
  grant no authority; migration must establish identity before application boot.
  """
  def deployment_operator_id do
    Repo.one(
      from identity in "current_fleet_identity",
        where: identity.id == 1,
        select: identity.operator_id
    )
  end
end
