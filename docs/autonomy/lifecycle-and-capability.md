# Fleet lifecycle and autonomous capability

> Imported from [#502](https://github.com/bturney/spacetraders/issues/502) on 2026-10-18. The contract text below is preserved from that issue without semantic edits. Qualification status is tracked separately; a written contract is not proof of implementation.

### C07 — Generation, restart, and forward recovery

Definitive authenticated token reset-date mismatch immediately fences old-generation mutations. Other authentication errors are not reset proof. Replacement uses stored AccountToken authority and permitted deterministic symbols; the old Stale Agent is retained until replacement succeeds. Bootstrap authoritatively establishes new Agent, Fleet, and Strategy-relevant starting facts before operation.

Strategy, revisions, Emergency Stop, credential authority, and useful causal/outcome history survive. Old credits, Claims, Reservations, Pledges, Contracts, Operational Intelligence, due work, and unfinished game execution cannot authorize the replacement world, even when symbols repeat. Reset-censored history remains inspectable without carrying active fences into the new Generation.

Deploys and restarts reconstruct current authority, attempts, commitments, Intents, demands, and waits; they are not Generation changes. Lock loss suppresses mutations. Existing PostgreSQL and production deployment are reused rather than repeated as migration milestones. Recovery after restore reconciles forward against the live game, accounts for events that may postdate the snapshot, and does not replay unproven local history. Schema expansion/contraction preserves compatible rollback where possible and explicitly records forward-only boundaries.

### C08 — Real capability completeness

The generated manifest stays keyed to the bundled OpenAPI contract, not a frozen operation count. Each operation has one owner, prerequisites, consequence/evidence model, timing, ambiguity recovery, availability conditions, and executable proof. All reads carry visibility and pagination semantics. The inventory currently contains 59 operations, but drift must update deliberate classification.

Registration belongs to Fleet Generation. Fleet-level negotiation, acceptance, fulfillment, acquisition, and scrapping retain outcome ownership. Ship outcomes use one root Intent and reusable prerequisites; transfer claims the required Ships and receiving capacity. Navigate remains the depth test: callers provide destination and constraints, while local/inter-System routing, posture, Flight Mode, refueling, fuel-independent capability, jump/warp prerequisites, and waits stay inside execution.

Complete capability families include Intelligence/charting/scanning, Surveys and resources/refinement/jettison, Markets, Contracts, Construction, transfer and producer-hauler graphs, purchase/registration, outfitting and mount/module changes, repair/scrap, and inter-System movement. Existing implementations may already meet some contracts; qualification is behavioral.

Shared progress reduces remaining Pledges regardless of actor; acquired Cargo is replanned rather than lost. Quotes and readiness are evidence for repair/acquisition/scrap alternatives. Known API defects, including duplicate-module removal inventory risk, retain explicit evidence-based guards and recovery rather than being modeled as intended mechanics. Historical research is a prior, not permission to invent permanent restrictions that the current API does not establish.
