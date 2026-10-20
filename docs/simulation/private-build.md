# Private simulator build-input handoff

**Tool boundary: read-only input/provenance validation, not runtime proof.** These
commands never start the application, build the simulator or invoke Docker.
The separate private standalone build/readiness checks below have passed; their
receipts are not manufactured by this validator. Fixture tests alone establish
neither execution approval nor a qualified artifact.

Source policy: [accepted #678 decision](https://github.com/bturney/spacetraders/issues/678#issuecomment-6126565823).
Use the selected private `bturney` fork preserving upstream history, supporting
only `sim/sim-erlang` and required dependencies. Retaining the upstream bot in
history does not adopt it as gameplay authority. This application's actual Fleet
remains the bot. No source or derived image redistribution is authorized.

## Read-only commands

```sh
mix simulation.artifact validate /private/retained/version
mix simulation.artifact identify /private/retained/version image.tar
```

`validate` checks the closed manifest contract, private permissions, byte
checksums, a self-contained Git bundle, pinned commits, upstream ancestry, and
the presence of the supported source subtree. It clones only the retained bundle
into a temporary bare repository; it does not check out or execute source. No
remote is consulted. Missing source cannot be replaced with an image digest.

`identify` additionally reads one Docker-save image's config from a private local
archive. It checks the config's content ID and declared platform, hashes the
whole archive, and binds these facts to the input identity. It does **not** verify
layer contents, load the image, or establish that it builds or boots. Only
selected regular metadata members of at most 1 MiB are read into memory. The
receiver must verify archive checksum, loaded image ID, layers and platform.

Both return allowlisted JSON with `qualification: "not_executed"`. Image records
also carry `verification: "archive_config_only"`. Never interpret these as a
readiness receipt. Private paths, raw Git errors, Docker environment, tags,
source, attachments and credentials are not exported. Unknown manifest fields
are rejected rather than copied. Compilation may print normal Mix output before
the JSON on a fresh checkout; downstream automation should call the module API
when it needs a structured result without CLI output.

## Private input contract, version 1

Keep `inputs.json` and all referenced inputs in a private retained version
directory, **outside the public source repository and disposable prototype
storage**. Directories must deny group/other access (normally `0700`), files must
deny group/other access (normally `0600`), and input paths must be relative,
without traversal or symlinks. Do not change retained inputs in place.

The manifest has exactly these fields:

| Field | Value |
| --- | --- |
| `schema_version` | `1` |
| `scope` | `standalone-http-world` |
| `fork_revision`, `upstream_revision` | Exact lowercase 40-character Git commit IDs; upstream must be an ancestor of fork |
| `api_schema_sha256` | SHA-256 of retained supported API schema bytes |
| `platform` | `linux/amd64` or `linux/arm64` |
| `permission` | `operator-reported-private-use`; provenance of the accepted decision, not independent legal verification |
| `toolchain` | Exactly `erlang_otp` and `rebar3`, each an exact numeric dotted version |
| `inputs` | Exactly the roles below; each value has only `path` and lowercase 64-character `sha256` |

| Input role | Retained content |
| --- | --- |
| `source_bundle` | Complete private fork Git bundle including pinned upstream/fork history, not a shallow/incremental bundle requiring unavailable objects |
| `dependencies_archive` | Required pinned dependency bytes, including an explicit empty inventory when appropriate |
| `dependency_lock` | Exact dependency identities/locks, or explicit revision-bound declaration of no dependencies |
| `api_schema` | Exact supported API contract; checksum must equal `api_schema_sha256` |
| `toolchain_archive` | Private offline builder/runtime images, compiler/build tools and necessary OS inputs; retain their content identities in the private inventory |
| `build_recipe` | Exact private build recipe defining the standalone serving closure, entry point, dependency consumption, builder identity and network prohibition |

The checks establish byte integrity, not the completeness or truth of a supplied
dependency/toolchain inventory, recipe safety, actual repository visibility,
actual tool versions, or API/mechanics compatibility. A successful fixture
validation cannot certify any of these. The recipe and inventories require
private source inspection and the approved offline rebuild/boot check below.

## Private input contract, version 2 (explicit build system)

Version 2 adds a closed, explicit build-system choice for recipes that use OTP's
`erlc` directly instead of rebar3. Its fields are **exactly** the version-1 fields
plus `build_system`, with `schema_version: 2`. All scope, permission, platform,
pin, checksum, path, private-retention and input-role requirements remain in force.

| `build_system` | Exact `toolchain` fields |
| --- | --- |
| `otp-erlc` | Only `erlang_otp`, pinning the OTP distribution including its compiler |
| `rebar3` | Only `erlang_otp` and `rebar3`, each independently pinned |

Every toolchain value must be an exact numeric dotted version (2–4 components,
for example the inert fixture version `28.1`), not a major-only release, mutable
alias, missing/null value, `not-used` placeholder or inferred version. Do not
invent a rebar3 version for a compiler-only recipe or add a separate `erlc`
version field. Unknown schema versions, build systems, fields and toolchain
keys, and mismatched build-system/toolchain combinations are rejected.

Both profiles require the retained bundle, pinned fork/upstream commits,
upstream ancestry and the supported `sim/sim-erlang/src` subtree. The rebar3
profiles (including version 1) also require the pinned `rebar.config`; the
compiler-only profile does not require an unused rebar configuration. This is
not a source, history or dependency-retention exemption. Zero external
dependencies still require the `dependencies_archive` and `dependency_lock`
roles with explicit empty/revision-bound inventories, alongside every other
retained input. These declarations do not prove the recipe uses only OTP or
has no dependencies; approved private inspection/build checks remain required.

Version-1 manifests remain valid without adding `build_system`; their sanitized
provenance and both identities are unchanged. Version 2 emits and hashes the
explicit schema version, build system and matching toolchain. The read-only
commands accept both versions without running either build system. Status stays
`not_executed` / `archive_config_only`; runtime receipts remain separate.

## Identity binding

`input_identity` hashes the sanitized manifest facts using recursively sorted
key/value-pair JSON. It excludes paths. `artifact_identity` additionally binds
the archive checksum, image config ID and platform. Changed input bytes, pins,
toolchain metadata, version-2 build-system facts or platform produce a different
identity. Retain the complete private manifest and bytes: sanitized provenance
cannot rebuild the simulator.

## Build/use gates still required

1. Provision/confirm the selected private fork and preserve history. Reconcile
   retained prototype modifications deliberately; dirty overlays are not exact
   executable revisions. Commit the private recipe/repairs privately, without
   publishing source or images to this public repository. Source access alone is
   not a redistribution grant.
2. Retain a complete offline input set and review the recipe's serving closure.
   Export only the pinned simulator subtree plus required dependencies into a
   clean private build context; never compile/run the upstream bot. Load pinned
   retained builder images locally; do not resolve mutable tags or pull missing
   bases. Record engine/build-tool versions and actual image/platform identities.
3. Keep ordinary local build/readiness regression checks bounded, with recorded
   exact inputs, resources, attempts, time limits and stopping rules. They do not
   require an additional approval checkpoint for ordinary implementation work.
   Real gameplay experiments, protected-host operations, capacity measurements
   and full-period qualification still require their separately approved immutable
   execution manifest. Default comparison budgets are not run approval. This
   module validates inputs; it is not a launch controller.
4. In the approved development-only isolation, deny **builder/daemon egress**,
   not just build-step networking. Use local pinned inputs, `--network=none`
   and `--pull=false`, no remote build contexts/frontends/ADD, registry, upstream
   fetches or host/live deployment. Those Docker flags alone do not prevent
   missing-base/frontend fetches. Perform an unavailable-upstream rebuild and
   verify representative real HTTP readiness plus pinned API identity from the
   actual artifact. Record measured results or failures, never inferred success.
5. Retain source, history, dependencies, locks, toolchains, recipe and image
   archives privately for retained comparisons; pin them while any comparison
   needs them. Manifests/reports are indefinite; full attempt evidence is at
   least 45 days and pinned until release. Image identity alone never permits
   deletion of rebuild inputs. Transfer only checksummed private archives through
   the separately approved host handoff; verify loaded identities before use.

Access loss stops new synchronization, not reuse of already authorized complete
retained inputs. Missing retained bytes block a rebuild; never fetch a mutable
replacement. Explicit permission withdrawal stops new build/use and returns to
the Operator for a decision. This tooling neither obtains permission nor
overrides withdrawal. Upstream contact, a registry, protected-host operations,
live credentials/network/database and simulator experiments are outside these
read-only commands.

## Downstream interfaces

`SpaceTraders.Simulation.Artifact.validate/2` and `identify/3` return
`{:ok, sanitized_map}` or `{:error, reason}`. Call them before admitting an
artifact, but require genuine build/readiness evidence and a separately approved
execution manifest where the execution gates above apply. Keep `input_identity`, `artifact_identity`, exact
commit/schema pins, platform, archive checksum, image ID, and explicit
qualification status in the durable runner record. Never promote
`not_executed`/`archive_config_only` into a qualified readiness state.

## Verified standalone handoff

The access-controlled [private implementation PR](https://github.com/bturney/spacetraders-simulator/pull/1)
is merged. Its executed recipe/source revision is
`1c084c5a519ce0f0bc5c7ebee7014039f1e10a05`, preserving upstream base
`2b68652afde4f30dd9005b572215ebdc3ac55a92`. A merge commit or a later source
revision must not be substituted for this executed pin.

- Two fresh offline builds of the revised standalone serving closure and two
  real-HTTP image-filesystem boots passed. The second build used copied retained
  inputs without the original checkout, cache or upstream access. The earlier
  two-build/two-boot results are retained separately, not replaced by the revised
  verification: four builds, four boots and 24 GET requests total, with no
  registration or gameplay mutation.
- Revised outputs match: image config ID
  `sha256:8aa715e5b589afe2aeaaae016a1a75e4e5d0c30cddc155bb074dfae5e841e21c`;
  archive SHA-256
  `992f10233ad9e87597cb9c5254ec3972b8e487b181a85b5296e14a7721e7a912`.
  The platform is `linux/amd64`, using OTP 27.3.4 without rebar3.
- Real retained bytes also pass this public compiler-only contract. Its canonical
  input identity is
  `sha256:4913666e0867b287ed9383538f4bd1d282896a758517ea8526b509ea47cf9259`;
  artifact identity is
  `sha256:17ce171a01f7113315a55b6dcef780752c866116987c49740c2774b8d1e43666`.
  These identities are distinct from the private inventory checksum. The public
  validator still reports `not_executed` and `archive_config_only`; separate
  bound runtime receipts establish the actual readiness checks.
- Source/history, dependencies, toolchain/OS inputs, recipes, artifacts and all
  original/revised receipts are retained owner-private outside temporary storage
  with checksummed inventories. The recorded combined allocation is 2.44 GiB,
  below that verification's 3 GiB cap; this is not proof of full-run retention fit.

The verified image filesystem ran in a no-egress namespace with enforced
1 CPU / 2 GiB / 128-task child limits. Actual image config/layer bytes and
source/input/contract bindings were checked before boot; contract drift and
provenance mismatches fail closed. **Docker-engine load/run remains unverified.**
Downstream bootstrap must verify its chosen runtime boundary instead of treating
namespace boot as Docker compatibility proof.

This handoff qualifies only reproducible standalone build and its bounded
GET-only readiness/API subset. It establishes no actual-bot/PostgreSQL
integration, authenticated gameplay, world controls, economic credibility,
protected-host capacity or 336-hour performance. The inherited bot/registry job
is guarded to its exact upstream repository and cannot run in this private fork.

Offline control coverage lives in
`test/spacetraders/simulation/artifact_test.exs`. It uses authored inert Git/tar
fixtures, removes the fake upstream before validation, and checks retention,
schema/identity binding, private output and negative controls. It does not run
Erlang simulator code or establish real artifact reproducibility.

Docker semantics: [build options](https://docs.docker.com/reference/cli/docker/build-legacy/),
[image save](https://docs.docker.com/reference/cli/docker/image/save/).
