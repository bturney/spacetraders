#!/usr/bin/env bash
# Verify product and release/deployment checks are separate CI contracts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/verify.yml"

python3 - "$WORKFLOW" <<'PY'
import re
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text()
if re.search(r"(?m)^  push:\s*$", workflow):
    raise SystemExit("Verification should not rerun after protected main merges")

jobs = {}
current_job = None

for line in workflow.splitlines():
    match = re.fullmatch(r"  ([a-z][a-z0-9-]*):", line)
    if match:
        current_job = match.group(1)
        jobs[current_job] = []
    elif current_job is not None:
        jobs[current_job].append(line)

def job_text(name):
    if name not in jobs:
        raise SystemExit(f"Missing CI job: {name}")
    return "\n".join(jobs[name])

product = job_text("product-verification")
operations = job_text("release-deployment-verification")

if "scripts/verify" not in product:
    raise SystemExit("Product verification job must run scripts/verify")

operational_checks = (
    "test/integration/postgres_compose_test.sh",
    "test/integration/release_boot_test.sh",
    "test/integration/migration_repair_test.sh",
)
for check in operational_checks:
    if check not in operations:
        raise SystemExit(f"Release/deployment job must run {check}")
    if check in product:
        raise SystemExit(f"Product job must not run operational check {check}")

print("Product and release/deployment CI contracts are separate.")
PY
