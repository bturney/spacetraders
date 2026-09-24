defmodule Mix.Tasks.Verify.Boundary do
  @shortdoc "Verifies the gameplay API boundary"

  @moduledoc """
  Verifies that gameplay traffic has one private transport boundary.

  Contexts may use the public operation adapters in `SpaceTraders.API` and
  governed evidence adapters in `SpaceTraders.Evidence`; only the API module
  may construct or dispatch an HTTP request. This check is intentionally
  source-based so a new transport call fails before it can reach production.
  """

  use Mix.Task

  @transport_modules ["Req", "Finch", "HTTPoison", "Hackney"]
  @transport_functions ~w(new request post get patch put delete)a
  @approved_transport_files ["lib/spacetraders/api.ex", "lib/mix/tasks/verify.boot.ex"]

  @impl true
  def run(_args) do
    violations = verify_paths(Path.wildcard("lib/**/*.ex"))

    if violations == [] do
      Mix.shell().info("Gameplay API boundary is intact")
    else
      Mix.raise("Gameplay transport bypass detected:\n" <> Enum.join(violations, "\n"))
    end
  end

  @doc false
  def verify_paths(paths) do
    paths
    |> Enum.reject(&(&1 in @approved_transport_files))
    |> Enum.flat_map(&violations/1)
  end

  defp violations(path) do
    ast = source_ast(path)
    transport_calls(ast, path) ++ legacy_calls(ast, path)
  end

  defp source_ast(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> strip_dead_code()
  rescue
    error in [SyntaxError] -> Mix.raise("Could not inspect #{path}: #{Exception.message(error)}")
  end

  defp strip_dead_code(ast) do
    Macro.prewalk(ast, fn
      {:if, meta, [{:__block__, _, [false]}, _then]} -> {:__block__, meta, []}
      {:if, meta, [false, _then]} -> {:__block__, meta, []}
      node -> node
    end)
  end

  defp transport_calls(ast, path), do: calls(ast, path)

  defp calls(ast, path) do
    {_ast, violations} =
      Macro.prewalk(ast, %{aliases: %{}, violations: []}, fn
        {:alias, _, [{:__aliases__, _, module}, [as: {:__aliases__, _, [alias_name]}]]} = node,
        state ->
          aliases = Map.put(state.aliases, Atom.to_string(alias_name), module_name(module))
          {node, %{state | aliases: aliases}}

        {:alias, _, [{:__aliases__, _, module}]} = node, state ->
          alias_name = module |> List.last() |> Atom.to_string()
          aliases = Map.put(state.aliases, alias_name, module_name(module))
          {node, %{state | aliases: aliases}}

        {{:., _, [{:__aliases__, _, module}, function]}, meta, _args} = node, state
        when function in @transport_functions ->
          module_name = resolve_module(module, state.aliases)

          if transport_module?(module_name) do
            violation = "#{path}:#{meta[:line]} #{module_name}.#{function}/..."
            {node, %{state | violations: [violation | state.violations]}}
          else
            {node, state}
          end

        node, state ->
          {node, state}
      end)

    Enum.reverse(violations.violations)
  end

  defp legacy_calls(ast, path) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, parts} = node, violations when is_list(parts) ->
          name = parts |> List.last() |> to_string()

          if name in ["Job", "JobBlocker", "JobOwner", "JobPolicy", "LegacyGameplayHistory"] do
            {node, ["#{path}:#{meta[:line]} legacy Job reference #{name}" | violations]}
          else
            {node, violations}
          end

        {kind, meta, [head | _]} = node, violations when kind in [:def, :defp] ->
          name = function_name(head)

          if name && String.contains?(String.downcase(name), "job") do
            {node, ["#{path}:#{meta[:line]} legacy Job entry point #{name}" | violations]}
          else
            {node, violations}
          end

        atom, violations when is_atom(atom) ->
          if Atom.to_string(atom) in ["job", "job_id", "jobs", "legacy_gameplay_history"] do
            {atom, ["#{path}: legacy Job persistence reference #{atom}" | violations]}
          else
            {atom, violations}
          end

        node, violations ->
          {node, violations}
      end)

    Enum.reverse(violations)
  end

  defp function_name({name, _meta, _args}) when is_atom(name), do: Atom.to_string(name)
  defp function_name({:when, _meta, [head | _]}), do: function_name(head)
  defp function_name(_), do: nil

  defp module_name(module), do: Enum.map_join(module, ".", &Atom.to_string/1)

  defp resolve_module(module, aliases) do
    [first | rest] = module

    Map.get(aliases, Atom.to_string(first), Atom.to_string(first))
    |> then(fn prefix -> Enum.join([prefix | Enum.map(rest, &Atom.to_string/1)], ".") end)
  end

  defp transport_module?(module_name) do
    root = module_name |> String.split(".") |> hd()
    root in @transport_modules
  end
end
