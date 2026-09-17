defmodule Mix.Tasks.Verify.BoundaryTest do
  use ExUnit.Case, async: true

  test "the repository transport boundary passes" do
    assert Mix.Tasks.Verify.Boundary.run([]) == :ok
  end

  test "rejects a transport call outside the approved adapters" do
    path = Path.join(System.tmp_dir!(), "boundary-#{System.unique_integer()}.ex")
    File.write!(path, "defmodule Bypass do\n  Req.get(\"/game\")\nend\n")

    on_exit(fn -> File.rm(path) end)

    assert [violation] = Mix.Tasks.Verify.Boundary.verify_paths([path])
    assert violation =~ "Req.get"
  end

  test "rejects aliased and nested transport modules" do
    path = Path.join(System.tmp_dir!(), "boundary-alias-#{System.unique_integer()}.ex")

    File.write!(
      path,
      "defmodule Bypass do\n  alias Req, as: HTTP\n  HTTP.get(\"/game\")\n  Req.Request.new([])\nend\n"
    )

    on_exit(fn -> File.rm(path) end)

    violations = Mix.Tasks.Verify.Boundary.verify_paths([path])
    assert Enum.any?(violations, &String.contains?(&1, "Req.get"))
    assert Enum.any?(violations, &String.contains?(&1, "Req.Request.new"))
  end
end
