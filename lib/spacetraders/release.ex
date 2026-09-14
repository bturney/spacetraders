defmodule SpaceTraders.Release do
  @moduledoc false

  @app :spacetraders

  alias SpaceTraders.{LegacyRepo, Repo}

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      migrate_repo(repo)
    end
  end

  def cutover do
    Application.load(@app)
    migrate_repo(Repo)
    transform_sqlite(:cutover)
  end

  def rehearse_sqlite_to_postgres do
    Application.load(@app)
    migrate_repo(Repo)
    transform_sqlite(:rehearsal)
  end

  defp transform_sqlite(mode) do
    Ecto.Migrator.with_repo(LegacyRepo, fn _ ->
      Ecto.Migrator.with_repo(Repo, fn _ ->
        if authoritative?() do
          if mode == :rehearsal do
            raise "PostgreSQL authority has advanced; SQLite rehearsal is no longer permitted"
          end

          IO.puts("operation=postgres_cutover status=already_authoritative store=postgresql")
        else
          {:ok, {tables, source}} =
            LegacyRepo.transaction(
              fn ->
                tables = source_tables()

                if "intents" in tables or "jobs" in tables do
                  case SpaceTraders.Cutover.assess(LegacyRepo) do
                    :ok ->
                      :ok

                    {:error, {:unprotected_mutations, counts}} ->
                      raise "PostgreSQL cutover refused: admitted mutations are not settled or safety-fenced #{inspect(counts)}"
                  end
                end

                source = Map.new(tables, &{&1, source_rows(&1)})
                transform_destination(mode, tables, source)
                {tables, source}
              end,
              mode: :immediate
            )

          {table_count, row_count, reconciliation} = reconciliation_report(tables, source)

          IO.puts(
            "operation=#{operation(mode)} status=completed tables=#{table_count} rows=#{row_count} reconciliation=#{reconciliation}"
          )
        end
      end)
    end)
  end

  defp transform_destination(:rehearsal, tables, source) do
    Repo.transaction(fn -> copy_and_verify(tables, source) end)
  end

  defp transform_destination(:cutover, tables, source) do
    {:ok, :ok} =
      SpaceTraders.Outbox.publish(
        %{
          topic: "runtime",
          event: "postgresql_authority_advanced",
          payload: %{"store" => "postgresql"}
        },
        fn ->
          copy_and_verify(tables, source)
          stop_legacy_work(tables)

          Repo.query!(
            "INSERT INTO runtime_authority (name, store, advanced_at) VALUES ('durable_truth', 'postgresql', $1)",
            [DateTime.utc_now()]
          )

          :ok
        end
      )
  end

  defp copy_and_verify(tables, source) do
    truncate_tables(tables)
    copy_tables(tables, source)
    reset_sequences(tables)
    verify_reconciliation!(tables, source)
  end

  defp stop_legacy_work(tables) do
    now = DateTime.utc_now()

    if "intents" in tables do
      Repo.query!(
        "UPDATE intents SET status = 'stopped', finished_at = $1, updated_at = $1 WHERE status IN ('active', 'waiting', 'awaiting_confirmation', 'blocked') AND in_flight_action IS NULL",
        [now]
      )
    end

    if "jobs" in tables do
      Repo.query!(
        "UPDATE jobs SET status = 'stopped', finished_at = $1, updated_at = $1 WHERE status IN ('active', 'waiting', 'blocked', 'paused') AND in_flight_action IS NULL",
        [now]
      )
    end
  end

  defp authoritative? do
    %{rows: rows} =
      Repo.query!("SELECT store FROM runtime_authority WHERE name = 'durable_truth'")

    rows == [["postgresql"]]
  end

  defp operation(:cutover), do: "postgres_cutover"
  defp operation(:rehearsal), do: "sqlite_rehearsal"

  defp migrate_repo(repo) do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  defp source_tables do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        LegacyRepo,
        """
        SELECT name FROM sqlite_master
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
           AND name NOT IN ('schema_migrations', 'runtime_authority', 'outbox_notifications')
        ORDER BY name
        """
      )

    Enum.map(rows, fn [table] -> table end)
  end

  defp source_rows(table) do
    %{columns: columns, rows: rows} =
      Ecto.Adapters.SQL.query!(LegacyRepo, "SELECT * FROM #{quote_identifier(table)}")

    types = postgres_column_types(table)

    {columns,
     Enum.map(rows, fn row ->
       Enum.zip(columns, row)
       |> Enum.map(fn {column, value} ->
         normalize_for_postgres(value, Map.fetch!(types, column))
       end)
     end)}
  end

  defp postgres_column_types(table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT column_name, data_type, udt_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        """,
        [table]
      )

    Map.new(rows, fn [column, data_type, udt_name] -> {column, {data_type, udt_name}} end)
  end

  defp normalize_for_postgres(nil, _type), do: nil

  defp normalize_for_postgres(value, {"timestamp without time zone", _}) when is_binary(value) do
    value
    |> String.replace(" ", "T")
    |> NaiveDateTime.from_iso8601!()
    |> with_microsecond_precision()
  end

  defp normalize_for_postgres(value, {"timestamp with time zone", _}) when is_binary(value) do
    {datetime, _offset} = DateTime.from_iso8601(value)
    with_microsecond_precision(datetime)
  end

  defp normalize_for_postgres(value, {"boolean", _}) when value in [0, 1], do: value == 1

  defp normalize_for_postgres(value, {type, _})
       when type in ["smallint", "integer", "bigint"] and is_binary(value),
       do: String.to_integer(value)

  defp normalize_for_postgres(value, {"jsonb", _}) when is_binary(value), do: Jason.decode!(value)

  defp normalize_for_postgres(value, {"ARRAY", _}) when is_binary(value),
    do: Jason.decode!(value)

  defp normalize_for_postgres(value, _type), do: value

  defp truncate_tables([]), do: :ok

  defp truncate_tables(tables) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE TABLE #{Enum.map_join(tables, ", ", &quote_identifier/1)} RESTART IDENTITY CASCADE"
    )
  end

  defp copy_tables(tables, source) do
    tables
    |> dependency_order()
    |> Enum.each(fn table -> copy_table(table, Map.fetch!(source, table)) end)
  end

  defp dependency_order(tables) do
    dependencies =
      Map.new(tables, fn table ->
        %{rows: rows} =
          Ecto.Adapters.SQL.query!(
            LegacyRepo,
            "PRAGMA foreign_key_list(#{quote_literal(table)})"
          )

        {table,
         rows
         |> Enum.map(fn [_id, _sequence, parent | _] -> parent end)
         |> Enum.reject(&(&1 == table))
         |> MapSet.new()}
      end)

    order_dependencies(tables, dependencies, [])
  end

  defp order_dependencies([], _dependencies, ordered), do: Enum.reverse(ordered)

  defp order_dependencies(remaining, dependencies, ordered) do
    ready =
      Enum.filter(
        remaining,
        &MapSet.disjoint?(Map.fetch!(dependencies, &1), MapSet.new(remaining))
      )

    if ready == [] do
      raise "SQLite tables have a cyclic foreign-key dependency"
    end

    order_dependencies(remaining -- ready, dependencies, Enum.reverse(ready) ++ ordered)
  end

  defp copy_table(table, {columns, rows}) do
    self_references = self_references(table)

    Enum.each(rows, fn row ->
      values = Enum.zip(columns, row) |> Map.new()
      insert_row(table, columns, values, self_references)
    end)

    if System.get_env("SQLITE_REHEARSAL_FAIL_AFTER_TABLE") == table do
      raise "SQLite rehearsal forced failure after #{table}"
    end

    Enum.each(rows, fn row ->
      restore_self_references(table, columns, Map.new(Enum.zip(columns, row)), self_references)
    end)
  end

  defp self_references(table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        LegacyRepo,
        "PRAGMA foreign_key_list(#{quote_literal(table)})"
      )

    for [_id, _sequence, ^table, from | _] <- rows, do: from
  end

  defp insert_row(table, columns, values, self_references) do
    placeholders = Enum.map_join(1..length(columns), ", ", &"$#{&1}")
    columns_sql = Enum.map_join(columns, ", ", &quote_identifier/1)

    values =
      Enum.map(columns, fn column ->
        if column in self_references, do: nil, else: Map.fetch!(values, column)
      end)

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO #{quote_identifier(table)} (#{columns_sql}) VALUES (#{placeholders})",
      values
    )
  end

  defp restore_self_references(_table, _columns, _values, []), do: :ok

  defp restore_self_references(table, _columns, values, self_references) do
    assignments = Enum.with_index(self_references, 1)

    assignment_sql =
      Enum.map_join(assignments, ", ", fn {column, index} ->
        "#{quote_identifier(column)} = $#{index}"
      end)

    parameters = Enum.map(self_references, &Map.fetch!(values, &1)) ++ [Map.fetch!(values, "id")]

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE #{quote_identifier(table)} SET #{assignment_sql} WHERE id = $#{length(parameters)}",
      parameters
    )
  end

  defp reset_sequences(tables) do
    Enum.each(tables, fn table ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT setval(pg_get_serial_sequence($1, 'id'), COALESCE((SELECT MAX(id) FROM #{quote_identifier(table)}), 1), EXISTS (SELECT 1 FROM #{quote_identifier(table)}))",
        [table]
      )
    end)
  end

  defp verify_reconciliation!(tables, source) do
    Enum.each(tables, fn table ->
      {columns, expected_rows} = Map.fetch!(source, table)

      %{rows: actual_rows} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT * FROM #{quote_identifier(table)}"
        )

      if canonical_rows(expected_rows) != canonical_rows(actual_rows) do
        raise "SQLite rehearsal reconciliation failed for #{table}"
      end

      # The query result must retain the source column order for the row comparison to be meaningful.
      %{columns: ^columns} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT * FROM #{quote_identifier(table)} LIMIT 0"
        )
    end)
  end

  defp reconciliation_report(tables, source) do
    row_count =
      Enum.reduce(source, 0, fn {_table, {_columns, rows}}, total -> total + length(rows) end)

    hash =
      tables
      |> Enum.map(fn table ->
        {columns, rows} = Map.fetch!(source, table)
        {table, columns, canonical_rows(rows)}
      end)
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {length(tables), row_count, hash}
  end

  defp canonical_rows(rows) do
    rows
    |> Enum.map(&canonical_value/1)
    |> Enum.sort_by(&:erlang.term_to_binary/1)
  end

  defp canonical_value(%NaiveDateTime{} = datetime),
    do: NaiveDateTime.to_string(datetime) |> String.trim_trailing(".000000")

  defp canonical_value(%DateTime{} = datetime),
    do: DateTime.to_iso8601(datetime) |> String.replace(".000000Z", "Z")

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)

  defp canonical_value(value) when is_map(value),
    do: Map.new(value, fn {key, nested_value} -> {key, canonical_value(nested_value)} end)

  defp canonical_value(value), do: value

  defp with_microsecond_precision(%{microsecond: {microseconds, _precision}} = datetime),
    do: %{datetime | microsecond: {microseconds, 6}}

  defp quote_identifier(identifier), do: "\"#{String.replace(identifier, "\"", "\"\"")}\""
  defp quote_literal(value), do: "'#{String.replace(value, "'", "''")}'"
end
