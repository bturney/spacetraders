#!/usr/bin/env python3
"""Offline attempt evidence. No gameplay, restore, cleanup or retention authority."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import struct
import subprocess
import tarfile
import tempfile
import time
import zipfile

VERSION = "attempt-bundle/v2"
MAX_BYTES = 128 * 1024 * 1024
# Portable SQL columns, not Ecto loading/decryption or SELECT *. Add fields only
# after inspecting their owner. Credential-bearing tables are never exported.
TABLES = {
    "fleet_strategy_revisions": "id number document source activated_at fleet_strategy_id inserted_at",
    "operators": "id confirmed_at inserted_at updated_at",
    "agents": "id symbol faction headquarters stale_at operator_id inserted_at updated_at",
    "current_fleet_identity": "id operator_id fleet_generation_id",
    "fleet_strategies": "id draft_document draft_source draft_version revision_number active_revision_id emergency_stopped_at emergency_resume_prepared_at emergency_stop_version operator_id inserted_at updated_at",
    "fleet_generations": "id number symbol faction replacement_symbols objective_progress starting_credits last_observed_credits last_observed_at last_observed_evidence_id allocation_version strategy_capable_at fenced_at retired_at operator_id agent_id fleet_strategy_revision_id initial_fleet_strategy_revision_id inserted_at updated_at",
    "strategy_decision_episodes": "id source_version evidence_references alternatives binding_constraints expectations actual_outcomes calibration_version selection_kind rejection_reason binding_limitation_kind next_observation_at stall_reason stalled_portfolio_id last_observed_at observation_count resolved_at classification operator_id fleet_generation_id fleet_strategy_revision_id inserted_at updated_at",
    "fleet_commitment_portfolios": "id version superseded_at operator_id fleet_generation_id fleet_strategy_revision_id strategy_decision_episode_id inserted_at",
    "fleet_commitments": "id candidate_id objective_index claims reservations pledges dependencies expected_value unwind_cost unwind_state decisive_reason fleet_commitment_portfolio_id replan_decision_episode_id inserted_at",
    "intents": "id caller type target_waypoint parameters review_revision status blocker in_flight_action mutation_attempt_id last_action_result recovery_attempts finished_at fleet_commitment_portfolio_version ship_id fleet_commitment_id fleet_commitment_portfolio_id inserted_at updated_at",
    "mutation_attempts": "id operation_id operation_owner state request_fingerprint prepared_evidence expected_effects consequence_bounds dependency_keys admitted_bounded_unknown_ids retry_authorized provenance prepared_at sent_or_unknown_at operator_id agent_id fleet_generation_id strategy_revision_id retry_of_id inserted_at updated_at",
    "mutation_attempt_outcomes": "id classification evidence recorded_at mutation_attempt_id inserted_at",
    "authoritative_observations": "id subject operation_id dependency_keys facts response_fingerprint observed_at fleet_generation_id agent_id inserted_at",
    "observation_demands": "id subject required_facts freshness_seconds due_at deadline_at deadline_missed_at owner withdrawn_at agent_id strategy_revision_id fulfilled_observation_id replaces_id inserted_at updated_at",
    "ships": "id symbol ship_type agent_id retired_at inserted_at updated_at",
    "timeline_events": "id owner_type owner_id event_type due_at status payload inserted_at updated_at",
    "credit_realizations": "id operation_id unit_price units worst_case_exposure realized_charge credits_after within_bound agent_id mutation_attempt_id calibration_version_id credit_shortfall_id inserted_at",
    "credit_calibration_versions": "id version margin_percent basis evidence previous_version_id mutation_attempt_id inserted_at",
    "credit_shortfalls": "id kind credits credit_floor worst_case_exposure realized_charge evidence detected_at released_at release_evidence agent_id mutation_attempt_id calibration_version_id widened_calibration_version_id strategy_revision_id inserted_at updated_at",
    "intelligence_observations": "id observing_ship_symbol source subject_type subject_system_symbol subject_symbol observed_at agent_id evidence_observation_id inserted_at updated_at",
    "intelligence_facts": "id subject_type subject_system_symbol subject_symbol field state value invalidated_at agent_id observation_id inserted_at updated_at",
    "fleet_activity": "id kind message metadata agent_id ship_id inserted_at updated_at",
    "mission_conditions": "id key kind summary entity_ref acknowledged_at resolved_at operator_id fleet_generation_id fleet_strategy_revision_id strategy_decision_episode_id inserted_at updated_at",
    "ship_reservations": "id ship_id ship_symbol operator_id reason released_at inserted_at updated_at",
    "manual_interventions": "id ship_reservation_id intent_id reason target_waypoint final_status inserted_at updated_at",
    "outbox_notifications": "id topic event payload delivered_at inserted_at",
    "runtime_authority": "name store advanced_at",
    "surveys": "id waypoint_symbol signature symbol size expiration deposits source observing_ship_symbol observed_at exhausted_at agent_id inserted_at updated_at",
    "allocation_result_pointers": "fleet_generation_id selection_kind operator_id fleet_strategy_revision_id strategy_decision_episode_id inserted_at",
    "fleet_commitment_claims": "id fleet_commitment_portfolio_id fleet_commitment_id resource",
    "ship_destination_history": "id waypoint_symbol position ship_id inserted_at updated_at",
}
PRIMARY_KEYS = {"runtime_authority": "name", "allocation_result_pointers": "fleet_generation_id"}

# Nested Bindings, CreditSpending/CreditCalibration and transfer preparation all
# reference Evidence.Observation UUIDs. Row-level Intelligence observation_id is
# a different owner and stays in JOINS; never infer an owner from an ID suffix.
NESTED_REFERENCE_OWNERS = {
    "observation_id": "authoritative_observations",
    "quote_observation_id": "authoritative_observations",
    "credit_observation_id": "authoritative_observations",
    "source_observation_id": "authoritative_observations",
    "target_observation_id": "authoritative_observations",
}

JOINS = {
    "agents": {"operator_id": "operators"},
    "current_fleet_identity": {"operator_id": "operators", "fleet_generation_id": "fleet_generations"},
    "fleet_strategies": {"operator_id": "operators", "active_revision_id": "fleet_strategy_revisions"},
    "fleet_strategy_revisions": {"fleet_strategy_id": "fleet_strategies"},
    "ships": {"agent_id": "agents"},
    "fleet_generations": {"fleet_strategy_revision_id": "fleet_strategy_revisions", "initial_fleet_strategy_revision_id": "fleet_strategy_revisions", "last_observed_evidence_id": "authoritative_observations"},
    "strategy_decision_episodes": {"fleet_generation_id": "fleet_generations", "fleet_strategy_revision_id": "fleet_strategy_revisions", "stalled_portfolio_id": "fleet_commitment_portfolios"},
    "fleet_commitment_portfolios": {"fleet_generation_id": "fleet_generations", "fleet_strategy_revision_id": "fleet_strategy_revisions", "strategy_decision_episode_id": "strategy_decision_episodes"},
    "fleet_commitments": {"fleet_commitment_portfolio_id": "fleet_commitment_portfolios", "replan_decision_episode_id": "strategy_decision_episodes"},
    "intents": {"ship_id": "ships", "fleet_commitment_id": "fleet_commitments", "fleet_commitment_portfolio_id": "fleet_commitment_portfolios", "mutation_attempt_id": "mutation_attempts"},
    "mutation_attempts": {"fleet_generation_id": "fleet_generations", "strategy_revision_id": "fleet_strategy_revisions", "retry_of_id": "mutation_attempts"},
    "mutation_attempt_outcomes": {"mutation_attempt_id": "mutation_attempts"},
    "authoritative_observations": {"fleet_generation_id": "fleet_generations"},
    "observation_demands": {"strategy_revision_id": "fleet_strategy_revisions", "fulfilled_observation_id": "authoritative_observations", "replaces_id": "observation_demands"},
    "credit_realizations": {"mutation_attempt_id": "mutation_attempts", "calibration_version_id": "credit_calibration_versions", "credit_shortfall_id": "credit_shortfalls"},
    "credit_calibration_versions": {"previous_version_id": "credit_calibration_versions", "mutation_attempt_id": "mutation_attempts"},
    "credit_shortfalls": {"mutation_attempt_id": "mutation_attempts", "calibration_version_id": "credit_calibration_versions", "widened_calibration_version_id": "credit_calibration_versions", "strategy_revision_id": "fleet_strategy_revisions"},
    "intelligence_observations": {"evidence_observation_id": "authoritative_observations"},
    "intelligence_facts": {"observation_id": "intelligence_observations"},
    "mission_conditions": {"fleet_generation_id": "fleet_generations", "fleet_strategy_revision_id": "fleet_strategy_revisions", "strategy_decision_episode_id": "strategy_decision_episodes"},
    "ship_reservations": {"ship_id": "ships"},
    "manual_interventions": {"ship_reservation_id": "ship_reservations", "intent_id": "intents"},
    "allocation_result_pointers": {"fleet_generation_id": "fleet_generations", "fleet_strategy_revision_id": "fleet_strategy_revisions", "strategy_decision_episode_id": "strategy_decision_episodes"},
    "fleet_commitment_claims": {"fleet_commitment_portfolio_id": "fleet_commitment_portfolios", "fleet_commitment_id": "fleet_commitments"},
    "ship_destination_history": {"ship_id": "ships"},
}
for _table, _columns in TABLES.items():
    for _field, _target in [("operator_id", "operators"), ("agent_id", "agents")]:
        if _field in _columns.split():
            JOINS.setdefault(_table, {})[_field] = _target


def require(condition, message):
    if not condition:
        raise ValueError(message)


def data_term(value):
    """Encode ONLY JSON data as OTP deterministic ETF; no VM or dump execution."""
    if value is None or type(value) is bool:
        atom = {None: b"null", True: b"true", False: b"false"}[value]
        return b"w" + bytes([len(atom)]) + atom
    if type(value) is int:
        if 0 <= value <= 255:
            return b"a" + bytes([value])
        if -(2 ** 31) <= value < 2 ** 31:
            return b"b" + struct.pack(">i", value)
        number = abs(value)
        digits = number.to_bytes((number.bit_length() + 7) // 8, "little")
        prefix = b"n" + bytes([len(digits)]) if len(digits) < 256 else b"o" + struct.pack(">I", len(digits))
        return prefix + bytes([value < 0]) + digits
    if type(value) is float:
        return b"F" + struct.pack(">d", value)
    if isinstance(value, str):
        data = value.encode()
        return b"m" + struct.pack(">I", len(data)) + data
    if isinstance(value, list):
        if not value:
            return b"j"
        if len(value) <= 65535 and all(type(item) is int and 0 <= item <= 255 for item in value):
            return b"k" + struct.pack(">H", len(value)) + bytes(value)
        return b"l" + struct.pack(">I", len(value)) + b"".join(data_term(v) for v in value) + b"j"
    if isinstance(value, dict):
        require(all(isinstance(k, str) for k in value), "world map keys must be strings")
        return b"t" + struct.pack(">I", len(value)) + b"".join(data_term(k) + data_term(value[k]) for k in sorted(value))
    raise ValueError("world contains non-data term")


def decode_data_term(data):
    """Bounded ETF data subset. Reject functions, modules, refs, PIDs, compressed
    terms and unknown tags. Improper RNG lists remain tagged data, not code.
    Never calls binary_to_term/eval."""
    require(len(data) <= 1024 * 1024 and data[:1] == b"\x83", "invalid native data header/size")
    offset, nodes = 1, 0

    def take(count):
        nonlocal offset
        require(0 <= count <= len(data) - offset, "truncated native data")
        result = data[offset:offset + count]
        offset += count
        return result

    def integer(count):
        return int.from_bytes(take(count), "big")

    def read(depth=0):
        nonlocal nodes
        nodes += 1
        require(depth <= 64 and nodes <= 100000, "native data complexity limit")
        tag = integer(1)
        if tag == 97:
            return integer(1)
        if tag == 98:
            return int.from_bytes(take(4), "big", signed=True)
        if tag in [110, 111]:
            count = integer(1 if tag == 110 else 4)
            sign = integer(1)
            require(sign in [0, 1] and count <= 4096, "invalid native integer")
            return int.from_bytes(take(count), "little") * (-1 if sign else 1)
        if tag in [119, 118, 100, 115]:
            count = integer(1 if tag in [119, 115] else 2)
            return take(count).decode("utf8" if tag in [119, 118] else "latin1")
        if tag in [104, 105]:
            count = integer(1 if tag == 104 else 4)
            require(count <= 100000, "native tuple size limit")
            return tuple(read(depth + 1) for _ in range(count))
        if tag == 106:
            return []
        if tag == 107:
            return list(take(integer(2)))
        if tag == 108:
            count = integer(4)
            require(count <= 100000, "native list size limit")
            result = [read(depth + 1) for _ in range(count)]
            tail = read(depth + 1)
            return result if tail == [] else {"$improper_list": result, "tail": tail}
        if tag == 109:
            return {"$binary": base64.b64encode(take(integer(4))).decode()}
        raise ValueError("executable or unsupported native data tag denied")

    result = read()
    require(offset == len(data), "trailing native data")
    return result


def validate_world(world):
    if world["schema"] == "authoritative-world-export/v1":
        require({"world", "identity", "current_time", "epoch_ms", "random_state", "settled_events", "limiter", "request_log", "coverage", "time_unit"} <= set(world), "required world evidence missing")
        require(world["hash_encoding"] == "erlang_external_term_deterministic/v1", "unsupported world hash encoding")
        state = {k: v for k, v in world.items() if k not in ["state_sha256", "hash_encoding"]}
        require(sha(b"\x83" + data_term(state)) == world["state_sha256"], "world state hash mismatch")
        require(world.get("credentials") == "omitted_no_restore_contract", "world credentials not omitted")
        require(set(world["random_state"]) == {"gameplay", "external"}, "required RNG evidence missing")
        require(world["world"]["now"] == world["current_time"] and world["identity"]["epoch_ms"] == world["epoch_ms"] == world["world"]["epoch_ms"], "world time/identity disagreement")
        for rng in world["random_state"].values():
            require(rng["encoding"] == "otp_rand_export_seed_external_term_base64/v1", "unsupported RNG encoding")
            decode_data_term(base64.b64decode(rng["value"], validate=True))
    else:
        require(world["schema"] == "portable-world/v1", "unsupported world schema")
        state = {k: v for k, v in world.items() if k not in ["state_sha256", "hash_encoding"]}
        require(world["hash_encoding"] == "canonical-json/v1" and sha(canonical(state)) == world["state_sha256"], "world state hash mismatch")
    require(isinstance(world["world"], dict) and isinstance(world["settled_events"], list), "world state/event inventory missing")
    require(isinstance(world["coverage"], dict) and isinstance(world["identity"], dict), "world identity/coverage missing")


def reference_key(key, index):
    if isinstance(key, str) and key.isdecimal() and key not in index:
        return int(key)
    return key


def nested_references(value, indexes):
    """One owner mapping/walker for fail-closed validation and graph navigation.
    None target means the existing evidence_id format/source is explicitly unknown.
    """
    if isinstance(value, list):
        for item in value:
            yield from nested_references(item, indexes)
    if not isinstance(value, dict):
        return
    for key, item in value.items():
        if key in NESTED_REFERENCE_OWNERS and item is not None:
            yield key, NESTED_REFERENCE_OWNERS[key], item
        elif key == "evidence_id" and isinstance(item, str):
            if item.startswith("intelligence-observation:"):
                yield key, "intelligence_observations", item.split(":", 1)[1]
            elif item in indexes["authoritative_observations"]:
                yield key, "authoritative_observations", item
            else:
                yield key, None, item
        elif key == "kind" and item == "observation" and value.get("id") is not None:
            yield "observation", "authoritative_observations", value["id"]
        if isinstance(item, (dict, list)):
            yield from nested_references(item, indexes)


def validate_database(db):
    require(db["schema"] == "application-evidence/v2", "unsupported database schema")
    require(set(db) == {"schema", "snapshot", "tables", "excluded_tables", "authority", "inventory"}, "database snapshot/provenance incomplete")
    require(isinstance(db["snapshot"], str) and db["snapshot"], "database snapshot identity missing")
    tables, inventory = db["tables"], db["inventory"]
    require(isinstance(db["excluded_tables"], dict) and not set(db["excluded_tables"]) & set(tables), "excluded table inventory inconsistent")
    for item in db["excluded_tables"].values():
        require(set(item) == {"rows", "reason"} and type(item["rows"]) is int and item["rows"] >= 0 and item["reason"] == "not_allowlisted_private_authority_only", "excluded table count/reason missing")
    require(set(tables) == set(TABLES) == set(inventory), "database table inventory incomplete")
    indexes = {}
    for name, rows in tables.items():
        require(inventory[name] == {"rows": len(rows), "sha256": sha(canonical(rows))}, "database inventory mismatch")
        require(all(set(row) == set(TABLES[name].split()) for row in rows), "missing or non-allowlisted database column")
        key = PRIMARY_KEYS.get(name, "id")
        ids = [row[key] for row in rows]
        require(len(ids) == len(set(ids)), "duplicate durable identity")
        indexes[name] = {row[key]: row for row in rows}
    for name, links in JOINS.items():
        for row in tables[name]:
            for field, target in links.items():
                value = row.get(field)
                require(value is None or value in indexes[target], "broken retained join: " + name + "." + field)
    for name, rows in tables.items():
        for row in rows:
            for value in row.values():
                if isinstance(value, (dict, list)):
                    for field, target, key in nested_references(value, indexes):
                        if target is not None:
                            require(reference_key(key, indexes[target]) in indexes[target],
                                    "broken referenced evidence: " + name + "." + field)
    # Issuing-root provenance is independent of the Intent's current attempt.
    for row in tables["mutation_attempts"]:
        provenance = row.get("provenance") or {}
        for field, target in [("intent_id", "intents"), ("commitment_id", "fleet_commitments")]:
            value = provenance.get(field)
            if isinstance(value, str) and value.isdecimal():
                value = int(value)
            require(value is None or value in indexes[target], "broken mutation provenance")
    return indexes


def validate(metadata, sections):
    try:
        require(metadata["schema"] == "attempt/v1", "unsupported attempt schema")
        require(set(metadata) == {"schema", "identity", "definition", "provenance", "resources", "coverage", "disposition", "claim_limits"}, "missing or unknown attempt field")
        require(isinstance(metadata["claim_limits"], list) and metadata["claim_limits"], "explicit claim limits required")
        identity = metadata["identity"]
        require(set(identity) == {"definition", "batch", "logical_run", "attempt"}, "missing identity")
        require(all(isinstance(v, str) and 0 < len(v) <= 256 for v in identity.values()), "invalid identity")
        require(identity["definition"] == "sha256:" + sha(canonical(metadata["definition"])), "definition hash mismatch")
        require(metadata["definition"]["provenance"] == metadata["provenance"], "provenance drift")
        require(metadata["definition"]["resources"] == metadata["resources"], "resource drift")
        require(set(metadata["provenance"]) == {"application", "simulator", "api", "scenario", "strategy", "build", "calibration"}, "provenance incomplete")
        for field, length in [("application", 40), ("simulator", 40), ("api", 64), ("build", 64)]:
            require(re.fullmatch("[0-9a-f]{" + str(length) + "}", metadata["provenance"][field]) is not None, "unpinned executable/API provenance")
        require(set(metadata["provenance"]["strategy"]) == {"document", "revision"}, "Strategy provenance incomplete")
        kind = metadata["disposition"]["kind"]
        require(kind in {"completed", "gate_noncompletion", "bot_failure", "harness_failure", "infrastructure_timeout", "interrupted", "startup_failed"}, "unknown disposition")
        require(bool(metadata["disposition"]["cause"]), "disposition cause or explicit unknown required")
        for name in ["simulated", "wall"]:
            coverage = metadata["coverage"][name]
            require(coverage["end"] >= coverage["start"], "negative coverage")
        simulated = metadata["coverage"]["simulated"]
        require(simulated["unit"] == "seconds" and all(type(simulated[key]) in [int, float] and simulated[key] >= 0 for key in ["start", "end"]), "invalid simulated coverage")
        require(metadata["coverage"]["wall"]["seconds"] >= 0, "negative wall duration")
        wall = metadata["coverage"]["wall"]
        start, end = (datetime.fromisoformat(wall[key].replace("Z", "+00:00")) for key in ["start", "end"])
        require(start.utcoffset() is not None and end.utcoffset() is not None, "wall time zone required")
        require(abs((end - start).total_seconds() - wall["seconds"]) < 1, "wall coverage/duration disagreement")
        require(set(sections) == {"database", "world", "time"}, "required sections missing")
        complete = True
        for name, section in sections.items():
            require(section["identity"] == identity, "section identity mismatch")
            status = section["status"]
            require(status in {"present", "not_created", "not_captured"}, "invalid section availability")
            if status != "present":
                require(bool(section.get("reason")) and "data" not in section, "absence needs explicit reason, not fabricated data")
                require(kind != "completed", "completed attempt requires all evidence")
                if status == "not_created":
                    require(kind == "startup_failed" and bool(section.get("stage")), "not-created requires startup-failure stage")
                else:
                    complete = False
                continue
            if name == "database":
                indexes = validate_database(section["data"])
                require(section["data"]["authority"]["database"] == metadata["resources"]["database"], "database resource identity mismatch")
                strategy = metadata["provenance"]["strategy"]
                if strategy["revision"] is not None:
                    require(strategy["revision"] in indexes["fleet_strategy_revisions"] and indexes["fleet_strategy_revisions"][strategy["revision"]]["document"] == strategy["document"], "Strategy revision/document mismatch")
                else:
                    require(kind == "startup_failed", "missing run-local Strategy revision")
            if name == "time":
                time = section["data"]
                require(time["schema"] == "attempt-time/v1" and isinstance(time["trace"], list), "invalid time evidence")
                coverage = metadata["coverage"]["simulated"]
                require((time["start"], time["end"]) == (coverage["start"], coverage["end"]), "time coverage mismatch")
                require(bool(time["ordering"]) and isinstance(time["unresolved"], (list, tuple)), "time ordering/unresolved evidence missing")
        if sections["world"]["status"] == "present":
            world = sections["world"]["data"]
            validate_world(world)
            require(world["identity"]["world_id"] == metadata["resources"]["world_id"], "world resource identity mismatch")
            require(world["identity"]["scenario_id"] == metadata["provenance"]["scenario"], "world scenario identity mismatch")
            require(world["current_time"] == metadata["coverage"]["simulated"]["end"], "world coverage mismatch")
        return complete
    except (KeyError, TypeError, AttributeError) as exc:
        raise ValueError("missing or malformed required evidence") from exc


def portable(value):
    if isinstance(value, tuple):
        return {"$tuple": [portable(v) for v in value]}
    if isinstance(value, dict):
        if any(not isinstance(k, str) for k in value):
            raise ValueError("portable map keys must be strings")
        return {k: portable(v) for k, v in value.items()}
    if isinstance(value, list):
        return [portable(v) for v in value]
    if value is None or type(value) in (str, int, float, bool):
        return value
    raise ValueError("unsupported data value; executable dumps are never accepted")


def canonical(value):
    return json.dumps(portable(value), sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode()


def decode_json(data):
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result

    def invalid_constant(_):
        raise ValueError("non-finite JSON value denied")

    return json.loads(data, object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def redact(value):
    """Defense in depth, not authorization to publish arbitrary raw payloads."""
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            normalized = re.sub(r"[^a-z]", "", key.lower())
            secret = any(word in normalized for word in
                         ["password", "credential", "authorization", "cookie", "privatekey", "secret", "token", "privatesource", "sourcecode"])
            result[key] = "[REDACTED]" if secret and item != "omitted_no_restore_contract" else redact(item)
        return result
    if isinstance(value, (list, tuple)):
        items = [redact(item) for item in value]
        return tuple(items) if isinstance(value, tuple) else items
    if isinstance(value, str):
        value = re.sub(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]+", "[REDACTED]", value)
        value = re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b", "[REDACTED]", value)
        value = re.sub(r"(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----", "[REDACTED]", value)
    return value


def database_document(tables, excluded, snapshot, authority):
    return {"schema": "application-evidence/v2", "snapshot": snapshot,
            "tables": tables, "excluded_tables": excluded, "authority": authority,
            "inventory": {name: {"rows": len(rows), "sha256": sha(canonical(rows))}
                          for name, rows in tables.items()}}


def database_sql():
    """One read-only snapshot. Explicit columns prevent credential decryption or
    accidental new-column exposure; all retained history, never current-only."""
    pairs = []
    for table, columns in TABLES.items():
        fields = ",".join('"' + col + '"' for col in columns.split())
        key = PRIMARY_KEYS.get(table, "id")
        pairs.append("'" + table + "', (SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.\"" + key + "\"), '[]'::jsonb) FROM (SELECT " + fields + " FROM public.\"" + table + "\") t)")
    return """BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object('snapshot', pg_current_snapshot()::text,
 'database', current_database(), 'tables', jsonb_build_object(""" + ",".join(pairs) + """),
 'catalog', (SELECT jsonb_object_agg(tablename,
   ((xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', tablename), false, true, '')))[1]::text)::bigint)
   FROM pg_tables WHERE schemaname = 'public'));
COMMIT;
"""


def capture_database(connection, authority=None):
    """connection = explicit host/port/user/database only. Never use deployment
    defaults, connection URLs, inherited PG credentials or report SQL errors."""
    require(set(connection) == {"host", "port", "user", "database"}, "explicit database identity required")
    require(connection["host"] in {"127.0.0.1", "::1"} or connection["host"].startswith("/"), "local isolated database required")
    require(re.fullmatch(r"sim_[a-zA-Z0-9_]+", connection["database"]) is not None, "simulation database name required")
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    env.update(PGPASSFILE="/dev/null", PGSERVICEFILE="/dev/null", PGCONNECT_TIMEOUT="3")
    args = ["psql", "-X", "-w", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
    for flag, key in [("-h", "host"), ("-p", "port"), ("-U", "user"), ("-d", "database")]:
        args.extend([flag, str(connection[key])])
    def bounded_output():
        resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_BYTES, MAX_BYTES))

    with tempfile.TemporaryFile() as output:
        result = subprocess.run(args, input=database_sql().encode(), stdout=output,
                                stderr=subprocess.PIPE, timeout=35, env=env,
                                preexec_fn=bounded_output)
        require(result.returncode == 0, "read-only database capture failed or exceeded limit; originals retained")
        output.seek(0)
        document = decode_json(output.read(MAX_BYTES + 1))
    tables = redact(document["tables"])
    for name, rows in tables.items():
        require(len(rows) == document["catalog"][name], "snapshot row count mismatch")
    excluded = {name: {"rows": count, "reason": "not_allowlisted_private_authority_only"}
                for name, count in document["catalog"].items() if name not in TABLES}
    db = database_document(tables, excluded, document["snapshot"],
                           {"kind": "postgresql-repeatable-read-allowlist/v1", "database": document["database"],
                            "raw_archive": authority, "redaction": "recursive-credentials-private-source/v1"})
    validate_database(db)
    return db


def retain_authority(source, destination):
    """Copy an already-stopped raw authority tree into a PRIVATE archive only.
    No restore, database startup, source mutation, deletion or cleanup receipt."""
    source, destination = Path(source).resolve(), Path(destination)
    require(destination.parent.stat().st_mode & 0o077 == 0, "raw authority destination must be private")
    require(not destination.resolve().is_relative_to(source), "archive cannot be inside source authority")
    inventory = {}
    for path in sorted(source.rglob("*")):
        require(not path.is_symlink(), "raw authority symlink denied")
        if path.is_file():
            inventory[str(path.relative_to(source))] = {"bytes": path.stat().st_size, "sha256": file_sha(path)}
        else:
            require(path.is_dir(), "raw authority special file denied")
    fd, temporary = tempfile.mkstemp(prefix=".private-authority-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            with tarfile.open(fileobj=stream, mode="w") as archive:
                for name in inventory:
                    archive.add(source / name, arcname=name, recursive=False)
                # Verify the bytes actually archived, not just a pre-copy inventory.
            stream.flush()
            os.fsync(stream.fileno())
        with tarfile.open(temporary) as archive:
            for member in archive:
                content = archive.extractfile(member)
                require(member.size == inventory[member.name]["bytes"] and sha(content.read()) == inventory[member.name]["sha256"], "raw authority changed during copy")
        for name, item in inventory.items():
            require(file_sha(source / name) == item["sha256"], "source authority changed during copy")
        receipt = {"schema": "private-authority/v1", "archive_sha256": file_sha(temporary),
                "inventory_sha256": sha(canonical(inventory)), "files": len(inventory),
                "bytes": sum(v["bytes"] for v in inventory.values()),
                "privacy": "private-raw/not-portable", "cleanup_authorized": False}
        verify_authority(temporary, receipt)
        os.link(temporary, destination)
        return receipt
    finally:
        os.unlink(temporary)


def verify_authority(path, receipt):
    require(receipt["schema"] == "private-authority/v1" and receipt["privacy"] == "private-raw/not-portable", "invalid private authority receipt")
    require(file_sha(path) == receipt["archive_sha256"], "private archive checksum mismatch")
    inventory = {}
    with tarfile.open(path, mode="r:") as archive:
        for member in archive:
            name = Path(member.name)
            require(member.isfile() and not name.is_absolute() and ".." not in name.parts and member.name not in inventory, "unsafe private authority inventory")
            h = hashlib.sha256()
            content = archive.extractfile(member)
            for block in iter(lambda: content.read(1024 * 1024), b""):
                h.update(block)
            inventory[member.name] = {"bytes": member.size, "sha256": h.hexdigest()}
    require(len(inventory) == receipt["files"] and sum(v["bytes"] for v in inventory.values()) == receipt["bytes"] and sha(canonical(inventory)) == receipt["inventory_sha256"], "private archive inventory mismatch")
    return True


def derived(metadata, sections):
    """Projection only: retained links or explicit unknowns, never causal guesses."""
    prefix = metadata["identity"]["logical_run"] + "/" + metadata["identity"]["attempt"] + "/"
    nodes, edges, unresolved = {}, [], []
    if sections["database"]["status"] == "present":
        tables = sections["database"]["data"]["tables"]
        indexes = validate_database(sections["database"]["data"])

        def address(table, key):
            return prefix + table + ":" + str(key)

        def edge(origin, relation, table, key):
            key = reference_key(key, indexes[table])
            require(key in indexes[table], "broken referenced evidence: " + relation)
            edges.append({"from": origin, "to": address(table, key), "relation": relation})

        for table, rows in tables.items():
            for row in rows:
                key = row[PRIMARY_KEYS.get(table, "id")]
                origin = address(table, key)
                nodes[origin] = {"table": table, "id": key}
                for field, target in JOINS.get(table, {}).items():
                    if row.get(field) is not None:
                        edge(origin, field, target, row[field])
                # observation_id is an Intelligence FK at the row boundary;
                # nested Bindings use the authoritative observation UUID.
                for field, value in row.items():
                    if isinstance(value, (dict, list)):
                        for relation, target, key in nested_references(value, indexes):
                            if target is None:
                                unresolved.append({"from": origin, "reference": key, "cause": "unknown_reference_format_or_unretained_source"})
                            else:
                                edge(origin, relation, target, key)
                if table == "mutation_attempts":
                    provenance = row.get("provenance") or {}
                    for field, target in [("intent_id", "intents"), ("commitment_id", "fleet_commitments")]:
                        if provenance.get(field) is not None:
                            edge(origin, "provenance." + field, target, provenance[field])
    graph = {"schema": "attempt-causal-graph/v1", "identity": metadata["identity"],
             "nodes": nodes, "edges": sorted(edges, key=canonical),
             "unresolved_references": sorted(unresolved, key=canonical),
             "missing_causes": "unknown; no explanation inferred by exporter"}
    world = sections["world"].get("data")
    summary = {"schema": "attempt-summary/v1", "identity": metadata["identity"],
               "coverage": metadata["coverage"], "disposition": metadata["disposition"],
               "availability": {name: s["status"] for name, s in sections.items()},
               "table_rows": {table: len(rows) for table, rows in sections["database"].get("data", {}).get("tables", {}).items()},
               "world_events": len(world["settled_events"]) if world else None,
               "world_coverage": world["coverage"] if world else None,
               "unknown_causes": True, "net_earnings": None,
               "net_earnings_reason": "no complete all-Strategy attributed monetary ledger asserted"}
    return graph, summary


def render_html(bundle):
    """Compatibility hook; investigation uses the same validated causal graph."""
    if __package__:
        from . import attempt_report
    else:
        import attempt_report
    return attempt_report.render_html(attempt_report.investigate(bundle))


def build(metadata, sections):
    complete = validate(metadata, sections)
    require(canonical(redact(metadata)) == canonical(metadata), "credential/private-source content in immutable metadata")
    # These are validated counts/reasons, not credential rows. A table name
    # containing 'tokens' must not erase the evidence that it was excluded.
    excluded = sections["database"].get("data", {}).get("excluded_tables")
    sections = redact(sections)
    if sections["database"]["status"] == "present":
        db = sections["database"]["data"]
        db["excluded_tables"] = portable(excluded)
        db["inventory"] = {name: {"rows": len(rows), "sha256": sha(canonical(rows))}
                           for name, rows in db["tables"].items()}
    validate(metadata, sections)
    graph, summary = derived(metadata, sections)
    data = {"attempt.json": canonical(metadata)}
    for name, section in sections.items():
        data[name + ".json"] = canonical(section)
    data["causal.json"] = canonical(graph)
    data["summary.json"] = canonical(summary)
    manifest = {"schema": VERSION, "identity": metadata["identity"],
                "exporter_sha256": file_sha(__file__),
                "complete_export": complete,
                "files": {name: {"sha256": sha(content), "bytes": len(content)}
                          for name, content in data.items()}}
    data["manifest.json"] = canonical(manifest)
    data["manifest.sha256"] = sha(data["manifest.json"]).encode()
    require(sum(map(len, data.values())) <= MAX_BYTES, "portable evidence size limit; originals retained")
    return data


def publish(metadata, sections, destination):
    """Exclusive atomic publication on one filesystem; never touches inputs."""
    started = time.monotonic()
    destination = Path(destination)
    data = build(metadata, sections)
    fd, temporary = tempfile.mkstemp(prefix=".attempt-export-", dir=destination.parent)
    try:
        with os.fdopen(fd, "w+b") as stream:
            with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, content in data.items():
                    archive.writestr(name, content)
            stream.flush()
            os.fsync(stream.fileno())
        read_bundle(temporary)
        os.link(temporary, destination)  # atomic, fails rather than replaces
        directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        return {"schema": "export-receipt/v1", "identity": metadata["identity"],
                "sha256": file_sha(destination), "bytes": destination.stat().st_size,
                "publication_wall_seconds": time.monotonic() - started,
                "published_at": datetime.now(timezone.utc).isoformat(),
                "cleanup_authorized": False}
    finally:
        os.unlink(temporary)


def read_bundle(path, receipt=None):
    if receipt is not None:
        require(receipt["schema"] == "export-receipt/v1" and receipt["cleanup_authorized"] is False,
                "invalid export receipt")
        require(file_sha(path) == receipt["sha256"] and Path(path).stat().st_size == receipt["bytes"],
                "export receipt byte/hash mismatch")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or sum(i.file_size for i in archive.infolist()) > MAX_BYTES:
            raise ValueError("duplicate or oversized bundle")
        manifest_bytes = archive.read("manifest.json")
        if sha(manifest_bytes).encode() != archive.read("manifest.sha256"):
            raise ValueError("manifest checksum mismatch")
        manifest = decode_json(manifest_bytes)
        require(re.fullmatch("[0-9a-f]{64}", manifest["exporter_sha256"]) is not None, "missing exporter executable identity")
        if manifest["schema"] != VERSION or set(names) != set(manifest["files"]) | {"manifest.json", "manifest.sha256"}:
            raise ValueError("unsupported version or file inventory mismatch")
        files = {}
        for name, inventory in manifest["files"].items():
            content = archive.read(name)
            if len(content) != inventory["bytes"] or sha(content) != inventory["sha256"]:
                raise ValueError("evidence checksum mismatch")
            files[name] = decode_json(content)
        metadata = files.pop("attempt.json")
        graph, summary = files.pop("causal.json"), files.pop("summary.json")
        sections = {name.removesuffix(".json"): value for name, value in files.items()}
        require(manifest["identity"] == metadata["identity"], "manifest identity mismatch")
        if receipt is not None:
            require(receipt["identity"] == metadata["identity"], "export receipt identity mismatch")
        require(validate(metadata, sections) == manifest["complete_export"], "completeness disagreement")
        require(derived(metadata, sections) == (graph, summary), "causal/summary disagreement with retained evidence")
        return {"manifest": manifest, "metadata": metadata, "sections": sections, "graph": graph, "summary": summary}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    reader = sub.add_parser("read")
    reader.add_argument("bundle")
    reader.add_argument("--receipt", help="trusted separate export receipt: verify whole archive and attempt identity")
    reader.add_argument("--html", help="new self-contained HTML output; never overwritten")
    reader.add_argument("--private-authority", help="optional private raw archive: verify bytes/inventory without restore")
    publisher = sub.add_parser("publish")
    publisher.add_argument("request")
    publisher.add_argument("destination")
    capture = sub.add_parser("capture-database")
    for name in ["host", "port", "user", "database", "output"]:
        capture.add_argument("--" + name, required=True)
    raw = sub.add_parser("retain-private-authority")
    raw.add_argument("source")
    raw.add_argument("destination")
    args = parser.parse_args()
    if args.command == "read":
        receipt = decode_json(Path(args.receipt).read_bytes()) if args.receipt else None
        result = read_bundle(args.bundle, receipt=receipt)
        if args.private_authority:
            require(result["sections"]["database"]["status"] == "present", "no database authority receipt")
            verify_authority(args.private_authority, result["sections"]["database"]["data"]["authority"]["raw_archive"])
        if args.html:
            with open(args.html, "x") as stream:
                os.chmod(args.html, 0o600)
                stream.write(render_html(result))
        print(json.dumps(result["manifest"], sort_keys=True))
    elif args.command == "publish":
        request = decode_json(Path(args.request).read_bytes())
        print(json.dumps(publish(request["metadata"], request["sections"], args.destination), sort_keys=True))
    elif args.command == "capture-database":
        db = capture_database({name: getattr(args, name) for name in ["host", "port", "user", "database"]})
        with open(args.output, "xb") as stream:
            os.chmod(args.output, 0o600)
            stream.write(canonical(db))
    else:
        print(json.dumps(retain_authority(args.source, args.destination), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, RecursionError, zipfile.BadZipFile, subprocess.TimeoutExpired):
        # No input values, SQL stderr, source paths, exception dumps or credentials.
        raise SystemExit("attempt export failed: invalid/unavailable evidence; original resources retained")
