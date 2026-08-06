defmodule Mix.Tasks.SpaceTraders.Gen.Models do
  @shortdoc "Generate API model structs from the bundled OpenAPI spec"
  @moduledoc """
  Generates Elixir structs in `lib/spacetraders/api/models/` from the bundled
  SpaceTraders OpenAPI models in `priv/spec/models/*.json` (v2.3.0).

  Output is committed. Re-run after updating `priv/spec/models/`:

      mix space_traders.gen.models

  Structs are generated for every flat model (no allOf/oneOf needed). Inline
  objects become synthetic structs named `<Parent><Field>` (e.g. `ShipFuelConsumed`).
  Each struct exposes `from_json/1`, the single decode path the API client uses.
  """

  use Mix.Task

  @models_dir "priv/spec/models"
  @out_dir "lib/spacetraders/api/models"
  @ns "SpaceTraders.API.Model"

  @impl true
  def run(args) do
    if "--check" in args do
      check_no_drift()
    else
      regenerate()
    end
  end

  # Re-write lib/spacetraders/api/models/*.ex from priv/spec/models/*.json.
  defp regenerate do
    out_dir = Path.expand(@out_dir)
    File.mkdir_p!(out_dir)
    File.rm(list_files(out_dir))

    for {name, source} <- generate_sources() do
      File.write!(Path.join(out_dir, name), source)
    end

    Mix.shell().info("Generated #{map_size(generate_sources())} structs into #{@out_dir}")
  end

  # Fail if the committed structs are stale relative to the bundled spec.
  defp check_no_drift do
    generated = generate_sources()
    out_dir = Path.expand(@out_dir)

    committed =
      list_files(out_dir) |> Map.new(fn path -> {Path.basename(path), File.read!(path)} end)

    extra =
      Map.keys(committed)
      |> Kernel.--(Map.keys(generated))

    if extra != [] do
      Mix.raise(
        "Stale generated files not produced by the current spec: #{Enum.join(extra, ", ")}. " <>
          "Run `mix space_traders.gen.models`."
      )
    end

    for {name, source} <- generated do
      committed_source = Map.get(committed, name)

      if committed_source != source do
        Mix.raise("""
        #{name} is stale — the bundled spec changed. Run `mix space_traders.gen.models`.
        """)
      end
    end

    Mix.shell().info(
      "Structs are up to date with the bundled spec (#{map_size(generated)} files)"
    )
  end

  @doc false
  @spec generate_sources() :: %{String.t() => String.t()}
  def generate_sources do
    models = load_models() |> expand_inline_models()

    Map.new(models, fn {name, model} ->
      source =
        generate(model, name, models)
        |> Code.format_string!()
        |> IO.iodata_to_binary()
        |> ensure_trailing_newline()

      {Macro.underscore(name) <> ".ex", source}
    end)
  end

  defp ensure_trailing_newline(source) do
    if String.ends_with?(source, "\n"), do: source, else: source <> "\n"
  end

  defp load_models do
    @models_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Map.new(fn path ->
      name = path |> Path.basename(".json")
      {name, path |> File.read!() |> Jason.decode!()}
    end)
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.map(files, &Path.join(dir, &1))
      {:error, _} -> []
    end
  end

  # Register synthetic structs for inline objects so every nested value is typed.
  defp expand_inline_models(models) do
    Enum.reduce(models, models, fn {name, model}, acc ->
      Enum.reduce(model["properties"] || %{}, acc, fn {field, prop}, acc ->
        acc
        |> add_sub_model(acc, name, field, prop)
        |> add_sub_model(acc, name, field, prop["items"])
      end)
    end)
  end

  defp add_sub_model(acc, models, parent, field, prop) do
    if inline_object?(prop) do
      sub_name = parent <> Macro.camelize(field)

      if Map.has_key?(models, sub_name) do
        acc
      else
        Map.put(acc, sub_name, prop)
      end
    else
      acc
    end
  end

  defp inline_object?(prop) do
    is_map(prop) and prop["type"] == "object" and is_map(prop["properties"])
  end

  defp generate(%{"type" => "object"} = model, name, models) do
    fields = model["properties"] || %{}
    required = MapSet.new(model["required"] || [])

    struct_fields =
      Enum.map(fields, fn {field, _} ->
        atom = field |> Macro.underscore() |> String.to_atom()
        "    #{inspect(atom)}"
      end)

    type_fields =
      Enum.map(fields, fn {field, prop} ->
        "    #{Macro.underscore(field)}: #{field_type(prop, name, field, models, required)}"
      end)

    decode_fields =
      Enum.map(fields, fn {field, prop} ->
        "    #{Macro.underscore(field)}: #{decode_expr(prop, name, field, models)}"
      end)

    moduledoc = (model["description"] || "") |> String.trim() |> inspect()

    """
    defmodule #{@ns}.#{name} do
      @moduledoc #{moduledoc}

      defstruct [
    #{Enum.join(struct_fields, ",\n")}
      ]

      @type t :: %__MODULE__{
    #{Enum.join(type_fields, ",\n")}
      }

      @doc "Decodes an API payload map into `#{@ns}.#{name}`."
      @spec from_json(map()) :: t()
      def from_json(json) when is_map(json) do
        %__MODULE__{
    #{Enum.join(decode_fields, ",\n")}
        }
      end
    end
    """
  end

  defp generate(%{"enum" => enums} = model, name, _models) do
    """
    defmodule #{@ns}.#{name} do
      @moduledoc #{(model["description"] || "") |> String.trim() |> inspect()}

      @type t :: String.t()
      @enums #{inspect(enums, limit: :infinity, printable_limit: :infinity)}

      @doc "All valid values."
      @spec values() :: [t()]
      def values, do: @enums
    end
    """
  end

  defp generate(model, name, _models) do
    """
    defmodule #{@ns}.#{name} do
      @moduledoc #{(model["description"] || "") |> String.trim() |> inspect()}

      @type t :: #{primitive_type(model["type"])}
    end
    """
  end

  defp primitive_type("string"), do: "String.t()"
  defp primitive_type("integer"), do: "integer()"
  defp primitive_type("number"), do: "float()"
  defp primitive_type("boolean"), do: "boolean()"
  defp primitive_type(_), do: "term()"

  # Field type: optional fields get `| nil`, arrays of object refs become lists.
  defp field_type(prop, parent, field, models, required) do
    optional = if MapSet.member?(required, field), do: "", else: " | nil"
    base = field_type_base(prop, parent, field, models)
    base <> optional
  end

  defp field_type_base(%{"type" => "array", "items" => items}, parent, field, models) do
    "[#{field_type_base(items, parent, field, models)}]"
  end

  defp field_type_base(%{"$ref" => ref}, _parent, _field, models) do
    ref_type(ref, models)
  end

  defp field_type_base(%{"type" => "object"}, parent, field, _models) do
    "#{@ns}.#{parent}#{Macro.camelize(field)}.t()"
  end

  defp field_type_base(%{"type" => "string"}, _parent, _field, _models), do: "String.t()"
  defp field_type_base(%{"type" => "integer"}, _parent, _field, _models), do: "integer()"
  defp field_type_base(%{"type" => "number"}, _parent, _field, _models), do: "float()"
  defp field_type_base(%{"type" => "boolean"}, _parent, _field, _models), do: "boolean()"

  defp ref_type(ref, models) do
    name = ref_name(ref)

    case Map.fetch(models, name) do
      {:ok, %{"type" => "object"}} -> "#{@ns}.#{name}.t()"
      {:ok, %{"enum" => _}} -> "String.t()"
      {:ok, model} -> primitive_type(model["type"])
      :error -> "term()"
    end
  end

  defp ref_name(ref), do: ref |> Path.basename(".json") |> String.trim_trailing(".json")

  # Decode expressions reference the exact struct module, including synthetic ones.
  defp decode_expr(%{"type" => "array", "items" => %{"$ref" => ref}}, _parent, field, models) do
    target = ref_name(ref)

    if match?({:ok, %{"type" => "object"}}, Map.fetch(models, target)) do
      "Enum.map(json[#{inspect(field)}] || [], &#{@ns}.#{target}.from_json/1)"
    else
      "json[#{inspect(field)}] || []"
    end
  end

  defp decode_expr(%{"type" => "array", "items" => items}, parent, field, _models) do
    if inline_object?(items) do
      mod = "#{@ns}.#{parent}#{Macro.camelize(field)}"
      "Enum.map(json[#{inspect(field)}] || [], &#{mod}.from_json/1)"
    else
      "json[#{inspect(field)}] || []"
    end
  end

  defp decode_expr(%{"$ref" => ref}, _parent, field, models) do
    target = ref_name(ref)

    if match?({:ok, %{"type" => "object"}}, Map.fetch(models, target)) do
      "json[#{inspect(field)}] && #{@ns}.#{target}.from_json(json[#{inspect(field)}])"
    else
      "json[#{inspect(field)}]"
    end
  end

  defp decode_expr(%{"type" => "object"}, parent, field, _models) do
    mod = "#{@ns}.#{parent}#{Macro.camelize(field)}"
    "json[#{inspect(field)}] && #{mod}.from_json(json[#{inspect(field)}])"
  end

  defp decode_expr(_prop, _parent, field, _models) do
    "json[#{inspect(field)}]"
  end
end
