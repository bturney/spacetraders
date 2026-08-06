# scripts/generate_types.exs
# One-shot codegen: emits an Elixir defstruct module per SpaceTraders JSON Schema model.
# The models are all plain `type: object` schemas — no allOf/oneOf/anyOf — so this
# is a pure walk of properties. Regenerate when the spec updates; commit the output.
#
# Run:  elixir scripts/generate_types.exs <models_dir> <output_dir>

defmodule GenerateTypes do
  def run(models_dir, output_dir) do
    models_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      model = path |> File.read!() |> Jason.decode!()
      mod_name = path |> Path.basename(".json") |> Macro.camelize()
      props = Map.get(model, "properties", %{})
      File.mkdir_p!(output_dir)
      File.write!(Path.join(output_dir, "#{mod_name}.ex"), emit(mod_name, props))
    end)

    IO.puts("wrote #{length(Path.wildcard(Path.join(models_dir, "*.json")))} modules to #{output_dir}")
  end

  defp emit(mod_name, props) do
    fields = for {k, spec} <- props, do: {to_atom(k), type(spec)}
    docs = for {k, spec} <- props, do: {to_atom(k), Map.get(spec, "description", "")}

    typespec = for {k, t} <- fields, into: [], do: ["    #{k}: #{t}"]
    defstruct = Enum.map_join(fields, "\n    ", fn {k, _} -> ":#{k}" end)

    """
    defmodule SpaceTraders.Api.Types.#{mod_name} do
      @moduledoc "Generated from #{mod_name}.json — do not edit."

      @type t :: %__MODULE__{
    #{Enum.join(typespec, ",\n")}
      }

      defstruct [
    #{defstruct}
      ]
    end
    """
  end

  defp type(%{"$ref" => ref}) do
    mod = ref |> Path.basename(".json") |> Macro.camelize()
    "SpaceTraders.Api.Types.#{mod}.t() | nil"
  end

  defp type(%{"type" => "array"} = spec) do
    inner =
      case spec["items"] do
        %{"$ref" => ref} ->
          mod = ref |> Path.basename(".json") |> Macro.camelize()
          "SpaceTraders.Api.Types.#{mod}.t()"
        %{"type" => t} -> prim(t)
      end
    "[#{inner}] | nil"
  end

  defp type(%{"type" => t}), do: prim(t)
  defp type(_), do: "term()"

  defp prim("string"), do: "String.t()"
  defp prim("integer"), do: "integer()"
  defp prim("number"), do: "float()"
  defp prim("boolean"), do: "boolean()"
  defp prim(_), do: "term()"

  defp to_atom(k), do: k |> Macro.underscore() |> String.to_atom()
end

GenerateTypes.run(List.first(System.argv()), List.last(System.argv()))
