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

## Adoption and staged contraction

Preflight automatically adopts empty or unambiguous sole-Operator installations
with zero or one current Agent. Retired Generations remain history; multiple plausible
Operators/current Agents, missing ownership or inconsistent relationships stop with
actionable resolution before schema contraction or autonomous startup. Never select
the newest record, merge credentials or delete competitors. Adoption and rerun preserve
encrypted credentials, accepted Strategy, game state and causal history.

T1 (#695) expands the schema with one durable current identity and coherent Mission
Control reads. Existing ownership interfaces and relationships remain compatibility
surfaces for later #694 slices; they are not the completed target architecture.
Serialized PostgreSQL adoption and atomic lifecycle publication establish identity
without another coordinator or process-local source of truth. Later slices remove
multi-Agent selectors, additional registration and tenant runtime iteration through
this boundary while retaining authentication, reauthentication and historical attribution.

Approved source: [#694](https://github.com/bturney/spacetraders/issues/694) and the
[Operator-confirmed design](https://github.com/bturney/spacetraders/issues/645#issuecomment-6111671385).
