defmodule SpaceTraders.FleetAllocation.JsonEvidence do
  @moduledoc """
  Serializes allocation decision evidence into the JSON-safe shape the
  Strategy Decision Episode columns store.

  Datetimes become ISO8601 strings and structs become plain string-keyed maps,
  so persisted evidence survives a reader that has no compiled struct for it.
  """

  @doc "Returns `value` as JSON-safe data: ISO8601 datetimes and plain maps."
  @spec dump(term()) :: term()
  def dump(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  def dump(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> dump()
  end

  def dump(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), dump(value)} end)
  end

  def dump(list) when is_list(list), do: Enum.map(list, &dump/1)
  def dump(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> dump()
  def dump(nil), do: nil
  def dump(atom) when is_atom(atom), do: Atom.to_string(atom)
  def dump(value), do: value
end
