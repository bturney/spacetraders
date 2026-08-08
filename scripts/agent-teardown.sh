#!/usr/bin/env bash
# Always clean this checkout, then make the run outcome inspectable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_agent_context.sh"
agent_context_require

run_status="${AGENT_RUN_STATUS:-1}"
failure_class="${AGENT_FAILURE_CLASS:-execution/unclassified}"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
finished_epoch="$(date +%s)"
started_epoch="${AGENT_STARTED_EPOCH:-$finished_epoch}"
duration_seconds=$((finished_epoch - started_epoch))

set +e
"$SCRIPT_DIR/teardown" 2>&1 | tee "$AGENT_ARTIFACT_DIR/teardown.log"
teardown_status="${PIPESTATUS[0]}"
set -e

rm -rf "$AGENT_DEPS_DIR"
rm -rf "$AGENT_PROJECT_ROOT/.agent-mix/$AGENT_TASK_ID/attempt-$AGENT_ATTEMPT"

if [ "$run_status" -eq 0 ] && [ "$teardown_status" -eq 0 ]; then
  result="success"
  failure_class=""
else
  result="failure"
  if [ "$teardown_status" -ne 0 ]; then
    failure_class="cleanup/failed"
  fi
fi

printf '{"task_id":"%s","attempt":%s,"result":"%s","run_status":%s,"teardown_status":%s,"failure_class":"%s","duration_seconds":%s,"finished_at":"%s","artifacts":"%s"}\n' \
  "$AGENT_TASK_ID" "$AGENT_ATTEMPT" "$result" "$run_status" "$teardown_status" "$failure_class" "$duration_seconds" "$finished_at" "$AGENT_ARTIFACT_DIR" > "$AGENT_ARTIFACT_DIR/result.json"

files=()
for file in input.json bootstrap.log verify.log teardown.log result.json; do
  if [ -f "$AGENT_ARTIFACT_DIR/$file" ]; then
    files+=("\"$file\"")
  fi
done
files+=("\"manifest.json\"")

printf '{"task_id":"%s","attempt":%s,"files":[%s]}\n' \
  "$AGENT_TASK_ID" "$AGENT_ATTEMPT" "$(IFS=,; printf '%s' "${files[*]}")" > "$AGENT_ARTIFACT_DIR/manifest.json"

if [ "$teardown_status" -ne 0 ]; then
  exit "$teardown_status"
fi
