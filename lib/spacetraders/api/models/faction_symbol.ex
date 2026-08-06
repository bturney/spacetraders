defmodule SpaceTraders.API.Model.FactionSymbol do
  @moduledoc "The symbol of the faction."

  @type t :: String.t()
  @enums [
    "COSMIC",
    "VOID",
    "GALACTIC",
    "QUANTUM",
    "DOMINION",
    "ASTRO",
    "CORSAIRS",
    "OBSIDIAN",
    "AEGIS",
    "UNITED",
    "SOLITARY",
    "COBALT",
    "OMEGA",
    "ECHO",
    "LORDS",
    "CULT",
    "ANCIENTS",
    "SHADOW",
    "ETHEREAL"
  ]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
