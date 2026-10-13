defmodule SpaceTraders.OperatorAuthority do
  @moduledoc """
  The global Operator authority boundary (ADR 0015).

  A deployment has one authenticated Operator. A `Scope` authenticates a
  command or read; it does not select which Fleet Strategy, Emergency Stop,
  Operator conditions or history it governs. Those belong to the deployment and
  are resolved from the durable current Fleet identity, never from the caller.

  Authority here is authorship and control, not standing gameplay authority:
  callers still pass Strategy, Emergency Stop and runtime authority checks.
  """

  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Repo

  @doc """
  Admits a scope only when it authenticates the deployment Operator.

  Returns the deployment Operator's id, the durable attribution key that
  pre-contraction tables still carry. A legacy Operator row that is not the
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

  The published current Fleet identity decides. Compatible legacy writers can
  insert the sole Operator before adoption publishes it (boot preflight always
  does); that Operator is unambiguous. With several Operator rows and nothing
  published, none is chosen.
  """
  def deployment_operator_id do
    Repo.one(
      from identity in "current_fleet_identity",
        where: identity.id == 1,
        select: identity.operator_id
    ) || sole_operator_id()
  end

  defp sole_operator_id do
    case Repo.all(from(operator in Operator, select: operator.id, limit: 2)) do
      [operator_id] -> operator_id
      _none_or_several -> nil
    end
  end
end
