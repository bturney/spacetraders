#!/usr/bin/env bash
# Exercise the public worktree setup contract against real Git worktrees.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
CACHE_DIR="$TEMP_ROOT/cache"
PORT_REGISTRY_DIR="$TEMP_ROOT/ports"
WORKTREE_ONE="$TEMP_ROOT/one"
WORKTREE_TWO="$TEMP_ROOT/two"
WORKTREE_THREE="$TEMP_ROOT/three"
WORKTREE_DIRTY="$TEMP_ROOT/dirty"
PIDS=()
REVISION="${WORKTREE_TEST_REVISION:-HEAD}"

cleanup() {
  local status=$?

  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done

  for worktree in "$WORKTREE_ONE" "$WORKTREE_TWO" "$WORKTREE_THREE" "$WORKTREE_DIRTY"; do
    if [ -d "$worktree" ]; then
      (cd "$worktree" && scripts/teardown) || true
      git -C "$PROJECT_ROOT" worktree remove --force "$worktree" || true
    fi
  done

  rm -rf "$TEMP_ROOT"
  exit "$status"
}

trap cleanup EXIT

source "$PROJECT_ROOT/scripts/_toolchain.sh"
scripts/bootstrap

for worktree in "$WORKTREE_ONE" "$WORKTREE_TWO" "$WORKTREE_THREE" "$WORKTREE_DIRTY"; do
  git -C "$PROJECT_ROOT" worktree add --detach "$worktree" "$REVISION" >/dev/null
done

setup_worktree() {
  local worktree="$1"
  local task_id="$2"
  SPACETRADERS_WORKTREE_CACHE_DIR="$CACHE_DIR" \
    SPACETRADERS_PORT_REGISTRY_DIR="$PORT_REGISTRY_DIR" \
    "$worktree/scripts/worktree-setup" "$task_id"
}

setup_worktree "$WORKTREE_ONE" integration-one >"$TEMP_ROOT/one.log" 2>&1 &
PIDS+=("$!")
setup_worktree "$WORKTREE_TWO" integration-two >"$TEMP_ROOT/two.log" 2>&1 &
PIDS+=("$!")

for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    grep -H . "$TEMP_ROOT"/one.log "$TEMP_ROOT"/two.log >&2 || true
    exit 1
  fi
done
PIDS=()

if [ "$(grep -h '^Populating warm cache ' "$TEMP_ROOT"/*.log | wc -l)" -ne 1 ]; then
  echo "Expected exactly one concurrent cache population." >&2
  exit 1
fi

cache_entry="$(printf '%s\n' "$CACHE_DIR"/entries/*)"
[ -d "$cache_entry/_build" ]
[ -d "$WORKTREE_ONE/_build" ]
[ -d "$WORKTREE_TWO/_build" ]

if [ "$(stat -c %i "$cache_entry/_build")" = "$(stat -c %i "$WORKTREE_ONE/_build")" ]; then
  echo "Worktree one received the cache build directory instead of a writable copy." >&2
  exit 1
fi

port_one="$(awk -F= '/^export PORT=/{print $2}' "$WORKTREE_ONE/.worktree-env")"
port_two="$(awk -F= '/^export PORT=/{print $2}' "$WORKTREE_TWO/.worktree-env")"

if [ "$port_one" = "$port_two" ]; then
  echo "Distinct task IDs received the same port." >&2
  grep -H . "$TEMP_ROOT"/one.log "$TEMP_ROOT"/two.log >&2 || true
  exit 1
fi

# The gate drops and recreates its database on every run, so two concurrent
# gates sharing one name destroy each other mid-run. Assert the databases
# differ here rather than inferring it from the two-gate run below: this is the
# cheap check that fails the moment allocation is removed, and it names the
# cause instead of surfacing as an unrelated_table or OwnershipError.
database_url() {
  local value
  value="$(sed -n 's/^export DATABASE_URL=//p' "$1" | head -n 1)"
  # worktree-setup writes the value with printf %q, so strip one quote layer.
  printf '%s\n' "${value#\"}"
}

url_one="$(database_url "$WORKTREE_ONE/.worktree-env")"
url_two="$(database_url "$WORKTREE_TWO/.worktree-env")"

if [ -z "$url_one" ] || [ -z "$url_two" ]; then
  echo "Worktree setup did not allocate a database." >&2
  grep -H . "$TEMP_ROOT"/one.log "$TEMP_ROOT"/two.log >&2 || true
  exit 1
fi

database_one="${url_one##*/}"
database_two="${url_two##*/}"

if [ "$database_one" = "$database_two" ] || [ "$url_one" = "$url_two" ]; then
  echo "Distinct task IDs received the same database: $url_one" >&2
  grep -H . "$TEMP_ROOT"/one.log "$TEMP_ROOT"/two.log >&2 || true
  exit 1
fi

admin_url="${url_one%/*}/postgres"

database_exists() {
  [ -n "$1" ] || return 1
  [ "$(psql "$admin_url" --no-psqlrc --tuples-only --no-align \
    --set=database_name="$1" \
    --command "SELECT 1 FROM pg_database WHERE datname = :'database_name'" 2>/dev/null || true)" = "1" ]
}

setup_worktree "$WORKTREE_THREE" integration-three >"$TEMP_ROOT/three.log" 2>&1
grep -q '^Restored warm cache ' "$TEMP_ROOT/three.log"

# Read the name before teardown, which removes the task environment file.
three_database="$(database_url "$WORKTREE_THREE/.worktree-env")"
three_database="${three_database##*/}"

(cd "$WORKTREE_THREE" && scripts/teardown)

# Teardown releases the task's database, so repeated setup/teardown cycles do
# not accumulate one database per task.
if [ -z "$three_database" ] || [ "$three_database" = "$database_one" ] || [ "$three_database" = "$database_two" ]; then
  echo "Teardown of a worktree owned a database another task also owns: '$three_database'" >&2
  exit 1
fi

for attempt in 1 2 3 4 5; do
  database_exists "$three_database" || break
  sleep 1
done

if database_exists "$three_database"; then
  echo "Teardown did not drop the task's database: $three_database" >&2
  exit 1
fi

printf '\n# dirty cache bypass\n' >> "$WORKTREE_DIRTY/README.md"
setup_worktree "$WORKTREE_DIRTY" integration-dirty >"$TEMP_ROOT/dirty.log" 2>&1
grep -q '^Dirty worktree: compiling privately' "$TEMP_ROOT/dirty.log"

if setup_worktree "$WORKTREE_THREE" integration-one >"$TEMP_ROOT/duplicate.log" 2>&1; then
  echo "Duplicate task ID unexpectedly received an allocated port." >&2
  exit 1
fi

# A distinct task ID: the database is named after the task, so reusing
# `integration-one` here would hand this worktree the database the gate
# worktree owns, and its teardown would drop it out from under that gate.
PORT=49999 setup_worktree "$WORKTREE_THREE" integration-override >"$TEMP_ROOT/override.log" 2>&1

(
  cd "$WORKTREE_ONE"
  source scripts/_toolchain.sh
  source .worktree-env
  scripts/verify
) >"$TEMP_ROOT/server-one.log" 2>&1 &
PIDS+=("$!")

(
  cd "$WORKTREE_TWO"
  source scripts/_toolchain.sh
  source .worktree-env
  scripts/verify
) >"$TEMP_ROOT/server-two.log" 2>&1 &
PIDS+=("$!")

for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    grep -H . "$TEMP_ROOT"/server-*.log >&2 || true
    exit 1
  fi
done
PIDS=()

for port in "$port_one" "$port_two"; do
  if ! grep -q "boot verify: GET http://127.0.0.1:$port/health -> 200 ok" "$TEMP_ROOT"/server-*.log; then
    grep -H 'boot verify:' "$TEMP_ROOT"/server-*.log >&2 || true
    exit 1
  fi
done

# The strongest form of the same property: each gate actually created and used
# its own database, so nothing about the shared name survived. This is the
# assertion that fails if the two gates resolve to one database again, and it
# fails immediately after the run rather than only on the next one.
for database in "$database_one" "$database_two"; do
  if ! database_exists "$database"; then
    echo "A gate did not use its allocated database: $database" >&2
    grep -H . "$TEMP_ROOT"/server-*.log >&2 || true
    exit 1
  fi
done

touch -d '1 second ago' "$cache_entry"
SPACETRADERS_WORKTREE_CACHE_DIR="$CACHE_DIR" scripts/worktree-cache-prune --max-age-days 0
! compgen -G "$CACHE_DIR/entries/*" >/dev/null

echo "Concurrent worktree isolation passed."
