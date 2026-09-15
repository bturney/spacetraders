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

# Build a representative legacy SQLite database. The release no longer migrates
# SQLite during normal deployment once PostgreSQL becomes authoritative.
"${compose[@]}" run --rm migrate bin/spacetraders eval '
  original_adapter = Application.fetch_env!(:spacetraders, :repo_adapter)
  Application.put_env(:spacetraders, :repo_adapter, Ecto.Adapters.SQLite3)

  try do
    Ecto.Migrator.with_repo(SpaceTraders.LegacyRepo, fn repo ->
      Ecto.Migrator.run(repo, :up, all: true)
    end)
  after
    Application.put_env(:spacetraders, :repo_adapter, original_adapter)
  end
'

# Cover retained current state, historical activity, encrypted credential references,
# and a scheduled wakeup before repeating the one-way rehearsal.
"${compose[@]}" run --rm migrate bin/spacetraders eval '
  Ecto.Migrator.with_repo(SpaceTraders.LegacyRepo, fn _ ->
    repo = SpaceTraders.LegacyRepo
    repo.query!("INSERT INTO operators (email, account_token_ciphertext, inserted_at, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ["sqlite@example.test", "encrypted-account-token"])
    repo.query!("INSERT INTO operators_tokens (operator_id, token, context, inserted_at) VALUES (1, ?, ?, CURRENT_TIMESTAMP)", [<<1, 2, 3>>, "session"])
    repo.query!("INSERT INTO fleet_strategies (operator_id, draft_document, draft_source, draft_version, revision_number, inserted_at, updated_at) VALUES (1, ?, ?, 2, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", [~s({"objectives":[{"objective":"Chart waypoints","kind":"attain","evaluation":"Increase chart coverage","scope":"fleet_generation"}],"hard_constraints":["Keep 75000 credits available"],"preferences":["Prefer nearby systems"],"consequences":"Near-term growth may slow"}), "operator"])
    repo.query!("INSERT INTO fleet_strategy_revisions (fleet_strategy_id, number, document, source, activated_at, inserted_at) VALUES (1, 1, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", [~s({"objectives":[{"objective":"Grow credits","kind":"continuous","evaluation":"Maximize net credit growth","scope":"recurring"}],"hard_constraints":["Keep 50000 credits available"],"preferences":["Prefer short routes"],"consequences":"Credits may be spent above the floor"}), "preset:steady_growth"])
    repo.query!("UPDATE fleet_strategies SET active_revision_id = 1 WHERE id = 1")
    repo.query!("INSERT INTO agents (symbol, faction, headquarters, agent_token_ciphertext, operator_id, inserted_at, updated_at) VALUES (?, ?, ?, ?, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ["SQLITE-1", "COSMIC", "X1-TEST-A1", "encrypted-agent-token"])
    repo.query!("INSERT INTO ships (symbol, ship_type, agent_id, inserted_at, updated_at) VALUES (?, ?, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ["SQLITE-1-1", "SHIP_PROBE"])
    repo.query!("INSERT INTO fleet_activity (agent_id, ship_id, kind, message, metadata, inserted_at, updated_at) VALUES (1, 1, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ["historical", "retained activity", ~s({"source":"sqlite"})])
    repo.query!("INSERT INTO timeline_events (owner_type, owner_id, event_type, due_at, status, payload, inserted_at, updated_at) VALUES (?, 1, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ["ship", "arrival", "2030-01-01T00:00:00Z", "scheduled", ~s({"waypoint":"X1-TEST-A1"})])
    repo.query!("INSERT INTO jobs (ship_id, type, extraction_waypoint, market_waypoint, cargo_threshold, status, sellable_goods, inserted_at, updated_at) VALUES (1, ?, ?, ?, 10, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ["explorer", "X1-TEST-A1", "X1-TEST-A1", "active", "[]"])
    repo.query!("INSERT INTO intents (ship_id, type, target_waypoint, caller, status, in_flight_action, inserted_at, updated_at) VALUES (1, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ["navigate", "X1-TEST-A2", "manual", "active", ~s({"kind":"navigate"})])
  end)
'

unsafe_log=$(mktemp)
if "${compose[@]}" run --rm migrate >"$unsafe_log" 2>&1; then
  printf '%s\n' 'Expected cutover to refuse an unfenced admitted mutation.' >&2
  exit 1
fi
grep -q 'PostgreSQL cutover refused: admitted mutations are not settled or safety-fenced' "$unsafe_log"
rm -f "$unsafe_log"

"${compose[@]}" run --rm migrate bin/spacetraders eval '
  Ecto.Migrator.with_repo(SpaceTraders.LegacyRepo, fn _ ->
    SpaceTraders.LegacyRepo.query!("UPDATE intents SET status = ?, blocker = ? WHERE id = 1", ["blocked", ~s({"reason":"mutation_outcome_unknown","summary":"Reconcile before dependent work","evidence":"intent_id=1","retry_condition":"authoritative_mutation_outcome_available"})])
  end)
'

if "${compose[@]}" run --rm -e SQLITE_REHEARSAL_FAIL_AFTER_TABLE=agents migrate; then
  printf '%s\n' 'Expected forced cutover transformation failure.' >&2
  exit 1
fi

authority_after_failure=$("${compose[@]}" exec -T postgres \
  psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align \
  --command "SELECT count(*) FROM runtime_authority")
[[ "$authority_after_failure" == 0 ]]

first_cutover=$("${compose[@]}" run --rm migrate)
second_cutover=$("${compose[@]}" run --rm migrate)

migration_count=$("${compose[@]}" exec -T postgres \
  psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align \
  --command 'SELECT count(*) FROM schema_migrations')

[[ "$migration_count" -gt 0 ]]

first_reconciliation=$(sed -n 's/.*reconciliation=//p' <<<"$first_cutover")
[[ "$first_reconciliation" =~ ^[0-9a-f]{64}$ ]]
grep -q 'operation=postgres_cutover status=completed tables=14 rows=10' <<<"$first_cutover"
grep -q 'operation=postgres_cutover status=already_authoritative store=postgresql' <<<"$second_cutover"

postgres_state=$("${compose[@]}" exec -T postgres psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align \
  --command "SELECT email || ':' || account_token_ciphertext FROM operators")
[[ "$postgres_state" == sqlite@example.test:encrypted-account-token ]]

authority_state=$("${compose[@]}" exec -T postgres psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align \
  --command "SELECT r.store || ':' || j.status || ':' || i.status || ':' || o.event FROM runtime_authority r CROSS JOIN jobs j CROSS JOIN intents i CROSS JOIN outbox_notifications o")
[[ "$authority_state" == postgresql:stopped:blocked:postgresql_authority_advanced ]]

strategy_state=$("${compose[@]}" exec -T postgres psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align \
  --command "SELECT (fs.draft_document->'objectives'->0->>'objective') || ':' || (fr.document->'objectives'->0->>'objective') || ':' || fs.active_revision_id FROM fleet_strategies fs JOIN fleet_strategy_revisions fr ON fr.id = fs.active_revision_id")
[[ "$strategy_state" == "Chart waypoints:Grow credits:1" ]]

if "${compose[@]}" run --rm migrate bin/spacetraders eval 'SpaceTraders.Release.rehearse_sqlite_to_postgres()'; then
  printf '%s\n' 'Expected forward-only authority to reject SQLite rehearsal.' >&2
  exit 1
fi

sqlite_state=$("${compose[@]}" run --rm migrate bin/spacetraders eval '
  Ecto.Migrator.with_repo(SpaceTraders.LegacyRepo, fn _ ->
    %{rows: [[job, intent]]} = SpaceTraders.LegacyRepo.query!("SELECT jobs.status, intents.status FROM jobs CROSS JOIN intents")
    IO.puts("#{job}:#{intent}")
  end)
')
[[ "$sqlite_state" == active:blocked ]]

"${compose[@]}" exec -T postgres psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --command "INSERT INTO operators (email, inserted_at, updated_at) VALUES ('recovery@example.test', now(), now())"

backup_dir=$(mktemp -d)
trap 'rm -rf "$backup_dir"; "${compose[@]}" down --volumes >/dev/null 2>&1 || true' EXIT
export COMPOSE_PROJECT_NAME=$PROJECT_NAME
export COMPOSE_FILE=compose.yaml
backup_output=$(scripts/postgres-recovery backup "$backup_dir/rehearsal")
restore_output=$(scripts/postgres-recovery restore-rehearsal "$backup_dir/rehearsal")
backup_operation_id=$(<"$backup_dir/rehearsal/operation_id")

grep -Eq '^operators=2:[0-9a-f]{64}$' "$backup_dir/rehearsal/manifest"
grep -q 'operation=backup status=completed' <<<"$backup_output"
grep -q 'operation=restore_rehearsal status=completed' <<<"$restore_output"
grep -q "backup_operation_id=$backup_operation_id" <<<"$restore_output"

"${compose[@]}" exec -T postgres createdb --username "$POSTGRES_USER" recovery_value_check
"${compose[@]}" exec -T postgres pg_restore --username "$POSTGRES_USER" \
  --dbname recovery_value_check --no-owner --no-acl <"$backup_dir/rehearsal/database.dump"
restored_email=$("${compose[@]}" exec -T postgres psql --username "$POSTGRES_USER" \
  --dbname recovery_value_check --tuples-only --no-align --command "SELECT email FROM operators WHERE email = 'recovery@example.test'")
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
