#!/usr/bin/env python3
"""Exercise the deployment script with isolated host state and command doubles."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CURRENT = "example.test/spacetraders:current"
PREVIOUS = "example.test/spacetraders:previous"
NEW = "example.test/spacetraders:new"

DOCKER = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

state = Path(os.environ["TEST_STATE"])
args = sys.argv[1:]
if args[0] == "inspect":
    print((state / "running-image").read_text().strip())
elif "--images" in args:
    print(os.environ["SPACETRADERS_IMAGE"])
    print("postgres:17-alpine")
elif "up" in args:
    (state / "running-image").write_text(os.environ["SPACETRADERS_IMAGE"])
elif "exec" in args:
    authority = os.environ.get("TEST_AUTHORITY", "pre_cutover")
    if authority == "unknown":
        sys.exit(1)
    if "to_regclass" in args[-1]:
        print("runtime_authority" if authority == "postgresql" else "")
    else:
        print(authority)
'''

CURL = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

state = Path(os.environ["TEST_STATE"])
args = sys.argv[1:]
(state / "curl-args").write_text(" ".join(args))
image = (state / "running-image").read_text().strip()
if image == os.environ.get("TEST_UNHEALTHY_IMAGE"):
    sys.exit(7)

# Model immediate connection failures and the configured one-second retry delay.
# No real sleeps: a late listener must fit within both curl retry limits.
ready_after = int(os.environ.get("TEST_READY_AFTER", "0"))
retries = int(args[args.index("--retry") + 1])
delay = int(args[args.index("--retry-delay") + 1])
budget = (int(args[args.index("--retry-max-time") + 1])
          if "--retry-max-time" in args else retries * delay)
if ready_after > min(retries * delay, budget):
    sys.exit(7)
print('{"status":"ok"}')
'''


class DeployHostTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="spacetraders-deploy-test-")
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name)
        commands = self.state / "bin"
        commands.mkdir()
        for name, content in [("docker", DOCKER), ("curl", CURL)]:
            command = commands / name
            command.write_text(content)
            command.chmod(0o755)

        # Keep production's fixed host path; only the test copy uses a sandbox.
        source = (ROOT / "scripts/deploy-host").read_text()
        host_path = "readonly DEPLOY_DIR=/srv/projects/spacetraders"
        self.assertEqual(source.count(host_path), 1)
        self.script = self.state / "deploy-host"
        self.script.write_text(source.replace(host_path, f"readonly DEPLOY_DIR={self.state}"))
        self.env = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                        TEST_STATE=str(self.state))
        self.write(".current-image", CURRENT)
        self.write(".previous-image", PREVIOUS)
        self.write("running-image", CURRENT)

    def write(self, name, value):
        (self.state / name).write_text(value + "\n")

    def read(self, name):
        return (self.state / name).read_text().strip()

    def run_deploy(self, *args, **env):
        return subprocess.run(
            ["bash", str(self.script), *args], env=dict(self.env, **env),
            capture_output=True, text=True, timeout=5,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_deploy_records_the_previous_image(self):
        self.assert_success(self.run_deploy("deploy", NEW))
        self.assertEqual(self.read(".current-image"), NEW)
        self.assertEqual(self.read(".previous-image"), CURRENT)

    def test_redeploy_keeps_existing_rollback_history(self):
        self.assert_success(self.run_deploy("deploy", CURRENT))
        self.assertEqual(self.read(".previous-image"), PREVIOUS)

    def test_first_deploy_falls_back_to_running_image(self):
        (self.state / ".current-image").unlink()
        self.assert_success(self.run_deploy("deploy", NEW))
        self.assertEqual(self.read(".previous-image"), CURRENT)

    def test_listener_starting_after_old_retry_window_succeeds(self):
        self.assert_success(self.run_deploy("deploy", NEW, TEST_READY_AFTER="12"))
        self.assertEqual(self.read(".current-image"), NEW)
        self.assertEqual(self.read(".previous-image"), CURRENT)

    def test_health_retries_have_a_bounded_startup_budget(self):
        self.assert_success(self.run_deploy("deploy", NEW))
        args = self.read("curl-args").split()
        self.assertIn("--retry-max-time", args)
        self.assertEqual(args[args.index("--retry-max-time") + 1], "60")

    def test_exhausted_health_budget_preserves_recorded_images(self):
        result = self.run_deploy("deploy", NEW, TEST_READY_AFTER="61",
                                 TEST_AUTHORITY="postgresql")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("recover forward", result.stderr)
        self.assertEqual(self.read(".current-image"), CURRENT)
        self.assertEqual(self.read(".previous-image"), PREVIOUS)

    def test_failed_deploy_restores_recorded_image_before_cutover(self):
        result = self.run_deploy("deploy", NEW, TEST_UNHEALTHY_IMAGE=NEW)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback completed", result.stderr)
        self.assertEqual(self.read("running-image"), CURRENT)
        self.assertEqual(self.read(".current-image"), CURRENT)

    def test_manual_rollback_reads_previous_image(self):
        self.assert_success(self.run_deploy("rollback"))
        self.assertEqual(self.read("running-image"), PREVIOUS)
        self.assertEqual(self.read(".current-image"), PREVIOUS)
        self.assertEqual(self.read(".previous-image"), CURRENT)

    def test_manual_rollback_without_history_fails_closed(self):
        (self.state / ".previous-image").unlink()
        result = self.run_deploy("rollback")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No previous image", result.stderr)
        self.assertEqual(self.read("running-image"), CURRENT)

    def test_postgres_authority_blocks_image_rollback(self):
        for authority in ["postgresql", "unknown"]:
            with self.subTest(authority=authority):
                result = self.run_deploy("deploy", NEW, TEST_UNHEALTHY_IMAGE=NEW,
                                         TEST_AUTHORITY=authority)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("rollback completed", result.stderr)
                self.assertEqual(self.read("running-image"), NEW)
                self.assertEqual(self.read(".current-image"), CURRENT)

    def test_postgres_authority_blocks_manual_rollback(self):
        for authority in ["postgresql", "unknown"]:
            with self.subTest(authority=authority):
                result = self.run_deploy("rollback", TEST_AUTHORITY=authority)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.read("running-image"), CURRENT)
                self.assertEqual(self.read(".current-image"), CURRENT)
                self.assertEqual(self.read(".previous-image"), PREVIOUS)


if __name__ == "__main__":
    unittest.main()
