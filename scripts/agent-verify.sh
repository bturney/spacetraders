#!/usr/bin/env bash
# Run the canonical real-surface gate and retain its complete transcript.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_agent_context.sh"
agent_context_require

"$SCRIPT_DIR/verify" 2>&1 | tee "$AGENT_ARTIFACT_DIR/verify.log"
