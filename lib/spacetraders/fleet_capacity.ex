defmodule SpaceTraders.FleetCapacity do
  @moduledoc """
  Fleet's one view of API capacity: the Capacity Disposition.

  Fleet work keeps its own Strategy, Planning, and Allocation authority and asks
  the governor only for capacity meaning. A deferral is temporary request
  pressure; it is never a verdict about the objective, a Neutral Wait, or a
  Claim decision. Anything that is not a `:proceed` disposition (a deferral,
  unavailable authority, or no disposition at all) suppresses new governed work.
  """

  alias SpaceTraders.API.CapacityGovernor
  alias SpaceTraders.API.CapacityGovernor.Disposition
  alias SpaceTraders.API.OperationInventory

  @doc """
  Advisory disposition for governed work of the named API operation. `attrs`
  carries the owner's ordering context (`:strategic_priority`,
  `:expected_value`, ...) untouched; the governor interprets it.
  """
  @spec disposition(String.t(), map()) :: Disposition.t()
  def disposition(operation_id, attrs \\ %{}) when is_binary(operation_id) and is_map(attrs),
    do: CapacityGovernor.disposition(OperationInventory.fetch!(operation_id), attrs, governor())

  # Test seam only: `config :spacetraders, SpaceTraders.FleetCapacity,
  # governor: name` points Fleet callers at an isolated governor instance.
  # Production configures nothing and always asks the application governor.
  defp governor do
    Keyword.get(Application.get_env(:spacetraders, __MODULE__, []), :governor, CapacityGovernor)
  end

  @doc "True only for an explicit `:proceed` disposition."
  @spec proceed?(term()) :: boolean()
  def proceed?(%Disposition{status: :proceed}), do: true
  def proceed?(_other), do: false
end
