# SQLite (ecto_sqlite3) for local state, Postgres deferred

Phase-1 state lives in SQLite (`ecto_sqlite3`), volume-backed, with no server database. Postgres was rejected as premature for a single-process, LAN-only app. Consequences: revisit if Phase-5 remote/multi-machine access becomes real — that forces Postgres.
