"""Inert tests at the immutable bootstrap-command seam; no ports/process boots."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest

SPEC = importlib.util.spec_from_file_location(
    "native_bootstrap", Path(__file__).parents[2] / "scripts/native_bootstrap.py")
boot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(boot)


class ManifestTest(unittest.TestCase):
    def manifest(self):
        return boot.definition("a" * 40, "b" * 64, "c" * 64, "d" * 64,
                               "e" * 64, "f" * 32)

    def test_definition_pins_inputs_and_is_canonical(self):
        manifest = self.manifest()
        identity = boot.validate(manifest)
        self.assertEqual(identity, boot.validate(dict(reversed(list(manifest.items())))))
        changed = copy.deepcopy(manifest)
        changed["strategy"]["hard_constraints"] = ["Keep at least 75,000 credits available"]
        self.assertNotEqual(identity, boot.validate(changed))
        changed = copy.deepcopy(manifest)
        changed["application"]["revision"] = "9" * 40
        self.assertNotEqual(identity, boot.validate(changed))

    def test_rejects_live_targets_credentials_unknown_fields_and_unbounded_limits(self):
        for field, value in [("api_url", "https://api.spacetraders.io/v2"),
                             ("database_url", "postgres://live/db"),
                             ("account_token", "not-simulation"), ("extra", True)]:
            with self.subTest(field=field):
                changed = self.manifest()
                changed[field] = value
                with self.assertRaises(ValueError):
                    boot.validate(changed)
        for field in ["wall_seconds", "requests", "memory_bytes", "tasks", "cpu_percent"]:
            changed = self.manifest()
            changed["limits"][field] = 0
            with self.assertRaises(ValueError):
                boot.validate(changed)

    def test_world_identity_and_resources_are_closed(self):
        for section, key, value in [("world", "revision", "0" * 40),
                                    ("world", "archive_sha256", "0" * 64),
                                    ("initial_world", "time_scale", 112),
                                    ("resources", "database", "spacetraders"),
                                    ("resources", "api_url", "http://127.0.0.1:4000/v2")]:
            changed = self.manifest()
            changed[section][key] = value
            with self.subTest(section=section, key=key), self.assertRaises(ValueError):
                boot.validate(changed)

    def test_inherited_authority_is_rejected_not_reused(self):
        for key in ["DATABASE_URL", "POSTGRES_HOST", "ENCRYPTION_KEY", "ACCOUNT_TOKEN",
                    "AGENT_TOKEN", "PHX_SERVER", "HTTP_PROXY", "SPACETRADERS_API_URL", "PGHOST", "PGPASSWORD"]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                boot.reject_environment({key: "anything"})
        boot.reject_environment({"PATH": "/usr/bin", "HOME": "/home/example"})

    def test_navigation_receipt_keeps_actual_consequence_but_no_credentials(self):
        body = {"data": {"token": "must-not-export", "nav": {
            "status": "IN_TRANSIT", "waypointSymbol": "X1-TEST-B",
            "route": {"arrival": "2026-10-18T12:00:30Z", "destination": {"symbol": "X1-TEST-B"}},
            "unexpectedSecret": "must-not-export"}}}
        receipt = boot.navigation_receipt("POST", "/v2/my/ships/TEST-1/navigate", 200,
                                          json_bytes(body))
        self.assertEqual(receipt, {"status": "IN_TRANSIT", "waypoint": "X1-TEST-B",
                                   "destination": "X1-TEST-B", "arrival": "2026-10-18T12:00:30Z"})
        self.assertIsNone(boot.navigation_receipt("POST", "/v2/register", 201, json_bytes(body)))

    def test_release_path_cannot_relabel_another_application(self):
        repo = Path("/example/checkout")
        expected = repo / "_build/prod/rel/spacetraders"
        self.assertEqual(boot.release_for(repo, expected), expected)
        with self.assertRaises(ValueError):
            boot.release_for(repo, Path("/example/stale-release"))

    def test_startup_deadline_cannot_be_renewed_by_next_phase(self):
        with self.assertRaises(ValueError):
            boot.remaining(time.monotonic() - 1)
        self.assertTrue(0 < boot.remaining(time.monotonic() + 10) <= 10)

    def test_shutdown_requires_positive_manager_confirmation(self):
        self.assertFalse(boot.shutdown_verified(1, ""))
        self.assertFalse(boot.shutdown_verified(0, ""))
        self.assertFalse(boot.shutdown_verified(1, "LoadState=not-found\nActiveState=inactive\n"))
        self.assertFalse(boot.shutdown_verified(0, "LoadState=loaded\nActiveState=active\n"))
        self.assertTrue(boot.shutdown_verified(0, "LoadState=not-found\nActiveState=inactive\n"))
        self.assertTrue(boot.shutdown_verified(0, "LoadState=loaded\nActiveState=failed\n"))

    def test_controlled_navigation_is_a_new_pinned_definition_not_a_native_relabel(self):
        world = {"revision": "1" * 40, "archive_sha256": "2" * 64, "image_sha256": "3" * 64,
                 "contract_sha256": "4" * 64, "input_inventory_sha256": "5" * 64}
        manifest = boot.definition("a" * 40, "b" * 64, "c" * 64, "d" * 64,
                                   "e" * 64, "f" * 32, world, 1792281600000)
        identity = boot.validate(manifest)
        self.assertNotEqual(identity, boot.validate(self.manifest()))
        changed = copy.deepcopy(manifest)
        changed["world"]["archive_sha256"] = boot.WORLD_ARCHIVE
        with self.assertRaisesRegex(ValueError, "native artifact"):
            boot.validate(changed)
        changed = copy.deepcopy(manifest)
        changed["initial_world"]["ships"] = [{"symbol": "injected"}]
        with self.assertRaises(ValueError):
            boot.validate(changed)
        changed = copy.deepcopy(manifest)
        changed["initial_world"]["epoch_ms"] += 1
        with self.assertRaises(ValueError):
            boot.validate(changed)

    def test_arrival_proof_requires_authoritative_http_continuation_order(self):
        at = "1970-01-01T00:00:10Z"
        arrival = {"class": "arrival", "ship": "TEST-1", "destination": "X1-TEST-A2",
                   "due_time": 10, "settled_time": 10, "after_gameplay_request_sequence": 1}
        result = {"evidence": {"ship_symbol": "TEST-1", "target_waypoint": "X1-TEST-A2",
                  "intent_status": "completed", "continuation_observed_at": at, "continued_at": at}}
        trace = [{"phase": "world_settled", "ordinal": 1, "at": at},
                 {"phase": "bot_released", "ordinal": 2, "at": at}]
        export = {"epoch_ms": 0, "settled_events": [arrival], "request_log": [
            [{"method": "POST", "path": ["my", "ships", "TEST-1", "navigate"], "now": 0}, {"status": 200}],
            [{"method": "GET", "path": ["my", "ships", "TEST-1"], "now": 10}, {"status": 200}],
            [{"method": "GET", "path": ["systems", "X1-TEST", "waypoints", "X1-TEST-A2", "market"], "now": 10}, {"status": 200}]]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "time-trace.json").write_text(json.dumps(trace))
            (root / "world-export.json").write_text(json.dumps(export))
            boot.validate_arrival_proof(root, copy.deepcopy(result))
            export["request_log"][1:] = reversed(export["request_log"][1:])
            (root / "world-export.json").write_text(json.dumps(export))
            with self.assertRaisesRegex(ValueError, "HTTP order"):
                boot.validate_arrival_proof(root, copy.deepcopy(result))


def json_bytes(value):
    import json
    return json.dumps(value).encode()


if __name__ == "__main__":
    unittest.main()
