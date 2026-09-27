defmodule Mix.Tasks.SpaceTraders.Gen.OperationsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.SpaceTraders.Gen.Operations

  @spec_path "priv/spec/SpaceTraders.json"
  @inventory_path "lib/spacetraders/api/operation_inventory.ex"

  test "generated inventory matches the pinned contract" do
    assert Operations.generate_source(pinned_spec()) == File.read!(@inventory_path)
  end

  test "an added operation cannot pass without a deliberate classification" do
    spec =
      update_in(pinned_spec(), ["paths"], fn paths ->
        Map.put(paths, "/capability-proof", %{
          "get" => %{
            "operationId" => "capability-proof",
            "responses" => %{"200" => %{"description" => "proof"}}
          }
        })
      end)

    assert_raise Mix.Error, ~r/Unclassified: \["capability-proof"\]/, fn ->
      Operations.generate_source(spec)
    end
  end

  test "a removed operation cannot pass with stale classification" do
    spec = update_in(pinned_spec(), ["paths"], &Map.delete(&1, "/"))

    assert_raise Mix.Error, ~r/absent from spec: \["get-status"\]/, fn ->
      Operations.generate_source(spec)
    end
  end

  test "a changed operation cannot pass as the wrong operation class" do
    spec =
      update_in(pinned_spec(), ["paths", "/"], fn methods ->
        methods
        |> Map.put("post", Map.fetch!(methods, "get"))
        |> Map.delete("get")
      end)

    assert_raise Mix.Error, ~r/Pinned API read\/mutation drift/, fn ->
      Operations.generate_source(spec)
    end
  end

  test "a contract change makes the generated inventory stale" do
    spec =
      update_in(pinned_spec(), ["paths", "/", "get", "summary"], fn summary ->
        summary <> " changed"
      end)

    refute Operations.generate_source(spec) == File.read!(@inventory_path)
  end

  test "the verification check rejects added, removed, and changed contract operations" do
    for {name, mutate} <- contract_mutations() do
      spec_path =
        Path.join(System.tmp_dir!(), "operations-#{name}-#{System.unique_integer()}.json")

      target_path =
        Path.join(System.tmp_dir!(), "operations-#{name}-#{System.unique_integer()}.ex")

      File.write!(spec_path, Jason.encode!(mutate.(pinned_spec())))
      File.write!(target_path, File.read!(@inventory_path))

      on_exit(fn ->
        File.rm(spec_path)
        File.rm(target_path)
      end)

      assert_raise Mix.Error, fn ->
        Operations.run(["--check"], spec_path: spec_path, target_path: target_path)
      end
    end
  end

  test "the canonical verification alias checks the operation inventory" do
    assert "space_traders.gen.operations --check" in Mix.Project.config()[:aliases][:verify]
  end

  defp pinned_spec do
    @spec_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp contract_mutations do
    [
      added: fn spec ->
        update_in(spec, ["paths"], fn paths ->
          Map.put(paths, "/capability-proof", %{
            "get" => %{
              "operationId" => "capability-proof",
              "responses" => %{"200" => %{"description" => "proof"}}
            }
          })
        end)
      end,
      removed: &update_in(&1, ["paths"], fn paths -> Map.delete(paths, "/") end),
      changed_class: fn spec ->
        update_in(spec, ["paths", "/"], fn methods ->
          methods
          |> Map.put("post", Map.fetch!(methods, "get"))
          |> Map.delete("get")
        end)
      end,
      changed_contract: fn spec ->
        update_in(spec, ["paths", "/", "get", "summary"], &(&1 <> " changed"))
      end
    ]
  end
end
