# Project-host operations

Use this runbook for production deployment, PostgreSQL migration, backup,
restore rehearsal, and fresh-database recovery on `project-host`.
Before changing deployment guarantees, read
[ADR 0009](../adr/0009-automatic-project-host-deployment.md).

## Authority boundary

PostgreSQL is the authoritative application database. Deployments migrate the
schema, then start the application only after migration succeeds.

The host keeps `.env` and image-state files under
`/srv/projects/spacetraders`. Docker stores authoritative PostgreSQL data in the
`spacetraders_spacetraders-postgres` volume. Versioned deployment commands send
only committed Compose files and scripts. They do not send host secrets.

## Host setup

The host `.env` must define `PHX_HOST`, `SECRET_KEY_BASE`, `ENCRYPTION_KEY`, and
`POSTGRES_PASSWORD`. `POSTGRES_DB` and `POSTGRES_USER` default to
`spacetraders`. `GRAFANA_BASE_URL` optionally overrides the tailnet-only
observability URL used by contextual links; it contains no credentials.
`PHX_CHECK_ORIGINS` is an optional comma-separated Phoenix origin allowlist.
Use scheme-relative origins with the non-default port. Add both Tailscale names
when Operators use both, for example:

```text
//project-host:4000,//project-host.<tailnet>.ts.net:4000
```

Generate and append the PostgreSQL password on the host. This command does not
write the value to terminal output or repository files. Run it only when
`POSTGRES_PASSWORD` is absent:

```sh
password=$(openssl rand -hex 32)
printf 'POSTGRES_PASSWORD=%s\n' "$password" >> /srv/projects/spacetraders/.env
unset password
chmod 0640 /srv/projects/spacetraders/.env
```

Bootstrap the runner once as root. Then run the registration command that the
installer prints as an authenticated Operator:

```sh
sudo scripts/install-runner
```

Setup is complete when `.env` has mode `0640`, the runner service is active,
and its GitHub runner has the `project-host` label.

## Deploy

Pushes to `main` publish an immutable `sha-<commit>` image and queue one
deployment. The workflow uses the image, Compose files, and deployment script
from the same commit.

For a manual deployment from a Tailscale-connected checkout:

```sh
scripts/deploy deploy <sha|tag>
```

PostgreSQL must pass `pg_isready` before the one-shot `migrate` service runs.
The migration service migrates PostgreSQL, and `web` starts only after it
succeeds. Deployment is complete when `GET /health` returns `{"status":"ok"}`
and the host records the application image.

The health check allows a 60-second retry window for application startup. Each
request is capped at 10 seconds; a final request can finish after that window.

A failed deployment makes a best-effort attempt to start the previous image.
Fix failed releases and deploy forward when rollback cannot recover service.

## Kill switch

Stopping the `web` service is the only way to halt gameplay; there is no in-app
Emergency Stop ([ADR 0017](../adr/0017-nothing-needs-the-operator.md)).

```sh
tailscale ssh project-host docker stop spacetraders-web-1
```

The stop waits up to 60 seconds for graceful shutdown, then sends no further
game requests. Ships already in flight finish their legs in the game either
way. `restart: unless-stopped` keeps the container stopped across host reboots.
PostgreSQL stays up, so nothing is lost.

Resume with `tailscale ssh project-host docker start spacetraders-web-1`, or
deploy any image. Boot recovery reconciles unresolved mutations on start.

## PostgreSQL health and migration

Run the health check from a Tailscale-connected checkout:

```sh
scripts/deploy postgres-health
```

A deployment includes the repeatable migration lifecycle. Health verification
is complete when the command reports `accepting connections` and emits
`operation=health status=completed` with one `operation_id`.

## Purge gameplay data

`scripts/purge-gameplay` removes every Generation, Agent, Ship, Intent,
observation, calibration and outbox row. It preserves the deployment Operator
password hash and encrypted AccountToken, Operator sessions, the agent name
bank, and the runtime authority row. It rebuilds `current_fleet_identity` with
no Generation so boot reaches the `:empty` state.

There is no automatic backup. Inspect the table list and row counts first, then
execute:

```sh
scripts/deploy purge-gameplay --dry-run
scripts/deploy purge-gameplay --execute
```

`--execute` stops `web`, truncates and rebuilds in one transaction, verifies the
purged tables are empty and `preflight_current_fleet()` passes, then starts
`web`. Afterwards the Operator logs in and uses Settings to mint or import an
Agent. Purged rows cannot be restored without a dump taken beforehand.

## Backup

Create a backup on the host:

```sh
scripts/deploy postgres-backup backups/postgres-$(date -u +%Y%m%dT%H%M%SZ)
```

The command publishes one directory atomically. It contains `database.dump`,
`database.dump.sha256`, `manifest`, and `operation_id`. Copy the complete
directory to storage outside `project-host`, then apply the storage retention
policy. In the copied directory, run `sha256sum --check database.dump.sha256`.
Backup is complete when the command emits `operation=backup status=completed`,
the off-host copy has all four files, and its checksum passes.

## Restore rehearsal

Rehearse the newest retained backup after each schema change and at least once
per month:

```sh
scripts/deploy postgres-restore-rehearsal backups/<backup-directory>
```

The command verifies the dump checksum, restores to a temporary database, and
compares the hash and row count of each public table. It then removes the
temporary database. Rehearsal is complete when it emits
`operation=restore_rehearsal status=completed` with the backup `operation_id`,
table count, and row count.

## Fresh-database recovery

This procedure deletes the production PostgreSQL database. Use it only when no
usable PostgreSQL backup remains. Run it on `project-host` from the deployment
checkout:

```sh
export COMPOSE_PROJECT_NAME=spacetraders
export COMPOSE_FILE=compose.yaml:compose.production.yaml
docker compose down
docker volume rm spacetraders_spacetraders-postgres
docker compose run --rm migrate
docker compose run --rm web \
  bin/spacetraders eval 'Code.eval_file("priv/repo/seeds.exs")'
docker compose up -d
```

`web` stays stopped until PostgreSQL migration and reseeding complete. Recovery
is complete when `GET /health` returns `{"status":"ok"}` and the seeded Agent
and Fleet are visible to the Operator.
