#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

config=$(SECRET_KEY_BASE=test ENCRYPTION_KEY=test PHX_HOST=example.test POSTGRES_PASSWORD=test \
  docker compose -f compose.yaml -f compose.production.yaml config --format json)

jq -e '
  .services.postgres.healthcheck.test == ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"] and
  .services.migrate.depends_on.postgres.condition == "service_healthy" and
  .services.web.depends_on.migrate.condition == "service_completed_successfully" and
  .services.web.environment.POSTGRES_HOST == "postgres" and
  .services.postgres.volumes[0].source == "spacetraders-postgres"
' <<<"$config" >/dev/null

images=$(SECRET_KEY_BASE=test ENCRYPTION_KEY=test PHX_HOST=example.test POSTGRES_PASSWORD=test \
  SPACETRADERS_IMAGE=example.test/spacetraders:sha-test \
  docker compose -f compose.yaml -f compose.production.yaml config --images | sort -u)
expected=$(printf '%s\n%s\n' example.test/spacetraders:sha-test postgres:17-alpine | sort -u)
[[ "$images" == "$expected" ]]
