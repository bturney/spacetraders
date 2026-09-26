#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source scripts/_toolchain.sh

command -v psql >/dev/null || {
  echo "psql is required to simulate schema drift" >&2
  exit 1
}

database="spacetraders_migration_repair_$$"
export DATABASE_URL="postgres://postgres:postgres@127.0.0.1/$database"

cleanup() {
  MIX_ENV=test mix ecto.drop --quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Drift and repair are asserted against PostgreSQL directly. `mix run` would
# start the application, and the application only ever starts against a fully
# migrated schema: compose.yaml gates web on migrate completing successfully.
psql_query() {
  psql "$DATABASE_URL" --tuples-only --no-align --quiet \
    --set ON_ERROR_STOP=1 --command "$1"
}

actual_outcomes_columns() {
  psql_query "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'strategy_decision_episodes' AND column_name = 'actual_outcomes'"
}

MIX_ENV=test mix ecto.create --quiet
MIX_ENV=test mix ecto.migrate --to 20260923010000
psql_query "ALTER TABLE strategy_decision_episodes DROP COLUMN actual_outcomes"
[[ "$(actual_outcomes_columns)" == "0" ]]
MIX_ENV=test mix ecto.migrate
[[ "$(actual_outcomes_columns)" == "1" ]]

# The repaired schema is complete, so the application starts against it.
MIX_ENV=test mix run -e ':ok'
