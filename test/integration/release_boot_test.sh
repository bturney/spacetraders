#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source scripts/_toolchain.sh

MIX_ENV=prod mix release --overwrite
secret_key=$(openssl rand -hex 32)
encryption_key=$(openssl rand -base64 32)
log_file=$(mktemp)
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -f "$log_file"
}
trap cleanup EXIT

PHX_SERVER=true RELEASE_NAME=spacetraders PORT=4010 \
POSTGRES_HOST=127.0.0.1 POSTGRES_DB=spacetraders_test POSTGRES_USER=postgres \
POSTGRES_PASSWORD=postgres SECRET_KEY_BASE="$secret_key" \
ENCRYPTION_KEY="$encryption_key" PHX_HOST=example.test \
  _build/prod/rel/spacetraders/bin/spacetraders start >"$log_file" 2>&1 &
app_pid=$!

response=""
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  if response=$(curl --fail --silent --show-error --max-time 1 http://127.0.0.1:4010/health 2>/dev/null); then
    break
  fi
done

[[ "$response" == '{"status":"ok"}' ]] || {
  python3 -c 'import pathlib,sys,re; text=pathlib.Path(sys.argv[1]).read_text(); text=re.sub(r"(?i)(password|secret|token|authorization|encryption_key)([=: ]+)[^ ]+", r"\1\2<REDACTED>", text); print(text[-4000:], file=sys.stderr)' "$log_file"
  exit 1
}
