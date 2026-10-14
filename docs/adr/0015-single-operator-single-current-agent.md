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
remains a separate implementation/defer decision, not a mandatory-core gate.

Approved source: [#694](https://github.com/bturney/spacetraders/issues/694) and the
[Operator-confirmed design](https://github.com/bturney/spacetraders/issues/645#issuecomment-6111671385).
