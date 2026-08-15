ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(SpaceTraders.Repo, :manual)

# Every `mix test` run creates a PID-named SQLite file (config/test.exs) that is
# never removed, so stale test DBs accumulate at the repo root. Remove the DB
# and its SQLite sidecars once the suite finishes.
db_path = Application.fetch_env!(:spacetraders, SpaceTraders.Repo)[:database]

ExUnit.after_suite(fn _ ->
  if is_binary(db_path) do
    for suffix <- ["", "-shm", "-wal"] do
      File.rm(db_path <> suffix)
    end
  end
end)
