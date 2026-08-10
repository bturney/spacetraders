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
    rg . "$TEMP_ROOT"/one.log "$TEMP_ROOT"/two.log >&2 || true
    exit 1
  fi
done
PIDS=()

if [ "$(rg --no-filename '^Populating warm cache ' "$TEMP_ROOT"/*.log | wc -l)" -ne 1 ]; then
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
  exit 1
fi

setup_worktree "$WORKTREE_THREE" integration-three >"$TEMP_ROOT/three.log" 2>&1
rg -q '^Restored warm cache ' "$TEMP_ROOT/three.log"

(cd "$WORKTREE_THREE" && scripts/teardown)

printf '\n# dirty cache bypass\n' >> "$WORKTREE_DIRTY/README.md"
setup_worktree "$WORKTREE_DIRTY" integration-dirty >"$TEMP_ROOT/dirty.log" 2>&1
rg -q '^Dirty worktree: compiling privately\.' "$TEMP_ROOT/dirty.log"

if setup_worktree "$WORKTREE_THREE" integration-one >"$TEMP_ROOT/duplicate.log" 2>&1; then
  echo "Duplicate task ID unexpectedly received an allocated port." >&2
  exit 1
fi

PORT=49999 setup_worktree "$WORKTREE_THREE" integration-one >"$TEMP_ROOT/override.log" 2>&1

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
    rg . "$TEMP_ROOT"/server-*.log >&2 || true
    exit 1
  fi
done
PIDS=()

for port in "$port_one" "$port_two"; do
  if ! rg -q "boot verify: GET http://127.0.0.1:$port/health -> 200 ok" "$TEMP_ROOT"/server-*.log; then
    rg 'boot verify:' "$TEMP_ROOT"/server-*.log >&2 || true
    exit 1
  fi
done

touch -d '1 second ago' "$cache_entry"
SPACETRADERS_WORKTREE_CACHE_DIR="$CACHE_DIR" scripts/worktree-cache-prune --max-age-days 0
! compgen -G "$CACHE_DIR/entries/*" >/dev/null

echo "Concurrent worktree isolation passed."
