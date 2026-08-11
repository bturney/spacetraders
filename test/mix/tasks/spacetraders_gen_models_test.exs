defmodule Mix.Tasks.SpaceTraders.Gen.ModelsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.SpaceTraders.Gen.Models

  @out_dir "lib/spacetraders/api/models"
  @request_out_dir "lib/spacetraders/api/request"

  test "generated structs match committed output (regenerable, no drift)" do
    generated = Models.generate_sources() |> Map.new()

    committed =
      Map.new(list_ex_files(@out_dir), fn path -> {Path.basename(path), File.read!(path)} end)

    assert Map.keys(generated) == Map.keys(committed)

    for {name, source} <- generated do
      assert committed[name] == source,
             "generated #{name} differs from committed output — run `mix space_traders.gen.models`"
    end
  end

  test "generated request structs match committed output (regenerable, no drift)" do
    generated = Models.generate_request_sources()

    committed =
      Map.new(list_ex_files(@request_out_dir), fn path ->
        {Path.basename(path), File.read!(path)}
      end)

    assert Map.keys(generated) == Map.keys(committed)

    for {name, source} <- generated do
      assert committed[name] == source,
             "generated #{name} differs from committed output — run `mix space_traders.gen.models`"
    end
  end

  defp list_ex_files(dir) do
    dir
    |> Path.join("*.ex")
    |> Path.wildcard()
  end
end
