#!/usr/bin/env bash

set -euo pipefail

EVENT_NAME="${1:-}"

if [[ -z "${EVENT_NAME}" ]]; then
  echo "Usage: collect-copilot-usage.sh <event-name>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DATA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/data"
DATA_FILE="${COPILOT_USAGE_DATA_FILE:-}"
PAYLOAD_FILE="$(mktemp)"
cleanup() {
  rm -f "${PAYLOAD_FILE}"
}
trap cleanup EXIT

cat > "${PAYLOAD_FILE}"

python3 - "${EVENT_NAME}" "${DATA_FILE}" "${DEFAULT_DATA_DIR}" "${PAYLOAD_FILE}" <<'PY'
import copy
import datetime as dt
import hashlib
import json
import os
import sys
import time


EVENT_ALIASES = {
    "sessionstart": "SessionStart",
    "sessionend": "Stop",
    "userpromptsubmitted": "UserPromptSubmit",
    "userpromptsubmit": "UserPromptSubmit",
    "userprompttransformed": "UserPromptSubmit",
    "pretooluse": "PreToolUse",
    "posttooluse": "PostToolUse",
    "posttoolusefailure": "ErrorOccurred",
    "agentstop": "Stop",
    "subagentstart": "SubagentStart",
    "subagentstop": "SubagentStop",
    "erroroccurred": "ErrorOccurred",
    "precompact": "PreCompact",
    "permissionrequest": "PreToolUse",
    "notification": "Stop",
    "stop": "Stop",
}


def iso_from_value(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return dt.datetime.fromtimestamp(float(value) / 1000.0, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")
    text = str(value).strip()
    return text or None


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def hash_value(value):
    return sha256_text(canonical_json(value))


def safe_len_text(value):
    if value is None:
        return 0
    return len(str(value))


def word_count(value):
    if value is None:
        return 0
    return len([part for part in str(value).split() if part])


def read_value(payload, *names):
    for name in names:
        if name in payload and payload[name] is not None:
            return payload[name]
    return None


def serialize_length(value):
    if value is None:
        return 0
    return len(canonical_json(value))


def normalize_event_name(value):
    text = str(value or "").strip()
    if not text:
        return "unknown"
    return EVENT_ALIASES.get(text.lower(), text)


def resolve_data_file(explicit_path, default_dir, payload):
    if explicit_path:
        return os.path.abspath(explicit_path)
    timestamp = iso_from_value(read_value(payload, "timestamp"))
    if timestamp:
        month = timestamp[5:7]
        year = timestamp[0:4]
    else:
        now = dt.datetime.now(tz=dt.timezone.utc)
        month = f"{now.month:02d}"
        year = f"{now.year:04d}"
    filename = f"copilot_usage_{month}_{year}.json"
    return os.path.join(os.path.abspath(default_dir), filename)


TOOL_CATEGORIES = {
    "ask_user": "interaction",
    "bash": "execute",
    "powershell": "execute",
    "create": "write",
    "edit": "write",
    "str_replace_editor": "write",
    "apply_patch": "write",
    "glob": "discovery",
    "grep": "discovery",
    "rg": "discovery",
    "task": "subagent",
    "view": "read",
    "web_fetch": "network",
    "web_search": "network",
}


def event_metadata(event_name, payload):
    metadata = {}
    if event_name == "SessionStart":
        initial_prompt = read_value(payload, "initialPrompt", "initial_prompt")
        metadata["source"] = read_value(payload, "source") or "unknown"
        metadata["hasInitialPrompt"] = bool(initial_prompt)
        metadata["initialPromptLength"] = safe_len_text(initial_prompt)
        metadata["initialPromptWordCount"] = word_count(initial_prompt)
        metadata["initialPromptHash"] = sha256_text(str(initial_prompt)) if initial_prompt else None
    elif event_name == "Stop":
        metadata["stopReason"] = read_value(payload, "stopReason", "stop_reason", "reason") or "unknown"
    elif event_name == "UserPromptSubmit":
        prompt = read_value(payload, "prompt")
        metadata["promptLength"] = safe_len_text(prompt)
        metadata["promptWordCount"] = word_count(prompt)
        metadata["promptHash"] = sha256_text(str(prompt)) if prompt else None
    elif event_name in ("PreToolUse", "PostToolUse"):
        tool_name = read_value(payload, "toolName", "tool_name") or "unknown"
        tool_args = read_value(payload, "toolArgs", "tool_input")
        metadata["toolName"] = tool_name
        metadata["toolCategory"] = TOOL_CATEGORIES.get(tool_name, "other")
        metadata["toolArgsLength"] = serialize_length(tool_args)
        metadata["toolArgsHash"] = hash_value(tool_args) if tool_args is not None else None
        if event_name == "PostToolUse":
            result = read_value(payload, "toolResult", "tool_result") or {}
            llm_text = read_value(result, "textResultForLlm", "text_result_for_llm")
            metadata["toolOutcome"] = "success"
            metadata["toolResultLength"] = safe_len_text(llm_text)
            metadata["toolResultHash"] = sha256_text(str(llm_text)) if llm_text else None
    elif event_name in ("SubagentStart", "SubagentStop"):
        transcript_path = read_value(payload, "transcriptPath", "transcript_path")
        agent_name = read_value(payload, "agentName", "agent_name")
        agent_display_name = read_value(payload, "agentDisplayName", "agent_display_name")
        metadata["agentName"] = agent_name or "unknown"
        metadata["agentDisplayName"] = agent_display_name
        metadata["transcriptPathHash"] = sha256_text(str(transcript_path)) if transcript_path else None
        if event_name == "SubagentStart":
            description = read_value(payload, "agentDescription", "agent_description")
            metadata["agentDescriptionLength"] = safe_len_text(description)
            metadata["agentDescriptionHash"] = sha256_text(str(description)) if description else None
        else:
            metadata["stopReason"] = read_value(payload, "stopReason", "stop_reason") or "unknown"
    elif event_name == "ErrorOccurred":
        error = read_value(payload, "error") or {}
        message = read_value(error, "message")
        stack = read_value(error, "stack")
        metadata["errorName"] = read_value(error, "name") or "Error"
        metadata["errorContext"] = read_value(payload, "errorContext", "error_context") or "unknown"
        metadata["recoverable"] = bool(read_value(payload, "recoverable"))
        metadata["errorMessageLength"] = safe_len_text(message)
        metadata["errorMessageHash"] = sha256_text(str(message)) if message else None
        metadata["hasStack"] = bool(stack)
    elif event_name == "PreCompact":
        transcript_path = read_value(payload, "transcriptPath", "transcript_path")
        instructions = read_value(payload, "customInstructions", "custom_instructions")
        metadata["trigger"] = read_value(payload, "trigger") or "unknown"
        metadata["transcriptPathHash"] = sha256_text(str(transcript_path)) if transcript_path else None
        metadata["customInstructionsLength"] = safe_len_text(instructions)
        metadata["customInstructionsHash"] = sha256_text(str(instructions)) if instructions else None
    return metadata


def ensure_store(path):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                raw = handle.read().strip()
            if raw:
                return json.loads(raw)
        except json.JSONDecodeError:
            pass
    return {
        "version": 1,
        "updatedAt": None,
        "summary": {
            "totalEvents": 0,
            "totalSessions": 0,
            "firstEventAt": None,
            "lastEventAt": None,
            "eventTypeCounts": {},
            "months": [],
        },
        "events": [],
    }


def recompute_summary(store):
    events = store.get("events", [])
    event_type_counts = {}
    sessions = set()
    months = set()
    first = None
    last = None
    for item in events:
        event_type = item.get("eventType", "unknown")
        event_type_counts[event_type] = event_type_counts.get(event_type, 0) + 1
        session_id = item.get("sessionId")
        if session_id:
            sessions.add(session_id)
        month = item.get("month")
        if month:
            months.add(month)
        timestamp = item.get("timestamp")
        if timestamp:
            if first is None or timestamp < first:
                first = timestamp
            if last is None or timestamp > last:
                last = timestamp
    store["summary"] = {
        "totalEvents": len(events),
        "totalSessions": len(sessions),
        "firstEventAt": first,
        "lastEventAt": last,
        "eventTypeCounts": dict(sorted(event_type_counts.items())),
        "months": sorted(months),
    }
    return store


def acquire_lock(lock_path):
    deadline = time.time() + 10.0
    while True:
        try:
            os.mkdir(lock_path)
            return
        except FileExistsError:
            if time.time() >= deadline:
                raise TimeoutError("Timed out waiting for collector lock.")
            time.sleep(0.05)


def release_lock(lock_path):
    if os.path.isdir(lock_path):
        os.rmdir(lock_path)


event_name = normalize_event_name(sys.argv[1])
data_file_override = sys.argv[2].strip()
default_data_dir = sys.argv[3]
payload_file = sys.argv[4]
with open(payload_file, "r", encoding="utf-8") as handle:
    payload_text = handle.read().strip() or "{}"

payload = json.loads(payload_text)
data_file = resolve_data_file(data_file_override, default_data_dir, payload)
os.makedirs(os.path.dirname(data_file), exist_ok=True)
lock_path = data_file + ".lock"
recorded_at = dt.datetime.now(tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")

acquire_lock(lock_path)
try:
    store = ensure_store(data_file)
    fingerprint = sha256_text(event_name + "|" + canonical_json(payload))
    for item in store.get("events", []):
        if item.get("sourceFingerprint") == fingerprint:
            store["updatedAt"] = recorded_at
            with open(data_file, "w", encoding="utf-8") as handle:
                json.dump(recompute_summary(store), handle, ensure_ascii=True, indent=2)
                handle.write("\n")
            sys.exit(0)

    session_id = str(read_value(payload, "sessionId", "session_id") or "unknown")
    timestamp = iso_from_value(read_value(payload, "timestamp"))
    cwd = str(read_value(payload, "cwd") or "")
    cwd_hash = sha256_text(cwd) if cwd else None
    month = timestamp[:7] if timestamp else None
    existing_events = store.get("events", [])
    session_event_index = 1 + sum(1 for item in existing_events if item.get("sessionId") == session_id)
    event_record = {
        "id": sha256_text(fingerprint + "|" + str(session_event_index)),
        "schemaVersion": 1,
        "eventType": event_name,
        "sessionId": session_id,
        "timestamp": timestamp,
        "recordedAt": recorded_at,
        "month": month,
        "cwd": cwd,
        "cwdHash": cwd_hash,
        "sourceSurface": "vscode-chat",
        "sessionEventIndex": session_event_index,
        "sourceFingerprint": fingerprint,
        "metadata": event_metadata(event_name, copy.deepcopy(payload)),
    }
    store.setdefault("events", []).append(event_record)
    store["updatedAt"] = recorded_at
    with open(data_file, "w", encoding="utf-8") as handle:
        json.dump(recompute_summary(store), handle, ensure_ascii=True, indent=2)
        handle.write("\n")
finally:
    release_lock(lock_path)
PY
