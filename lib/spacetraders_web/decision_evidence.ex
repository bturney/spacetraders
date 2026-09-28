defmodule SpaceTradersWeb.DecisionEvidence do
  @moduledoc false

  def outcome_label(outcomes) when map_size(outcomes) == 0, do: "Unknown — not recorded"

  def outcome_label(outcomes) do
    outcomes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("; ", fn {key, value} -> "#{field_label(key)}: #{value_label(value)}" end)
  end

  def classification_label(classification) do
    classification
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def field_label(key), do: key |> to_string() |> String.replace("_", " ")
  def value_label(value) when is_binary(value) or is_number(value), do: to_string(value)
  def value_label(value), do: Jason.encode!(value)
end
