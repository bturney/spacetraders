defmodule SpaceTraders.Fleet.SystemExplorationPolicy do
  @moduledoc "Decides whether System Exploration baseline coverage is complete."

  alias SpaceTraders.Fleet.JobPolicy

  @spec decide(map()) :: JobPolicy.decision()
  def decide(%{coverage: coverage, viability: viability}) when is_map(coverage) do
    if Enum.all?(coverage, fn {_symbol, missing} -> missing == [] end) do
      {:complete, %{coverage: coverage}}
    else
      {:block, {:unresolved_coverage, coverage, viability}}
    end
  end
end
