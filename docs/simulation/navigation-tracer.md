# Coordinated navigation tracer (#781)

`navigation-tracer/v1` is a bounded extension of the [isolated bootstrap](native-bootstrap.md),
not a general runner or complete accelerated-runtime qualification. It boots the
actual production application, fresh normally migrated PostgreSQL and a newly
pinned private controlled world over real HTTP. No test transport, injected
intelligence, replacement policy, runtime recompilation or process suspension.

## Run boundary

Normal registration → mint → immutable Strategy activation remain unchanged.
The bot selects an intelligence Commitment and navigates autonomously. Success
requires retained Episode → Portfolio → Commitment → completed intelligence Intent
→ original successful navigation MutationAttempt provenance, a done durable
Arrival, and an authoritative post-Arrival Market observation. Completed Intents
clear their current mutation pointer; the proof follows retained provenance.

The coordinator changes time only, never gameplay selection. It barriers the
registered Reconciler, DemandScheduler, ReadCoordinator, Outbox and dynamic
ShipServers; callbacks account for their synchronous work, HTTP/DB operations,
local notifications and newly generated callbacks. Released clock messages must
be acknowledged. Drain repeats until the work revision is unchanged, no callback
or released wake remains, governed requests are settled, and durable work is
classified. PG pending Arrival rows must have an explicit future clock owner;
unarmed rows, other unfinished root types/events, unresolved mutation attempts,
owner loss or a 30-second wall drain timeout prevent further advancement.

At the minimum next supported world event, bot wake or 180-second diagnostic
horizon, world settlement returns **before** application clock release. The
ordered trace records strictly increasing boundaries and world-before-bot order.
The authoritative world request log independently proves Ship refresh and Market
continuation after Arrival settlement at that same instant. The diagnostic drains
spawned work at the completed instant before stopping, including a newly selected
intelligence root waiting for its next Arrival.

## Inputs and commands

Use a **new** private `controlled-world-artifact/v1` receipt and its exact archive,
not the frozen #778 native image or a #780 component compile directory. The private
supported artifact builder retains source/toolchain inputs, compiles the serving
closure offline, packages `serve-controlled` with its secret-file interface, and
records new archive/image/source/input-inventory/canonical control-contract hashes.
The launcher verifies these identities, image labels and the actual HTTP contract.
No Docker-engine compatibility is inferred from filesystem boot.

```sh
python3 scripts/native_bootstrap.py prepare \
  --repo "$PWD" --release "$PWD/_build/prod/rel/spacetraders" \
  --postgres /private/postgres-rootfs.tar \
  --controlled-world /private/new-build/controlled-artifact.json \
  --output /private/new-app-inputs

python3 scripts/native_bootstrap.py start \
  --manifest /private/new-app-inputs/manifest.json \
  --application /private/new-app-inputs/application.tar \
  --world /private/new-build/controlled-image.tar \
  --postgres /private/postgres-rootfs.tar --output /private/new-attempt
```

The closed definition pins the generated starter, three independently named
streams, epoch/reset date, normal starting resources, exact Strategy and isolated
attempt identities. Existing bootstrap limits apply: 1 CPU, 3 GiB/no swap, 256
tasks, 240 total wall seconds, shared 45-second startup budget, 240 forwarded game
requests, 1 MiB proxy bodies, three-second transport safeguards and 2 GiB/attempt
storage admission. Additional fixed ceilings: 180 simulated seconds/advancements,
500 coordinator control requests, 256 events per settlement. All artifacts,
databases, controller credentials and exports stay private. Owned shutdown is
positively inspected on both success and failure; original attempts are retained.

For the explicit negative control, create a new valid definition/attempt identity
and set `negative_control` to `incomplete_drain`. An owned participant intentionally
leaves one operation unresolved. The expected underlying result is a retained
`harness_failure`, zero world advancement/settlement, `drain-failure.json`, and
verified shutdown—not a successful gameplay result. Never overwrite the positive
definition or relabel an earlier receipt.

## Demonstrated coverage and gaps

This is **navigation prerequisite + Arrival + intelligence continuation** only.
The closed synchronous participant set and durable Arrival classification are not
complete durable draining (#784). Observation Demand reconstruction, all semantic
timestamp sites, schema chronology and other mechanics remain #782/later work.
The actual governor, protocol limiter, MutationAttempts and world quotas remain
active. Their existing wall pacing/retries are deliberately not accelerated here;
queued operations block drain. Capacity-release/429/outage qualification remains
#783. Transport deadlines, PG health and runtime authority liveness stay wall time.

The world artifact includes supported Arrival/economic/rival scheduling, but this
short starter does not reach the first economic tick or exercise rival scenarios.
No trade/fuel qualification, complete world mechanics, crash/restart recovery,
portable complete export, first gate, 336-hour coverage, speed/capacity claim or
campaign approval follows. Production defaults outside explicit mode are unchanged.

Ordinary regression (no world/port boot):

```sh
mix test test/spacetraders/simulation --max-failures 1
python3 -m unittest discover -s test/integration -p native_bootstrap_test.py -v
```
