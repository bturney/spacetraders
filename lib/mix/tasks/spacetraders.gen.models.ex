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
  @spec_path "priv/spec/SpaceTraders.json"
  @model_target {"lib/spacetraders/api/models", "SpaceTraders.API.Model"}
  @request_target {"lib/spacetraders/api/request", "SpaceTraders.API.Request"}
  @request_operations [
    {:post, "/register", "RegisterRequest"},
    {:post, "/my/contracts/{contractId}/deliver", "DeliverContractRequest"},
    {:post, "/my/ships/{shipSymbol}/navigate", "NavigateRequest"},
    {:patch, "/my/ships/{shipSymbol}/nav", "ShipNavRequest"},
    {:post, "/my/ships/{shipSymbol}/sell", "SellCargoRequest"},
    {:post, "/my/ships/{shipSymbol}/purchase", "PurchaseCargoRequest"},
    {:post, "/my/ships/{shipSymbol}/jettison", "JettisonCargoRequest"},
    {:post, "/my/ships/{shipSymbol}/transfer", "TransferCargoRequest"},
    {:post, "/my/ships", "PurchaseShipRequest"},
    {:post, "/systems/{systemSymbol}/waypoints/{waypointSymbol}/construction/supply",
     "SupplyConstructionRequest"},
    {:post, "/my/ships/{shipSymbol}/modules/install", "InstallShipModuleRequest"},
    {:post, "/my/ships/{shipSymbol}/modules/remove", "RemoveShipModuleRequest"}
  ]

  @impl true
  def run(args) do
    if "--check" in args do
      check_no_drift()
    else
      regenerate()
    end
  end

  # Re-write generated response models and request payloads from the bundled spec.
  defp regenerate do
    for {target, sources} <- generated_targets() do
      {out_dir, _namespace} = target
      out_dir = Path.expand(out_dir)
      File.mkdir_p!(out_dir)
      File.rm(list_files(out_dir))

      for {name, source} <- sources do
        File.write!(Path.join(out_dir, name), source)
      end
    end

    Mix.shell().info("Generated #{generated_count()} structs from the bundled spec")
  end

  # Fail if the committed structs are stale relative to the bundled spec.
  defp check_no_drift do
    for {target, generated} <- generated_targets() do
      {out_dir, _namespace} = target

      committed =
        list_files(Path.expand(out_dir))
        |> Map.new(fn path -> {Path.basename(path), File.read!(path)} end)

      check_target_no_drift(out_dir, generated, committed)
    end

    Mix.shell().info("Structs are up to date with the bundled spec (#{generated_count()} files)")
  end

  @doc false
  @spec generate_sources() :: %{String.t() => String.t()}
  def generate_sources do
    models = load_models() |> expand_inline_models()

    Map.new(models, fn {name, model} ->
      source =
        generate_model(model, name, models, model_namespace())
        |> Code.format_string!()
        |> IO.iodata_to_binary()
        |> ensure_trailing_newline()

      {Macro.underscore(name) <> ".ex", source}
    end)
  end

  @doc false
  @spec generate_request_sources() :: %{String.t() => String.t()}
  def generate_request_sources do
    models = load_models()

    @request_operations
    |> Map.new(fn {method, path, name} ->
      schema = request_schema(path, method)

      source =
        generate_request(schema, name, models, request_namespace())
        |> Code.format_string!()
        |> IO.iodata_to_binary()
        |> ensure_trailing_newline()

      {Macro.underscore(name) <> ".ex", source}
    end)
  end

  defp generated_targets do
    %{
      @model_target => generate_sources(),
      @request_target => generate_request_sources()
    }
  end

  defp generated_count do
    generated_targets() |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum()
  end

  defp check_target_no_drift(out_dir, generated, committed) do
    extra = Map.keys(committed) -- Map.keys(generated)

    if extra != [] do
      Mix.raise(
        "Stale generated files in #{out_dir}: #{Enum.join(extra, ", ")}. " <>
          "Run `mix space_traders.gen.models`."
      )
    end

    for {name, source} <- generated do
      if committed[name] != source do
        Mix.raise("#{Path.join(out_dir, name)} is stale — run `mix space_traders.gen.models`.")
      end
    end
  end

  defp model_namespace, do: elem(@model_target, 1)
  defp request_namespace, do: elem(@request_target, 1)

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

  defp generate_model(%{"type" => "object"} = model, name, models, namespace) do
    fields = model["properties"] || %{}
    required = MapSet.new(model["required"] || [])

    struct_fields =
      Enum.map(fields, fn {field, _} ->
        atom = field |> Macro.underscore() |> String.to_atom()
        "    #{inspect(atom)}"
      end)

    type_fields =
      Enum.map(fields, fn {field, prop} ->
        "    #{Macro.underscore(field)}: #{field_type(prop, name, field, models, required, namespace)}"
      end)

    decode_fields =
      Enum.map(fields, fn {field, prop} ->
        "    #{Macro.underscore(field)}: #{decode_expr(prop, name, field, models, namespace)}"
      end)

    moduledoc = (model["description"] || "") |> String.trim() |> inspect()

    """
    defmodule #{namespace}.#{name} do
      @moduledoc #{moduledoc}

      defstruct [
    #{Enum.join(struct_fields, ",\n")}
      ]

      @type t :: %__MODULE__{
    #{Enum.join(type_fields, ",\n")}
      }

      @doc "Decodes an API payload map into `#{namespace}.#{name}`."
      @spec from_json(map()) :: t()
      def from_json(json) when is_map(json) do
        %__MODULE__{
    #{Enum.join(decode_fields, ",\n")}
        }
      end
    end
    """
  end

  defp generate_model(%{"enum" => enums} = model, name, _models, namespace) do
    """
    defmodule #{namespace}.#{name} do
      @moduledoc #{(model["description"] || "") |> String.trim() |> inspect()}

      @type t :: String.t()
      @enums #{inspect(enums, limit: :infinity, printable_limit: :infinity)}

      @doc "All valid values."
      @spec values() :: [t()]
      def values, do: @enums
    end
    """
  end

  defp generate_model(model, name, _models, namespace) do
    """
    defmodule #{namespace}.#{name} do
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
  defp field_type(prop, parent, field, models, required, namespace) do
    optional = if MapSet.member?(required, field), do: "", else: " | nil"
    base = field_type_base(prop, parent, field, models, namespace)
    base <> optional
  end

  defp field_type_base(%{"type" => "array", "items" => items}, parent, field, models, namespace) do
    "[#{field_type_base(items, parent, field, models, namespace)}]"
  end

  defp field_type_base(%{"$ref" => ref}, _parent, _field, models, _namespace) do
    ref_type(ref, models)
  end

  defp field_type_base(%{"type" => "object"}, parent, field, _models, namespace) do
    "#{namespace}.#{parent}#{Macro.camelize(field)}.t()"
  end

  defp field_type_base(%{"type" => "string"}, _parent, _field, _models, _namespace),
    do: "String.t()"

  defp field_type_base(%{"type" => "integer"}, _parent, _field, _models, _namespace),
    do: "integer()"

  defp field_type_base(%{"type" => "number"}, _parent, _field, _models, _namespace), do: "float()"

  defp field_type_base(%{"type" => "boolean"}, _parent, _field, _models, _namespace),
    do: "boolean()"

  defp ref_type(ref, models) do
    name = ref_name(ref)

    case Map.fetch(models, name) do
      {:ok, %{"type" => "object"}} -> "#{model_namespace()}.#{name}.t()"
      {:ok, %{"enum" => _}} -> "String.t()"
      {:ok, model} -> primitive_type(model["type"])
      :error -> "term()"
    end
  end

  defp ref_name(ref), do: ref |> Path.basename(".json") |> String.trim_trailing(".json")

  # Decode expressions reference the exact struct module, including synthetic ones.
  defp decode_expr(
         %{"type" => "array", "items" => %{"$ref" => ref}},
         _parent,
         field,
         models,
         namespace
       ) do
    target = ref_name(ref)

    if match?({:ok, %{"type" => "object"}}, Map.fetch(models, target)) do
      "Enum.map(json[#{inspect(field)}] || [], &#{namespace}.#{target}.from_json/1)"
    else
      "json[#{inspect(field)}] || []"
    end
  end

  defp decode_expr(%{"type" => "array", "items" => items}, parent, field, _models, namespace) do
    if inline_object?(items) do
      mod = "#{namespace}.#{parent}#{Macro.camelize(field)}"
      "Enum.map(json[#{inspect(field)}] || [], &#{mod}.from_json/1)"
    else
      "json[#{inspect(field)}] || []"
    end
  end

  defp decode_expr(%{"$ref" => ref}, _parent, field, models, namespace) do
    target = ref_name(ref)

    if match?({:ok, %{"type" => "object"}}, Map.fetch(models, target)) do
      "json[#{inspect(field)}] && #{namespace}.#{target}.from_json(json[#{inspect(field)}])"
    else
      "json[#{inspect(field)}]"
    end
  end

  defp decode_expr(%{"type" => "object"}, parent, field, _models, namespace) do
    mod = "#{namespace}.#{parent}#{Macro.camelize(field)}"
    "json[#{inspect(field)}] && #{mod}.from_json(json[#{inspect(field)}])"
  end

  defp decode_expr(_prop, _parent, field, _models, _namespace) do
    "json[#{inspect(field)}]"
  end

  defp request_schema(path, method) do
    @spec_path
    |> File.read!()
    |> Jason.decode!()
    |> get_in([
      "paths",
      path,
      to_string(method),
      "requestBody",
      "content",
      "application/json",
      "schema"
    ])
  end

  defp generate_request(schema, name, models, namespace) do
    fields = schema["properties"] |> Enum.sort_by(&elem(&1, 0))
    required = MapSet.new(schema["required"] || [])

    struct_fields =
      Enum.map(fields, fn {field, _} ->
        "    #{field |> Macro.underscore() |> String.to_atom() |> inspect()}"
      end)

    type_fields =
      Enum.map(fields, fn {field, prop} ->
        "    #{Macro.underscore(field)}: #{field_type(prop, name, field, models, required, namespace)}"
      end)

    required_checks =
      for {field, _} <- fields, MapSet.member?(required, field) do
        atom = Macro.underscore(field)

        "    if is_nil(request.#{atom}), do: raise(ArgumentError, \"required field #{field} is nil\")"
      end

    json_fields =
      Enum.map(fields, fn {field, _} ->
        atom = Macro.underscore(field)

        if MapSet.member?(required, field) do
          "Map.put(#{inspect(field)}, request.#{atom})"
        else
          "then(fn json -> if is_nil(request.#{atom}), do: json, else: Map.put(json, #{inspect(field)}, request.#{atom}) end)"
        end
      end)

    """
    defmodule #{namespace}.#{name} do
      @moduledoc #{(schema["description"] || "") |> String.trim() |> inspect()}

      defstruct [
    #{Enum.join(struct_fields, ",\n")}
      ]

      @type t :: %__MODULE__{
    #{Enum.join(type_fields, ",\n")}
      }

      @spec new(map()) :: t()
      def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

      @spec to_json(t()) :: map()
      def to_json(%__MODULE__{} = request) do
    #{Enum.join(required_checks, "\n")}

        %{}
        |> #{Enum.join(json_fields, "\n        |>")}
      end
    end
    """
  end
end
