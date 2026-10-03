#!/usr/bin/env bash
# Verify the product gate delegates to Mix without provisioning prerequisites.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

mkdir -p "$TEMP_ROOT/bin"
cat > "$TEMP_ROOT/bin/mix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'MIX_ENV=%s\nDATABASE_URL=%s\nARGS=%s\n' "$MIX_ENV" "$DATABASE_URL" "$*" >> "$GATE_CALL"
if [[ -n "${AGENT_TASK_ID:-}" || -n "${AGENT_ATTEMPT:-}" ]]; then
  echo "Product gate unexpectedly depends on runner identity." >&2
  exit 64
fi
exit "${MIX_EXIT_STATUS:-0}"
EOF
chmod +x "$TEMP_ROOT/bin/mix"

export DATABASE_URL="postgres://gate-test:gate-test@localhost/gate_test"
export GATE_CALL="$TEMP_ROOT/call"
env -u AGENT_TASK_ID -u AGENT_ATTEMPT PATH="$TEMP_ROOT/bin:$PATH" bash "$ROOT_DIR/scripts/verify"

expected="MIX_ENV=test
DATABASE_URL=$DATABASE_URL
ARGS=verify"
actual="$(<"$GATE_CALL")"
if [[ "$actual" != "$expected" ]]; then
  printf 'Expected product gate to invoke only mix verify with caller configuration.\n' >&2
  printf 'Actual invocation:\n%s\n' "$actual" >&2
  exit 1
fi

if env -u AGENT_TASK_ID -u AGENT_ATTEMPT MIX_EXIT_STATUS=37 PATH="$TEMP_ROOT/bin:$PATH" \
  bash "$ROOT_DIR/scripts/verify"; then
  echo "Product gate unexpectedly succeeded when Mix failed." >&2
  exit 1
else
  gate_status=$?
fi
if [[ "$gate_status" -ne 37 ]]; then
  printf 'Expected product gate to preserve Mix exit status 37, got %s.\n' "$gate_status" >&2
  exit 1
fi

mkdir -p "$TEMP_ROOT/empty-bin"
if missing_mix_output="$(PATH="$TEMP_ROOT/empty-bin" /bin/bash "$ROOT_DIR/scripts/verify" 2>&1)"; then
  echo "Product gate unexpectedly passed without Mix on PATH." >&2
  exit 1
fi
if [[ "$missing_mix_output" != *"mix is not available on PATH"* ]]; then
  printf 'Missing Mix failure was unclear:\n%s\n' "$missing_mix_output" >&2
  exit 1
fi

echo "Product gate consumes the prepared environment."
