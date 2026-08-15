# SQLite has a single writer; serial cases avoid sandbox checkout timeouts while
# concurrent-worktree CI still proves workspace isolation.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(SpaceTraders.Repo, :manual)
