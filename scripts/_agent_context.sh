#!/usr/bin/env bash
# Shared task-scoped artifact convention for unattended agent runs.
set -euo pipefail

AGENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_PROJECT_ROOT="$(cd "$AGENT_SCRIPT_DIR/.." && pwd)"

agent_context_invalid_result() {
  local failure_class="$1"
  local finished_at
  local artifact_dir
  local task_class="null"

  case "${AGENT_TASK_CLASS:-}" in
    implementation | qa) task_class="\"$AGENT_TASK_CLASS\"" ;;
  esac

  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  artifact_dir="$AGENT_PROJECT_ROOT/artifacts/invalid-task/attempt-unknown/${finished_at//:/-}-$$"
  mkdir -p "$artifact_dir"
  printf '{"task_class":%s,"scenario":"invalid-runner-input","result":"expected_failure","result_type":"lifecycle-verification","target":"runner-contract","allowed_side_effects":"artifacts-only","human_interventions":0,"duration_seconds":0,"retries":0,"failure_class":"%s","finished_at":"%s","artifacts":"%s"}\n' \
    "$task_class" "$failure_class" "$finished_at" "$artifact_dir" > "$artifact_dir/result.json"
}

agent_context_require() {
  if [[ -z "${AGENT_TASK_ID:-}" || -z "${AGENT_ATTEMPT:-}" ]]; then
    AGENT_CONTEXT_FAILURE_CLASS="runner/missing_task_identity"
    echo "AGENT_TASK_ID and AGENT_ATTEMPT are required runner inputs." >&2
    return 64
  fi

  if [[ ! "$AGENT_TASK_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    AGENT_CONTEXT_FAILURE_CLASS="runner/invalid_task_id"
    echo "AGENT_TASK_ID must begin with a letter or digit and may then contain periods, underscores, or hyphens." >&2
    return 64
  fi

  if [[ ! "$AGENT_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
    AGENT_CONTEXT_FAILURE_CLASS="runner/invalid_attempt"
    echo "AGENT_ATTEMPT must be a positive integer." >&2
    return 64
  fi

  export AGENT_TASK_CLASS="${AGENT_TASK_CLASS:-qa}"
  if [[ "$AGENT_TASK_CLASS" != "implementation" && "$AGENT_TASK_CLASS" != "qa" ]]; then
    AGENT_CONTEXT_FAILURE_CLASS="runner/invalid_task_class"
    echo "AGENT_TASK_CLASS must be implementation or qa." >&2
    return 64
  fi

  export AGENT_ARTIFACT_DIR="$AGENT_PROJECT_ROOT/artifacts/$AGENT_TASK_ID/attempt-$AGENT_ATTEMPT"
  export AGENT_DEPS_DIR="$AGENT_PROJECT_ROOT/.agent-deps/$AGENT_TASK_ID/attempt-$AGENT_ATTEMPT"
  mkdir -p "$AGENT_ARTIFACT_DIR"
}
