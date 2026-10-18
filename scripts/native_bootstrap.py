#!/usr/bin/env python3
"""One local native-time diagnostic, not an experiment runner. No Docker daemon.

All application/PG/world processes share one new loopback-only network namespace
and one bounded cgroup. Inputs are local immutable archives; outputs stay private.
"""
import argparse
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import uuid

WORLD_REVISION = "1c084c5a519ce0f0bc5c7ebee7014039f1e10a05"
WORLD_ARCHIVE = "992f10233ad9e87597cb9c5254ec3972b8e487b181a85b5296e14a7721e7a912"
WORLD_IMAGE = "8aa715e5b589afe2aeaaae016a1a75e4e5d0c30cddc155bb074dfae5e841e21c"
WORLD_CONTRACT = "fd600681ac05640e7669a236bc10e61fd28d795bdceebb605e56948bd84b609b"
INITIAL_WORLD = {"seed": 7192026, "reset_date": "2026-10-17", "time_scale": 1,
                 "market": "stock", "neighbours": 0, "agents": 0, "ships": 0}
LIMITS = {"wall_seconds": 240, "startup_seconds": 45, "requests": 240,
          "cpu_percent": 100, "memory_bytes": 3221225472, "tasks": 256,
          "storage_bytes": 2147483648}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write(path, value):
    Path(path).write_bytes(canonical(value) + b"\n")
    Path(path).chmod(0o600)


def resources(attempt):
    return {"attempt": attempt, "database": "sim_" + attempt,
            "username": "sim_" + attempt, "api_url": "http://127.0.0.1:4001/v2",
            "database_host": "127.0.0.1", "database_port": 5432,
            "isolation": "bwrap-private-user-pid-ipc-uts-net-systemd-cgroup-v1"}


def definition(revision, archive, schema, lock, postgres, attempt, controlled_world=None, epoch_ms=None):
    manifest = {"schema": "native-bootstrap/v1", "bootstrap_sha256": digest(__file__), "application": {
                "revision": revision, "archive_sha256": archive,
                "api_schema_sha256": schema, "mix_lock_sha256": lock},
            "world": {"revision": WORLD_REVISION, "archive_sha256": WORLD_ARCHIVE,
                      "image_sha256": WORLD_IMAGE, "contract_sha256": WORLD_CONTRACT},
            "postgres_archive_sha256": postgres, "initial_world": dict(INITIAL_WORLD),
            "resources": resources(attempt), "limits": dict(LIMITS),
            "mint": {"symbol": "SIM779", "faction": "COSMIC"},
            "negative_control": "none",
            "sequence": "migrate-world-ready-runtime-ready-register-mint-activate-observe",
            "strategy": {"objectives": [{"objective": "Grow credits", "kind": "continuous",
                "evaluation": "Maximize net credit growth over time", "scope": "recurring"}],
                "hard_constraints": ["Keep at least 50,000 credits available"],
                "preferences": ["Prefer lower-risk routes when expected returns are similar"],
                "consequences": "The Fleet may spend credits and accept bounded trading losses while preserving the credit floor."}}
    if controlled_world is not None:
        manifest.update(schema="navigation-tracer/v1", world=controlled_world,
                        initial_world={"contract": "world-control/v1", "scenario_id": "generated-starter/v1",
                            "world_id": "navigation-" + attempt, "epoch_ms": epoch_ms,
                            "reset_date": "2026-10-18", "random_streams": {
                                name: {"id": name + "-781-v1", "seed": seed}
                                for name, seed in [("generation", 7192026), ("gameplay", 781), ("external", 1781)]}})
        manifest["sequence"] = "migrate-controlled-world-ready-runtime-ready-register-mint-activate-coordinate-arrival"
        manifest["mint"] = {"symbol": "SIM781", "faction": "COSMIC"}
    return manifest


def validate(m):
    try:
        controlled = m["schema"] == "navigation-tracer/v1"
        if controlled:
            if set(m["world"]) != {"revision", "archive_sha256", "image_sha256", "contract_sha256", "input_inventory_sha256"}:
                raise ValueError("invalid controlled artifact identity")
            for key, value in m["world"].items():
                if not re.fullmatch(r"[0-9a-f]{40}" if key == "revision" else r"[0-9a-f]{64}", value):
                    raise ValueError("controlled artifact requires immutable hashes")
            if m["world"]["archive_sha256"] == WORLD_ARCHIVE:
                raise ValueError("native artifact is not controlled-world proof")
            epoch = m["initial_world"]["epoch_ms"]
            if type(epoch) is not int or epoch % 1000 or not 0 < epoch <= 4102444800000:
                raise ValueError("controlled world requires a whole-second pinned epoch")
        template = definition(m["application"]["revision"], m["application"]["archive_sha256"],
                              m["application"]["api_schema_sha256"], m["application"]["mix_lock_sha256"],
                              m["postgres_archive_sha256"], m["resources"]["attempt"],
                              m["world"] if controlled else None, epoch if controlled else None)
        if set(m) != set(template) or set(m["application"]) != set(template["application"]):
            raise ValueError("unknown or missing manifest field")
        for key in ["bootstrap_sha256", "world", "initial_world", "resources", "sequence", "schema", "mint"]:
            if canonical(m[key]) != canonical(template[key]):
                raise ValueError("unsupported " + key)
        if not re.fullmatch(r"[0-9a-f]{32}", m["resources"]["attempt"]):
            raise ValueError("invalid attempt identity")
        for key, value in m["application"].items():
            if not re.fullmatch(r"[0-9a-f]{40}" if key == "revision" else r"[0-9a-f]{64}", value):
                raise ValueError("application inputs must be immutable hashes")
        if not re.fullmatch(r"[0-9a-f]{64}", m["postgres_archive_sha256"]):
            raise ValueError("invalid PostgreSQL filesystem identity")
        if set(m["limits"]) != set(LIMITS):
            raise ValueError("unknown limit")
        for key, cap in LIMITS.items():
            value = m["limits"][key]
            if type(value) is not int or not 0 < value <= cap:
                raise ValueError("invalid or excessive " + key)
        if m["negative_control"] not in (["none", "incomplete_drain"] if controlled else ["none", "migration_unavailable", "world_unavailable"]):
            raise ValueError("unsupported negative control")
        strategy = m["strategy"]
        if set(strategy) != set(template["strategy"]) or not strategy["objectives"]:
            raise ValueError("invalid Strategy document")
        # The application's supported activation API performs semantic validation.
        if any(not isinstance(strategy[k], list) for k in ["objectives", "hard_constraints", "preferences"]):
            raise ValueError("invalid Strategy lists")
        return "sha256:" + hashlib.sha256(canonical(m)).hexdigest()
    except (KeyError, TypeError, AttributeError) as exc:
        raise ValueError("invalid bootstrap manifest") from exc


def reject_environment(env):
    forbidden = {"DATABASE_URL", "ENCRYPTION_KEY", "SECRET_KEY_BASE", "PHX_SERVER",
                 "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "ACCOUNT_TOKEN", "AGENT_TOKEN",
                 "PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD", "PGPASSFILE",
                 "PGSERVICE", "PGSERVICEFILE", "PGOPTIONS", "PGSSLMODE", "RELEASE_COOKIE"}
    if any(k.upper() in forbidden or k.upper().startswith(("POSTGRES_", "SPACETRADERS_")) for k in env):
        raise ValueError("inherited target/credential/proxy configuration rejected; use a clean environment")


def extract(archive, target, rootfs=False):
    target.mkdir(mode=0o700)
    with tarfile.open(archive) as t:
        members = t.getmembers()
        for member in members:
            p = Path(member.name)
            if p.is_absolute() or ".." in p.parts or not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("unsafe archive member")
            if rootfs and member.issym() and Path(member.linkname).is_absolute():
                # Preserve rootfs link semantics without allowing host-root links
                # during unprivileged extraction (tarfile's data filter checks it).
                member.linkname = os.path.relpath(member.linkname.lstrip("/"), p.parent)
            if member.issym() and (Path(member.linkname).is_absolute() or
                                   not (target / p.parent / member.linkname).resolve().is_relative_to(target.resolve())):
                raise ValueError("escaping archive symlink")
        t.extractall(target, members=members, filter="data")


def release_for(repo, supplied):
    expected = Path(repo).resolve() / "_build/prod/rel/spacetraders"
    if Path(supplied).resolve() != expected.resolve():
        raise ValueError("release path must be the output of this checkout's production build")
    return expected.resolve()


def remaining(deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise ValueError("shared startup deadline exhausted")
    return seconds


def shutdown_verified(exit_code, output):
    fields = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    return (exit_code == 0 and fields.get("LoadState") in ["loaded", "not-found"]
            and fields.get("ActiveState") in ["inactive", "failed"])


def prepare(args):
    reject_environment(os.environ)
    repo, release, out = map(lambda p: Path(p).resolve(), [args.repo, args.release, args.output])
    release = release_for(repo, release)
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=repo).strip():
        raise ValueError("commit application changes before building a pinned diagnostic artifact")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo).decode().strip()
    schema, lock = digest(repo / "priv/spec/SpaceTraders.json"), digest(repo / "mix.lock")
    out.mkdir(mode=0o700)
    # Build from the clean pinned checkout, using already-present dependencies.
    # No deps.get, upstream fetch, registry, live configuration or build overlay.
    with (out / "build.log").open("wb") as log:
        subprocess.run(["mix", "release", "--overwrite", "--path", str(release)], cwd=repo,
                       env=dict(os.environ, MIX_ENV="prod"), stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=300)
    write(release / "native-build.json", {"revision": revision, "api_schema_sha256": schema, "mix_lock_sha256": lock})
    archive = out / "application.tar"
    with tarfile.open(archive, "w", dereference=False) as t:
        for p in sorted(release.iterdir()):
            t.add(p, arcname=p.name)
    archive.chmod(0o600)
    controlled = None
    if args.controlled_world:
        receipt = json.loads(Path(args.controlled_world).read_text())
        if receipt["schema"] != "controlled-world-artifact/v1":
            raise ValueError("controlled artifact receipt required")
        controlled = {k: receipt[k] for k in ["revision", "archive_sha256", "image_sha256", "contract_sha256", "input_inventory_sha256"]}
    m = definition(revision, digest(archive), schema, lock, digest(args.postgres), uuid.uuid4().hex,
                   controlled, int(time.time()) * 1000 if controlled else None)
    validate(m)
    write(out / "manifest.json", m)
    print(out / "manifest.json")


def start(args):
    reject_environment(os.environ)
    m = json.loads(Path(args.manifest).read_text())
    identity = validate(m)
    if digest(args.application) != m["application"]["archive_sha256"] or digest(args.world) != m["world"]["archive_sha256"]:
        raise ValueError("artifact checksum mismatch")
    if digest(args.postgres) != m["postgres_archive_sha256"]:
        raise ValueError("PostgreSQL filesystem checksum mismatch")
    out = Path(args.output).resolve()
    out.mkdir(mode=0o700)  # exclusive: no attempt reset/retry/overwriting evidence
    if out.stat().st_mode & 0o077:
        raise ValueError("output must be private")
    write(out / "manifest.json", m)
    write(out / "identity.json", {"definition": identity, "parent_network_namespace": os.readlink("/proc/self/ns/net")})
    runtime = out / "runtime"
    runtime.mkdir(mode=0o700)
    for name in ["manifest.json", "identity.json"]:
        shutil.copyfile(out / name, runtime / name)
    started = time.monotonic()
    result = {"definition": identity, "state": "harness_failure", "stage": "artifact_preflight"}
    unit = "st-native-" + m["resources"]["attempt"]
    try:
        extract(Path(args.application), out / "application")
        if json.loads((out / "application/native-build.json").read_text()) != {
                k: v for k, v in m["application"].items() if k != "archive_sha256"}:
            raise ValueError("application archive provenance mismatch")
        extract(Path(args.world), out / "image")
        world_image = m["world"]["image_sha256"]
        config = json.loads((out / "image" / (world_image + ".json")).read_text())
        if digest(out / "image" / (world_image + ".json")) != world_image:
            raise ValueError("image configuration identity mismatch")
        image_manifest = json.loads((out / "image/manifest.json").read_text())
        layers = image_manifest[0]["Layers"]
        if len(layers) != 1 or config["rootfs"]["diff_ids"] != ["sha256:" + digest(out / "image" / layers[0])]:
            raise ValueError("world image layer identity mismatch")
        extract(out / "image" / layers[0], out / "world")
        if m["schema"] == "navigation-tracer/v1":
            labels = config["config"]["Labels"]
            if labels.get("private.source") != m["world"]["revision"] or labels.get("private.inputs") != m["world"]["input_inventory_sha256"]:
                raise ValueError("controlled image source/input provenance mismatch")
            if config["config"]["Entrypoint"][-5:] != ["serve-controlled", "--port", "4000", "--controller-token-file", "/out/world-controller"]:
                raise ValueError("unsupported controlled entrypoint")
        extract(Path(args.postgres), out / "postgres-image", rootfs=True)
        # The pinned artifact's own entrypoint is the initial-world authority.
        write(out / "world-entrypoint.json", config["config"]["Entrypoint"])
        shutil.copyfile(out / "world-entrypoint.json", runtime / "world-entrypoint.json")
        for name in ["pg", "socket"]:
            (runtime / name).mkdir(mode=0o700)
        (out / "passwd").write_text(f"sim:x:{os.getuid()}:{os.getgid()}:simulation:/tmp:/bin/sh\n")
        (out / "group").write_text(f"sim:x:{os.getgid()}:\n")
        allocated = sum(p.stat().st_blocks * 512 for p in out.rglob("*") if p.is_file())
        if allocated + 536870912 > m["limits"]["storage_bytes"] or os.statvfs(out).f_bavail * os.statvfs(out).f_frsize < 2**31:
            raise ValueError("diagnostic storage admission failed")
        command = ["/usr/bin/bwrap", "--unshare-user", "--unshare-pid", "--unshare-ipc",
                   "--unshare-net", "--unshare-uts", "--die-with-parent", "--new-session",
                   "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
                   "--size", "134217728", "--tmpfs", "/database",
                   "--dir", "/run", "--dir", "/etc", "--ro-bind", "/usr", "/usr",
                   "--ro-bind", str(out / "passwd"), "/etc/passwd", "--ro-bind", str(out / "group"), "/etc/group",
                   "--ro-bind", "/lib", "/lib", "--ro-bind", "/lib64", "/lib64",
                   "--ro-bind", "/bin", "/bin", "--ro-bind", "/sys/fs/cgroup", "/sys/fs/cgroup",
                   "--ro-bind", str(out / "application"), "/app",
                   "--ro-bind", str(out / "world"), "/worldfs",
                   "--ro-bind", str(out / "postgres-image"), "/pgfs",
                   "--bind", str(runtime), "/out",
                   "--ro-bind", str(runtime / "manifest.json"), "/out/manifest.json",
                   "--ro-bind", str(Path(__file__).resolve()), "/bootstrap.py",
                   "--clearenv", "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", "/tmp",
                   "--setenv", "LANG", "C.UTF-8", "--chdir", "/tmp",
                   "/usr/bin/python3", "/bootstrap.py", "inside"]
        limits = m["limits"]
        result["stage"] = "isolated_start"
        with (out / "controller.log").open("wb") as log:
            completed = subprocess.run(["systemd-run", "--user", "--quiet", "--wait", "--pipe",
                "--unit=" + unit, "--property=Type=exec", "--property=CPUQuota=" + str(limits["cpu_percent"]) + "%",
                "--property=MemoryMax=" + str(limits["memory_bytes"]), "--property=MemorySwapMax=0",
                "--property=TasksMax=" + str(limits["tasks"]),
                "--property=RuntimeMaxSec=" + str(max(1, int(limits["wall_seconds"] - (time.monotonic() - started) - 15))),
                "--property=TimeoutStopSec=5", "--property=KillMode=control-group", *command],
                stdout=log, stderr=subprocess.STDOUT, timeout=limits["wall_seconds"] + 15)
        result["exit_code"] = completed.returncode
        if (runtime / "bootstrap.json").exists():
            result.update(json.loads((runtime / "bootstrap.json").read_text()))
        if completed.returncode != 0:
            result["state"] = "harness_failure"
        if result["state"] == "passed":
            evidence = result["evidence"]
            receipts = [json.loads(line) for line in (runtime / "http.jsonl").read_text().splitlines()]
            matching = [r for r in receipts if r.get("navigation", {}).get("destination") == evidence["target_waypoint"]
                        and r["method"] == "POST" and r["status"] == 200
                        and r["path"] == "/v2/my/ships/" + evidence["ship_symbol"] + "/navigate"]
            if not matching or evidence["operation_id"] != "navigate-ship" or evidence["observation_count"] <= 0:
                raise ValueError("durable bootstrap has no matching authoritative HTTP navigation consequence")
            result["navigation_receipt"] = matching[0]
            if m["schema"] == "navigation-tracer/v1":
                validate_arrival_proof(runtime, result)
    except Exception as exc:
        result["state"] = "harness_failure"
        result["error"] = str(exc)
    finally:
        # Bounded cgroup stop also covers lost launcher responses and grandchildren.
        result.update(owned_shutdown=False, qualification=("narrow_navigation_arrival_not_full_drain_or_full_period"
                      if m["schema"] == "navigation-tracer/v1" else "native_time_bootstrap_only_not_gameplay_or_full_period"))
        try:
            stopped = subprocess.run(["systemctl", "--user", "stop", unit], capture_output=True, timeout=15)
            inspection = subprocess.run(["systemctl", "--user", "show", unit,
                                         "--property=LoadState", "--property=ActiveState"], capture_output=True, timeout=5)
            result.update(owned_shutdown=shutdown_verified(inspection.returncode, inspection.stdout.decode()),
                          shutdown_command_exit=stopped.returncode, shutdown_inspection_exit=inspection.returncode,
                          shutdown_state=inspection.stdout.decode().strip())
        except Exception as exc:
            result["shutdown_error"] = type(exc).__name__
        result["wall_seconds"] = time.monotonic() - started
        if not result["owned_shutdown"]:
            result["state"] = "harness_failure"
        write(out / "result.json", result)
        write(out / "checksums.json", {str(p.relative_to(out)): digest(p) for p in runtime.rglob("*")
                                       if p.is_file() and not p.is_symlink()})
    print(json.dumps(result, sort_keys=True))
    return 0 if result["state"] == "passed" else 1


class RequestBudget:
    """Real HTTP forwarding only: no responses, intelligence or gameplay policy invented."""
    def __init__(self, limit):
        self.limit, self.count = limit, 0
        self.lock = threading.Lock()
        self.exceeded = threading.Event()

    def take(self):
        with self.lock:
            if self.count >= self.limit:
                self.exceeded.set()
                raise ValueError("HTTP request ceiling exhausted")
            self.count += 1
            return self.count


def navigation_receipt(method, path, status, body):
    if method != "POST" or status != 200 or not re.fullmatch(r"/v2/my/ships/[A-Z0-9_-]+/navigate", path):
        return None
    nav = json.loads(body)["data"]["nav"]
    return {"status": nav["status"], "waypoint": nav["waypointSymbol"],
            "destination": nav["route"]["destination"]["symbol"], "arrival": nav["route"]["arrival"]}


def proxy(budget):
    class Forward(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def forward(self):
            conn = http.client.HTTPConnection("127.0.0.1", 4000, timeout=3)
            number = None
            try:
                number = budget.take()
                if not self.path.startswith("/v2/") or ".." in self.path or self.headers.get("Transfer-Encoding"):
                    raise ValueError("invalid HTTP target/framing")
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 <= size <= 1048576:
                    raise ValueError("request body ceiling")
                body = self.rfile.read(size)
                headers = {k: v for k, v in self.headers.items() if k.lower() not in ["host", "connection", "proxy-authorization"]}
                headers.update(Host="stsim", Connection="close")
                conn.request(self.command, self.path, body, headers)
                response = conn.getresponse()
                data = response.read(1048577)
                if len(data) > 1048576:
                    raise ValueError("response body ceiling")
                with open("/out/http.jsonl", "a") as log:
                    receipt = {"number": number, "method": self.command, "path": self.path,
                               "status": response.status, "body_sha256": hashlib.sha256(data).hexdigest()}
                    navigation = navigation_receipt(self.command, self.path, response.status, data)
                    if navigation:
                        receipt["navigation"] = navigation
                    log.write(json.dumps(receipt) + "\n")
                self.send_response(response.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                # Preserve scarcity/retry headers; never follow redirects.
                for k, v in response.getheaders():
                    if k.lower() in ["retry-after", "x-ratelimit-remaining", "x-ratelimit-limit", "x-ratelimit-reset"]:
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)
            except Exception as error:
                if number is not None:
                    with open("/out/http.jsonl", "a") as log:
                        log.write(json.dumps({"number": number, "method": self.command, "path": self.path,
                                              "status": None, "transport_error": type(error).__name__}) + "\n")
                self.send_error(503, "bounded bootstrap HTTP transport failure")
            finally:
                conn.close()

        do_GET = do_POST = do_PATCH = do_DELETE = do_PUT = forward

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 4001), Forward)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def initialize_controlled_world(m, world, deadline):
    token = Path("/out/world-controller").read_text()
    for suffix, payload, expected in [("contract", None, 200), ("initialize", m["initial_world"], 201)]:
        while True:
            if world.poll() is not None:
                raise ValueError("controlled world exited before readiness")
            conn = http.client.HTTPConnection("127.0.0.1", 4000, timeout=min(3, remaining(deadline)))
            try:
                conn.request("POST" if payload else "GET", "/_control/world/" + suffix,
                             canonical(payload) if payload else None,
                             {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
                response = conn.getresponse()
                data = response.read(1048577)
                if len(data) > 1048576 or response.status != expected:
                    raise ValueError("controlled world rejected readiness/initialization")
                body = json.loads(data)
                if suffix == "contract":
                    if hashlib.sha256(canonical(body)).hexdigest() != m["world"]["contract_sha256"]:
                        raise ValueError("controlled-world contract mismatch")
                    write("/out/world-control-contract.json", body)
                else:
                    write("/out/world-initialized.json", body)
                break
            except ConnectionRefusedError:
                remaining(deadline)
                time.sleep(0.1)
            finally:
                conn.close()


def validate_arrival_proof(runtime, result):
    evidence = result["evidence"]
    trace = json.loads((runtime / "time-trace.json").read_text())
    export = json.loads((runtime / "world-export.json").read_text())
    arrivals = [e for e in export["settled_events"] if e["class"] == "arrival"
                and e["ship"] == evidence["ship_symbol"] and e["destination"] == evidence["target_waypoint"]]
    if not arrivals or evidence["intent_status"] != "completed":
        raise ValueError("no authoritative Arrival/completed continuation")
    boundaries = [e for e in trace if e["phase"] == "world_settled"]
    if not boundaries or any(a["at"] >= b["at"] for a, b in zip(boundaries, boundaries[1:])):
        raise ValueError("non-increasing semantic advancement")
    for settled in boundaries:
        release = trace[settled["ordinal"]]
        if release["phase"] != "bot_released" or release["at"] != settled["at"]:
            raise ValueError("world-before-bot ordering absent")
    result["arrival_settlements"] = arrivals
    result["coverage"] = "navigation intelligence Arrival; closed synchronous participant set; not #782/#783/#784"


def inside():
    os.umask(0o077)
    out = Path("/out")
    # RLIMIT_FSIZE also caps anonymous BEAM JIT memfds and prevents VM startup.
    # The cgroup bounds JIT memory; the database has a quota-sized tmpfs.
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    Path("/database/pg").mkdir(mode=0o700)
    m = json.loads((out / "manifest.json").read_text())
    validate(m)
    startup_started = time.monotonic()
    startup_deadline = startup_started + m["limits"]["startup_seconds"]
    startup_deadline_unix_ms = int((time.time() + m["limits"]["startup_seconds"]) * 1000)
    interfaces = {line.split(":")[0].strip() for line in Path("/proc/net/dev").read_text().splitlines() if ":" in line}
    parent = json.loads((out / "identity.json").read_text())["parent_network_namespace"]
    if interfaces != {"lo"} or os.readlink("/proc/self/ns/net") == parent:
        raise ValueError("private network namespace not established")
    cgroup = Path("/sys/fs/cgroup") / Path("/proc/self/cgroup").read_text().strip().split("::", 1)[1].lstrip("/")
    actual = {key: (cgroup / key).read_text().strip() for key in ["cpu.max", "memory.max", "memory.swap.max", "pids.max"]}
    quota, period = map(int, actual["cpu.max"].split())
    if (quota / period > m["limits"]["cpu_percent"] / 100 or
        int(actual["memory.max"]) > m["limits"]["memory_bytes"] or actual["memory.swap.max"] != "0" or
        int(actual["pids.max"]) > m["limits"]["tasks"]):
        raise ValueError("resource cgroup limits not enforced")
    write(out / "isolation.json", {"interfaces": sorted(interfaces), "network_namespace": os.readlink("/proc/self/ns/net"),
                                   "cgroup": actual, "home_visible": Path("/home/ben").exists(),
                                   "host_socket_visible": Path("/var/run/postgresql").exists()})
    children, logs = [], []
    budget = None
    server = None
    result = {"state": "harness_failure", "stage": "database_initialization"}
    env = dict(os.environ, ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1 +A 1", RELEASE_DISTRIBUTION="none",
               RELEASE_TMP="/tmp/release", ERL_CRASH_DUMP="/out/application-crash.dump",
               ERL_CRASH_DUMP_BYTES="8388608",
               SPACETRADERS_NATIVE_STARTUP_DEADLINE_MS=str(startup_deadline_unix_ms),
               SPACETRADERS_NATIVE_BOOTSTRAP="/out/manifest.json",
               SPACETRADERS_NATIVE_MANIFEST_SHA256=digest(out / "manifest.json"))

    def run(command, name):
        with (out / (name + ".log")).open("wb") as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True,
                           timeout=remaining(startup_deadline))

    def spawn(command, name):
        remaining(startup_deadline)
        log = (out / (name + ".log")).open("wb")
        logs.append(log)
        child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(child)
        return child

    def pg_command(*args):
        return ["/usr/bin/bwrap", "--unshare-user", "--uid", "999", "--gid", "999",
                "--die-with-parent", "--ro-bind", "/pgfs", "/", "--proc", "/proc",
                "--dev", "/dev", "--tmpfs", "/tmp",
                "--bind", "/database/pg", "/var/lib/postgresql/data",
                "--bind", "/out/socket", "/var/run/postgresql",
                "--clearenv", "--setenv", "HOME", "/tmp", "--setenv", "LANG", "C.UTF-8",
                "--setenv", "PATH", "/usr/lib/postgresql/17/bin:/usr/bin:/bin", *args]

    try:
        user, database = m["resources"]["username"], m["resources"]["database"]
        run(pg_command("initdb", "-D", "/var/lib/postgresql/data", "-U", user,
                       "--auth-local=trust", "--auth-host=reject", "--no-locale"), "initdb")
        # Socket and loopback are inside the private namespace, not host sockets.
        Path("/database/pg/pg_hba.conf").write_text("local all all trust\nhost all all 127.0.0.1/32 trust\n")
        spawn(pg_command("postgres", "-D", "/var/lib/postgresql/data", "-k", "/var/run/postgresql", "-h", "127.0.0.1",
                         "-c", "shared_buffers=32MB", "-c", "max_connections=20"), "postgres")
        while subprocess.run(pg_command("pg_isready", "-h", "/var/run/postgresql", "-U", user), capture_output=True,
                             timeout=min(2, remaining(startup_deadline))).returncode:
            remaining(startup_deadline)
            time.sleep(0.1)
        run(pg_command("createdb", "-h", "/var/run/postgresql", "-U", user, database), "createdb")
        result["stage"] = "migrations"
        if m["negative_control"] == "migration_unavailable":
            children[-1].terminate()
            children[-1].wait(timeout=5)
        run(["/app/bin/spacetraders", "eval", "SpaceTraders.Release.migrate()"], "migrations")
        result["stage"] = "world_readiness"
        controlled = m["schema"] == "navigation-tracer/v1"
        if controlled:
            (out / "world-controller").write_text(uuid.uuid4().hex + uuid.uuid4().hex)
            (out / "world-controller").chmod(0o600)
        world = spawn(["/usr/bin/bwrap", "--unshare-user", "--die-with-parent",
                        "--ro-bind", "/worldfs", "/", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
                        *(["--ro-bind", "/out/world-controller", "/out/world-controller"] if controlled else []),
                       "--clearenv", "--setenv", "HOME", "/tmp", "--setenv", "PATH", "/usr/bin:/bin",
                       "--setenv", "ERL_ROOTDIR", "/opt/otp", "--chdir", "/opt/stsim",
                       *json.loads((out / "world-entrypoint.json").read_text())], "world")
        if m["negative_control"] == "world_unavailable":
            world.terminate()
            world.wait(timeout=5)
        budget = RequestBudget(m["limits"]["requests"])
        server = proxy(budget)
        if controlled:
            initialize_controlled_world(m, world, startup_deadline)
        while True:
            if world.poll() is not None:
                raise ValueError("world exited before semantic readiness")
            try:
                conn = http.client.HTTPConnection("127.0.0.1", 4001, timeout=min(2, remaining(startup_deadline)))
                conn.request("GET", "/v2/")
                response = conn.getresponse()
                body = json.loads(response.read(1048576))
                conn.close()
                if response.status != 200 or body.get("status") != "stsim: SpaceTraders simulator":
                    raise ValueError("world API identity mismatch")
                expected = {"version": "v2", "resetDate": m["initial_world"]["reset_date"], "simTimeScale": 1}
                if any(body.get(k) != v for k, v in expected.items()) or body.get("stats", {}).get("agents") != 0 or body.get("stats", {}).get("ships") != 0:
                    raise ValueError("initial world identity mismatch")
                write(out / "world-ready.json", body)
                break
            except (OSError, json.JSONDecodeError):
                remaining(startup_deadline)
                time.sleep(0.5)
        result["stage"] = "autonomous_bootstrap"
        app = spawn(["/app/bin/spacetraders", "start"], "application")
        app_deadline = time.monotonic() + max(1, m["limits"]["wall_seconds"] - 60)
        startup_complete = False
        while app.poll() is None:
            if not startup_complete:
                if (out / "bootstrap.json").exists():
                    checkpoint = json.loads((out / "bootstrap.json").read_text())
                    ready_at = checkpoint.get("startup_ready_unix_ms")
                    if ready_at is not None:
                        if ready_at > startup_deadline_unix_ms:
                            raise ValueError("application exceeded shared startup deadline")
                        startup_complete = True
                if not startup_complete:
                    remaining(startup_deadline)
            if budget.exceeded.is_set():
                raise ValueError("HTTP request ceiling exhausted")
            if time.monotonic() >= app_deadline:
                raise ValueError("application wall deadline exhausted")
            time.sleep(0.1)
        code = app.returncode
        if budget.exceeded.is_set():
            raise ValueError("HTTP request ceiling exhausted")
        if (out / "bootstrap.json").exists():
            result.update(json.loads((out / "bootstrap.json").read_text()))
            if result.get("startup_ready_unix_ms", startup_deadline_unix_ms + 1) > startup_deadline_unix_ms:
                raise ValueError("application did not meet shared startup deadline")
        if code != 0:
            raise ValueError("application failed; inspect private application.log")
        result["requests"] = budget.count
    except Exception as exc:
        result.update(state="harness_failure", error=str(exc))
    finally:
        if budget is not None:
            result["requests"] = budget.count
        if server:
            server.shutdown()
            server.server_close()
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
        for log in logs:
            log.close()
        # Preserve the bounded cluster after an ordinary success/startup failure.
        # Hard cgroup death can leave an incomplete archive; no recovery claim.
        shutil.copytree("/database/pg", out / "pg", dirs_exist_ok=True)
        write(out / "bootstrap.json", result)
    return 0 if result["state"] == "passed" else 1


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    for key in ["repo", "release", "postgres", "output"]:
        p.add_argument("--" + key, required=True)
    p.add_argument("--controlled-world", help="new private controlled-artifact.json; never the native artifact")
    p = sub.add_parser("start")
    for key in ["manifest", "application", "world", "postgres", "output"]:
        p.add_argument("--" + key, required=True)
    p = sub.add_parser("validate")
    p.add_argument("manifest")
    sub.add_parser("inside")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
    elif args.command == "start":
        return start(args)
    elif args.command == "validate":
        print(validate(json.loads(Path(args.manifest).read_text())))
    else:
        return inside()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("native bootstrap: " + str(error), file=sys.stderr)
        sys.exit(1)
