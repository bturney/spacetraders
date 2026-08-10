#!/usr/bin/env bash
# Exercise the repository-owned task workspace lifecycle in a disposable repo.
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
PROJECT_ROOT="$TEMP_ROOT/project"
WORKSPACE="$TEMP_ROOT/project-diagnose-timeout"
RUNNER="$TEMP_ROOT/record-pwd"
RUNNER_PWD="$TEMP_ROOT/runner-pwd"
RUNNER_TASK_ID="$TEMP_ROOT/runner-task-id"
LEASES="$TEMP_ROOT/leases"

cleanup() {
  git -C "$PROJECT_ROOT" worktree remove --force "$WORKSPACE" 2>/dev/null || true
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

mkdir -p "$PROJECT_ROOT/scripts" "$LEASES"
export TEST_LEASES="$LEASES"
cp "$SOURCE_ROOT/scripts/task-start" "$PROJECT_ROOT/scripts/task-start"
cp "$SOURCE_ROOT/scripts/task-stop" "$PROJECT_ROOT/scripts/task-stop"

cat > "$PROJECT_ROOT/scripts/worktree-setup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAIL_SETUP:-0}" = 1 ]; then
  exit 23
fi
printf '%s\n' "$1" > "$TEST_LEASES/$1"
printf 'export AGENT_TASK_ID=%s\n' "$1" > .worktree-env
printf 'export WORKTREE_PORT_LEASE=0\n' >> .worktree-env
printf 'export TEST_LEASES=%s\n' "$TEST_LEASES" >> .worktree-env
EOF

cat > "$PROJECT_ROOT/scripts/teardown" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rm -f "$TEST_LEASES/$AGENT_TASK_ID"
rm -f .worktree-env
EOF

cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
pwd > "$1"
printf '%s\n' "${AGENT_TASK_ID:-}" > "$2"
EOF

printf '.worktree-env\nignored-proof\nnested/keep.db\n' > "$PROJECT_ROOT/.gitignore"

chmod +x "$PROJECT_ROOT/scripts/"* "$RUNNER"

git -C "$PROJECT_ROOT" init --initial-branch=main >/dev/null
git -C "$PROJECT_ROOT" config user.email test@example.com
git -C "$PROJECT_ROOT" config user.name "Task Workspace Test"
git -C "$PROJECT_ROOT" add .gitignore scripts
git -C "$PROJECT_ROOT" commit -m "Fixture" >/dev/null

printf 'alternate base\n' > "$PROJECT_ROOT/alternate.txt"
git -C "$PROJECT_ROOT" add alternate.txt
git -C "$PROJECT_ROOT" commit -m "Alternate base" >/dev/null
git -C "$PROJECT_ROOT" branch alternate
git -C "$PROJECT_ROOT" reset --hard HEAD~1 >/dev/null

"$PROJECT_ROOT/scripts/task-start" diagnose-timeout -- "$RUNNER" "$RUNNER_PWD" "$RUNNER_TASK_ID"

[ "$(cat "$RUNNER_PWD")" = "$WORKSPACE" ]
[ "$(cat "$RUNNER_TASK_ID")" = "diagnose-timeout" ]
[ "$(git -C "$WORKSPACE" branch --show-current)" = "feature/diagnose-timeout" ]
grep -Fx "export AGENT_TASK_ID=diagnose-timeout" "$WORKSPACE/.worktree-env"

"$PROJECT_ROOT/scripts/task-stop" diagnose-timeout

[ ! -e "$WORKSPACE" ]
git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/feature/diagnose-timeout
[ ! -e "$LEASES/diagnose-timeout" ]

if "$PROJECT_ROOT/scripts/task-start" diagnose-timeout; then
  echo "Existing task branch unexpectedly started without --resume." >&2
  exit 1
fi

"$PROJECT_ROOT/scripts/task-start" diagnose-timeout --resume
[ -f "$WORKSPACE/.worktree-env" ]
"$PROJECT_ROOT/scripts/task-stop" diagnose-timeout

resume_commit="$(git -C "$PROJECT_ROOT" rev-parse feature/diagnose-timeout)"
if FAIL_SETUP=1 "$PROJECT_ROOT/scripts/task-start" diagnose-timeout --resume; then
  echo "Failed resumed setup unexpectedly succeeded." >&2
  exit 1
fi
[ ! -e "$WORKSPACE" ]
[ "$(git -C "$PROJECT_ROOT" rev-parse feature/diagnose-timeout)" = "$resume_commit" ]

"$PROJECT_ROOT/scripts/task-start" alternate --base alternate
[ "$(git -C "$TEMP_ROOT/project-alternate" rev-parse HEAD)" = "$(git -C "$PROJECT_ROOT" rev-parse alternate)" ]
"$PROJECT_ROOT/scripts/task-stop" alternate

"$PROJECT_ROOT/scripts/task-start" 63
[ "$(git -C "$TEMP_ROOT/project-63" branch --show-current)" = "feature/63" ]
"$PROJECT_ROOT/scripts/task-stop" 63

"$PROJECT_ROOT/scripts/task-start" collision
if "$PROJECT_ROOT/scripts/task-start" collision; then
  echo "Existing task workspace unexpectedly started without --resume." >&2
  exit 1
fi
"$PROJECT_ROOT/scripts/task-stop" collision

if FAIL_SETUP=1 "$PROJECT_ROOT/scripts/task-start" failed-setup; then
  echo "Failed setup unexpectedly succeeded." >&2
  exit 1
fi
[ ! -e "$TEMP_ROOT/project-failed-setup" ]
! git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/feature/failed-setup

set +e
"$PROJECT_ROOT/scripts/task-start" runner-exit -- sh -c 'exit 19'
runner_status=$?
set -e
if [ "$runner_status" -ne 19 ]; then
  echo "Runner failure unexpectedly succeeded." >&2
  exit 1
fi
"$PROJECT_ROOT/scripts/task-stop" runner-exit

"$PROJECT_ROOT/scripts/task-start" runner-teardown -- ./scripts/teardown
[ ! -f "$TEMP_ROOT/project-runner-teardown/.worktree-env" ]
"$PROJECT_ROOT/scripts/task-start" runner-teardown --resume
[ -f "$TEMP_ROOT/project-runner-teardown/.worktree-env" ]
"$PROJECT_ROOT/scripts/task-stop" runner-teardown

"$PROJECT_ROOT/scripts/task-start" missing-env
rm "$TEMP_ROOT/project-missing-env/.worktree-env"
"$PROJECT_ROOT/scripts/task-stop" missing-env
[ ! -e "$LEASES/missing-env" ]

"$PROJECT_ROOT/scripts/task-start" dirty-stop
printf 'uncommitted\n' > "$TEMP_ROOT/project-dirty-stop/dirty.txt"
if "$PROJECT_ROOT/scripts/task-stop" dirty-stop; then
  echo "Dirty task workspace was unexpectedly removed." >&2
  exit 1
fi
[ -d "$TEMP_ROOT/project-dirty-stop" ]
rm "$TEMP_ROOT/project-dirty-stop/dirty.txt"
"$PROJECT_ROOT/scripts/task-stop" dirty-stop

"$PROJECT_ROOT/scripts/task-start" ignored-stop
printf 'ignored proof\n' > "$TEMP_ROOT/project-ignored-stop/ignored-proof"
if "$PROJECT_ROOT/scripts/task-stop" ignored-stop; then
  echo "Task workspace with ignored files was unexpectedly removed." >&2
  exit 1
fi
[ -d "$TEMP_ROOT/project-ignored-stop" ]
rm "$TEMP_ROOT/project-ignored-stop/ignored-proof"
"$PROJECT_ROOT/scripts/task-stop" ignored-stop

"$PROJECT_ROOT/scripts/task-start" nested-db-stop
mkdir "$TEMP_ROOT/project-nested-db-stop/nested"
printf 'ignored database\n' > "$TEMP_ROOT/project-nested-db-stop/nested/keep.db"
if "$PROJECT_ROOT/scripts/task-stop" nested-db-stop; then
  echo "Task workspace with an ignored nested database was unexpectedly removed." >&2
  exit 1
fi
rm -rf "$TEMP_ROOT/project-nested-db-stop/nested"
"$PROJECT_ROOT/scripts/task-stop" nested-db-stop

echo "Task workspace lifecycle passed."
