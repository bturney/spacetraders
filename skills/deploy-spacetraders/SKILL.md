---
name: deploy-spacetraders
repo: bturney/spacetraders
description: >
  Deploy or redeploy the SpaceTraders Phoenix application on project-host.
  Use when the user asks to deploy, redeploy, release, restart, or roll back
  the production app, especially after a merge to main or when an image pull
  or registry DNS failure needs troubleshooting.
---

# Deploy SpaceTraders

Run the production deployment through Tailscale SSH. The canonical host
details and Compose commands are in the `Project-host deployment` section of
the repository `README.md`; read `README.md` in full before every deployment.

## Deploy

1. Confirm the merged commit's image is published. Refresh `origin/main` and
   use that merge commit, rather than the current feature branch HEAD:

   ```sh
   git fetch origin main
   SHA=$(git rev-parse origin/main)
   gh run list --workflow publish-image.yml --branch main --commit "$SHA" --limit 1 --json databaseId,headSha,status,conclusion
   ```

   If that run is in progress, wait with `gh run watch <run-id> --exit-status`.
   Completion criterion: the returned run has `headSha` equal to `SHA` and a
   successful conclusion. The publish workflow must expose the immutable
   `sha-$SHA` image tag.

2. Pull and restart the host with the immutable image tag. Project-host stores a
   Compose bundle, not a Git checkout, so validate the resolved image before
   pulling. Never copy, print, or inspect host secret values.

   ```sh
   IMAGE="ghcr.io/bturney/spacetraders:sha-$SHA"
   tailscale ssh project-host "cd /srv/projects/spacetraders && test \"\$(SPACETRADERS_IMAGE=$IMAGE docker compose -f compose.yaml -f compose.production.yaml config --images | sort -u)\" = \"$IMAGE\" && SPACETRADERS_IMAGE=$IMAGE docker compose -f compose.yaml -f compose.production.yaml pull && SPACETRADERS_IMAGE=$IMAGE docker compose -f compose.yaml -f compose.production.yaml up -d"
   ```

   Completion criterion: the resolved image is exactly `$IMAGE`, Compose exits
   successfully, and the `web` service is `Up` in `docker compose ... ps`.

3. Verify the application after startup.

   ```sh
   tailscale ssh project-host 'curl -fsS --retry 10 --retry-connrefused --retry-delay 1 --connect-timeout 5 --max-time 10 http://127.0.0.1:4000/health'
   ```

   Completion criterion: the command returns `{"status":"ok"}`.

## Registry failure

If the image pull reports that `ghcr.io` cannot resolve, test the host without
changing the deployment:

```sh
tailscale ssh project-host 'getent hosts ghcr.io; docker pull ghcr.io/bturney/spacetraders:latest'
```

Retry the deployment after registry DNS recovers. Do not remove the running
container when the pull fails; verify the existing service health instead.

## Rollback

Set `IMAGE` to a complete image reference, such as
`ghcr.io/bturney/spacetraders:previous-tag` or
`ghcr.io/bturney/spacetraders@sha256:<digest>`, then replace only the image
setting on the host without printing `.env`:

```sh
tailscale ssh project-host 'cd /srv/projects/spacetraders && IMAGE="ghcr.io/bturney/spacetraders:previous-tag" && SPACETRADERS_IMAGE="$IMAGE" docker compose -f compose.yaml -f compose.production.yaml pull && SPACETRADERS_IMAGE="$IMAGE" docker compose -f compose.yaml -f compose.production.yaml config --images'
```

Completion criterion: the pull succeeds and the final image listed is exactly
the selected rollback reference. Then run `up -d` with that same
`SPACETRADERS_IMAGE` value and repeat the health-check step. Update the host
`.env` separately only if future restarts must keep the rollback reference.
