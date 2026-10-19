"""Authored poor-attempt reports through the offline CLI; no live services."""
import json
import copy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from attempt_export_test import export, fixture

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/attempt_report.py"


def poor_attempt():
    meta, sections = fixture("interrupted")
    tables = sections["database"]["data"]["tables"]

    def row(table, **values):
        record = dict.fromkeys(export.TABLES[table].split())
        record.update(values)
        tables[table].append(record)

    row("strategy_decision_episodes", id=2, selection_kind="selected_plan",
        classification="still_evaluating", inserted_at="2026-10-18T00:00:00Z",
        expectations={"maximum_credit_change": 120}, actual_outcomes={},
        alternatives=[{"candidate": "wait", "reason": "lower_expected_contribution"}],
        binding_constraints=[{"credit_floor": 500}],
        evidence_references=[{"kind": "observation", "id": "authored-quote"}])
    row("fleet_commitment_portfolios", id=3, strategy_decision_episode_id=2)
    row("fleet_commitments", id=4, fleet_commitment_portfolio_id=3,
        decisive_reason="Highest-ranked feasible contribution", expected_value=120)
    row("intents", id=5, fleet_commitment_id=4, status="active", type="buy",
        mutation_attempt_id="authored-current", recovery_attempts=0)
    row("mutation_attempts", id="authored-original", state="proven_absent",
        provenance={"intent_id": 5, "commitment_id": 4},
        prepared_evidence={"spending": {"quote_observation_id": "authored-quote"}})
    row("mutation_attempts", id="authored-current", state="sent_or_unknown",
        retry_of_id="authored-original", provenance={"intent_id": 5, "commitment_id": 4},
        prepared_evidence={"bindings": [{"observation_id": "authored-ship"}]})
    row("authoritative_observations", id="authored-quote", observed_at="2026-10-18T00:00:00Z",
        facts={"price": 10, "note": "<script>alert('authored')</script>"})
    row("authoritative_observations", id="authored-ship", facts={"cargo": {"units": 0}})
    sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
    return meta, sections


class ReportTest(unittest.TestCase):
    def command(self, bundle, output, receipt=None):
        command = [sys.executable, str(SCRIPT), str(bundle), "--output-dir", str(output)]
        if receipt is not None:
            command.extend(["--receipt", str(receipt)])
        return subprocess.run(command, capture_output=True, text=True, timeout=10)

    def run_report(self, root, meta, sections):
        bundle = root / "bundle.zip"
        receipt = export.publish(meta, sections, bundle)
        (root / "receipt.json").write_text(json.dumps(receipt))
        result = subprocess.run([sys.executable, str(SCRIPT), str(bundle), "--receipt",
                                 str(root / "receipt.json"), "--output-dir", str(root / "report")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((root / "report/report.json").read_text()), (root / "report/report.html").read_text()

    def test_poor_attempt_follows_original_and_current_evidence_without_live_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, html = self.run_report(root, *poor_attempt())
            self.assertEqual(report["schema"], "attempt-investigation/v1")
            self.assertEqual(report["identity"]["attempt"], "attempt-1")
            self.assertTrue(report["source"]["receipt_verified"])
            self.assertEqual(report["navigation"]["status"], "retained_chain")
            chain = report["episodes"][0]["commitments"][0]["intents"][0]
            self.assertEqual(chain["node"], "run-1/attempt-1/intents:5")
            self.assertEqual(set(chain["attempts"]), {"run-1/attempt-1/mutation_attempts:authored-original",
                                                    "run-1/attempt-1/mutation_attempts:authored-current"})
            self.assertEqual(report["graph"], export.read_bundle(root / "bundle.zip")["graph"])
            for text in ["Expectations", "Actual outcomes", "Considered alternatives", "Binding constraints",
                         "Chosen work", "World events", "Recovery evidence", "sent_or_unknown",
                         "quote_observation_id", "authored-original", "Unknown causes"]:
                self.assertIn(text, html)
            self.assertIn('href="#run-1/attempt-1/authoritative_observations:authored-quote"', html)
            self.assertNotIn("<script>", html)
            self.assertNotRegex(html, r'(?:href|src)=[\"\'](?:https?:|//)')
            self.assertIsNone(report["economics"]["net_earnings"]["amount"])
            self.assertNotIn("current_coordinates_unavailable", html)
            manifest = json.loads((root / "report/report-manifest.json").read_text())
            for name, item in manifest["files"].items():
                self.assertEqual(export.file_sha(root / "report" / name), item["sha256"])

    def test_incomplete_capture_and_missing_chain_are_visible_not_success(self):
        meta, sections = poor_attempt()
        tables = sections["database"]["data"]["tables"]
        tables["intents"][0].update(status="blocked", mutation_attempt_id=None,
                                    blocker={"reason": "unknown", "evidence_id": "unretained-source:7"})
        tables["mutation_attempts"] = []
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        sections["world"] = {"identity": meta["identity"], "status": "not_captured", "reason": "capture interrupted"}
        with tempfile.TemporaryDirectory() as directory:
            report, html = self.run_report(Path(directory), meta, sections)
            self.assertFalse(report["source"]["manifest"]["complete_export"])
            self.assertEqual(report["navigation"]["status"], "unavailable")
            self.assertIn("Incomplete export", html)
            self.assertIn("no_retained_mutation_attempt", html)
            self.assertIn("unretained-source:7", html)
            self.assertIn("capture interrupted", html)
            self.assertIsNone(report["economics"]["net_earnings"]["amount"])
        # Even a traversable chain must not advertise complete navigation when
        # capture is missing or a particular original attempt lacks observations.
        meta, sections = poor_attempt()
        tables = sections["database"]["data"]["tables"]
        tables["mutation_attempts"][0]["prepared_evidence"] = {}
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        with tempfile.TemporaryDirectory() as directory:
            report, html = self.run_report(Path(directory), meta, sections)
            self.assertEqual(report["navigation"]["status"], "partial")
            self.assertIn("no_retained_original_observation_link", html)

    def test_recorded_economics_are_distinct_from_exact_attempt_earnings_and_balance(self):
        meta, sections = poor_attempt()
        tables = sections["database"]["data"]["tables"]
        tables["strategy_decision_episodes"][0]["actual_outcomes"] = {
            "net_earnings": 70, "trade_margin": 90, "episode_cash_flow": -100,
            "open_commitments": [4], "unknown": [{"item": "supporting_charge", "reason": "unretained"}]}
        generation = dict.fromkeys(export.TABLES["fleet_generations"].split())
        generation.update(id=1, starting_credits=1000, last_observed_credits=9999)
        tables["fleet_generations"] = [generation]
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        with tempfile.TemporaryDirectory() as directory:
            report, html = self.run_report(Path(directory), meta, sections)
            money = report["economics"]
            self.assertIsNone(money["net_earnings"]["amount"])
            self.assertEqual(money["episode_projections"][0]["net_earnings"],
                             {"amount": 70, "status": "recorded_projection"})
            self.assertEqual(money["episode_projections"][0]["episode_cash_flow"]["amount"], -100)
            self.assertEqual(money["episode_projections"][0]["trade_margin"]["amount"], 90)
            self.assertEqual(money["episode_projections"][0]["open_commitments"], [4])
            self.assertEqual(money["last_observed_credits"][0]["amount"], 9999)
            self.assertIn("not independently re-derived", html)
            self.assertIn("Last observed or ending credits are not earnings", html)

    def test_contradictory_mutation_root_ownership_never_publishes_a_report(self):
        meta, sections = poor_attempt()
        tables = sections["database"]["data"]["tables"]
        other = copy.deepcopy(tables["fleet_commitments"][0])
        other["id"] = 44
        tables["fleet_commitments"].append(other)
        tables["mutation_attempts"][0]["provenance"]["commitment_id"] = 44
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            export.publish(meta, sections, root / "bundle.zip")
            result = self.command(root / "bundle.zip", root / "report")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid, broken or unavailable evidence", result.stderr)
            self.assertFalse((root / "report").exists())

    def test_zero_amounts_remain_recorded_while_non_numeric_amounts_stay_unknown(self):
        for amount, expected in [(0, {"amount": 0, "status": "recorded_projection"}),
                                 (True, {"amount": None, "status": "unknown"}),
                                 ("70", {"amount": None, "status": "unknown"})]:
            with self.subTest(amount=amount), tempfile.TemporaryDirectory() as directory:
                meta, sections = poor_attempt()
                tables = sections["database"]["data"]["tables"]
                tables["strategy_decision_episodes"][0]["actual_outcomes"] = {
                    metric: amount for metric in ["net_earnings", "episode_cash_flow", "trade_margin"]}
                sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
                report, _ = self.run_report(Path(directory), meta, sections)
                for metric in ["net_earnings", "episode_cash_flow", "trade_margin"]:
                    self.assertEqual(report["economics"]["episode_projections"][0][metric], expected)
                self.assertIsNone(report["economics"]["net_earnings"]["amount"])

    def test_current_and_retry_attempts_reject_conflicting_commitment_without_intent_provenance(self):
        for route, attempt_index in [("current_pointer", 1), ("retry_traversal", 0)]:
            with self.subTest(route=route), tempfile.TemporaryDirectory() as directory:
                meta, sections = poor_attempt()
                tables = sections["database"]["data"]["tables"]
                other = copy.deepcopy(tables["fleet_commitments"][0])
                other["id"] = 44
                tables["fleet_commitments"].append(other)
                tables["mutation_attempts"][attempt_index]["provenance"] = {"commitment_id": 44}
                sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
                root = Path(directory)
                export.publish(meta, sections, root / "bundle.zip")
                original = (root / "bundle.zip").read_bytes()
                result = self.command(root / "bundle.zip", root / "report")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid, broken or unavailable evidence", result.stderr)
                self.assertFalse((root / "report").exists())
                self.assertEqual((root / "bundle.zip").read_bytes(), original)

    def test_incomplete_capture_with_a_retained_path_is_partial_and_receipt_absence_is_visible(self):
        meta, sections = poor_attempt()
        sections["world"] = {"identity": meta["identity"], "status": "not_captured", "reason": "capture interrupted"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            export.publish(meta, sections, root / "bundle.zip")
            result = self.command(root / "bundle.zip", root / "report")
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((root / "report/report.json").read_bytes())
            html = (root / "report/report.html").read_text()
            self.assertEqual(report["navigation"]["status"], "partial")
            self.assertEqual(len(report["navigation"]["retained_paths"]), 1)
            self.assertFalse(report["source"]["receipt_verified"])
            self.assertIn("Incomplete export", html)
            self.assertIn("No trusted separate receipt checked", html)
            self.assertIn({"section": "world", "reason": "not_captured", "detail": "capture interrupted"},
                          report["navigation"]["gaps"])

    def test_resealed_missing_links_forged_completeness_identity_and_versions_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            meta, sections = poor_attempt()
            sections["world"] = {"identity": meta["identity"], "status": "not_captured", "reason": "not retained"}
            receipt = export.publish(meta, sections, root / "original.zip")
            (root / "trusted.json").write_text(json.dumps(receipt))
            original_bytes = (root / "original.zip").read_bytes()
            with zipfile.ZipFile(root / "original.zip") as archive:
                original = {name: archive.read(name) for name in archive.namelist()}
            for defect in ["missing_target", "missing_graph_link", "complete", "identity", "version", "checksum"]:
                with self.subTest(defect=defect):
                    data = dict(original)
                    manifest = json.loads(data["manifest.json"])
                    if defect == "missing_target":
                        db = json.loads(data["database.json"])
                        db["data"]["tables"]["authoritative_observations"] = []
                        db["data"] = export.database_document(db["data"]["tables"], {}, "authored", {"database": "sim_authored"})
                        data["database.json"] = export.canonical(db)
                        graph = json.loads(data["causal.json"])
                        graph["nodes"] = {key: value for key, value in graph["nodes"].items()
                                          if value["table"] != "authoritative_observations"}
                        graph["edges"] = [edge for edge in graph["edges"] if edge["to"] in graph["nodes"]]
                        data["causal.json"] = export.canonical(graph)
                        summary = json.loads(data["summary.json"])
                        summary["table_rows"]["authoritative_observations"] = 0
                        data["summary.json"] = export.canonical(summary)
                    elif defect == "missing_graph_link":
                        graph = json.loads(data["causal.json"])
                        graph["edges"] = [edge for edge in graph["edges"] if edge["relation"] != "quote_observation_id"]
                        data["causal.json"] = export.canonical(graph)
                    elif defect == "complete":
                        manifest["complete_export"] = True
                    elif defect == "identity":
                        manifest["identity"]["attempt"] = "other-attempt"
                    elif defect == "version":
                        manifest["schema"] = "attempt-bundle/v999"
                    manifest["files"] = {name: {"bytes": len(data[name]), "sha256": export.sha(data[name])}
                                          for name in manifest["files"]}
                    data["manifest.json"] = export.canonical(manifest)
                    data["manifest.sha256"] = export.sha(data["manifest.json"]).encode()
                    if defect == "checksum":
                        data["time.json"] += b"damage"
                    path = root / (defect + ".zip")
                    with zipfile.ZipFile(path, "w") as archive:
                        for name, value in data.items():
                            archive.writestr(name, value)
                    for trusted in [None, root / "trusted.json"]:
                        output = root / (defect + ("-trusted" if trusted else "-internal"))
                        result = self.command(path, output, trusted)
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertFalse(output.exists())
            self.assertEqual((root / "original.zip").read_bytes(), original_bytes)

    def test_existing_reader_html_hook_uses_the_investigation_without_a_second_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            meta, sections = poor_attempt()
            export.publish(meta, sections, root / "bundle.zip")
            html = export.render_html(export.read_bundle(root / "bundle.zip"))
            self.assertIn("Considered alternatives", html)
            self.assertIn("Recovery evidence", html)

    def test_replan_relationship_does_not_replace_original_episode_or_assign_work_to_waits(self):
        meta, sections = poor_attempt()
        tables = sections["database"]["data"]["tables"]
        for identity, selection in [(22, "selected_plan"), (23, "neutral_wait"), (24, "refused_publication")]:
            episode = dict.fromkeys(export.TABLES["strategy_decision_episodes"].split())
            episode.update(id=identity, selection_kind=selection)
            tables["strategy_decision_episodes"].append(episode)
        tables["fleet_commitments"][0]["replan_decision_episode_id"] = 22
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        with tempfile.TemporaryDirectory() as directory:
            report, _ = self.run_report(Path(directory), meta, sections)
            episodes = {episode["node"].rsplit(":", 1)[1]: episode for episode in report["episodes"]}
            original, replanned = episodes["2"]["commitments"][0], episodes["22"]["commitments"][0]
            self.assertEqual(original["node"], replanned["node"])
            self.assertEqual(original["via"], ["portfolio_origin"])
            self.assertEqual(replanned["via"], ["replan_decision_episode_id"])
            self.assertEqual(episodes["23"]["commitments"], [])
            self.assertEqual(episodes["24"]["commitments"], [])

    def test_original_timestamps_world_events_and_recovery_outcomes_remain_separate_sources(self):
        meta, sections = poor_attempt()
        tables = sections["database"]["data"]["tables"]
        tables["mutation_attempts"][0]["prepared_at"] = "2026-10-18T00:00:00Z"
        outcome = dict.fromkeys(export.TABLES["mutation_attempt_outcomes"].split())
        outcome.update(id=6, mutation_attempt_id="authored-original", classification="proven_absent",
                       recorded_at="2026-10-18T00:00:01Z", evidence={"observation_id": "authored-ship"})
        tables["mutation_attempt_outcomes"].append(outcome)
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        world = sections["world"]["data"]
        world["settled_events"] = [{"kind": "authored_arrival", "at": 9}]
        world["state_sha256"] = export.sha(export.canonical({k: v for k, v in world.items()
                                                            if k not in ["state_sha256", "hash_encoding"]}))
        with tempfile.TemporaryDirectory() as directory:
            report, html = self.run_report(Path(directory), meta, sections)
            self.assertIn({"node": "run-1/attempt-1/mutation_attempt_outcomes:6", "field": "recorded_at",
                           "timestamp": "2026-10-18T00:00:01Z"}, report["chronology"]["application"])
            self.assertEqual(report["world"]["data"]["settled_events"], [{"kind": "authored_arrival", "at": 9}])
            self.assertEqual(report["episodes"][0]["commitments"][0]["intents"][0]["outcomes"],
                             ["run-1/attempt-1/mutation_attempt_outcomes:6"])
            self.assertIn("Application chronology", html)
            self.assertIn("World settled events", html)
            self.assertIn("Recovery evidence", html)
            self.assertIn('href="#run-1/attempt-1/mutation_attempt_outcomes:6"', html)

    def test_redaction_private_modes_and_no_replacement_survive_report_generation(self):
        meta, sections = poor_attempt()
        sections["time"]["data"]["unresolved"] = [{"private_source": "never-share-source",
                                                     "token": "never-share-token", "reason": "Bearer never-share-bearer"}]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, html = self.run_report(root, meta, sections)
            for secret in ["never-share-source", "never-share-token", "never-share-bearer"]:
                self.assertNotIn(secret, html)
                self.assertNotIn(secret, json.dumps(report))
            before = {p.name: p.read_bytes() for p in (root / "report").iterdir()}
            self.assertEqual((root / "report").stat().st_mode & 0o077, 0)
            for path in (root / "report").iterdir():
                self.assertEqual(path.stat().st_mode & 0o077, 0)
            self.assertNotEqual(self.command(root / "bundle.zip", root / "report").returncode, 0)
            self.assertEqual({p.name: p.read_bytes() for p in (root / "report").iterdir()}, before)
            # A resealed, internally consistent bundle is not permission to leak
            # newly introduced known-secret payloads through the reader.
            with zipfile.ZipFile(root / "bundle.zip") as archive:
                data = {name: archive.read(name) for name in archive.namelist()}
            section = json.loads(data["time.json"])
            section["data"]["unresolved"] = [{"token": "never-share-forged"}]
            data["time.json"] = export.canonical(section)
            manifest = json.loads(data["manifest.json"])
            manifest["files"]["time.json"] = {"bytes": len(data["time.json"]), "sha256": export.sha(data["time.json"])}
            data["manifest.json"] = export.canonical(manifest)
            data["manifest.sha256"] = export.sha(data["manifest.json"]).encode()
            forged = root / "forged.zip"
            with zipfile.ZipFile(forged, "w") as archive:
                for name, value in data.items():
                    archive.writestr(name, value)
            result = self.command(forged, root / "forged-report")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("never-share-forged", result.stderr)
            self.assertFalse((root / "forged-report").exists())

    def test_decision_observations_do_not_become_missing_mutation_observation_joins(self):
        meta, sections = poor_attempt()
        tables = sections["database"]["data"]["tables"]
        for attempt in tables["mutation_attempts"]:
            attempt["prepared_evidence"] = {"preconditions": ["owned_ship", "navigation_eligible"]}
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        with tempfile.TemporaryDirectory() as directory:
            report, html = self.run_report(Path(directory), meta, sections)
            self.assertEqual(report["episodes"][0]["decision_observations"],
                             ["run-1/attempt-1/authoritative_observations:authored-quote"])
            self.assertEqual(report["episodes"][0]["commitments"][0]["intents"][0]["observations"], [])
            self.assertEqual(report["navigation"]["status"], "unavailable")
            self.assertEqual(report["navigation"]["retained_paths"], [])
            self.assertIn("Original decision observations (not mutation evidence)", html)
            self.assertIn("no_retained_original_observation_link", html)


if __name__ == "__main__":
    unittest.main()
