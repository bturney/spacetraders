# Market Cargo recorded-action recovery — #568

Scope: [#568](https://github.com/bturney/spacetraders/issues/568), the bounded
Gate 1 increment under [#502](https://github.com/bturney/spacetraders/issues/502).
Implementation base: integration `1277936`, with #567 already integrated.
The Operator-authorized public seams are `Intents.execute_action/4`,
`Intents.reconcile/5`, retained Evidence bindings/proof assembly, and independent
MutationAttempts/recorded-dispatch durability. No production trial was performed.

## Adoption and deletion

Market buy/sell action selection calls `Intents.execute_action/4`. The separate
buy/sell dispatch functions and their caller-owned preparation/dispatch branches
are deleted. Prepared boot recovery and live responses use the same selected
response continuation. Re-entry judges Cargo effects and invokes the established
shared accepted/absence/retry progression; it does not construct observation
timestamps, provenance, dependency coverage, fingerprints or retry permission.

Ship Execution still judges Market listing eligibility, requested quantities,
price limits, sale value and current available credits/reserves. The selected
action retains pre-dispatch Cargo/credit baselines. Recovery requires exact Cargo
delta and correctly directed credit effects for acceptance, or unchanged Cargo
and credits for absence. Partial Cargo effects, changed credits without Cargo,
missing baselines and failed retention remain unresolved. A zero-price listing
permits unchanged credits with the exact Cargo effect. Fresh current Market and
spending eligibility is checked before an absence retry; the selected quantity
cannot silently change. Partial buy acceptance does not declare the requested
quantity complete. Recovered quantity does not fabricate a transaction price,
Trade Margin or Episode Cash Flow.

`Evidence.recovery_agent_binding/3` reuses usable retained credit acquisitions;
`Evidence.recovery_proof/4` assembles exact Ship/credit sources with their original
times. MutationAttempts remains the sole verdict, retry and Safety Fence
authority. Failed retention cannot become proof. Shared `RecordedAction.retry_authority/3`
checks current selection/owner before capability eligibility reads, allowing
stopped/lost-Claim absence to retire without requiring a functioning Market.
Preparation and final transport admission still recheck authority. This preliminary
check does not consume retry permission, authorize transport or validate old
transfer preflight facts before their permitted replacement.

## Verification receipt

All commands ran in `opencode/kimaki-spec-502-568` with the pinned toolchain,
private writable `MIX_BUILD_PATH=/tmp/opencode/568-build` and prepared private
`DATABASE_URL=postgres://postgres:postgres@localhost:5502/spacetraders_568`.
`MIX_ENV=test`; canonical boot port `4568`. Each retained transcript ends with
explicit `COMMAND_EXIT`.

| Contract / command | Result | Full transcript |
| --- | --- | --- |
| `mix test test/spacetraders/owned_intent_recovery_test.exs --only market_recovery --seed 0`: exact acceptance/absence retry red | 4 failures; exit 2 | `/tmp/opencode/568-market-red.log` |
| Same command: first slice green | 4 selected tests, 0 failures; exit 0 | `/tmp/opencode/568-market-green.log` |
| Same command: satisfied outcome before unused retry red/green | 2 failures then 12 selected tests, 0 failures; exits 2/0 | `/tmp/opencode/568-withdraw-red.log`, `/tmp/opencode/568-withdraw-green.log` |
| Same command: stopped absence and partial quantity judgments | stop red: 2 failures; partial red: only partial buy fails; exits 2/2 | `/tmp/opencode/568-stop-red.log`, `/tmp/opencode/568-partial-red.log` |
| `mix test` owned recovery, Fleet Intents, Ship execution durability, recorded runtime and direct MutationAttempts files, `--seed 0` | 161 tests, 0 failures; exit 0 | `/tmp/opencode/568-targeted-final.log` |
| `mix test` owned recovery, transfer recovery, Ship execution durability and recorded Emergency Stop files, `--seed 0` | 130 tests, 0 failures; exit 0 | `/tmp/opencode/568-regression-green.log` |
| `scripts/verify` final | 935 tests, 0 failures; compile, format, generators, boundary and HTTP boot pass; exit 0 | `/tmp/opencode/568-canonical-final.log` |

The first canonical attempt (`/tmp/opencode/568-canonical.log`, 935 tests,
1 failure, exit 1) exposed a real regression: the preliminary retry check
validated expired transfer preflight before its established replacement. The
shared owner-authority check now separates that from transport request/evidence
validation. Existing transfer recovery then passed without altering its tests,
followed by the final canonical gate above. This was a scoped correction, not an
environmental rerun. Initial database preparation used an unavailable default
port; the private database was then explicitly prepared on local port 5502.

The 15 added owner-seam tests cover both Market action kinds: exact source reuse
across identical replacement and restart, one absence retry, unused retry
withdrawal, stopped absence retirement, equivalent live/prepared boot progression,
obsolete selection calls, credit retention failure and unresolved credit effects;
the final case preserves partial-buy judgment. Existing shared source/expiry,
ledger invariants, independent commits, authority-loss and concurrent admission
tests remain intact.

## Remaining qualification

This work does not repair or certify #502's worst-case spending-authority bound.
An observed listing remains an eligibility input, not a guaranteed expenditure
bound. It does not implement #559 economics projection or certify Gates 2–5.
Refit purchase ownership remains the separate #573 adoption; its existing
continuation is preserved when a prepared buy re-enters the shared response path.
