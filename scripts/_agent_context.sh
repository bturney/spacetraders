#!/usr/bin/env bash
# Shared task-scoped artifact convention for unattended agent runs.
set -euo pipefail

AGENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_PROJECT_ROOT="$(cd "$AGENT_SCRIPT_DIR/.." && pwd)"

agent_context_require() {
  : "${AGENT_TASK_ID:?AGENT_TASK_ID is required; the runner must assign a task identifier}"
  : "${AGENT_ATTEMPT:?AGENT_ATTEMPT is required; the runner must assign a positive attempt number}"

  if [[ ! "$AGENT_TASK_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "AGENT_TASK_ID must begin with a letter or digit and may then contain periods, underscores, or hyphens." >&2
    return 64
  fi

  if [[ ! "$AGENT_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
    echo "AGENT_ATTEMPT must be a positive integer." >&2
    return 64
  fi

  export AGENT_ARTIFACT_DIR="$AGENT_PROJECT_ROOT/artifacts/$AGENT_TASK_ID/attempt-$AGENT_ATTEMPT"
  export AGENT_DEPS_DIR="$AGENT_PROJECT_ROOT/.agent-deps/$AGENT_TASK_ID/attempt-$AGENT_ATTEMPT"
  mkdir -p "$AGENT_ARTIFACT_DIR"
}
