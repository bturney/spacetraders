defmodule SpaceTraders.Fleet.ProcurementPolicy do
  @moduledoc "Chooses completion or the next Intent for a Procurement Job."

  alias SpaceTraders.Fleet.JobPolicy

  @spec decide(map()) :: JobPolicy.decision()
  def decide(%{accepted: accepted, shared_fulfilled: shared, requested: requested})
      when accepted >= requested or shared >= requested,
      do: {:complete, %{accepted: accepted, shared_fulfilled: shared}}

  def decide(_facts), do: {:intent, :procure_or_deliver}
end
