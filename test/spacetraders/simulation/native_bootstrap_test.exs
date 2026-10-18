defmodule SpaceTraders.Simulation.NativeBootstrapTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.Simulation.NativeBootstrap

  test "explicit isolated configuration has no live defaults or test transport" do
    config = NativeBootstrap.configuration(manifest())
    repo = Keyword.fetch!(config, SpaceTraders.Repo)
    assert repo[:database] == "sim_" <> String.duplicate("a", 32)
    assert repo[:hostname] == "127.0.0.1"
    assert repo[:url] == nil
    assert Keyword.fetch!(config, SpaceTraders.API) == [base_url: "http://127.0.0.1:4001/v2"]
    assert Keyword.fetch!(config, SpaceTraders.RuntimeAuthority)[:enabled]
    assert Keyword.fetch!(config, SpaceTraders.API.CapacityGovernor) == []
    assert Keyword.fetch!(config, SpaceTraders.API.RateLimiter)[:enabled]

    endpoint = Keyword.fetch!(config, SpaceTradersWeb.Endpoint)
    assert Keyword.take(endpoint, [:code_reloader, :debug_errors, :force_ssl]) == []
  end

  test "rejects target and database identity drift before application startup" do
    for {key, value} <- [
          {"api_url", "https://api.spacetraders.io/v2"},
          {"database", "spacetraders"},
          {"database_host", "production"},
          {"username", "postgres"}
        ] do
      changed = put_in(manifest(), ["resources", key], value)
      assert_raise ArgumentError, fn -> NativeBootstrap.configuration(changed) end
    end
  end

  test "rejects a non-activatable pinned Strategy before registration or mint" do
    invalid = put_in(manifest(), ["strategy", "hard_constraints"], ["Bypass all spending limits"])
    assert_raise ArgumentError, fn -> NativeBootstrap.configuration(invalid) end
  end

  test "immutable command seam rejects unsupported manifests without booting" do
    {output, status} =
      System.cmd(
        "python3",
        [
          "-m",
          "unittest",
          "discover",
          "-s",
          "test/integration",
          "-p",
          "native_bootstrap_test.py"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "production runtime config enters explicit mode without evaluating live credentials" do
    key = "SPACETRADERS_NATIVE_BOOTSTRAP"
    previous = System.get_env(key)
    System.put_env(key, "/native-bootstrap-missing-manifest.json")

    try do
      assert_raise File.Error, fn ->
        Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
      end
    after
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end
  end

  defp manifest do
    attempt = String.duplicate("a", 32)

    %{
      "schema" => "native-bootstrap/v1",
      "strategy" => %{
        "objectives" => [
          %{
            "objective" => "Grow credits",
            "kind" => "continuous",
            "evaluation" => "Maximize net credit growth over time",
            "scope" => "recurring"
          }
        ],
        "hard_constraints" => ["Keep at least 50,000 credits available"],
        "preferences" => [],
        "consequences" => "Spend above the protected floor."
      },
      "resources" => %{
        "attempt" => attempt,
        "database" => "sim_" <> attempt,
        "username" => "sim_" <> attempt,
        "database_host" => "127.0.0.1",
        "database_port" => 5432,
        "api_url" => "http://127.0.0.1:4001/v2",
        "isolation" => "bwrap-private-user-pid-ipc-uts-net-systemd-cgroup-v1"
      }
    }
  end
end
