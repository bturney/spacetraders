# Automatic project-host deployment after image publication

**Status:** accepted

Each successful `Publish image` run from `main` triggers a queued deployment on
the `project-host` self-hosted GitHub Actions runner. The workflow uses the
immutable `sha-<commit>` image, and deployments are serialized so rapid merges
are applied in publish order.

The host owns the deployment implementation at
`/srv/projects/spacetraders/deploy`. It validates the resolved Compose image,
pulls it, starts the services, and checks `/health`. It records a reference
only after a passing health check. A failed deployment automatically reinstates
the last recorded image; when no state file exists, it uses the current web
container image as the rollback candidate.

The same host routine is used by the self-hosted workflow and the
Tailscale-based `scripts/deploy` wrapper. The runner uses a dedicated account
with only the Docker and compose-bundle access required for this deployment.
Host `.env` values are never emitted by either path.
