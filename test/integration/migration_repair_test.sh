#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source scripts/_toolchain.sh

database="spacetraders_migration_repair_$$"
export DATABASE_URL="postgres://postgres:postgres@127.0.0.1/$database"

cleanup() {
  MIX_ENV=test mix ecto.drop --quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT

MIX_ENV=test mix ecto.create --quiet
MIX_ENV=test mix ecto.migrate --to 20260923010000
MIX_ENV=test mix run -e 'Ecto.Adapters.SQL.query!(SpaceTraders.Repo, "ALTER TABLE strategy_decision_episodes DROP COLUMN actual_outcomes")'
MIX_ENV=test mix ecto.migrate

result=$(MIX_ENV=test mix run -e 'result = Ecto.Adapters.SQL.query!(SpaceTraders.Repo, "SELECT count(*) FROM information_schema.columns WHERE table_schema = '\''public'\'' AND table_name = '\''strategy_decision_episodes'\'' AND column_name = '\''actual_outcomes'\''"); IO.puts(result.rows |> hd() |> hd())')
[[ "$result" == "1" ]]
