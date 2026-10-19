#!/usr/bin/env python3
"""Per-attempt offline investigation. No services, gameplay or cleanup authority."""
import argparse
import html
import json
import os
from pathlib import Path
import zipfile

if __package__:
    from . import attempt_export as evidence
else:
    import attempt_export as evidence

VERSION = "attempt-investigation/v1"


def investigate(bundle):
    """Project the exporter's canonical graph, never generate a second graph."""
    metadata, sections, graph = bundle["metadata"], bundle["sections"], bundle["graph"]
    evidence.require(evidence.validate(metadata, sections) == bundle["manifest"]["complete_export"],
                     "completeness disagreement")
    evidence.require(evidence.derived(metadata, sections) == (graph, bundle["summary"]),
                     "causal/summary disagreement")
    tables = sections["database"].get("data", {}).get("tables", {})
    indexes = {table: {row[evidence.PRIMARY_KEYS.get(table, "id")]: row for row in rows}
               for table, rows in tables.items()}
    records = {node: indexes[record["table"]][record["id"]]
               for node, record in graph["nodes"].items()}
    # The writer redacts before sealing. Refuse known-secret content introduced
    # by a resealed bundle instead of turning integrity into sharing authority.
    for value in [metadata, graph, sections['world'], sections['time'], *records.values()]:
        evidence.require(evidence.canonical(evidence.redact(value)) == evidence.canonical(value),
                         'unredacted credential/private-source evidence')
    adjacency = {node: [] for node in records}
    for edge in graph["edges"]:
        adjacency[edge["from"]].append(edge)
        adjacency[edge["to"]].append(edge)

    def linked(node, table, relations):
        return sorted({other for edge in adjacency[node] if edge["relation"] in relations
                       for other in [edge["to"] if edge["from"] == node else edge["from"]]
                       if graph["nodes"][other]["table"] == table})

    for node, record in graph['nodes'].items():
        if record['table'] != 'mutation_attempts':
            continue
        owners = linked(node, 'intents', {'provenance.intent_id'})
        commitments = linked(node, 'fleet_commitments', {'provenance.commitment_id'})
        for owner in owners:
            root_commitments = linked(owner, 'fleet_commitments', {'fleet_commitment_id'})
            evidence.require(not commitments or not root_commitments or commitments == root_commitments,
                             'contradictory mutation root ownership')

    episodes, gaps, complete_paths = [], [], []
    for name, section in sections.items():
        if section['status'] != 'present':
            gaps.append({'section': name, 'reason': section['status'], 'detail': section['reason']})
    gaps.extend(graph['unresolved_references'])
    for node, record in graph["nodes"].items():
        if record["table"] != "strategy_decision_episodes":
            continue
        portfolios = linked(node, "fleet_commitment_portfolios", {"strategy_decision_episode_id"})
        original = {commitment for portfolio in portfolios for commitment in
                    linked(portfolio, "fleet_commitments", {"fleet_commitment_portfolio_id"})}
        replanned = set(linked(node, "fleet_commitments", {"replan_decision_episode_id"}))
        episode = {"node": node, "portfolios": portfolios, "commitments": [],
                   "decision_observations": linked(node, 'authoritative_observations',
                                                   set(evidence.NESTED_REFERENCE_OWNERS) | {'evidence_id', 'observation'})}
        for commitment in sorted(original | replanned):
            work = {"node": commitment, "via": [], "intents": []}
            if commitment in original:
                work["via"].append("portfolio_origin")
            if commitment in replanned:
                work["via"].append("replan_decision_episode_id")
            for intent in linked(commitment, "intents", {"fleet_commitment_id"}):
                attempts = set(linked(intent, "mutation_attempts", {"mutation_attempt_id", "provenance.intent_id"}))
                # Issuing Commitment provenance also retains attempts after the
                # root's current attempt changes. Never join by Ship or time.
                for attempt in linked(commitment, "mutation_attempts", {"provenance.commitment_id"}):
                    owners = linked(attempt, "intents", {"provenance.intent_id"})
                    if intent in owners:
                        attempts.add(attempt)
                pending = list(attempts)
                while pending:
                    for retry in linked(pending.pop(), "mutation_attempts", {"retry_of_id"}):
                        if retry not in attempts:
                            attempts.add(retry)
                            pending.append(retry)
                for attempt in attempts:
                    owners = linked(attempt, 'intents', {'provenance.intent_id'})
                    evidence.require(not owners or owners == [intent], 'contradictory mutation root ownership')
                    issuing_commitments = linked(attempt, 'fleet_commitments', {'provenance.commitment_id'})
                    evidence.require(not issuing_commitments or issuing_commitments == [commitment],
                                     'contradictory mutation root ownership')
                outcomes = {outcome for attempt in attempts for outcome in
                            linked(attempt, 'mutation_attempt_outcomes', {'mutation_attempt_id'})}
                observations = set()
                for attempt in sorted(attempts):
                    sources = [attempt] + linked(attempt, 'mutation_attempt_outcomes', {'mutation_attempt_id'})
                    original_observations = {observation for source in sources for observation in
                                             linked(source, 'authoritative_observations',
                                                    set(evidence.NESTED_REFERENCE_OWNERS) | {'evidence_id', 'observation'})}
                    observations.update(original_observations)
                    if not original_observations:
                        gaps.append({"node": attempt, "reason": "no_retained_original_observation_link; cause unknown"})
                root = {"node": intent, "attempts": sorted(attempts), "observations": sorted(observations),
                        "outcomes": sorted(outcomes)}
                work["intents"].append(root)
                if attempts and observations:
                    complete_paths.append({"episode": node, "commitment": commitment, **root})
                if not attempts:
                    gaps.append({"node": intent, "reason": "no_retained_mutation_attempt; execution cause unknown"})
                elif not observations:
                    gaps.append({"node": intent, "reason": "no_retained_original_observation_link; cause unknown"})
            if not work["intents"]:
                gaps.append({"node": commitment, "reason": "no_retained_root_intent"})
            episode["commitments"].append(work)
        if not episode["commitments"] and records[node].get("selection_kind") == "selected_plan":
            gaps.append({"node": node, "reason": "selected_plan_without_retained_commitment"})
        episodes.append(episode)
    status = "partial" if complete_paths and gaps else "retained_chain" if complete_paths else "unavailable"
    projections = []
    balances = []
    for node, record in graph['nodes'].items():
        row = records[node]
        if record['table'] == 'fleet_generations':
            balances.append({'node': node, 'amount': row.get('last_observed_credits'),
                             'observed_at': row.get('last_observed_at'),
                             'meaning': 'last observed balance, not earnings or a proven ending balance'})
        if record['table'] != 'strategy_decision_episodes':
            continue
        outcomes = row.get('actual_outcomes')
        outcomes = outcomes if isinstance(outcomes, dict) else {}
        projection = {'node': node, 'source': 'actual_outcomes; not independently re-derived',
                      'open_commitments': outcomes.get('open_commitments'),
                      'unknown': outcomes.get('unknown')}
        for metric in ['net_earnings', 'episode_cash_flow', 'trade_margin']:
            amount = outcomes.get(metric)
            projection[metric] = {'amount': amount if type(amount) is int else None,
                                  'status': 'recorded_projection' if type(amount) is int else 'unknown'}
        projections.append(projection)
    chronology = [{'node': node, 'field': field, 'timestamp': row[field]}
                  for node, row in records.items()
                  if graph['nodes'][node]['table'] in {
                      'strategy_decision_episodes', 'fleet_commitments', 'intents',
                      'mutation_attempts', 'mutation_attempt_outcomes', 'authoritative_observations', 'timeline_events'}
                  for field in ['inserted_at', 'prepared_at', 'sent_or_unknown_at', 'recorded_at', 'observed_at', 'finished_at', 'due_at']
                  if row.get(field) is not None]
    chronology.sort(key=lambda event: (str(event['timestamp']), event['node'], event['field']))
    return {"schema": VERSION, "identity": metadata["identity"],
            "renderer_sha256": evidence.file_sha(__file__),
            "source": {"manifest": bundle["manifest"], "receipt_verified": False},
            "metadata": metadata, "summary": bundle["summary"], "graph": graph,
            "records": records, "episodes": episodes,
            "chronology": {"application": chronology,
                           "ordering": "retained timestamp text order; no timezone repair or world/application causal ordering inferred"},
            "navigation": {"status": status, "gaps": gaps, "retained_paths": complete_paths},
            "economics": {"net_earnings": {"amount": None, "status": "unknown",
                                          "reason": bundle["summary"]["net_earnings_reason"]},
                          "episode_projections": projections, "last_observed_credits": balances},
            "world": sections["world"], "time": sections["time"],
            "unknown_causes": "Unknown causes remain unknown; temporal proximity is not a causal join."}


def read_report(path, receipt=None):
    report = investigate(evidence.read_bundle(path, receipt=receipt))
    report["source"].update(bundle_sha256=evidence.file_sha(path),
                            bundle_bytes=Path(path).stat().st_size,
                            receipt_verified=receipt is not None)
    return report


STYLE = """
:root { color: #203142; background: #fff; font: 17px/1.55 'Segoe UI', sans-serif; }
body { margin: 0 auto; max-width: 86rem; padding: 2rem; }
h1 { font-size: 2.4rem; line-height: 1.15; } h2 { margin-top: 2.5rem; }
h3 { margin-top: 1.8rem; } h1,h2,h3,h4 { color: #183e60; }
p,li,dl { max-width: 76ch; } a { color: #075ba1; overflow-wrap: anywhere; }
a:focus-visible,summary:focus-visible { outline: 3px solid #075ba1; outline-offset: 3px; }
pre { white-space: pre-wrap; overflow-wrap: anywhere; font: .85rem/1.5 monospace;
      background: #edf2f6; padding: 1rem; max-width: 100%; }
.warning { border-left: .4rem solid #9c6500; background: #fff3cf; padding: 1rem; }
.work { margin-left: 1rem; border-left: 2px solid #b8c8d6; padding-left: 1rem; }
.comparison { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 1rem; }
section { scroll-margin-top: 1rem; } summary { cursor: pointer; }
table { border-collapse: collapse; width: 100%; } th,td { text-align: left; padding: .6rem; border-bottom: 1px solid #b8c8d6; }
@media(max-width: 48rem) { body { padding: 1rem; } .comparison { display: block; } .work { margin-left: 0; } }
@media print { :root { font-size: 10pt; } body { padding: 0; } pre { background: none; border: 1px solid #b8c8d6; }
  a { color: inherit; } details { display: block; } details > * { display: block; } }
"""


def render_html(report):
    esc = html.escape

    def pretty(value):
        if value is None or value == {} or value == []:
            return '<p>Unknown / not recorded. An empty record is not proof of zero.</p>'
        return '<pre>' + esc(json.dumps(value, indent=2, ensure_ascii=False)) + '</pre>'

    def link(node):
        return '<a href="#' + esc(node, quote=True) + '">' + esc(node) + '</a>'

    content = ['<!doctype html><html lang="en"><head><meta charset="utf-8">',
               '<meta name="viewport" content="width=device-width, initial-scale=1">',
               '<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;; base-uri &#39;none&#39;; form-action &#39;none&#39;">',
               '<title>Attempt investigation</title><style>' + STYLE + '</style></head><body>',
               '<header><h1>Attempt investigation</h1><p>' + esc(report['identity']['logical_run']) +
               ' / ' + esc(report['identity']['attempt']) + '</p>',
               '<p>Disposition: <strong>' + esc(report['metadata']['disposition']['kind']) + '</strong></p>',
               pretty(report['metadata']['disposition']), '</header>',
               '<nav aria-label="Investigation"><a href="#decisions">Decisions and chosen work</a> · '
               '<a href="#chronology">Application chronology</a> · <a href="#money">Monetary evidence</a> · <a href="#world">World events</a> · '
               '<a href="#records">Original records</a> · <a href="#provenance">Provenance</a></nav>',
               '<h2>Evidence boundary</h2><p>Integrity verified. Checksums are not signatures, gameplay success, or qualification.</p>']
    if not report['source']['manifest']['complete_export']:
        content.append('<p class="warning">Incomplete export. Missing evidence prevents complete investigation.</p>')
    if not report['source']['receipt_verified']:
        content.append('<p class="warning">No trusted separate receipt checked. Internal consistency only; authenticity is unproven.</p>')
    content.extend(['<p>Causal navigation: ' + esc(report['navigation']['status']) +
                    '. A retained chain is not a successful or completed outcome.</p>',
                    pretty(report['summary']['availability']),
                    '<h3>Unknown causes and missing links</h3><p>' + esc(report['unknown_causes']) + '</p>',
                    pretty(report['navigation']['gaps']), pretty(report['graph']['unresolved_references']),
                    '<h2 id="decisions">Strategy Decision Episodes</h2>'])
    records = report['records']
    for episode in report['episodes']:
        row = records[episode['node']]
        content.extend(['<article><h3>Episode ' + link(episode['node']) + '</h3>',
                        '<p>Classification: ' + esc(str(row.get('classification') or 'unknown')) +
                        '; selection: ' + esc(str(row.get('selection_kind') or 'unknown')) + '</p>',
                        '<div class="comparison"><section><h4>Expectations</h4>' + pretty(row.get('expectations')) +
                        '</section><section><h4>Actual outcomes (recorded projection)</h4>' + pretty(row.get('actual_outcomes')) + '</section></div>',
                        '<h4>Considered alternatives</h4>' + pretty(row.get('alternatives')),
                        '<h4>Binding constraints and limitations</h4>' + pretty({key: row.get(key) for key in
                            ['binding_constraints', 'binding_limitation_kind', 'rejection_reason', 'stall_reason', 'next_observation_at']}),
                        '<h4>Original decision observations (not mutation evidence)</h4><ul>'])
        content.extend('<li>' + link(observation) + '</li>' for observation in episode['decision_observations'])
        content.append('</ul><h4>Chosen work</h4>')
        if not episode['commitments']:
            content.append('<p>No retained chosen work linked. Refusal or wait is not a selected plan.</p>')
        for work in episode['commitments']:
            content.extend(['<div class="work"><h4>Fleet Commitment ' + link(work['node']) + '</h4>',
                            '<p>Episode relationship: ' + esc(', '.join(work['via'])) + '</p>',
                            pretty({key: records[work['node']].get(key) for key in
                                    ['decisive_reason', 'expected_value', 'claims', 'reservations', 'dependencies', 'unwind_state']})])
            for root in work['intents']:
                intent = records[root['node']]
                content.extend(['<h4>Root Intent ' + link(root['node']) + '</h4>',
                                pretty({key: intent.get(key) for key in ['type', 'status', 'blocker', 'in_flight_action', 'last_action_result']}),
                                '<h4>Recovery evidence</h4>', pretty({'recovery_attempts': intent.get('recovery_attempts')}),
                                '<p>Original, current and retry-linked mutation attempts:</p><ul>'])
                for attempt in root['attempts']:
                    content.append('<li>' + link(attempt) + ' — ' + esc(str(records[attempt].get('state'))) + '</li>')
                content.append('</ul><p>Recorded outcomes (no replay or settlement inferred):</p><ul>')
                content.extend('<li>' + link(outcome) + '</li>' for outcome in root['outcomes'])
                content.append('</ul><p>Original observations:</p><ul>')
                content.extend('<li>' + link(observation) + '</li>' for observation in root['observations'])
                content.append('</ul>')
            content.append('</div>')
        content.append('</article>')
    content.extend(['<h2 id="chronology">Application chronology</h2>',
                    '<p>' + esc(report['chronology']['ordering']) + '</p>',
                    '<table><thead><tr><th>Original timestamp</th><th>Field</th><th>Original record</th></tr></thead><tbody>'])
    content.extend('<tr><td>' + esc(str(event['timestamp'])) + '</td><td>' + esc(event['field']) +
                   '</td><td>' + link(event['node']) + '</td></tr>' for event in report['chronology']['application'])
    content.extend(['</tbody></table>', '<h2 id="money">Monetary evidence</h2>',
                    '<p>Net Earnings requires complete bounded-outcome goods and supporting-cost attribution. '
                    'Episode Cash Flow includes attributable spending on unfinished work. Trade Margin excludes supporting costs. '
                    'Last observed or ending credits are not earnings.</p>', pretty(report['economics']),
                    '<h2 id="world">World events and time evidence</h2>',
                    '<p>World events and application records remain separate clocks/sources. No event-to-work join is inferred.</p>',
                    '<h3>World settled events</h3>',
                    pretty(report['world'].get('data', {}).get('settled_events')),
                    '<h3>Time owner trace and unresolved work</h3>', pretty(report['time']),
                    '<details><summary>Full original world evidence (including pending events and coverage)</summary>',
                    pretty(report['world']), '</details>',
                    '<h2 id="records">Original records and retained causal links</h2>'])
    adjacency = {node: [] for node in records}
    for edge in report['graph']['edges']:
        adjacency[edge['from']].append((edge['relation'], edge['to'], 'to'))
        adjacency[edge['to']].append((edge['relation'], edge['from'], 'from'))
    for node, row in records.items():
        content.extend(['<section id="' + esc(node, quote=True) + '"><h3>' + esc(node) + '</h3>', pretty(row), '<ul>'])
        content.extend('<li>' + esc(direction + ' ' + relation) + ': ' + link(target) + '</li>'
                       for relation, target, direction in adjacency[node])
        content.append('</ul></section>')
    content.extend(['<h2 id="provenance">Provenance, coverage and claim limits</h2>',
                    pretty(report['metadata']), pretty(report['source']), '</body></html>'])
    return '\n'.join(content)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle')
    parser.add_argument('--receipt', help='trusted separate export receipt')
    parser.add_argument('--output-dir', required=True, help='new private output directory; never overwritten')
    args = parser.parse_args()
    receipt = evidence.decode_json(Path(args.receipt).read_bytes()) if args.receipt else None
    report = read_report(args.bundle, receipt)
    data = {'report.json': evidence.canonical(report), 'report.html': render_html(report).encode()}
    manifest = {'schema': VERSION, 'identity': report['identity'],
                'source': report['source'], 'renderer_sha256': report['renderer_sha256'],
                'files': {name: {'sha256': evidence.sha(value), 'bytes': len(value)} for name, value in data.items()},
                'cleanup_authorized': False}
    destination = Path(args.output_dir)
    destination.mkdir(mode=0o700)
    for name, value in {**data, 'report-manifest.json': evidence.canonical(manifest)}.items():
        with (destination / name).open('xb') as stream:
            stream.write(value)
    print(json.dumps({'schema': VERSION, 'navigation': report['navigation']['status'],
                      'complete_export': report['source']['manifest']['complete_export']}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, RecursionError, zipfile.BadZipFile):
        raise SystemExit('attempt investigation failed: invalid, broken or unavailable evidence; no complete report published; originals retained')
