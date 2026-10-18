defmodule SpaceTraders.Simulation.NativeBootstrap do
  @moduledoc """
  Explicit native-time bootstrap boundary for the local, isolated HTTP diagnostic.

  It registers, mints and activates through normal application commands. It never
  chooses work, acquires intelligence for the planner, or drives reconciliation.
  This is not an experiment runner, clock coordinator or recovery protocol.
  """

  alias SpaceTraders.{FleetGeneration, FleetStrategy, Repo, RuntimeAuthority}
  alias SpaceTraders.Agent.Scope

  @test_capacity Application.compile_env(:spacetraders, :capacity_test_disabled_allowed, false)

  @doc "Configuration only; no connection, startup or fallback to deployment settings."
  def configuration(%{"schema" => "native-bootstrap/v1", "resources" => r} = manifest) do
    unless Map.get(manifest, "proof", "navigation") in ["navigation", "paid_transaction"] do
      raise ArgumentError, "native bootstrap: unsupported observation proof"
    end

    unless FleetStrategy.validate_activation_document(manifest["strategy"]) == :ok do
      raise ArgumentError, "native bootstrap: pinned Strategy cannot be activated"
    end

    attempt = r["attempt"]

    unless is_binary(attempt) and Regex.match?(~r/\A[0-9a-f]{32}\z/, attempt) and
             r["database"] == "sim_" <> attempt and r["username"] == "sim_" <> attempt and
             r["database_host"] == "127.0.0.1" and r["database_port"] == 5432 and
             r["api_url"] == "http://127.0.0.1:4001/v2" and
             r["isolation"] == "bwrap-private-user-pid-ipc-uts-net-systemd-cgroup-v1" do
      raise ArgumentError, "native bootstrap: isolated resource identities required"
    end

    [
      {:native_bootstrap, manifest},
      {Repo,
       [
         url: nil,
         hostname: "127.0.0.1",
         port: 5432,
         username: r["username"],
         database: r["database"],
         password: nil,
         pool_size: 5,
         log: false,
         show_sensitive_data_on_connection_error: false
       ]},
      {SpaceTraders.API, [base_url: r["api_url"]]},
      {RuntimeAuthority, [enabled: true]},
      {SpaceTraders.API.CapacityGovernor, []},
      {SpaceTraders.API.RateLimiter, [enabled: true]},
      {:fleet_reconciler_enabled, true},
      {:demand_scheduler_enabled, true},
      {:dns_cluster_query, nil},
      {SpaceTraders.Secret, [key: :crypto.strong_rand_bytes(32)]},
      {SpaceTradersWeb.Endpoint,
       [
         server: false,
         watchers: [],
         secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48))
       ]}
    ]
  end

  def configuration(_), do: raise(ArgumentError, "native bootstrap: invalid manifest")

  @doc false
  def read_configuration!(path) do
    bytes = File.read!(path)
    expected = System.fetch_env!("SPACETRADERS_NATIVE_MANIFEST_SHA256")

    unless hash(bytes) == expected do
      raise ArgumentError, "native bootstrap: changed manifest"
    end

    unless isolated_interfaces?() do
      raise ArgumentError, "native bootstrap: loopback-only namespace required before migration"
    end

    configuration(Jason.decode!(bytes))
  end

  @doc false
  def validate_runtime! do
    if manifest = Application.get_env(:spacetraders, :native_bootstrap) do
      if @test_capacity, do: raise(ArgumentError, "native bootstrap: test build rejected")
      configuration(manifest)
      resources = manifest["resources"]
      repo = Application.fetch_env!(:spacetraders, Repo)
      api = Application.fetch_env!(:spacetraders, SpaceTraders.API)

      unless isolated_interfaces?() and
               repo[:hostname] == resources["database_host"] and
               repo[:database] == resources["database"] and
               repo[:username] == resources["username"] and
               is_nil(repo[:url]) and is_nil(repo[:password]) and
               api == [base_url: resources["api_url"]] and RuntimeAuthority.enabled?() and
               Application.get_env(:spacetraders, SpaceTraders.API.RateLimiter)[:enabled] do
        raise ArgumentError, "native bootstrap: unsafe application configuration"
      end
    end

    :ok
  end

  @doc false
  def children do
    if Application.get_env(:spacetraders, :native_bootstrap) do
      [%{id: __MODULE__, start: {Task, :start_link, [&run/0]}, restart: :temporary}]
    else
      []
    end
  end

  defp run do
    manifest = Application.fetch_env!(:spacetraders, :native_bootstrap)

    deadline_unix_ms =
      System.fetch_env!("SPACETRADERS_NATIVE_STARTUP_DEADLINE_MS") |> String.to_integer()

    deadline =
      System.monotonic_time(:millisecond) + deadline_unix_ms - System.os_time(:millisecond)

    try do
      Process.put(:native_bootstrap_stage, "runtime_readiness")
      await_authority(deadline)
      # A fresh migrated database must contain neither identities nor intelligence.
      %{rows: [[0, 0, 0]]} =
        Repo.query!(
          "SELECT (SELECT count(*) FROM operators), (SELECT count(*) FROM agents), (SELECT count(*) FROM authoritative_observations)"
        )

      attempt = manifest["resources"]["attempt"]
      password = Base.encode64(:crypto.strong_rand_bytes(32))

      {:ok, operator} =
        SpaceTraders.Agent.register_operator(%{
          "email" => "native-#{attempt}@simulation.invalid",
          "password" => password,
          "password_confirmation" => password,
          "account_token" => "SIMULATION_ONLY_" <> attempt
        })

      scope = Scope.for_operator(operator)
      Process.put(:native_bootstrap_stage, "normal_mint")
      {:ok, _agent} = FleetGeneration.mint(scope, manifest["mint"])
      minted_at = DateTime.utc_now()
      projection = FleetStrategy.get(scope)
      Process.put(:native_bootstrap_stage, "immutable_strategy_activation")

      {:ok, draft} =
        FleetStrategy.save_draft(scope, manifest["strategy"], projection.draft_version)

      {:ok, revision} = FleetStrategy.activate(scope, draft.draft_version)
      true = revision.document == manifest["strategy"]
      startup_ready_unix_ms = System.os_time(:millisecond)
      if System.monotonic_time(:millisecond) >= deadline, do: raise("shared startup deadline")

      write_result(%{
        state: "observing",
        stage: "immutable_strategy_activated",
        minted_at: minted_at,
        startup_ready_unix_ms: startup_ready_unix_ms,
        strategy_revision_id: revision.id
      })

      # Observe only. No manual reconcile, fake work, policy or intelligence.
      proof_deadline =
        System.monotonic_time(:millisecond) + (manifest["limits"]["wall_seconds"] - 75) * 1_000

      Process.put(:native_bootstrap_stage, "durable_autonomous_bootstrap")
      proof = Map.get(manifest, "proof", "navigation")
      evidence = await_evidence(revision.id, proof, proof_deadline)

      write_result(%{
        state: "passed",
        stage: "durable_autonomous_bootstrap",
        minted_at: minted_at,
        startup_ready_unix_ms: startup_ready_unix_ms,
        observed_at: DateTime.utc_now(),
        strategy_revision_id: revision.id,
        evidence: evidence,
        proof: proof,
        net_earnings: "unknown",
        scope:
          "native-time bootstrap; not first-gate, recovery, mechanics or full-period qualification"
      })

      System.stop(0)
    rescue
      error ->
        # Do not serialize exception values: changesets can contain credentials.
        location =
          Enum.find_value(__STACKTRACE__, fn
            {__MODULE__, function, _args, info} ->
              %{function: function, line: info[:line]}

            _ ->
              nil
          end)

        write_result(%{
          state: "harness_failure",
          stage: Process.get(:native_bootstrap_stage),
          error: inspect(error.__struct__),
          location: location
        })

        System.stop(1)
    end
  end

  defp await_authority(deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise("shared startup deadline")

    case RuntimeAuthority.execution_allowed?() do
      :ok -> :ok
      _ -> wait(deadline, fn -> await_authority(deadline) end)
    end
  end

  defp await_evidence(revision_id, proof, deadline) do
    operations =
      case proof do
        "navigation" -> ["navigate-ship"]
        "paid_transaction" -> ["purchase-cargo", "sell-cargo", "refuel-ship"]
      end

    # Allowlisted durable causal chain. PostgreSQL is the evidence authority;
    # this projection neither authorizes work nor fills missing outcomes.
    %{columns: columns, rows: rows} =
      Repo.query!(
        """
        SELECT e.id AS episode_id, e.selection_kind, p.id AS portfolio_id,
               c.id AS commitment_id, i.id AS intent_id, i.type AS intent_type,
               i.target_waypoint, s.symbol AS ship_symbol,
               i.status AS intent_status, a.id::text AS mutation_attempt_id,
                a.operation_id, a.state AS mutation_state,
                a.prepared_evidence,
               (SELECT count(*) FROM authoritative_observations) AS observation_count
        FROM strategy_decision_episodes e
        JOIN fleet_commitment_portfolios p ON p.strategy_decision_episode_id = e.id
        JOIN fleet_commitments c ON c.fleet_commitment_portfolio_id = p.id
        JOIN intents i ON i.fleet_commitment_id = c.id
        JOIN ships s ON s.id = i.ship_id
        JOIN mutation_attempts a ON a.id = i.mutation_attempt_id
          OR ($3 AND a.provenance->>'intent_id' = i.id::text)
        WHERE e.fleet_strategy_revision_id = $1 AND e.selection_kind = 'selected_plan'
          AND a.state IN ('succeeded', 'accepted')
          AND a.operation_id = ANY($2)
        ORDER BY i.id LIMIT 1
        """,
        [revision_id, operations, proof == "paid_transaction"]
      )

    case rows do
      [row] -> Enum.zip(columns, row) |> Map.new()
      [] -> wait(deadline, fn -> await_evidence(revision_id, proof, deadline) end)
    end
  end

  defp wait(deadline, next) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise("bounded bootstrap deadline")
    Process.sleep(250)
    next.()
  end

  defp write_result(result) do
    File.write!("/out/bootstrap.json.new", Jason.encode!(result))
    File.rename!("/out/bootstrap.json.new", "/out/bootstrap.json")
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp isolated_interfaces? do
    File.read!("/proc/net/dev")
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ":"))
    |> Enum.map(&(&1 |> String.split(":") |> hd() |> String.trim()))
    |> Kernel.==(["lo"])
  end
end
