# Native-time bootstrap diagnostic (#779)

This is a local, opt-in real-HTTP regression boundary, **not** an experiment
runner, Docker-engine proof, accelerated clock, gameplay benchmark or full-period
qualification. No live endpoints, protected host, mutable #780 world, inherited
credentials or replacement gameplay policy. Ordinary production boot is unchanged.

## Boundary

One whole production BEAM release, normally migrated fresh PostgreSQL cluster,
and the verified #778 archive run in a new user/PID/IPC/UTS/network namespace.
Only loopback exists; no host home, deployment sockets or Docker socket is
mounted. A systemd user cgroup enforces 1 CPU, 3 GiB RAM/no swap, 256 tasks and
240 wall seconds. The real HTTP forwarding boundary allows at most 240 forwarded world requests
(including startup and retries), 1 MiB bodies and 3-second transport deadlines.
Exhaustion stops the attempt; denied forwarding is not free API quota.
The normal governor and protocol limiter remain enabled. Forwarding never
fabricates game responses and preserves rate-limit/Retry-After headers.

The closed manifest pins application release/source/lock/OpenAPI hashes, world
archive/image/source/checked-subset-contract, PostgreSQL filesystem archive, initial
world, exact Strategy document, random attempt/resource identities, sequence and
limits. Canonical SHA-256 is the definition identity; changing inputs or limits
changes it. The official app OpenAPI hash and world supported-subset contract are
**different contracts**, not a parity claim. Only the exact retained #778 artifact
is supported; the private merge commit and #780 branch are not substituted.

Normal startup commands are migration → semantic empty-world readiness → runtime
authority readiness → Operator registration → Agent mint → draft save/immutable
Strategy activation. There is no seeded Agent, intelligence, planner, manual
reconcile call, test HTTP transport or governor bypass. Success requires a
PostgreSQL-backed causal chain: selected Strategy Decision Episode → Portfolio →
Fleet Commitment → Intent → successful MutationAttempt, with acquired evidence.
Observation is read-only and never drives gameplay selection.

## Commands

Prerequisites: local Linux `bwrap`, user systemd/cgroup v2, a retained PostgreSQL 17 filesystem archive,
Python 3.13, pinned project toolchain and already-present dependencies. No package,
registry or upstream access occurs. Build from a **clean committed checkout**.
Use private storage outside `/tmp`; each prepare/start output must be new.

```sh
python3 scripts/native_bootstrap.py prepare \
  --repo "$PWD" --release "$PWD/_build/prod/rel/spacetraders" \
  --postgres /private/store/postgres-rootfs.tar --output /private/store/779-inputs

python3 scripts/native_bootstrap.py validate /private/store/779-inputs/manifest.json

python3 scripts/native_bootstrap.py start \
  --manifest /private/store/779-inputs/manifest.json \
  --application /private/store/779-inputs/application.tar \
  --world /private/retained-778/build-A/image.tar \
  --postgres /private/store/postgres-rootfs.tar --output /private/store/779-attempt
```

`prepare` compiles a production release (300-second build deadline), records
source/contract/lock provenance, and packages exact executable bytes. It does not
start the app or contact a game. `start` verifies archive/config/layer hashes
before boot. No inference from archive metadata to Docker compatibility is made:
the selected supported development boundary is actual filesystem boot under
bubblewrap. Missing isolation/resource support fails closed.

The PostgreSQL archive may be exported from an **already-local immutable image**
using a never-started `docker create --pull never --network none` container and
`docker export`. Record its image ID/archive hash and remove only that owned
stopped export container. No PostgreSQL container, Docker network, daemon-side
world or published host port is started. PostgreSQL and the world each execute
inside their own exact read-only root filesystem, sharing only the attempt's
private network namespace. Host PostgreSQL client packages are not a server.

Inherited database/game credentials, target variables and HTTP proxies are
rejected, not reused. Run from a clean environment if present; never supply live
values to satisfy the check. Each invocation gets new database/user, world memory,
application globals, encryption key, password and simulation-only AccountToken.
No local startup settings change production configuration outside explicit mode.

`result.json` records success/failure stage, wall time, request count and owned
shutdown. `runtime/bootstrap.json` contains only allowlisted durable IDs and chronology;
`runtime/http.jsonl` stores method/path/status/body hash and an allowlisted actual
navigation consequence, never auth headers or raw bodies. Success additionally
matches the successful HTTP navigation destination/Ship to the durable Intent.
Private logs, database, manifest, world readiness, isolation/cgroup receipt and
checksums remain in the attempt directory after success **and failure**. Never
publish that directory: it contains private world bytes and DB credentials.
The parent cgroup stop fences all descendants even when application startup fails.
The PostgreSQL data directory has a 128 MiB tmpfs ceiling and is copied privately
after normal shutdown. A hard cgroup death may interrupt that copy; no complete
export, retention or restart/recovery qualification is implied.
There is no automatic retry, evidence cleanup, restart/resume or experiment budget.

For bounded startup negative controls, copy the manifest to a **new definition**,
assign a new attempt identity and matching resource names, and set
`negative_control` to `migration_unavailable` or `world_unavailable`. These kill
the owned prerequisite before readiness; they must fail without minting and
retain diagnostics plus shutdown receipt. They are not mutation-fault/recovery
qualification. An exhausted/failed diagnostic remains an original outcome.

## Regression checks

```sh
mix test test/spacetraders/simulation/native_bootstrap_test.exs
python3 -m unittest discover -s test/integration -p native_bootstrap_test.py -v
```

The ordinary suite runs only inert manifest/configuration checks. The explicit
`start` command is the bounded whole-app diagnostic. Real experiments, campaign
execution, protected-host capacity and full-period qualification retain their
separate approval, manifest and budget gates.
