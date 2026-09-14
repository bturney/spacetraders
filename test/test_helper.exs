# SQLite has a single writer; serial cases avoid sandbox checkout timeouts while
# PostgreSQL verification proves the same behavior through its own adapter.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(SpaceTraders.Repo, :manual)

# Every SQLite test run creates a PID-named file. PostgreSQL owns its test
# database lifecycle through `mix ecto.drop/create` instead.
if SpaceTraders.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
  db_path = Application.fetch_env!(:spacetraders, SpaceTraders.Repo)[:database]

  ExUnit.after_suite(fn _ ->
    if is_binary(db_path) do
      for suffix <- ["", "-shm", "-wal"] do
        File.rm(db_path <> suffix)
      end
    end
  end)
end
