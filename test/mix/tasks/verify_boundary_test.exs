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

  test "rejects legacy Job persistence and ownership references" do
    path = Path.join(System.tmp_dir!(), "boundary-job-#{System.unique_integer()}.ex")

    File.write!(
      path,
      "defmodule LegacyJob do\n  alias SpaceTraders.Fleet.{Intent, Job}\n  def run, do: Repo.get(Job, 1)\nend\n"
    )

    on_exit(fn -> File.rm(path) end)

    assert [violation | _] = Mix.Tasks.Verify.Boundary.verify_paths([path])
    assert violation =~ "legacy Job"
  end

  test "rejects legacy module declarations and string ownership" do
    path = Path.join(System.tmp_dir!(), "boundary-job-#{System.unique_integer()}.ex")

    File.write!(
      path,
      "defmodule Bypass do\n  defmodule Job do\n  end\n  def run, do: Repo.all(from i in Intent, where: i.caller == \"job\")\nend\n"
    )

    on_exit(fn -> File.rm(path) end)

    violations = Mix.Tasks.Verify.Boundary.verify_paths([path])

    assert Enum.any?(violations, &String.contains?(&1, "legacy Job"))
    assert Enum.any?(violations, &String.contains?(&1, "legacy Job string"))
  end

  test "does not exempt dead branches from the retirement boundary" do
    path = Path.join(System.tmp_dir!(), "boundary-dead-#{System.unique_integer()}.ex")

    File.write!(
      path,
      "defmodule Bypass do\n  if false do\n    alias SpaceTraders.Fleet.Job\n  end\nend\n"
    )

    on_exit(fn -> File.rm(path) end)

    assert [_violation | _] = Mix.Tasks.Verify.Boundary.verify_paths([path])
  end
end
