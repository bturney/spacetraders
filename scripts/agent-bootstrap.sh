#!/usr/bin/env bash
# Prepare a task-scoped checkout and record the runner inputs used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_agent_context.sh"
agent_context_require

if [ -e "$AGENT_ARTIFACT_DIR/input.json" ]; then
  echo "Attempt $AGENT_TASK_ID/$AGENT_ATTEMPT already has evidence; allocate a new attempt." >&2
  exit 73
fi

"$SCRIPT_DIR/worktree-setup" "$AGENT_TASK_ID" 2>&1 | tee "$AGENT_ARTIFACT_DIR/bootstrap.log"

revision="$(git -C "$AGENT_PROJECT_ROOT" rev-parse HEAD)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
workspace_digest="$(
  {
    git -C "$AGENT_PROJECT_ROOT" diff --binary HEAD
    git -C "$AGENT_PROJECT_ROOT" ls-files --others --exclude-standard -z |
      while IFS= read -r -d '' file; do
        printf 'untracked:%s\0' "$file"
        sha256sum "$AGENT_PROJECT_ROOT/$file"
      done
  } | sha256sum | cut -d ' ' -f 1
)"

printf '{"task_id":"%s","attempt":%s,"source_revision":"%s","workspace_digest":"%s","started_at":"%s","producer":"scripts/agent-bootstrap.sh"}\n' \
  "$AGENT_TASK_ID" "$AGENT_ATTEMPT" "$revision" "$workspace_digest" "$started_at" > "$AGENT_ARTIFACT_DIR/input.json"
