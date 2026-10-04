defmodule SpaceTraders.RecordedShipFixtureOrderTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 180_000

  test "qualification teardown preserves global state and ownership in both neighboring suite orders" do
    {output, status} =
      System.cmd("mix", ["run", "test/diagnostics/recorded_ship_fixture_order.exs"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "both orders repeated twice; global and ownership probes passed"
    IO.puts(output)
  end
end
