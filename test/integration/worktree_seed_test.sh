#!/usr/bin/env bash
# A fresh worktree with no deps/ or _build/ runs `mix test <file>` green with
# no prior command: the test alias seeds both from the main checkout (#619).
# Cold run copies and recompiles only app files; warm run copies and compiles
# nothing; the main checkout is never written.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

FILE="${1:-test/spacetraders/checkout_db_test.exs}"
MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
[[ -d "$MAIN/deps" && -d "$MAIN/_build/test" ]] || {
  echo "main checkout $MAIN needs deps/ and _build/test (run mix setup there once)" >&2
  exit 1
}

scratch="$(mktemp -d /tmp/seedtest.XXXXXX)"
wt="$scratch/wt"
export PGPASSWORD=postgres
db=""
cleanup() {
  if [[ -d "$wt" ]]; then
    db="$(cd "$wt" && MIX_ENV=test mix run --no-start --no-deps-check -e \
      'IO.puts(SpaceTraders.Repo.config()[:database])' 2>/dev/null | tail -1 || true)"
  fi
  git -C "$ROOT_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$scratch"
  if [[ -n "$db" ]]; then
    dropdb -h 127.0.0.1 -U postgres --if-exists "$db" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

newest_in_main() {
  find "$MAIN/deps" "$MAIN/_build/test" -type f -printf '%T@\n' | sort -n | tail -1
}

git worktree add --detach "$wt" HEAD >/dev/null 2>&1
# Exercise the working-tree state of the checkout under test, not just HEAD.
git diff HEAD --binary | git -C "$wt" apply --allow-empty

[[ ! -e "$wt/deps" && ! -e "$wt/_build" ]]
main_stamp="$(newest_in_main)"

cd "$wt"
run() {
  local start end
  start=$(date +%s.%N)
  mix test "$FILE" >"$scratch/$1.log" 2>&1 || {
    cat "$scratch/$1.log" >&2
    echo "FAIL: $1 run" >&2
    exit 1
  }
  end=$(date +%s.%N)
  printf '%s run: %.1fs\n' "$1" "$(awk "BEGIN{print $end - $start}")"
}

run cold
if grep -q "==> " "$scratch/cold.log"; then
  echo "FAIL: cold run compiled dependencies" >&2
  exit 1
fi

touch "$scratch/mark"
run warm
if grep -q "Compiling\|==> " "$scratch/warm.log"; then
  echo "FAIL: warm run compiled" >&2
  exit 1
fi
if [[ -n "$(find deps _build/test -newer "$scratch/mark" -type f ! -name .mix_test_failures -print -quit)" ]]; then
  echo "FAIL: warm run rewrote deps/ or _build/" >&2
  exit 1
fi

if [[ "$(newest_in_main)" != "$main_stamp" ]]; then
  echo "FAIL: main checkout was written" >&2
  exit 1
fi
echo "worktree seed: ok"
