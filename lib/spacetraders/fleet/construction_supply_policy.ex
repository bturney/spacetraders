defmodule SpaceTraders.Fleet.ConstructionSupplyPolicy do
  @moduledoc "Chooses completion or the next Intent for a Construction Supply Job."

  alias SpaceTraders.Fleet.JobPolicy

  @spec decide(map()) :: JobPolicy.decision()
  def decide(%{construction_complete?: true}), do: {:complete, %{}}
  def decide(%{remaining: 0}), do: {:complete, %{}}
  def decide(_facts), do: {:intent, :supply_construction}
end
