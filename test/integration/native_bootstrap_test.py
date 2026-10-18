"""Inert tests at the immutable bootstrap-command seam; no ports/process boots."""
import copy
import importlib.util
from pathlib import Path
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


def json_bytes(value):
    import json
    return json.dumps(value).encode()


if __name__ == "__main__":
    unittest.main()
