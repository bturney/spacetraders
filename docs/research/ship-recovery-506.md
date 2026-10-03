# Validated Ship recovery — issue 506

Base revision: `bbaa847bd564edecd17d88e62a3a008483a0e7d1`.
Implementation revision: the commit containing this receipt, on
`feature/506-validated-ship-recovery`.

## Recovery boundary

- Boot, Arrival, Cooldown and supported reconciliation validate fresh governed
  Ship observations. A supplied model must match retained authoritative evidence;
  otherwise the boundary obtains a new read. Missing navigation, route, fuel,
  Cargo, Cooldown or module facts cannot become absence/completion evidence.
- Preparation resumes its original recorded attempt under send admission.
  Already-satisfied outcomes suppress that send. Persisted absence consumes one
  retry under current authority, or withdraws unused retry authority when fresh
  evidence satisfies the outcome. Original attempt history remains intact.
- Sent/unknown and Bounded Unknown remain recoverable through MutationAttempts.
  Dependent credits and other owned/world resources must be observed too.
  Reconciliation preserves acquisition timestamps rather than restamping old
  facts after a dependent read. Invalid evidence leaves selected work and its
  actual scoped blocker/fence intact.
- Historical selected actions acquire an explicit ambiguous ledger identity,
  preserving their original action/result and timestamps without manufacturing
  a send marker or retry permission. Missing recipient parameters conservatively
  protect the Agent's resources; identified effects retain their declared scope.
  Historical Cooldowns without send identity remain unknown rather than crashing
  or becoming synthetic acceptance proof.

## Regression evidence

Ordinary coverage in `owned_intent_recovery_test.exs`,
`ship_execution_durability_test.exs` and `mutation_attempts_test.exs` covers
accepted, absent, prepared, Bounded Unknown, failed/malformed/stale observations,
changed authority, stale event identity and legacy missing-attempt cases.
Existing delivery and arrival fixtures now return their observed state through
the governed HTTP read instead of using a model alone as authoritative proof.

The interrupted retry test uses a claimed root Intent, real PostgreSQL commits,
the production boot re-entry, and different pinned sender/observer backends.
The game accepts the orbit retry, the sender dies before receiving its response,
and boot accepts the retained effect without another orbit. Both attempts and
the linked send marker remain independently visible across the interruption.
This is a Ship Execution recovery proof; it makes no profitable-loop claim.

## Verification receipt

Final command:

```sh
source scripts/_toolchain.sh
DATABASE_URL=postgres://postgres:postgres@localhost/spacetraders_test_506 scripts/verify
```

Result: exit 0; **774 tests, 0 failures**, 94.7 seconds for ExUnit; compilation,
formatting, generated models/inventory, gameplay boundary and boot checks pass.
Boot health returned HTTP 200. Full local transcript:
`/tmp/opencode/506-delivery-verify.log`.

[Retained complete transcripts](https://gist.github.com/bturney/7211ab2c3d6edaff45ab5cb936edccb3)
include the final gate and comparison evidence. An earlier run had 773 tests
and one shared Capacity Governor counter assertion failure in
`API.ErrorTest` at line 175. Its isolated file passed (13 tests, 0 failures).
A clean-source main comparison at the base revision, using a separate migrated
database, had 754 tests and a different global API admission correlation failure
in `API.ClientTest`. Those results establish comparison scope, not proof that
the two failures have an identical cause. A subsequent unchanged gate passed
773 tests; the final run above includes the additional legacy Cooldown proof.

Two-axis review completed. Three evidence/retry findings and two maintainability
findings were addressed, with regressions for malformed absence credits,
expired dependent evidence and already-satisfied persisted absence. Verification
tool behavior remains outside this change (issue 400).
