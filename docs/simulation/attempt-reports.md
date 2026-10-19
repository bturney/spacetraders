# Offline per-attempt investigation

```sh
python3 scripts/attempt_report.py PRIVATE/bundle.zip --receipt PRIVATE/receipt.json --output-dir PRIVATE/new-investigation
```

Open `new-investigation/report.html` directly, without an application, PostgreSQL,
Grafana, web server, JavaScript or external assets. `report.json` is the same
`attempt-investigation/v1` projection for machine readers. `report-manifest.json`
pins both outputs by byte length/SHA-256, renderer bytes, source bundle bytes,
original exporter manifest and run/attempt identity. It is published last; a
directory without that manifest is not a complete publication. Outputs are
private (`0700` directory, `0600` files); an existing destination is never replaced.
Portable evidence and rendered HTML remain private unless separately authorized
for sharing. Do not attach private investigations to Discord or diff previews.

The reader uses `attempt_export.read_bundle` and its **one canonical causal graph**.
It checks supported bundle versions, checksums, original provenance, row/section
inventories, resource identity and known joins, including nested quote/credit/
source/target/Binding Observation identities. A trusted separate receipt also
checks the whole ZIP and identity. Without one the HTML explicitly warns that
only internal consistency was checked. Hashes are not signatures or gameplay
qualification. Missing known targets, resealed graph loss, forged completeness,
contradictory mutation-root ownership or unredacted known secrets reject the
report; stderr contains no payload or source-path dump. An honest incomplete
capture renders with a prominent warning, not a successful drill-down claim.

## Reading the investigation

Start with disposition, achieved simulated/wall coverage and claim limits. Each
Strategy Decision Episode shows recorded expectations/actual outcomes, considered
alternatives, binding constraints, limitations and chosen work. Portfolio-origin
and replan Episode relationships remain distinct. Follow local links through
Fleet Commitments, root Intents, **original and current** MutationAttempts,
retry lineage, recovery outcomes and their original Observations. Every canonical
record and edge is retained; there are no live database/Grafana URLs. No join is
guessed from Ship identity, similar amounts or nearby timestamps.

`navigation.status` describes evidence, never outcome success: `retained_chain`
means at least one Episode-to-original-Observation path with no detected gaps;
`partial` means a path exists but capture, references or required drill-down links
are incomplete; `unavailable` means no such path is retained. Blocked roots with
no mutation are explicitly disclosed, not invented mutations or inferred causes.
Refusals and Neutral Waits are not selected work. Unknown reference formats,
absent observations and causes remain visible. The separate r4 coordinates
diagnosis cannot be imported into an unrelated export lacking that evidence.

Application chronology preserves original timestamp fields and text ordering,
without repairing missing timezones. World settled/pending events and the time
owner's trace/unresolved work remain separately inspectable; no cross-clock or
event-to-work causality is fabricated. All records, not just successful work,
remain in the machine output and original-record appendix.

## Monetary boundaries

Exact attempt Net Earnings remains **unknown** without a complete attributed
bounded-outcome ledger. Recorded Episode `actual_outcomes` projections are shown
as `recorded_projection`, not independently re-derived or summed into exact
attempt earnings. Net Earnings, Episode Cash Flow and Trade Margin have separate
fields; open Commitments, unknown supporting charges and incomplete work remain
visible. A numeric zero in a recorded projection remains zero; absent/non-numeric
amounts remain unknown. Last observed credits are neither proven ending credits
nor contribution earnings. This report does not implement a competing accounting
engine, paired ranking, policy evaluation, runner, retention or cleanup authority.

## Focused verification

```sh
python3 -m unittest discover -s test/integration -p 'attempt_*test.py'
mix test test/spacetraders/simulation/attempt_export_test.exs test/spacetraders/simulation/attempt_report_test.exs --max-failures 1
```

The authored Python contracts need no services and can run in an empty network/PID
namespace with only Python, read-only source, and disposable output storage. The
ordinary ExUnit discovery wrapper runs the same contracts. Actual retained proof
requires separately authorized private data, never a public fixture copied from a
real attempt. Reading sealed bundles does not require opening/restoring PG files
or starting services. Original bundles, receipts, failed exports and proof outputs
must remain immutable; write evidence-only reports to new directories.
