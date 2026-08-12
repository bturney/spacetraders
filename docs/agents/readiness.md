# Agent Readiness

Runner contract and proof artifacts for `scripts/agent-run`.

## Runner Contract

Runner inputs: isolated checkout, network access to Hex, GitHub, and the pinned
Erlang distribution, `AGENT_TASK_ID`, positive `AGENT_ATTEMPT`, and optional
`AGENT_TASK_CLASS` (`implementation` or `qa`; defaults to `qa`). The hermetic
gate needs no game credentials; live-game verification needs runner-provided
API credentials.

The lifecycle validates identity, isolates Mix state and the HTTP port, runs the
canonical real-server gate, then tears down. Missing identity writes an
expected-failure record in a unique directory below
`artifacts/invalid-task/attempt-unknown/`.

Evidence lives at `artifacts/<task-id>/attempt-<attempt>/`: inputs, lifecycle
transcripts, manifest, and result. Inputs identify the source revision and exact
workspace digest. CI uploads the directory. The runner supplies no secret-bearing
environment variables to this unredacted lifecycle; live-game checks stay outside it.

Each `result.json` is a machine-readable trial record. It names the task class,
scenario, result type, verification target, allowed side effects, intervention and
retry counts, terminal status, failure class, duration, and artifact directory. A
no-diff lifecycle run produces `lifecycle-verification` for `checkout-health` and
may create task-scoped builds, test databases, and artifacts plus shared pinned-toolchain
cache and port-registry entries. Invalid or missing runner input produces an
`expected_failure` record in a unique directory under
`artifacts/invalid-task/attempt-unknown/`; its
`task_class` is `null` unless the supplied value was valid.

## Automation Path

| Stage | Input | Output and terminal condition | Owner |
| --- | --- | --- | --- |
| Triage | issue, acceptance criteria | owned task or terminal triage label | human or triage agent |
| Dispatch | task, base revision, target, risk | task and attempt IDs | automation platform |
| Provision | isolated checkout, runner inputs | bootstrap transcript or `runner/*` failure | runner |
| Execute | accepted task | change or QA observation | agent |
| Prove | change or QA target | verification transcript and result artifact | lifecycle |
| Submit | approved target, scoped identity | branch, PR, or QA report | automation platform |
| Reconcile | CI, review, acceptance | complete, retry, escalate, or fail | automation platform |
| Complete | reconciled result | durable terminal task state | issue tracker |

Nonterminal transitions retain artifacts. The automation platform owns retries,
escalation, provider authentication, and result submission.

## Enforcement Boundary

Scripts enforce inputs, isolation, bootstrap, verification, teardown, and
artifact location. Agents own interpretation, implementation, exploratory QA,
diagnosis, and task-specific proof.
