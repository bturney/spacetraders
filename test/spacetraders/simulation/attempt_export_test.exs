defmodule SpaceTraders.Simulation.AttemptExportTest do
  use ExUnit.Case, async: true

  test "portable attempt export and offline reader contracts without private fixtures or ports" do
    {output, status} =
      System.cmd(
        "python3",
        ["-m", "unittest", "discover", "-s", "test/integration", "-p", "attempt_export_test.py"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
