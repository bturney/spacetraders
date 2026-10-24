# S1 follow-up: departure, return and fresh purchase evidence

**2026-10-23, #843: bounded S1 pass for both presets, combining the existing #835 guard cases with the pinned #837 representative application trace.** The earlier [receipt](shipyard-evidence-821.md) understated surviving departure/return evidence. This is an artifact audit, not a new world run, production correction, full-suite result or whole-P1/Gate 0 certificate. #838 remains partial; B's clock comparison remains inconclusive; latest integration gate/review remain pending.

## Verified natural timeline

Both `837-final-V-{preset}/837-{preset}.json` receipts at `6236a75` contain the following **2026-10-22 UTC application/world** requests. Their raw SHA256s remain pinned in the [main receipt](shipyard-evidence-821.md#critical-artifact-integrity). The audit below checks those bytes before using the evidence.

| Request start | Verified action / consequence, both presets |
| --- | --- |
| 01:22:31 | Probe `PROOF824-2`, docked at A1, reads Shipyard; original offer observation completes 01:22:32. |
| 01:22:39 | Purchase preparation is **not_sent**, `ship_investment_evidence_unavailable`: original enabled-work validity expires at this boundary. Not a purchase effect or a presence-only refusal. |
| 01:22:40 / 01:22:41 | Same probe orbits/navigates A1 → A3 for its separately allocated **Market intelligence** Claim/Intent. Actual departure 01:22:42, arrival 01:48:47; no teleport or acquisition-owned Claim. |
| 01:48:48 / 01:48:49 | Probe docks A3 and reads Market; new governed observation at 01:48:50 fulfils both planning and execution Demands. |
| 01:48:58 / 01:48:59 | Completed Market work gives way to a new normal Shipyard intelligence Claim/Intent; probe orbits/navigates A3 → A1. Actual arrival 02:15:05. |
| 02:15:06 / 02:15:07 | Probe docks A1, reads Shipyard, creates **new** original observation at 02:15:08; old offer timestamp is not refreshed in place. |
| 02:15:14 | Another purchase preparation is **not_sent** when its own original Market support expires. Fresh offer/presence alone does not bypass investment evidence validity. |
| 02:15:18 / 02:15:24 | Fresh A1 Market read completes 02:15:19; new current Claim-only loser at 02:15:21 supports a new purchase Commitment/Episode. Durable Attempt precedes the one POST; effect 02:15:25, readiness read completes 02:15:26. Probe is docked at A1; starter is **IN_TRANSIT**, despite its A1 destination. Acquisition has no Ship Claim. |

| Authority / original evidence | steady_growth, Generation/Revision 11/11 | charted_expansion, Generation/Revision 12/12 |
| --- | --- | --- |
| Unrelated A3 visit: Intent / Commitment / Episode | 176 / 138 / 292 | 491 / 348 / 775 |
| Normal return: Intent / Commitment / Episode | 178 / 140 / 298 | 493 / 350 / 781 |
| Initial → fresh governed Shipyard observation | `74c117be-5a15-492a-8ba4-0861a77dde45` → `acc3c5a1-7e2b-4177-b7d5-54f28986b7f6` | `ee102f77-dc7a-4325-894c-baddc732b4df` → `ffcd6502-54e4-4518-9395-c2cc126c4d80` |
| Intelligence offer reference, initial → fresh | `intelligence-observation:285` → `intelligence-observation:291` | `intelligence-observation:781` → `intelligence-observation:787` |
| Current loser Episode → purchase Episode / Commitment | 305 → 306 / 144 | 788 → 789 / 354 |

**Absence and binding-reason limits:** no purchase POST occurs between departure and return. Of 136 intervening request-entry snapshots, 125 have no actually present Ship at A1; **11 show the independent starter at A1, 01:45:07–01:45:17**. Do not claim the whole interval lacks co-location. Acquisition-refusal Episodes 297/780 explicitly retain `shipyard_offers_unavailable` and stale reset evidence; this trace does **not** isolate absence as the sole binding cause. The separate #835 test `independent trade and observation departures never authorize a purchase from transit destinations` supplies that controlled guard (`purchase_precondition_unmet`), while its 301-second expiry/refresh and reset-evidence cases cover those variations. Together, focused refusal guards and this normal governed return/fresh-evidence/purchase path meet #835 AC2's representative integration obligation; they do not prove every concurrent departure schedule.

**No borrowed authority or restamped loser:** probe orbit/navigation/dock Attempts join the same Ship's own Claim, Intent, portfolio and current Generation/Revision; Market and return work use distinct Commitments. At purchase send neither probe Commitment remains in the active checkpoint; acquisition holds no Ship Claim. The new loser is a recorded `claim_conflict` alternative in the referenced current Market Episode, with its original dependencies/validity matching the acquisition valuation. Both earlier not-sent decisions retain distinct Candidates and expired original support. Steady's winning loser uses A3; expansion's uses A2: the unrelated A3 read is real useful intelligence, **not falsely credited as the decisive Market dependency in both arms**.

The raw receipt does not include the Intelligence table's source foreign key. Its offer reference retains the exact observation time/yard; a unique governed observation and API response at that time establish the original read in this trace, with unchanged price/type. The audit does not invent a UUID-to-integer foreign-key join. Returned offer reads fulfil `ship_execution` Demands; withdrawn acquisition Demands are not relabelled fulfilled. Host-time Intent `finished_at` fields are not used to order game effects.

## Reproduce the read-only audit

From the repository, run this block. It reads only the two existing raw receipts, starts no runtime/DB and emits no authentication payloads. Assertions fail on changed bytes, borrowed authority, absent send-time presence, stale/restamped work or a purchase during the away interval.

```sh
python3 - <<'PY'
import hashlib, json, pathlib
from datetime import datetime
root = pathlib.Path('/home/ben/.local/state/opencode/spec-821')
pins = {'steady_growth': 'c211deea368af9a2ec6e06ad880f1bc8bd359454526d194cefee7f035241a4ad',
        'charted_expansion': '2273dc3e35c70695cd393e4b7a01e490fba64fdfc5a517dc2171efbb4ac25870'}
def time(s): return datetime.fromisoformat(s.replace('Z', '+00:00'))
def present(state):
    return [s for s, x in state['ships'].items() if x['nav']['status'] in ('DOCKED', 'IN_ORBIT') and x['nav']['waypointSymbol'] == 'X1-UX81-A1']
for preset, digest in pins.items():
    path = root / f'837-final-V-{preset}/837-{preset}.json'
    assert hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() == digest
    d = json.loads(path.read_text())
    assert d['code_revision'] == '6236a75afb94977f9106b5d036f310f183d8e777'
    effects, episodes = d['request_effects'], {e['id']: e for e in d['decisions']}
    def request(t, method, suffix):
        matches = [e for e in effects if time(e['started_at']) == time('2026-10-22T'+t+'Z') and e['method'] == method and e['path'].endswith(suffix)]
        assert len(matches) == 1
        return matches[0]
    def observation(effect, operation, subject):
        matches = [o for o in d['observations'] if o['operation_id'] == operation and o['subject'] == subject and time(o['observed_at']) == time(effect['completed_at'])]
        assert len(matches) == 1
        o = matches[0]
        assert o['fleet_generation_id'] == d['generation']
        assert any(x['fulfilled_observation_id'] == o['id'] and x['owner'] == 'ship_execution' for x in d['all_demands'])
        return o
    def authority(effect, subject_type):
        a, = [a for a in d['attempts'] if a['sent_or_unknown_at'] == effect['started_at'] and '/v2'+a['prepared_evidence']['request']['path'] == effect['path']]
        p = a['provenance']
        i, = [i for i in d['intents'] if i['id'] == p['intent_id']]
        c, = [c for c in d['all_commitments'] if c['id'] == p['commitment_id']]
        assert a['state'] == 'succeeded' and time(a['prepared_at']) <= time(a['sent_or_unknown_at'])
        assert p['fleet_generation_id'] == d['generation'] and p['strategy_revision_id'] == d['strategy_revision']
        assert p['ship_symbol'] == 'PROOF824-2' and p['ship_id'] == i['ship_id']
        assert p['portfolio_id'] == c['fleet_commitment_portfolio_id'] and c['claims'] == ['PROOF824-2']
        assert i['fleet_commitment_id'] == c['id'] and i['type'] == 'acquire_intelligence'
        assert i['parameters']['subject_type'] == subject_type and i['status'] == 'completed'
        assert episodes[p['decision_episode_id']]['selection_kind'] == 'selected_plan'
        return i, c, p['decision_episode_id']
    first, fresh = [observation(request(t, 'GET', 'A1/shipyard'), 'get-shipyard', 'shipyard:X1-UX81:X1-UX81-A1') for t in ('01:22:31', '02:15:07')]
    assert first['id'] != fresh['id'] and (time(fresh['observed_at'])-time(first['observed_at'])).total_seconds() == 3156
    assert all(request(t, 'GET', 'A1/shipyard')['before']['ships']['PROOF824-2']['nav']['status'] == 'DOCKED' for t in ('01:22:31', '02:15:07'))
    joins = []
    for times, kind, origin, destination in [(('01:22:40','01:22:41','01:48:48'), 'market', 'A1', 'A3'), (('01:48:58','01:48:59','02:15:06'), 'shipyard', 'A3', 'A1')]:
        leg = [request(t, 'POST', '/PROOF824-2/'+action) for t, action in zip(times, ('orbit','navigate','dock'))]
        auth = [authority(e, kind) for e in leg]
        assert len({(i['id'], c['id'], ep) for i, c, ep in auth}) == 1
        assert auth[0][0]['target_waypoint'] == 'X1-UX81-'+destination
        nav = leg[1]['response']['nav']['route']
        assert nav['origin']['symbol'] == 'X1-UX81-'+origin and nav['destination']['symbol'] == 'X1-UX81-'+destination
        assert (time(nav['arrival'])-time(nav['departureTime'])).total_seconds() == 1565
        assert time(nav['arrival']) < time(leg[2]['started_at'])
        joins.append((auth[0][0]['id'], auth[0][1]['id'], auth[0][2]))
    assert joins[0][1] != joins[1][1]
    market = request('01:48:49', 'GET', 'A3/market')
    assert market['before']['ships']['PROOF824-2']['nav']['status'] == 'DOCKED'
    observation(market, 'get-market', 'market:X1-UX81:X1-UX81-A3')
    away = [e for e in effects if time('2026-10-22T01:22:42Z') <= time(e['started_at']) < time('2026-10-22T02:15:05Z')]
    assert len(away) == 136 and sum(bool(present(e['before'])) for e in away) == 11
    assert all(e['path'] != '/v2/my/ships' or e['method'] != 'POST' for e in away)
    assert any('shipyard_offers_unavailable' == x.get('reason') for e in episodes.values() for x in e['expectations'].get('limitations', []) if any(w.get('validity', {}).get('as_of') == '2026-10-22T01:48:56.000000Z' for w in e['expectations'].get('considered_work', [])))
    buy = request('02:15:24', 'POST', '/my/ships')
    assert [e for e in effects if e['method'] == 'POST' and e['path'] == '/v2/my/ships'] == [buy]
    assert present(buy['before']) == ['PROOF824-2'] and buy['signed_cash'] == -100000
    cp, = [c for c in d['spending_checkpoints'] if c['at'] == buy['started_at'] and c['path'] == buy['path']]
    a, = [a for a in cp['attempts'] if a['operation_id'] == 'purchase-ship']
    assert a['state'] == 'sent_or_unknown' and a['sent_or_unknown_at'] == buy['started_at']
    p = a['provenance']; ep = episodes[p['decision_episode_id']]; v = ep['expectations']['valuation']; w = v['enabled_work']
    c, = [c for c in cp['commitments'] if c['id'] == p['commitment_id']]
    assert c['claims'] == [] and not any(x['id'] in [j[1] for j in joins] for x in cp['commitments'])
    assert p['fleet_generation_id'] == d['generation'] and p['strategy_revision_id'] == d['strategy_revision']
    assert time(v['shipyard']['observed_at']) == time(fresh['observed_at'])
    assert v['shipyard']['evidence_id'] in [x['evidence_id'] for x in c['dependencies']]
    assert all(x['evidence_id'] in [dep['evidence_id'] for dep in c['dependencies']] for x in w['dependencies'])
    assert fresh['facts']['ships'][0]['purchase_price'] == request('02:15:07', 'GET', 'A1/shipyard')['response']['ships'][0]['purchasePrice'] == 100000
    assert first['facts']['ships'][0]['type'] == fresh['facts']['ships'][0]['type'] == buy['body']['shipType'] == 'SHIP_LIGHT_HAULER'
    alt, = [x for x in episodes[w['decision_episode_id']]['alternatives'] if x['candidate_id'] == w['candidate_id']]
    assert alt['reasons'] == ['claim_conflict'] and alt['alternative']['dependencies'] == w['dependencies'] and alt['alternative']['validity'] == w['validity']
    assert time(w['validity']['as_of']) == time('2026-10-22T02:15:21Z') < time(buy['started_at']) < time(w['validity']['expires_at'])
    for dep in w['dependencies']:
        o, = [o for o in d['observations'] if 'evidence-observation:'+o['id'] == dep['evidence_id']]
        assert time(o['observed_at']) == time(dep['observed_at']) and time(buy['started_at']) < time(dep['valid_until'])
    refused = [a for a in d['attempts'] if a['operation_id'] == 'purchase-ship' and a['state'] == 'not_sent']
    assert len(refused) == 2 and all(a['sent_or_unknown_at'] is None and a['outcomes'][0]['evidence']['reason'] == ':ship_investment_evidence_unavailable' for a in refused)
    assert all(episodes[a['provenance']['decision_episode_id']]['expectations']['valuation']['enabled_work']['candidate_id'] != w['candidate_id'] for a in refused)
    assert all(time(episodes[a['provenance']['decision_episode_id']]['expectations']['valuation']['enabled_work']['validity']['expires_at']) == time(a['prepared_at']) for a in refused)
    print(preset, 'PASS: bounded S1 return/progress', joins, 'loser/purchase', w['decision_episode_id'], ep['id'])
PY
```
