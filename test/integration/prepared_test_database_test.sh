#!/usr/bin/env bash
# Verify ordinary mix test runs reuse the caller's prepared PostgreSQL database.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source scripts/_toolchain.sh

if ! command -v psql >/dev/null; then
  echo "psql is required to verify prepared test database reuse" >&2
  exit 1
fi

export DATABASE_URL="${DATABASE_URL:-postgres://postgres:postgres@localhost/spacetraders_test}"

database_identity() {
  psql "$DATABASE_URL" --no-psqlrc --tuples-only --no-align --quiet \
    --set=ON_ERROR_STOP=1 \
    --command "SELECT (SELECT oid FROM pg_database WHERE datname = current_database()) || ':' || (SELECT count(*) FROM pg_database)"
}

before="$(database_identity)"

for run in 1 2; do
  MIX_ENV=test mix test test/spacetraders/agent_test.exs:21
  after_run="$(database_identity)"

  if [[ "$after_run" != "$before" ]]; then
    echo "mix test changed database identity/count: before=$before after=$after_run" >&2
    exit 1
  fi
done

echo "Prepared test database reuse passed: $before"
