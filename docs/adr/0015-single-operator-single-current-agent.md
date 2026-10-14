# One authenticated Operator and one current Agent

Status: Accepted

The deployment serves one authenticated Operator and at most one current Agent.
Authentication identity controls application authority; Agent and Fleet Generation
identities preserve game-generation provenance. Empty setup and fenced replacement
states are valid. Historical identities never form another tenant-routing mechanism
or a second concurrently commanded Fleet. This supersedes ADR 0006's multi-Operator
rationale while retaining encrypted AccountToken and AgentToken storage in PostgreSQL.

## Lifecycle and authority

Fleet Generation remains the owner of registration, bootstrap and replacement,
extending [ADR 0010](0010-autonomous-runtime.md). Definitive Server Reset evidence
fences predecessor gameplay before replacement. Try the current name and faction
first, then the remaining Agent Name Bank in order only after definitive name
conflicts. Initial preferences are ORBITALIST, PARALLAX, APHELION, SIDEREAL and
LIMINAL; duplicates do not cause repeated attempts, and generated suffixes are not
approved names. Settings preserves durable preferences and unsaved form drafts.

AccountToken is minting authority; AgentToken is generation-specific gameplay
authority. Runtime authority, API Capacity Governor admission, Emergency Stop and
authenticated Operator controls retain their boundaries. Registration uncertainty
belongs in MutationAttempts under [ADR 0011](0011-single-recovery-authority-for-mutations.md),
never a parallel registration ledger. Symbol occupancy proves neither account
ownership nor a recoverable AgentToken. Lost responses fence another mint until
reconciled; interrupted successful adoption continues that identity rather than
consuming another candidate.

Voluntary Agent Replacement is conditional on clean reuse of the existing lifecycle;
a substantial new subsystem is grounds for explicit deferral. Confirmation durably
pauses predecessor mutations; definitive failure leaves it paused until authenticated
retry or explicit resume. Unresolved registration forbids remint and resume. No
liquidation, objective completion, upstream deletion or resource transfer is required.
Late predecessor results retain original attribution and never update successor resources.

Fleet Strategy and revisions survive replacement. Generation-scoped objective
progress starts fresh, recurring progress restarts, and Strategy-lifetime contributions
remain. Retain meaningful Agent, Generation, Ship and causal evidence identities;
do not overwrite one permanent Agent record to erase generation boundaries.

## Adoption and completed contraction

Preflight automatically adopts empty or unambiguous sole-Operator installations
with zero or one current Agent. Retired Generations remain history; multiple plausible
Operators/current Agents, missing ownership or inconsistent relationships stop with
actionable resolution before schema contraction or autonomous startup. Never select
the newest record, merge credentials or delete competitors. Adoption and rerun preserve
encrypted credentials, accepted Strategy, game state and causal history.

T1 (#695) performs legacy adoption in an actual PostgreSQL migration. T10 (#704)
preflights again before irreversible contraction, removes tenant foreign keys and
indexes, and retains original `operator_id` values as authorship/causal attribution,
not Ecto associations or resource routing. Authentication/session relationships and
Agent, Ship, Generation, Revision, Episode and Evidence foreign keys remain meaningful.
Generation numbering and the Fleet Strategy are deployment-wide. The published
identity restricts deletion of its Operator and Generation.

Current Fleet reads, Strategy review, allocation, execution, resume and reset resolve
the same published Generation. Boot synchronously validates the completed schema and
identity before autonomous children; it never adopts raw legacy writers. Registration
recovery and atomic lifecycle publication remain the only establishment path. Existing
Agent selectors and tenant subscriptions are retired. Explicit `generation=` entity
links read historical evidence only; current entity links have no identity selector.

DDL contraction and its version publication share one migration transaction. Failed
preflight or interrupted DDL retains the earlier schema and records; rerun repeats
preflight. Rollback after completed irreversible contraction requires a pre-contraction
backup, not guessed ownership reconstruction. Product and separate operational checks
are documented in `docs/agents/testing.md`. Optional voluntary replacement (#705)
is explicitly deferred as described below, not a mandatory-core gate.

## Optional voluntary replacement: deferred (#705)

Outcome after inspecting the integrated #701/#703/#704 lifecycle at `f787145`:
**do not expose voluntary replacement**. Initial mint/import, automatic Server
Reset replacement, Name Bank editing and registration reconciliation remain
supported. This is the conditional deferral approved by
[#705](https://github.com/bturney/spacetraders/issues/705), not delivery of its
implementation-only confirmation/failure/resume criteria.

Registration itself has strong reuse: `FleetGeneration.Registration.with_authority/1`
serializes establishment with a PostgreSQL session lock while MutationAttempts
commits dispatch, uncertainty, encrypted successful identity and adoption independently.
`register_first_available/3` advances only on definitive code 4103 conflicts;
`adopt_registration/2`, `establish_generation!/6` and `generation_progress/2`
already preserve Strategy, original identities and scope-correct progress. These
capabilities are not the blocker, and no parallel registration ledger is needed.

The missing capability is a **durable, reversible, generation-specific abandonment
pause**, distinct from both definitive Server Reset fencing and Emergency Stop.
The following existing boundaries prevent a safe thin UI wrapper:

| Boundary | Concrete evidence and consequence |
| --- | --- |
| Generation and current identity | `FleetGeneration.Generation` has `fenced_at` and `retired_at`, but no pause reason/version or voluntary-transition state. `Identity.read!/0` projects either healthy `:current` or ended `:transition`; `gameplay_authority/1` rejects fenced Generations, while `publish_generation!/2` permits replacing only an ended/empty predecessor. A healthy predecessor cannot simply use the existing mint allowlist. |
| Reset fencing and restart | `FleetGeneration.mark_stale/1` marks the Agent `stale_at`, fences its token, supersedes Neutral Wait and withdraws Observation Demands. `FleetGenerationAdmission.init/1` reconstructs token fences from `stale_at`; there is no per-token authenticated unfence operation. `server_reset_replacement/1` requires both stale Agent and fenced Generation, then tries the predecessor symbol first. Reusing that path invents reset evidence and gives voluntary replacement the wrong candidate order. Boot calls `resume_reset_replacement/0`, not an authenticated retry policy for voluntary failure. |
| Resume and admission | `FleetStrategy.resume/2` and `complete_emergency_stop_resume/2` control a deployment-wide Emergency Stop version. `mutation_allowed?/0` suppresses registration too. Emergency Stop cannot pause only predecessor gameplay while permitting minting, and its resume does not reconcile a voluntary registration. `Evidence.refresh_for_emergency_stop_resume/1` skips transition identities; clearing a Generation fence through this path would not authoritatively refresh the healthy predecessor. |
| Work and truthful history | `Fleet.Intents.RecordedAction.owner/3` refuses fenced commitment authority. `Fleet.Intents.censor_reset_generation/2` explicitly classifies interrupted work as reset-censored, not resumably paused. `MissionControl.activity/1` builds a Server Reset milestone from `fenced_at`; Mission Control LiveView labels transitions and replacement history as Server Resets. Reusing reset flags would falsely describe voluntary abandonment even if minting succeeded. |
| Recovery choice across commits | `Registration.recovery/2` describes only the latest registration outcome; definitive rejection/absence is `:clear`. It cannot retain the Operator's choice to keep a healthy predecessor paused before any request, after definitive failure, or after reconciliation proves no mint. That choice needs separate lifecycle authority linked to the predecessor and the existing attempt, not a second outcome ledger. |

Supporting the optional contract would therefore require a new lifecycle state
and serialized confirm/retry/resume transitions; predecessor-only admission and
restart reconstruction; authoritative refresh and work requalification before
resume; and reason-aware history/UI/boot policy. Its races with queued requests,
Emergency Stop, uncertain registration and adoption must be qualified through
the approved independently committed PostgreSQL and HTTP seams. Adding a button,
calling `mark_stale/1`, clearing timestamps, or temporarily disengaging Emergency
Stop is not clean reuse. No such partial authority or control is shipped.

Future implementation can reuse the existing registration/adoption/progress
machinery **after** this pause/resume lifecycle exists. It must exclude the
healthy predecessor symbol, retain failure pause, block retry and resume during
uncertainty, and reconcile late predecessor actions without fabricating reset
or successful objective outcomes. This describes the reopening boundary, not
a new mandatory subsystem or additional work authorized by #694.

Qualification remains at #694's pre-approved seams: the authenticated Mission
Control briefing test checks no healthy-Fleet replacement control, rejects a
forged reset-retry event without any mutation, and observes the same unfenced
Generation and gameplay authority afterwards. Existing reset, registration
recovery, durable authority and late-result proofs continue to qualify the
mandatory core. No voluntary-confirmation or pause/resume behavior is claimed.

Approved source: [#694](https://github.com/bturney/spacetraders/issues/694) and the
[Operator-confirmed design](https://github.com/bturney/spacetraders/issues/645#issuecomment-6111671385).
