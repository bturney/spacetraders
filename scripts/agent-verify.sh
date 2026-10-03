#!/usr/bin/env bash
# Activate the prepared runner environment, then retain the product gate transcript.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_agent_context.sh"
agent_context_require
source "$SCRIPT_DIR/_toolchain.sh"

"$SCRIPT_DIR/verify" 2>&1 | tee "$AGENT_ARTIFACT_DIR/verify.log"
