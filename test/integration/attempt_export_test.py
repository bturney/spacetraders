"""Inert, authored export-contract fixtures. No private world fixtures or ports."""
import copy
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/attempt_export.py"
spec = importlib.util.spec_from_file_location("attempt_export", SCRIPT)
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


def fixture(kind="completed"):
    provenance = {"application": "a" * 40, "simulator": "b" * 40,
                  "api": "c" * 64, "scenario": "authored-contract/v1",
                  "strategy": {"document": {"objectives": []}, "revision": 1},
                  "build": "d" * 64, "calibration": "unqualified"}
    resources = {"cpu": 1, "database": "sim_authored", "world_id": "authored"}
    definition = {"provenance": provenance, "resources": resources, "horizon": 10}
    identity = {"definition": "sha256:" + export.sha(export.canonical(definition)),
                "batch": "batch-1", "logical_run": "run-1", "attempt": "attempt-1"}
    meta = {"schema": "attempt/v1", "identity": identity, "definition": definition,
            "provenance": provenance, "resources": resources,
            "coverage": {"simulated": {"start": 0, "end": 10, "unit": "seconds"},
                         "wall": {"start": "2026-10-18T00:00:00Z", "end": "2026-10-18T00:00:01Z", "seconds": 1}},
            "disposition": {"kind": kind, "cause": "unknown"}, "claim_limits": ["authored fixture only"]}
    tables = {name: [] for name in export.TABLES}
    for table, values in [("operators", {"id": 1}),
                          ("fleet_strategies", {"id": 1, "operator_id": 1, "active_revision_id": 1}),
                          ("fleet_strategy_revisions", {"id": 1, "fleet_strategy_id": 1, "document": provenance["strategy"]["document"]})]:
        record = dict.fromkeys(export.TABLES[table].split())
        record.update(values)
        tables[table].append(record)
    db = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
    world = {"schema": "portable-world/v1", "identity": {"world_id": "authored", "scenario_id": "authored-contract/v1"},
             "current_time": 10, "world": {"cargo": {"inventory": [{"symbol": "ORE", "units": 3}]}},
             "settled_events": [], "coverage": {"complete_world_coverage": False}}
    world["state_sha256"] = export.sha(export.canonical(world))
    world["hash_encoding"] = "canonical-json/v1"
    time = {"schema": "attempt-time/v1", "start": 0, "end": 10, "trace": [],
            "ordering": "not_coordinated", "unresolved": [("pending", None)]}
    sections = {name: {"identity": identity, "status": "present", "data": data}
                for name, data in [("database", db), ("world", world), ("time", time)]}
    return meta, sections


class ExportTest(unittest.TestCase):
    def test_atomic_complete_bundle_is_offline_readable_with_cargo_and_tuple(self):
        meta, sections = fixture()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "attempt.zip"
            receipt = export.publish(meta, sections, target)
            result = export.read_bundle(target)
            self.assertTrue(result["manifest"]["complete_export"])
            self.assertEqual(result["sections"]["world"]["data"]["world"]["cargo"]["inventory"][0]["units"], 3)
            self.assertEqual(result["sections"]["time"]["data"]["unresolved"], [{"$tuple": ["pending", None]}])
            self.assertEqual(receipt["sha256"], export.file_sha(target))
            self.assertEqual(export.read_bundle(target, receipt=receipt)["metadata"]["identity"], meta["identity"])
            changed_receipt = dict(receipt, sha256="0" * 64)
            with self.assertRaisesRegex(ValueError, "receipt"):
                export.read_bundle(target, receipt=changed_receipt)
            original = target.read_bytes()
            with self.assertRaises(FileExistsError):
                export.publish(meta, sections, target)
            self.assertEqual(target.read_bytes(), original)

    def test_missing_sections_identity_hash_or_inventory_never_publish(self):
        for defect in ["missing", "identity", "definition", "inventory", "snapshot", "join"]:
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                meta, sections = fixture()
                if defect == "missing":
                    del sections["world"]
                elif defect == "identity":
                    sections["world"] = copy.deepcopy(sections["world"])
                    sections["world"]["identity"]["attempt"] = "other"
                elif defect == "definition":
                    meta["definition"]["horizon"] = 11
                elif defect == "inventory":
                    sections["database"]["data"]["inventory"]["intents"]["rows"] = 7
                elif defect == "snapshot":
                    del sections["database"]["data"]["snapshot"]
                else:
                    db = sections["database"]["data"]
                    row = dict.fromkeys(export.TABLES["intents"].split())
                    row.update(id=2, fleet_commitment_id=99)
                    db["tables"]["intents"] = [row]
                    db["inventory"]["intents"] = {"rows": 1, "sha256": export.sha(export.canonical(db["tables"]["intents"]))}
                target = Path(directory) / "attempt.zip"
                with self.assertRaises(ValueError):
                    export.publish(meta, sections, target)
                self.assertFalse(target.exists())

    def test_adverse_absence_is_honest_and_does_not_authorize_cleanup(self):
        for kind in ["bot_failure", "harness_failure", "infrastructure_timeout", "interrupted", "startup_failed"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                meta, sections = fixture(kind)
                status = "not_created" if kind == "startup_failed" else "not_captured"
                sections["world"] = {"identity": meta["identity"], "status": status,
                                     "stage": "world_start", "reason": "world unavailable; no state invented"}
                receipt = export.publish(meta, sections, Path(directory) / "attempt.zip")
                bundle = export.read_bundle(Path(directory) / "attempt.zip")
                self.assertEqual(bundle["manifest"]["complete_export"], kind == "startup_failed")
                self.assertFalse(receipt["cleanup_authorized"])
                self.assertNotIn("data", bundle["sections"]["world"])

    def test_secret_keys_bearer_values_and_source_are_redacted_recursively(self):
        meta, sections = fixture()
        sections["time"]["data"]["unresolved"] = [
            {"token": "secret-token", "recovery_credential_ciphertext": "ciphertext",
             "headers": {"Authorization": "Bearer credential"},
             "private_source": "private module bytes", "reason": "Bearer opaque-secret",
             "cargo": {"units": 3}}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "attempt.zip"
            export.publish(meta, sections, path)
            with zipfile.ZipFile(path) as archive:
                all_bytes = b"".join(archive.read(name) for name in archive.namelist())
            for secret in [b"secret-token", b'"ciphertext"', b"Bearer credential", b"private module bytes", b"opaque-secret"]:
                self.assertNotIn(secret, all_bytes)
            self.assertEqual(export.read_bundle(path)["sections"]["time"]["data"]["unresolved"][0]["cargo"]["units"], 3)

    def test_world_hash_summary_and_safe_data_decoder(self):
        self.assertEqual(export.decode_data_term(base64.b64decode("g2gCdwJva2EB")), ("ok", 1))
        self.assertEqual(export.data_term([1, 2, 3]), b"k\x00\x03\x01\x02\x03")
        for payload in [b"\x83p\x00\x00\x00\x00", b"\x83q", b"\x83R", b"\x83a\x01trailing"]:
            with self.assertRaises(ValueError):
                export.decode_data_term(payload)
        meta, sections = fixture()
        sections["world"]["data"]["schema"] = "authoritative-world-export/v1"
        sections["world"]["data"].update(epoch_ms=0, random_state={}, limiter={}, request_log=[], time_unit="integer_seconds_since_epoch")
        sections["world"]["data"]["hash_encoding"] = "erlang_external_term_deterministic/v1"
        sections["world"]["data"]["state_sha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "world.*hash"):
                export.publish(meta, sections, Path(directory) / "attempt.zip")

    def test_offline_reader_rejects_resealed_semantic_tampering_and_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            meta, sections = fixture()
            path = Path(directory) / "attempt.zip"
            export.publish(meta, sections, path)
            with zipfile.ZipFile(path) as archive:
                data = {name: archive.read(name) for name in archive.namelist()}
            corrupt = Path(directory) / "corrupt.zip"
            with zipfile.ZipFile(corrupt, "w") as archive:
                for name, content in data.items():
                    archive.writestr(name, content + b"damage" if name == "time.json" else content)
            with self.assertRaisesRegex(ValueError, "checksum"):
                export.read_bundle(corrupt)
            changed = json.loads(data["time.json"])
            changed["identity"]["attempt"] = "another"
            data["time.json"] = export.canonical(changed)
            manifest = json.loads(data["manifest.json"])
            manifest["files"]["time.json"] = {"bytes": len(data["time.json"]), "sha256": export.sha(data["time.json"])}
            data["manifest.json"] = export.canonical(manifest)
            data["manifest.sha256"] = export.sha(data["manifest.json"]).encode()
            broken = Path(directory) / "broken.zip"
            with zipfile.ZipFile(broken, "w") as archive:
                for name, content in data.items():
                    archive.writestr(name, content)
            with self.assertRaisesRegex(ValueError, "identity"):
                export.read_bundle(broken)

    def test_ambiguous_json_and_executable_data_are_not_serialization_inputs(self):
        for data in ['{"identity": 1, "identity": 2}', '{"value": NaN}']:
            with self.assertRaises(ValueError):
                export.decode_json(data)
        with self.assertRaises(ValueError):
            export.canonical({"dump": lambda: "must never execute"})

    def test_payload_resource_binding_not_only_envelope_identity_is_verified(self):
        meta, sections = fixture()
        sections["database"]["data"]["authority"]["database"] = "sim_other_attempt"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "database.*identity"):
                export.publish(meta, sections, Path(directory) / "attempt.zip")

    def test_private_authority_archive_never_enters_bundle_and_failure_keeps_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            source = root / "source"
            source.mkdir()
            (source / "credential-table").write_text("raw-secret-only-private")
            before = (source / "credential-table").read_bytes()
            authority = export.retain_authority(source, root / "private.tar")
            self.assertTrue(export.verify_authority(root / "private.tar", authority))
            self.assertEqual((root / "private.tar").stat().st_mode & 0o077, 0)
            meta, sections = fixture()
            sections["database"]["data"]["authority"]["raw_archive"] = authority
            target = root / "attempt.zip"
            export.publish(meta, sections, target)
            self.assertNotIn(b"raw-secret-only-private", target.read_bytes())
            with self.assertRaises(FileExistsError):
                export.retain_authority(source, root / "private.tar")
            self.assertEqual((source / "credential-table").read_bytes(), before)
            corrupt = root / "corrupt.tar"
            corrupt.write_bytes((root / "private.tar").read_bytes() + b"damage")
            with self.assertRaises(ValueError):
                export.verify_authority(corrupt, authority)

    def test_excluded_credential_table_inventory_keeps_counts_but_no_rows(self):
        meta, sections = fixture()
        sections["database"]["data"]["excluded_tables"] = {
            "operators_tokens": {"rows": 2, "reason": "not_allowlisted_private_authority_only"}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "attempt.zip"
            export.publish(meta, sections, path)
            database = export.read_bundle(path)["sections"]["database"]["data"]
            self.assertEqual(database["excluded_tables"]["operators_tokens"]["rows"], 2)
            self.assertNotIn("operators_tokens", database["tables"])

    def test_offline_graph_retains_replan_and_original_attempt_and_observation_joins(self):
        meta, sections = fixture("interrupted")
        tables = sections["database"]["data"]["tables"]
        def row(table, **values):
            record = dict.fromkeys(export.TABLES[table].split())
            record.update(values)
            tables[table].append(record)
        row("strategy_decision_episodes", id=2)
        row("fleet_generations", id=7)
        row("allocation_result_pointers", fleet_generation_id=7, strategy_decision_episode_id=2, fleet_strategy_revision_id=1, operator_id=1)
        row("fleet_commitment_portfolios", id=3, strategy_decision_episode_id=2)
        row("fleet_commitments", id=4, fleet_commitment_portfolio_id=3, replan_decision_episode_id=2)
        row("fleet_commitment_claims", id=6, fleet_commitment_id=4, fleet_commitment_portfolio_id=3, resource="ship:AUTHORED")
        row("ships", id=8)
        row("ship_destination_history", id=9, ship_id=8, waypoint_symbol="AUTHORED-A")
        row("intents", id=5, fleet_commitment_id=4, mutation_attempt_id="current")
        row("authoritative_observations", id="obs", facts={"cargo": {"units": 3}})
        row("mutation_attempts", id="original", state="bounded_unknown", provenance={"intent_id": 5}, prepared_evidence={"observation_id": "obs"})
        row("mutation_attempts", id="current", retry_of_id="original", provenance={"intent_id": 5})
        sections["database"]["data"] = export.database_document(tables, {}, "authored", {"database": "sim_authored"})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "attempt.zip"
            export.publish(meta, sections, path)
            result = export.read_bundle(path)
            graph = result["graph"]
            self.assertTrue(any(edge["relation"] == "replan_decision_episode_id" for edge in graph["edges"]))
            self.assertTrue(any(edge["relation"] == "observation_id" for edge in graph["edges"]))
            self.assertTrue(any(node.endswith("mutation_attempts:original") for node in graph["nodes"]))
            self.assertTrue(any(node.endswith("allocation_result_pointers:7") for node in graph["nodes"]))
            self.assertTrue(any(node.endswith("fleet_commitment_claims:6") for node in graph["nodes"]))
            self.assertTrue(any(edge["relation"] == "ship_id" and "ship_destination_history" in edge["from"] for edge in graph["edges"]))
            self.assertIn("bounded_unknown", export.render_html(result))
            self.assertEqual(result["summary"]["world_events"], 0)


if __name__ == "__main__":
    unittest.main()
