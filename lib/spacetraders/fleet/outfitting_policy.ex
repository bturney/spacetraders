defmodule SpaceTraders.Fleet.OutfittingPolicy do
  @moduledoc "Chooses the next Intent for a Ship Outfitting Job."

  alias SpaceTraders.Fleet.JobPolicy

  @spec decide(map()) :: JobPolicy.decision()
  def decide(facts) do
    cond do
      facts.ready? ->
        {:complete, %{installed_modules: facts.installed_modules}}

      facts.intent? ->
        {:intent, :reconcile}

      is_binary(facts.cargo_candidate) and facts.slot_available? ->
        {:intent, %{type: :install_module, module_symbol: facts.cargo_candidate}}

      is_binary(facts.cargo_candidate) and is_binary(facts.authorized_removal) ->
        {:intent, %{type: :remove_module, module_symbol: facts.authorized_removal}}

      is_binary(facts.cargo_candidate) ->
        {:block, :module_slot_removal_not_authorized}

      facts.sourcing? ->
        {:intent, :purchase_module}

      true ->
        {:block, {:acceptable_module_missing_from_cargo, facts.acceptable_modules}}
    end
  end
end
