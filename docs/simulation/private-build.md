# Private simulator build-input handoff

**Status: input/provenance tooling only; #778 is not complete.** No real simulator
build, boot, HTTP readiness check, unavailable-upstream rebuild, or reproducibility
qualification has been performed by this implementation. These commands never
start the application or invoke Docker. Fixture tests are not execution approval.

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

`input_identity` hashes the sanitized manifest facts using recursively sorted
key/value-pair JSON. It excludes paths. `artifact_identity` additionally binds
the archive checksum, image config ID and platform. Changed input bytes, pins,
toolchain metadata or platform produce a different identity. Retain the complete
private manifest and bytes: sanitized provenance cannot rebuild the simulator.

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
3. Before any build/boot verification, obtain the required approved immutable
   execution manifest, resource/attempt/time bounds and stopping rules. This
   ticket, its commands and default comparison budgets authorize no execution.
   A runner must enforce these gates; this module is not a launch controller.
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
artifact, but require a separate approved execution manifest and genuine
build/readiness evidence. Keep `input_identity`, `artifact_identity`, exact
commit/schema pins, platform, archive checksum, image ID, and explicit
qualification status in the durable runner record. Never promote
`not_executed`/`archive_config_only` into a qualified readiness state.

Offline control coverage lives in
`test/spacetraders/simulation/artifact_test.exs`. It uses authored inert Git/tar
fixtures, removes the fake upstream before validation, and checks retention,
schema/identity binding, private output and negative controls. It does not run
Erlang simulator code or establish real artifact reproducibility.

Docker semantics: [build options](https://docs.docker.com/reference/cli/docker/build-legacy/),
[image save](https://docs.docker.com/reference/cli/docker/image/save/).
