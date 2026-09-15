# Automatic project-host deployment after image publication

**Status:** accepted

Each successful `Publish image` run from `main` triggers a queued deployment on
the `project-host` self-hosted GitHub Actions runner. The workflow uses the
immutable `sha-<commit>` image, and deployments are serialized so rapid merges
are applied in publish order.

The published commit owns the deployment implementation and Compose bundle.
The automatic workflow checks out that exact commit. A manual deployment sends
the same files to a temporary directory on `project-host`. The routine uses the
host's `.env` and state files, validates the resolved images, starts the
services, and checks `/health`. It records an application image reference only
after a passing health check. A failed deployment makes a best-effort attempt to
reinstate the last recorded image with the current Compose bundle; when no state
file exists, it uses the current web container image as the rollback candidate.
This single-Operator service does not retain versioned Compose bundles. If image
rollback cannot recover service, the Operator creates a fresh PostgreSQL volume,
runs migrations, and reseeds authoritative PostgreSQL state.

The self-hosted workflow and the Tailscale-based `scripts/deploy` wrapper use the
same versioned routine and Compose files. The runner uses a dedicated account
with only the Docker and host-state access required for this deployment. Host
`.env` values are never emitted by either path.
