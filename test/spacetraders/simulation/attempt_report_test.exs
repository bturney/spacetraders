defmodule SpaceTraders.Simulation.AttemptReportTest do
  use ExUnit.Case, async: true

  test "offline per-attempt investigation without services or private fixtures" do
    {output, status} =
      System.cmd(
        "python3",
        ["-m", "unittest", "discover", "-s", "test/integration", "-p", "attempt_report_test.py"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
