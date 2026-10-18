# Portable attempt evidence

`scripts/attempt_export.py` owns a read-only export boundary, not a runner,
coordinator, mutation reconciler, restore tool or retention/cleanup policy.
It accepts evidence from the actual PostgreSQL and world/time owners. It never
creates missing game events, outcomes, explanations or monetary receipts.

## Commands

1. Capture a **simulation-only**, isolated database with explicit connection
   identity. Stop/fence application writers first when associating this snapshot
   with a separately stopped raw archive. PostgreSQL stays available for this
   read-only transaction; the exporter does not stop services itself.

   ```sh
   python3 scripts/attempt_export.py capture-database --host /PRIVATE/socket --port 5432 --user SIMULATION_USER --database sim_ATTEMPT --output PRIVATE/database.json
   ```

2. Optionally retain an already-stopped native authority directory into a new
   **private** archive. Its parent directory must have mode `0700`. This archive
   can contain credential tables: never attach it to a portable report, public
   fixture, diff preview or issue. The returned receipt contains hashes/counts,
   not raw rows or a source path. Attach that receipt as
   `sections.database.data.authority.raw_archive` in the request.

   ```sh
   python3 scripts/attempt_export.py retain-private-authority PRIVATE/stopped-pg PRIVATE/raw-authority.tar
   ```

3. Assemble the request below from the existing attempt owner and atomically
   publish to a **new** output name. Save stdout as the attempt-bound receipt in
   private storage. Never replace an original attempt after changing evidence.

   ```sh
   python3 scripts/attempt_export.py publish PRIVATE/request.json PRIVATE/attempt.zip
   ```

4. Verify offline, optionally checking the separately held raw archive and
   producing a new self-contained, escaped, script-free HTML drill-down.

   ```sh
   python3 scripts/attempt_export.py read PRIVATE/attempt.zip --receipt PRIVATE/receipt.json --private-authority PRIVATE/raw-authority.tar --html PRIVATE/attempt.html
   ```

5. Run the inert regression seam. No ports, private fixtures or game activity:

   ```sh
   mix test test/spacetraders/simulation/attempt_export_test.exs --max-failures 1
   ```

## Request contract

The JSON root has `metadata` and `sections`. All required fields are validated
before publishing, then validated again by the offline reader.

| Object | Required content |
| --- | --- |
| `metadata` | `schema = attempt/v1`, `identity`, `definition`, `provenance`, `resources`, `coverage`, `disposition`, nonempty `claim_limits` |
| `identity` | Distinct `definition = sha256:<canonical-definition-hash>`, `batch`, `logical_run`, `attempt` strings; copied exactly into every section and manifest |
| `definition` | Immutable declared inputs; `provenance` and `resources` must exactly match the corresponding metadata fields. Canonical JSON: sorted string keys, UTF-8, compact separators, no non-finite numbers |
| `provenance` | Exact 40-hex `application` and `simulator` source revisions; 64-hex `api` schema and application `build` artifact hashes; pinned `scenario`, `calibration`, and `strategy = {document, revision}`. Retain further image/toolchain/scenario/stream/build-input hashes in the definition; a digest does not replace authorized private rebuild inputs |
| `resources` | Recorded allocation/isolation plus `database` and `world_id`. Those names are checked against actual PostgreSQL/world payloads, not just section envelopes |
| `coverage` | `simulated = {start, end, unit: seconds}` in the world's time coordinates; disclose origin/mint and unsupported classes. `wall = {start, end, seconds}` with offset-bearing ISO timestamps and agreeing elapsed duration |
| `disposition` | `kind`: `completed`, `gate_noncompletion`, `bot_failure`, `harness_failure`, `infrastructure_timeout`, `interrupted`, or `startup_failed`; `cause`: retained explanation or explicit `unknown`. A completed **bounded diagnostic** is not full-period qualification |
| `sections` | Exactly `database`, `world`, `time`. Each has `identity`, `status`, and either `data` or an explicit absence reason |

`status = present` requires the section's data. `not_created` requires an explicit
startup-failure stage and reason; it does **not** serialize a fictitious empty
world/database. `not_captured` preserves an adverse/interrupted attempt but forces
`complete_export = false`. A completed attempt requires all three sections.
Required section omission, incomplete column/table inventory, changed identity,
broken known joins, Strategy/document disagreement or any hash mismatch fails
publication. Export completeness is distinct from achieved gameplay coverage.

The database section is `application-evidence/v1`, produced by
`capture_database/2`: one repeatable-read, read-only snapshot with explicit
column allowlists for all 28 currently supported evidence tables. It retains
all historical/unfinished rows, exact portable row counts/hashes, and exact
counts/reasons for excluded tables. Operators expose identity/chronology only;
Agents expose token-free registry identity. Password hashes, AccountTokens,
AgentTokens, session tokens and recovery ciphertext are never selected. New
columns/tables require a deliberate policy/schema update, not `SELECT *`.

The authoritative SQL snapshot is itself portable evidence, not a restorable
whole database. A private native archive has a separate verified file inventory;
its receipt binds archive bytes/counts/hashes, not a claim that independently
captured running services formed a consistent checkpoint. Capture while the
application is fenced/stopped; retain the attempt owner's capture boundary.
The raw archive remains private and optional to the offline portable reader.

The world section accepts the owner's `authoritative-world-export/v1` JSON.
Its deterministic Erlang-term state hash is reconstructed from **data only**;
RNG data is decoded through a bounded non-executable ETF subset. Functions,
exports, modules, PIDs, references, compressed/unknown tags and trailing bytes
are rejected. Tuples/improper RNG lists remain tagged data. There is no
`eval`, `binary_to_term`, function invocation, pickle loading or world restore.
`portable-world/v1` is also supported for independently authored evidence
schemas: `hash_encoding = canonical-json/v1`, `state_sha256` hashes the whole
object excluding those two hash fields. Neither schema is permission to put
private world payloads in the public repository.

The time section is `attempt-time/v1`: `start`, `end`, owner-supplied `trace`,
explicit `ordering`, and `unresolved`. It must agree with achieved coverage and
the world's final authoritative time. A frozen/native diagnostic must say so;
it cannot claim coordinator drain or world-before-bot qualification. The world
section independently retains actual scheduled events, request order, RNG,
quota state and unsupported-event coverage. No trace is invented from logs.

## Integrity, causal navigation and limits

`attempt-bundle/v1` is one stored ZIP containing `attempt.json`, three evidence
sections, `causal.json`, `summary.json`, `manifest.json`, and `manifest.sha256`.
Each member has SHA-256 and byte length. The reader checks the exact member
inventory, versions, hashes, identity/resource/Strategy agreement, row inventory,
retained joins, safe world hash/decoding, and regenerated summary/graph agreement.
It never extracts executable members. The current fail-closed portable limit is
128 MiB; exceeding it preserves originals rather than sampling required rows.
Larger evidence requires a later explicitly versioned streaming format/limit.

The graph namespaces every row by logical run and attempt. It retains Episode
→ Portfolio → Commitment (including replan Episode) → Intent → current **and
original/provenance-linked** MutationAttempts, retries, outcomes, referenced
observations and demand/Intelligence/credit links. Unknown reference formats and
missing causes remain explicit; a broken known retained join rejects export.
Net Earnings remains unknown without a complete attributed monetary ledger.

Publication writes a mode-`0600` staging file, fsyncs and verifies it, then uses an
exclusive same-filesystem hard link and directory fsync. Concurrent/repeated
publication cannot overwrite an existing output. A crash before the link leaves
only an unpublished staging file; a crash after the link leaves an independently
readable bundle. The receipt adds the whole ZIP hash, identity and measured
publication wall duration/time. Evidence-capture wall coverage and subsequent
publication overhead are separate measurements, not an invented total.

Checksums detect corruption/inconsistency, **not authenticity**: retain trusted
receipt hashes separately; `--receipt` also checks the whole archive's
hash/size/attempt identity against that trusted copy. Portable content is still private experiment data
unless separately authorized for sharing. Explicit allowlists plus recursive
credential/private-source-key and Bearer/JWT/PEM redaction are defense in depth,
not permission to ingest arbitrary dumps or publish unreviewed free text.

Every receipt says `cleanup_authorized = false`. Export failure never moves,
deletes, resets or changes original resources. Copy receipts, retention/pinning,
storage admission, cleanup eligibility and deletion belong to the runner and
#793, not this module. This implementation establishes no protected-host,
capacity, 45-day retention-fit, game-mechanics or 336-hour qualification.
