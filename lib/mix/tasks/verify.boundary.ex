defmodule Mix.Tasks.Verify.Boundary do
  @shortdoc "Verifies the gameplay API boundary"

  @moduledoc """
  Verifies the gameplay transport and ADR 0010 retirement boundaries.

  Contexts may use the public operation adapters in `SpaceTraders.API` and
  governed evidence adapters in `SpaceTraders.Evidence`; only the API module
  may construct or dispatch an HTTP request. The source scan also rejects
  retired Job ownership, persistence, timer payloads, and entry points.
  """

  use Mix.Task

  @transport_modules ["Req", "Finch", "HTTPoison", "Hackney"]
  @transport_functions ~w(new request post get patch put delete)a
  @approved_transport_files ["lib/spacetraders/api.ex", "lib/mix/tasks/verify.boot.ex"]
  @boundary_file "lib/mix/tasks/verify.boundary.ex"
  @attempt_admission_files [
    "lib/spacetraders/api.ex",
    "lib/spacetraders/api/recorded_dispatch.ex",
    "lib/spacetraders/mutation_attempts.ex"
  ]
  @retired_ship_sends ~w(navigate_ship warp_ship jump_ship set_ship_flight_mode dock_ship orbit_ship extract_resources extract_resources_with_survey create_survey siphon_resources refine_ship scan_waypoints create_chart refuel_ship sell_cargo purchase_cargo jettison_cargo install_ship_module remove_ship_module transfer_cargo deliver_contract supply_construction reconcile_absent_and_retry)a

  @impl true
  def run(_args) do
    violations = verify_paths(Path.wildcard("lib/**/*.ex")) ++ operation_coverage_violations()

    if violations == [] do
      Mix.shell().info("Gameplay API boundary is intact")
    else
      Mix.raise("Gameplay transport bypass detected:\n" <> Enum.join(violations, "\n"))
    end
  end

  defp operation_coverage_violations do
    alias SpaceTraders.API.{OperationInventory, ShipAction}

    expected =
      OperationInventory.all()
      |> Enum.filter(&(&1.owner == :ship_execution))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    declared =
      ShipAction.implemented_operations() ++ Map.keys(ShipAction.unsupported_operations())

    if MapSet.new(declared) == expected and length(declared) == length(Enum.uniq(declared)),
      do: [],
      else: [
        "Ship operation coverage drift: classify every implemented/unsupported adapter in API.ShipAction (#505)"
      ]
  end

  @doc false
  def verify_paths(paths) do
    paths
    |> Enum.reject(&(&1 == @boundary_file))
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
  rescue
    error in [SyntaxError] -> Mix.raise("Could not inspect #{path}: #{Exception.message(error)}")
  end

  defp transport_calls(ast, path), do: calls(ast, path)

  defp calls(ast, path) do
    {_ast, violations} =
      Macro.prewalk(ast, %{aliases: %{}, violations: []}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, members}]} = node, state ->
          aliases =
            Enum.reduce(members, state.aliases, fn {:__aliases__, _, parts}, aliases ->
              Map.put(
                aliases,
                parts |> List.last() |> Atom.to_string(),
                module_name(base ++ parts)
              )
            end)

          {node, %{state | aliases: aliases}}

        {:alias, _, [{:__aliases__, _, module}, [as: {:__aliases__, _, [alias_name]}]]} = node,
        state ->
          aliases = Map.put(state.aliases, Atom.to_string(alias_name), module_name(module))
          {node, %{state | aliases: aliases}}

        {:alias, _, [{:__aliases__, _, module}]} = node, state ->
          alias_name = module |> List.last() |> Atom.to_string()
          aliases = Map.put(state.aliases, alias_name, module_name(module))
          {node, %{state | aliases: aliases}}

        {{:., _, [{:__aliases__, _, module}, function]}, meta, _args} = node, state
        when is_atom(function) ->
          module_name = resolve_module(module, state.aliases)

          if reason = call_violation(module_name, function, path) do
            violation = "#{path}:#{meta[:line]} #{module_name}.#{function}/... #{reason}"
            {node, %{state | violations: [violation | state.violations]}}
          else
            {node, state}
          end

        node, state ->
          {node, state}
      end)

    Enum.reverse(violations.violations)
  end

  defp call_violation(module, function, path) do
    cond do
      transport_module?(module) and function in @transport_functions and
          path not in @approved_transport_files ->
        "bypasses gameplay transport"

      module == "SpaceTraders.API" and function in @retired_ship_sends ->
        "retired unrecorded Ship send (ADR 0010; #505)"

      module == "SpaceTraders.Contracts" and function == :deliver_goods ->
        "Ship delivery must use recorded dispatch"

      module == "SpaceTraders.Fleet" and function == :supply_construction ->
        "Ship supply must use recorded dispatch"

      module == "SpaceTraders.MutationAttempts" and
          function in [:with_retry, :prepare_for_dispatch] ->
        "retired callback dispatch protocol"

      module == "SpaceTraders.MutationAttempts" and
        function in [:prepare, :prepare_retry, :mark_sent_or_unknown] and
          path not in @attempt_admission_files ->
        "caller-owned attempt admission; use RecordedDispatch"

      true ->
        nil
    end
  end

  defp legacy_calls(ast, path) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [name | _]} = node, violations when is_atom(name) ->
          if legacy_module_name?(Atom.to_string(name)) do
            {node, ["#{path}:#{meta[:line]} legacy Job module #{name}" | violations]}
          else
            {node, violations}
          end

        {:__aliases__, meta, parts} = node, violations when is_list(parts) ->
          name = parts |> List.last() |> to_string()

          if legacy_module_name?(name) do
            {node, ["#{path}:#{meta[:line]} legacy Job reference #{name}" | violations]}
          else
            {node, violations}
          end

        {kind, meta, [head | _]} = node, violations when kind in [:def, :defp] ->
          name = function_name(head)

          cond do
            name && legacy_entry_point?(name) ->
              {node, ["#{path}:#{meta[:line]} legacy Job entry point #{name}" | violations]}

            name in ~w(claim_intent_action dispatch_claimed_action with_retry prepare_for_dispatch) or
                (path == "lib/spacetraders/api.ex" and
                   name in Enum.map(@retired_ship_sends, &Atom.to_string/1)) ->
              {node,
               ["#{path}:#{meta[:line]} retired Ship dispatch protocol #{name}" | violations]}

            true ->
              {node, violations}
          end

        atom, violations when is_atom(atom) ->
          if Atom.to_string(atom) in ["job", "job_id", "jobs", "legacy_gameplay_history"] do
            {atom, ["#{path}: legacy Job persistence reference #{atom}" | violations]}
          else
            {atom, violations}
          end

        string, violations when is_binary(string) ->
          if legacy_string?(string) do
            {string, ["#{path}: legacy Job string reference #{inspect(string)}" | violations]}
          else
            {string, violations}
          end

        node, violations ->
          {node, violations}
      end)

    Enum.reverse(violations)
  end

  defp legacy_module_name?(name) do
    name in ["Job", "JobBlocker", "JobOwner", "JobPolicy", "LegacyGameplayHistory"] or
      String.ends_with?(name, ".Job")
  end

  defp legacy_entry_point?(name) do
    lower_name = String.downcase(name)

    String.contains?(lower_name, "job") or
      lower_name in ["request_for_agent", "request_manual_intent", "request_delivery"]
  end

  defp legacy_string?(value) do
    lower_value = String.downcase(value)

    String.contains?(lower_value, "job") or
      String.contains?(lower_value, "legacy_gameplay_history")
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
