#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_NAME="spacetraders-postgres-test-$$"
export SECRET_KEY_BASE="$(printf 'test%.0s' {1..16})"
export ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
export PHX_HOST=example.test
export POSTGRES_PASSWORD=test
export POSTGRES_USER=recovery_owner
export POSTGRES_DB=recovery_test

cd "$ROOT_DIR"

compose=(docker compose -p "$PROJECT_NAME" -f compose.yaml)
trap '"${compose[@]}" down --volumes >/dev/null 2>&1 || true' EXIT

"${compose[@]}" up --detach --wait postgres
"${compose[@]}" run --rm migrate
"${compose[@]}" run --rm migrate

migration_count=$("${compose[@]}" exec -T postgres \
  psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align \
  --command 'SELECT count(*) FROM schema_migrations')

[[ "$migration_count" -gt 0 ]]

"${compose[@]}" exec -T postgres psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --command "INSERT INTO operators (email, inserted_at, updated_at) VALUES ('recovery@example.test', now(), now())"

backup_dir=$(mktemp -d)
trap 'rm -rf "$backup_dir"; "${compose[@]}" down --volumes >/dev/null 2>&1 || true' EXIT
export COMPOSE_PROJECT_NAME=$PROJECT_NAME
export COMPOSE_FILE=compose.yaml
backup_output=$(scripts/postgres-recovery backup "$backup_dir/rehearsal")
restore_output=$(scripts/postgres-recovery restore-rehearsal "$backup_dir/rehearsal")
backup_operation_id=$(<"$backup_dir/rehearsal/operation_id")

grep -Eq '^operators=1:[0-9a-f]{64}$' "$backup_dir/rehearsal/manifest"
grep -q 'operation=backup status=completed' <<<"$backup_output"
grep -q 'operation=restore_rehearsal status=completed' <<<"$restore_output"
grep -q "backup_operation_id=$backup_operation_id" <<<"$restore_output"

"${compose[@]}" exec -T postgres createdb --username "$POSTGRES_USER" recovery_value_check
"${compose[@]}" exec -T postgres pg_restore --username "$POSTGRES_USER" \
  --dbname recovery_value_check --no-owner --no-acl <"$backup_dir/rehearsal/database.dump"
restored_email=$("${compose[@]}" exec -T postgres psql --username "$POSTGRES_USER" \
  --dbname recovery_value_check --tuples-only --no-align --command 'SELECT email FROM operators')
[[ "$restored_email" == recovery@example.test ]]

failure_override="$backup_dir/migration-failure.yaml"
cat >"$failure_override" <<'YAML'
services:
  migrate:
    command: ["sh", "-c", "exit 42"]
YAML

if "${compose[@]}" -f "$failure_override" up --detach web >"$backup_dir/failure.log" 2>&1; then
  printf '%s\n' 'Expected migration failure to fail Compose startup.' >&2
  exit 1
fi

web_state=$("${compose[@]}" -f "$failure_override" ps --all --format json web |
  jq -r '(if type == "array" then .[0].State else .State end) // "absent"')
[[ "$web_state" != "running" ]]
grep -q 'service "migrate" didn.t complete successfully: exit 42' "$backup_dir/failure.log"
