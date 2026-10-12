defmodule SpaceTraders.CurrentFleetMigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :spacetraders, adapter: Ecto.Adapters.Postgres
  end

  @version 20_261_011_100_000
  @previous 20_261_010_200_000
  @migrations Path.expand("../../priv/repo/migrations", __DIR__)

  setup do
    base =
      SpaceTraders.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :socket_dir, :ssl])

    database =
      "fleet_identity_migration_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    admin_config = Keyword.put(base, :database, "postgres")
    {:ok, admin} = Postgrex.start_link(admin_config)
    Postgrex.query!(admin, "CREATE DATABASE #{database}", [])

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(admin_config)
      Postgrex.query!(cleanup, "DROP DATABASE #{database} WITH (FORCE)", [])
      GenServer.stop(cleanup)
    end)

    start_supervised!(
      {MigrationRepo,
       base ++ [database: database, pool: DBConnection.ConnectionPool, pool_size: 2, log: false]}
    )

    run_migrations(to: @previous)
    %{database: database}
  end

  test "an actual empty database migration is restart and rerun safe" do
    assert [@version] = migrate()
    assert identity() == [[nil, nil]]
    assert [] = migrate()
    assert identity() == [[nil, nil]]
    assert scalar("SELECT count(*) FROM operators") == 0
    assert scalar("SELECT count(*) FROM fleet_generations") == 0
  end

  test "adoption preserves encrypted credentials, accepted Strategy, resources and causal history" do
    owner = owner()
    agent = agent(owner)
    [_, strategy, revision] = strategy(owner)
    now = DateTime.utc_now(:second)
    old_generation = generation(owner, nil, 1, now)
    current_generation = generation(owner, agent, 2, nil, revision)

    query(
      "INSERT INTO strategy_decision_episodes (operator_id, fleet_generation_id, fleet_strategy_revision_id, source_version, calibration_version, expectations, inserted_at, updated_at) VALUES ($1, $2, $3, 1, 'retained', '{\"credit_change\": 100}', $4, $4)",
      [owner, old_generation, revision, now]
    )

    query(
      "INSERT INTO mutation_attempts (id, operator_id, agent_id, fleet_generation_id, strategy_revision_id, operation_id, operation_owner, state, request_fingerprint, provenance, prepared_at, inserted_at, updated_at) VALUES ('7299492a-f749-4d32-8bdf-e53d7a21d87a', $1, $2, $3, $4, 'purchase-cargo', 'ship_execution', 'ambiguous', 'retained-fingerprint', '{\"causal_origin\": \"retained\"}', $5, $5, $5)",
      [owner, agent, old_generation, revision, now]
    )

    query(
      "INSERT INTO ships (symbol, ship_type, agent_id, inserted_at, updated_at) VALUES ('ORBITALIST-1', 'SHIP_COMMAND_FRIGATE', $1, $2, $2)",
      [agent, now]
    )

    query(
      "INSERT INTO fleet_activity (agent_id, kind, message, inserted_at, updated_at) VALUES ($1, 'trade', 'Retained causal activity', $2, $2)",
      [agent, now]
    )

    before = retained()

    assert [@version] = migrate()
    assert identity() == [[owner, current_generation]]
    assert retained() == before

    assert MigrationRepo.get!(SpaceTraders.Agent.Operator, owner).account_token ==
             "ACCOUNT_SECRET"

    assert MigrationRepo.get!(SpaceTraders.Agent.Agent, agent).agent_token == "AGENT_SECRET"

    assert scalar("SELECT active_revision_id FROM fleet_strategies WHERE id = #{strategy}") ==
             revision

    assert scalar(
             "SELECT count(*) FROM fleet_generations WHERE id = #{old_generation} AND retired_at IS NOT NULL"
           ) == 1

    assert [] = migrate()
    assert retained() == before
  end

  test "a sole imported Agent with historical Generations receives a new distinct identity without bootstrap guesses" do
    owner = owner()
    agent = agent(owner)
    generation(owner, nil, 1, DateTime.utc_now(:second))
    before = query("SELECT agent_token_ciphertext FROM agents").rows
    assert [@version] = migrate()
    assert [[^owner, generation_id]] = identity()

    assert [[^agent, 2, "ORBITALIST", nil, nil]] =
             query(
               "SELECT agent_id, number, symbol, starting_credits, strategy_capable_at FROM fleet_generations WHERE id = $1",
               [generation_id]
             ).rows

    assert query("SELECT agent_token_ciphertext FROM agents").rows == before
  end

  test "a stale unretired Generation is adopted as fenced history in transition, not discarded" do
    owner = owner()
    agent = agent(owner)
    now = DateTime.utc_now(:second)
    query("UPDATE agents SET stale_at = $1 WHERE id = $2", [now, agent])
    assert [@version] = migrate()
    assert [[^owner, generation_id]] = identity()

    assert [[fenced_at, nil]] =
             query("SELECT fenced_at, retired_at FROM fleet_generations WHERE id = $1", [
               generation_id
             ]).rows

    assert NaiveDateTime.compare(fenced_at, DateTime.to_naive(now)) == :eq
  end

  test "multiple plausible Operators fail before schema expansion and preserve all records" do
    first = owner()
    agent(first)
    owner("second@example.com")
    assert_preflight_failure("multiple plausible Operators")
  end

  test "multiple plausible current Agents fail without newest-record selection" do
    owner = owner()
    agent(owner)
    agent(owner, "PARALLAX")
    assert_preflight_failure("multiple plausible current Agents")
  end

  test "unowned Agent and unfinished Generation without an Agent fail with an ownership explanation" do
    agent(nil)
    assert_preflight_failure("ambiguous Agent, Generation or Strategy ownership")
  end

  test "an unfinished Generation without its Agent is not legitimate retired history" do
    owner = owner()
    generation(owner, nil, 1, nil)
    assert_preflight_failure("ambiguous Agent, Generation or Strategy ownership")
  end

  test "a fully migrated but newly ambiguous installation cannot start the actual autonomous supervisor",
       %{database: database} do
    migrate()
    owner()
    owner("second@example.com")

    url =
      URI.parse(SpaceTraders.CheckoutDb.url(:test))
      |> Map.put(:path, "/#{database}")
      |> URI.to_string()

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "test/integration/current_fleet_boot_probe.exs"],
        env: [{"DATABASE_URL", url}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 1, output
    assert output =~ "boot rejected:"
    assert output =~ "multiple plausible Operators"
    refute output =~ "boot succeeded"
    assert identity() == [[nil, nil]]
    assert scalar("SELECT count(*) FROM operators") == 2
  end

  test "adopted credentials and pre-migration sessions authenticate after actual fresh application boots",
       %{database: database} do
    operator =
      %SpaceTraders.Agent.Operator{}
      |> SpaceTraders.Agent.Operator.registration_changeset(
        %{
          email: "adopted@example.com",
          password: "adopted durable password",
          account_token: "ADOPTED_ACCOUNT_SECRET"
        },
        validate_unique: false
      )
      |> MigrationRepo.insert!(log: false)

    {session, token_record} = SpaceTraders.Agent.OperatorToken.build_session_token(operator)
    MigrationRepo.insert!(token_record, log: false)
    agent = agent(operator.id)
    generation(operator.id, nil, 1, DateTime.utc_now(:second))
    current_generation = generation(operator.id, agent, 2, nil)
    before = retained()
    assert [@version] = migrate()
    assert identity() == [[operator.id, current_generation]]
    assert retained() == before

    # The booted app needs every later migration, not only the adoption one.
    run_migrations(all: true)
    assert retained() == before

    url =
      URI.parse(SpaceTraders.CheckoutDb.url(:test))
      |> Map.put(:path, "/#{database}")
      |> URI.to_string()

    for _ <- 1..2 do
      {output, status} =
        System.cmd("mix", ["run", "--no-start", "test/integration/sole_operator_auth_probe.exs"],
          env: [
            {"DATABASE_URL", url},
            {"MIX_ENV", "test"},
            {"ADOPTED_SESSION_TOKEN", Base.encode64(session)}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "adopted authentication passed"
      refute output =~ "ADOPTED_ACCOUNT_SECRET"
      refute output =~ "AGENT_SECRET"
      refute output =~ "adopted durable password"
      assert retained() == before
      assert identity() == [[operator.id, current_generation]]
    end
  end

  defp assert_preflight_failure(message) do
    before = retained()
    error = assert_raise Postgrex.Error, fn -> migrate() end
    assert error.postgres.message =~ message
    assert error.postgres.hint =~ "explicitly"

    assert scalar(
             "SELECT count(*) FROM information_schema.tables WHERE table_name = 'current_fleet_identity'"
           ) == 0

    assert scalar("SELECT count(*) FROM schema_migrations WHERE version = #{@version}") == 0
    assert retained() == before
    # Failed migration rolls back its function as well; retry still preflights.
    assert_raise Postgrex.Error, fn -> migrate() end
    assert retained() == before
  end

  defp migrate, do: run_migrations(to: @version)

  defp run_migrations(opts) do
    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        Ecto.Migrator.run(MigrationRepo, @migrations, :up, Keyword.put(opts, :log, false))
      end)

    # Ecto reloads actual migration modules for each isolated database. Assert
    # those expected diagnostics; other compiler warnings still fail the proof.
    assert Enum.all?(diagnostics, fn diagnostic ->
             diagnostic.severity == :warning &&
               String.starts_with?(
                 IO.chardata_to_string(diagnostic.message),
                 "redefining module SpaceTraders.Repo.Migrations."
               )
           end),
           inspect(diagnostics)

    result
  end

  defp identity,
    do: query("SELECT operator_id, fleet_generation_id FROM current_fleet_identity").rows

  defp query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(MigrationRepo, sql, params)
  defp scalar(sql), do: query(sql).rows |> List.first() |> List.first()

  defp owner(email \\ "operator@example.com") do
    {:ok, ciphertext} = SpaceTraders.Secret.dump("ACCOUNT_SECRET")

    [[id]] =
      query(
        "INSERT INTO operators (email, hashed_password, account_token_ciphertext, inserted_at, updated_at) VALUES ($1, 'retained-password-hash', $2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) RETURNING id",
        [email, ciphertext]
      ).rows

    id
  end

  defp agent(owner, symbol \\ "ORBITALIST") do
    {:ok, ciphertext} = SpaceTraders.Secret.dump("AGENT_SECRET")

    [[id]] =
      query(
        "INSERT INTO agents (operator_id, symbol, faction, headquarters, agent_token_ciphertext, inserted_at, updated_at) VALUES ($1, $2, 'COSMIC', 'X1-UX81-A1', $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) RETURNING id",
        [owner, symbol, ciphertext]
      ).rows

    id
  end

  defp strategy(owner) do
    [[id]] =
      query(
        "INSERT INTO fleet_strategies (operator_id, inserted_at, updated_at) VALUES ($1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) RETURNING id",
        [owner]
      ).rows

    [[revision]] =
      query(
        "INSERT INTO fleet_strategy_revisions (fleet_strategy_id, number, document, source, activated_at, inserted_at) VALUES ($1, 1, '{\"objectives\": []}', 'accepted', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) RETURNING id",
        [id]
      ).rows

    query("UPDATE fleet_strategies SET active_revision_id = $1 WHERE id = $2", [revision, id])
    [owner, id, revision]
  end

  defp generation(owner, agent, number, retired_at, revision \\ nil) do
    [[id]] =
      query(
        "INSERT INTO fleet_generations (operator_id, agent_id, number, symbol, faction, retired_at, fleet_strategy_revision_id, inserted_at, updated_at) VALUES ($1, $2, $3, 'ORBITALIST', 'COSMIC', $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) RETURNING id",
        [owner, agent, number, retired_at, revision]
      ).rows

    id
  end

  defp retained do
    for table <- [
          "operators",
          "agents",
          "fleet_strategies",
          "fleet_strategy_revisions",
          "fleet_generations",
          "ships",
          "fleet_activity",
          "strategy_decision_episodes",
          "mutation_attempts"
        ] do
      query("SELECT row_to_json(t) FROM #{table} t ORDER BY id").rows
    end
  end
end
