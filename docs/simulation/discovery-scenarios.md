# Matched discovery scenarios

Issue #795 extends the private world's supported
[world controls](world-controls.md) with explicit discovery sensitivity inputs.
This document describes the integration contract only; private implementation,
game payloads and proof exports remain access-controlled.

## Initialize and match

Use scenario identity `discovery/v1` with the original immutable world identity,
epoch/reset date and separately identified generation, gameplay and external
seeds. Its additional `scenario_inputs` selects:

| Input | Contract |
| --- | --- |
| `opportunity` | `quiet`, `contested` or `exhausted` |
| `waypoint_symbols` | 1–128 unique existing generated Waypoints, excluding Headquarters and Jump Gates |
| `claim_window_seconds` | Ordered integer bounds within the supported horizon; contested starts after epoch, exhausted uses epoch only |

Quiet leaves the selected opportunities uncharted without external claims.
Contested schedules one external chart claim per selected Waypoint. Exhausted
starts with authoritative external claims. These deliberately named scenario
changes do not alter starting Fleet resources or pretend to be normal starter
frontier observations. The original generated-starter profile rejects overrides.
Unknown inputs, injected state and payout overrides fail closed.

The discovery external substream is domain-separated from gameplay and other
external extensions. It plans claims once at initialization, in sorted Waypoint
order, with a declared bounded integer scheduling window. That window is a
scenario input, **not a calibrated rival pace/probability**. Pin executable and OTP
revisions as well as seeds. Compare the exported inputs, full planned stream and
random state—not request counts or final state hashes alone.

## Order and outcomes

World events settle before bot wakes. Rival chart events have priority **30**;
Arrival keeps priority **10**, and scheduled economics reserves **20**. The stable
order is due time, class priority, then Ship symbol or external event identity.
The original no-skip and atomic event-budget rules apply to the combined queue.
The controller still cannot certify application quiescence on its own.

Own actions may legitimately change the resulting world. A bot that charts before
the scheduled rival keeps its claim; the rival event still occurs and records
`already_claimed`. A rival first claim removes the bot's opportunity and its later
chart request is rejected. Another actual Agent's successful chart has the same
firstness consequence. No full rival bot is introduced.

Credential-free authoritative exports retain discovery inputs, planned/pending
events, external random state, settled outcomes and request/event chronology.
The private offline replay comparator reports mismatched inputs and unexplained
external scheduling/outcome divergence. It explains only receipt-supported own
firstness differences; other world divergence requires causal review. Neither
matched seeds nor a short replay promise bit-for-bit concurrent determinism.

## Income and uncertainty

Income means the **first successful Waypoint chart**, never first System entry.
Successful chart HTTP responses and later Waypoint reads preserve the actual
submitting Agent and absolute timestamp. Previously charted data with absent
provenance does not invent a submitting Agent.

Authoritative `first-waypoint-chart/v1` receipts retain Waypoint, Agent, Ship or
unknown, time, Chart Provenance, source, reward and reward basis. Existing simulator
payout/credit rules remain unchanged; those constants are not independently
established global distributions or guaranteed reward floors. External claim
payouts remain unknown. Supporting cost allocation and exact Net Earnings remain
unknown where causal attribution is absent, not zero. Failed/repeated charting
cannot create another receipt or reward. Normal travel/fuel costs remain real
game consequences, separate from any unproved chart-cost allocation.

## Evidence boundary

Private bounded regressions exercise real game HTTP, matched streams under
different read/action counts, legitimate own-action divergence, same-time
Arrival/rival/bot order, another Agent's first claim, exhausted opportunities,
repeatability, changed-seed controls and corrupted-export divergence detection.
They retain source pins, actual resource limits, request counts and private proofs.

Scheduled production/background market activity is a separate #787 extension;
this slice does not manufacture it. No construction, hidden-production,
large-Fleet, payout-tail or globally calibrated rival coverage follows. Missing
autonomous reward-frontier planning is neither added nor assumed. Chart/rival-
dependent preferences remain provisional; uncertainty-sensitive outcomes are
inconclusive. No actual-bot/PG, artifact-image, protected-host capacity,
first-gate, 336-hour or full-suite qualification is claimed.
