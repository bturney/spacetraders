defmodule Mix.Tasks.Verify.BootTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  test "boots and serves /health while the configured PORT is held by another listener" do
    {:ok, holder} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, held_port} = :inet.port(holder)

    try do
      {output, status} =
        System.cmd("mix", ["verify.boot"],
          env: [{"MIX_ENV", "test"}, {"PORT", Integer.to_string(held_port)}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "boot verify: GET http://127.0.0.1:"
      refute output =~ ":#{held_port}/health"
    after
      :gen_tcp.close(holder)
    end
  end
end
