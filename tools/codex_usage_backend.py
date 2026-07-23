from __future__ import annotations

import argparse
import json
import os
import platform
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def is_codex_dir(path: Path) -> bool:
    if not path.exists() or not path.is_dir():
        return False
    markers = [
        path / "state_5.sqlite",
        path / "session_index.jsonl",
        path / "sessions",
        path / "archived_sessions",
        path / "deleted_sessions_backup",
    ]
    return any(marker.exists() for marker in markers)


def candidate_codex_dirs() -> list[Path]:
    candidates: list[Path] = []

    def add(path_value: object) -> None:
        if not path_value:
            return
        path = Path(str(path_value)).expanduser()
        if path.name.lower() == ".codex":
            candidates.append(path)
        else:
            candidates.append(path / ".codex")

    def add_exact(path_value: object) -> None:
        if path_value:
            candidates.append(Path(str(path_value)).expanduser())

    for env_name in ("CODEX_HOME", "CODEX_DIR"):
        add(os.environ.get(env_name))

    add(Path.home())
    for env_name in ("USERPROFILE", "HOME"):
        add(os.environ.get(env_name))

    user_profile = os.environ.get("USERPROFILE")
    if user_profile:
        users_root = Path(user_profile).parent
        if users_root.exists():
            candidates.extend(users_root.glob("*/.codex"))

    if os.name == "nt":
        for letter in "CDEFGHIJKLMNOPQRSTUVWXYZ":
            users_root = Path(f"{letter}:/Users")
            if users_root.exists():
                candidates.extend(users_root.glob("*/.codex"))

    system_name = platform.system()
    if system_name == "Darwin":
        users_root = Path("/Users")
        if users_root.exists():
            candidates.extend(users_root.glob("*/.codex"))
        add_exact(Path.home() / "Library" / "Application Support" / "Codex")
    elif system_name == "Linux":
        users_root = Path("/home")
        if users_root.exists():
            candidates.extend(users_root.glob("*/.codex"))
        xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
        if xdg_config_home:
            add_exact(Path(xdg_config_home) / "codex")

    unique: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate).lower()
        if key in seen:
            continue
        seen.add(key)
        unique.append(candidate)
    return unique


def discover_codex_dir() -> Path:
    for candidate in candidate_codex_dirs():
        if is_codex_dir(candidate):
            return candidate
    return Path.home() / ".codex"


def resolve_codex_dir(value: str = "") -> Path:
    if value:
        return Path(value).expanduser()
    return discover_codex_dir()


def path_lookup_keys(path_value: object) -> set[str]:
    if not path_value:
        return set()
    text = str(path_value)
    path = Path(text).expanduser()
    keys = {text.lower(), str(path).lower()}
    try:
        keys.add(str(path.resolve()).lower())
    except OSError:
        pass
    return keys


def rollout_id_from_path(path: Path) -> str:
    name = path.name
    if name.startswith("rollout-") and name.endswith(".jsonl"):
        return name[-42:-6]
    return ""


def ui_string(value: object, max_len: int = 240) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    text = "".join(ch if ord(ch) >= 32 else " " for ch in text)
    text = " ".join(text.split())
    if len(text) > max_len:
        return text[: max_len - 3] + "..."
    return text


CODEX_IDE_CONTEXT_PREFIX = "# Context from my IDE setup:"
CODEX_REQUEST_MARKER = "my request for codex"
UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
DEFAULT_MODEL_PRICING: list[dict[str, object]] = [
    {"model_id": "gpt-5.6-sol", "display_name": "GPT-5.6 Sol", "input": 5.0, "output": 30.0, "cache_read": 0.50, "cache_creation": 6.25},
    {"model_id": "gpt-5.6-terra", "display_name": "GPT-5.6 Terra", "input": 2.5, "output": 15.0, "cache_read": 0.25, "cache_creation": 3.125},
    {"model_id": "gpt-5.6-luna", "display_name": "GPT-5.6 Luna", "input": 1.0, "output": 6.0, "cache_read": 0.10, "cache_creation": 1.25},
    {"model_id": "gpt-5.6", "display_name": "GPT-5.6 Sol", "input": 5.0, "output": 30.0, "cache_read": 0.50, "cache_creation": 6.25},
    {"model_id": "gpt-5.5", "display_name": "GPT-5.5", "input": 5.0, "output": 30.0, "cache_read": 0.50, "cache_creation": 0.0},
    {"model_id": "gpt-5.4", "display_name": "GPT-5.4", "input": 2.50, "output": 15.0, "cache_read": 0.25, "cache_creation": 0.0},
    {"model_id": "gpt-5.4-mini", "display_name": "GPT-5.4 Mini", "input": 0.75, "output": 4.50, "cache_read": 0.075, "cache_creation": 0.0},
    {"model_id": "gpt-5.4-nano", "display_name": "GPT-5.4 Nano", "input": 0.20, "output": 1.25, "cache_read": 0.02, "cache_creation": 0.0},
    {"model_id": "gpt-5.3-codex", "display_name": "GPT-5.3 Codex", "input": 1.75, "output": 14.0, "cache_read": 0.175, "cache_creation": 0.0},
    {"model_id": "gpt-5.2", "display_name": "GPT-5.2", "input": 1.75, "output": 14.0, "cache_read": 0.175, "cache_creation": 0.0},
    {"model_id": "gpt-5.2-codex", "display_name": "GPT-5.2 Codex", "input": 1.75, "output": 14.0, "cache_read": 0.175, "cache_creation": 0.0},
    {"model_id": "gpt-5.1", "display_name": "GPT-5.1", "input": 1.25, "output": 10.0, "cache_read": 0.125, "cache_creation": 0.0},
    {"model_id": "gpt-5.1-codex", "display_name": "GPT-5.1 Codex", "input": 1.25, "output": 10.0, "cache_read": 0.125, "cache_creation": 0.0},
    {"model_id": "gpt-5", "display_name": "GPT-5", "input": 1.25, "output": 10.0, "cache_read": 0.125, "cache_creation": 0.0},
    {"model_id": "gpt-5-codex", "display_name": "GPT-5 Codex", "input": 1.25, "output": 10.0, "cache_read": 0.125, "cache_creation": 0.0},
    {"model_id": "gpt-5-codex-mini", "display_name": "GPT-5 Codex Mini", "input": 0.25, "output": 2.0, "cache_read": 0.025, "cache_creation": 0.0},
    {"model_id": "gpt-5-mini", "display_name": "GPT-5 Mini", "input": 0.25, "output": 2.0, "cache_read": 0.025, "cache_creation": 0.0},
    {"model_id": "gpt-5-nano", "display_name": "GPT-5 Nano", "input": 0.05, "output": 0.40, "cache_read": 0.005, "cache_creation": 0.0},
    {"model_id": "gpt-4.1", "display_name": "GPT-4.1", "input": 2.0, "output": 8.0, "cache_read": 0.50, "cache_creation": 0.0},
    {"model_id": "gpt-4.1-mini", "display_name": "GPT-4.1 Mini", "input": 0.40, "output": 1.60, "cache_read": 0.10, "cache_creation": 0.0},
    {"model_id": "gpt-4.1-nano", "display_name": "GPT-4.1 Nano", "input": 0.10, "output": 0.40, "cache_read": 0.025, "cache_creation": 0.0},
    {"model_id": "codex-mini", "display_name": "Codex Mini", "input": 0.75, "output": 3.0, "cache_read": 0.025, "cache_creation": 0.0},
]
PRICING_BY_MODEL = {str(row["model_id"]): row for row in DEFAULT_MODEL_PRICING}


def parse_timestamp_to_unix(value: object) -> int:
    if value is None:
        return 0
    if isinstance(value, (int, float)):
        number = int(value)
        return number // 1000 if number > 1_000_000_000_000 else number
    text = str(value).strip()
    if not text:
        return 0
    try:
        normalized = text.replace("Z", "+00:00")
        return int(datetime.fromisoformat(normalized).timestamp())
    except ValueError:
        return 0


def truncate_text(value: object, max_len: int = 160) -> str:
    text = ui_string(value, max(max_len, 4))
    if len(text) > max_len:
        return text[: max_len - 3] + "..."
    return text


def path_basename(value: object) -> str:
    text = str(value or "").strip().rstrip("/\\")
    if not text:
        return ""
    return re.split(r"[/\\]+", text)[-1] or text


def extract_text(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            text = extract_text_from_item(item)
            if text.strip():
                parts.append(text)
        return "\n".join(parts)
    if isinstance(content, dict):
        for key in ("text", "input_text", "output_text"):
            value = content.get(key)
            if isinstance(value, str):
                return value
        nested = content.get("content")
        if nested is not None:
            return extract_text(nested)
    return ""


def extract_text_from_item(item: object) -> str:
    if isinstance(item, str):
        return item
    if not isinstance(item, dict):
        return ""
    item_type = str(item.get("type") or "")
    if item_type == "tool_use":
        return "[Tool: %s]" % (item.get("name") or "unknown")
    if item_type == "tool_result":
        return extract_text(item.get("content"))
    return extract_text(item)


def codex_request_heading_payload(line: str) -> str | None:
    trimmed = line.strip()
    if not trimmed.startswith("#"):
        return None
    heading = trimmed.lstrip("#").lstrip()
    if not heading.lower().startswith(CODEX_REQUEST_MARKER):
        return None
    suffix = heading[len(CODEX_REQUEST_MARKER) :].lstrip()
    if not suffix:
        return ""
    if suffix[0] not in ":：-—":
        return None
    return suffix.lstrip(":：-— \t").strip()


def extract_codex_prompt_from_ide_context(text: str) -> str | None:
    normalized = text.replace("\r\n", "\n")
    lines = normalized.split("\n")
    prompt: str | None = None
    for index, line in enumerate(lines):
        inline_prompt = codex_request_heading_payload(line)
        if inline_prompt is None:
            continue
        if inline_prompt:
            prompt = inline_prompt
            continue
        following_prompt = "\n".join(lines[index + 1 :]).strip()
        prompt = following_prompt or None
    return prompt


def title_candidate_from_user_message(text: str) -> str | None:
    trimmed = text.strip()
    if not trimmed:
        return None
    if trimmed.startswith("# AGENTS.md") or trimmed.startswith("<environment_context>"):
        return None
    if trimmed.startswith(CODEX_IDE_CONTEXT_PREFIX):
        return extract_codex_prompt_from_ide_context(trimmed)
    return trimmed


def normalize_model_for_pricing(raw: object) -> str:
    name = str(raw or "").strip().lower()
    if "/" in name:
        name = name.rsplit("/", 1)[-1]
    if len(name) > 11:
        suffix = name[-11:]
        if (
            suffix[0] == "-"
            and suffix[1:5].isdigit()
            and suffix[5] == "-"
            and suffix[6:8].isdigit()
            and suffix[8] == "-"
            and suffix[9:11].isdigit()
        ):
            name = name[:-11]
    parts = name.rsplit("-", 1)
    if len(parts) == 2 and len(parts[1]) == 8 and parts[1].isdigit():
        name = parts[0]
    for suffix in ("-minimal", "-low", "-medium", "-high", "-xhigh"):
        if name.endswith(suffix) and name[: -len(suffix)] in PRICING_BY_MODEL:
            return name[: -len(suffix)]
    return name


def pricing_candidates(model: object) -> list[str]:
    normalized = normalize_model_for_pricing(model)
    candidates = [normalized]
    for suffix in ("-xhigh", "-high", "-medium", "-low", "-minimal"):
        if normalized.endswith(suffix):
            candidates.append(normalized[: -len(suffix)])
    parts = normalized.split("-")
    while len(parts) > 2:
        parts.pop()
        candidates.append("-".join(parts))
    result: list[str] = []
    for item in candidates:
        if item and item not in result:
            result.append(item)
    return result


def find_model_pricing(model: object) -> dict[str, object] | None:
    for candidate in pricing_candidates(model):
        if candidate in PRICING_BY_MODEL:
            return PRICING_BY_MODEL[candidate]
    return None


def token_int(data: dict, *keys: str) -> int:
    for key in keys:
        value = data.get(key)
        if isinstance(value, (int, float)):
            return int(value)
        if isinstance(value, str) and value.strip().isdigit():
            return int(value)
    return 0


def usage_counters(data: object) -> dict[str, int]:
    if not isinstance(data, dict):
        return {}
    input_tokens = token_int(data, "input_tokens")
    cache_read = token_int(data, "cached_input_tokens", "cache_read_input_tokens")
    cache_creation = token_int(data, "cache_write_input_tokens", "cache_creation_input_tokens")
    output_tokens = token_int(data, "output_tokens")
    total_tokens = token_int(data, "total_tokens")
    return {
        "input_tokens": input_tokens,
        "cache_read_tokens": cache_read,
        "cache_creation_tokens": cache_creation,
        "fresh_input_tokens": max(input_tokens - cache_read - cache_creation, 0),
        "output_tokens": output_tokens,
        "total_tokens": total_tokens or input_tokens + output_tokens,
    }


def delta_usage(previous: dict[str, int] | None, current: dict[str, int]) -> dict[str, int]:
    if previous is None:
        return current
    input_tokens = max(current.get("input_tokens", 0) - previous.get("input_tokens", 0), 0)
    cache_read = max(current.get("cache_read_tokens", 0) - previous.get("cache_read_tokens", 0), 0)
    cache_creation = max(current.get("cache_creation_tokens", 0) - previous.get("cache_creation_tokens", 0), 0)
    output_tokens = max(current.get("output_tokens", 0) - previous.get("output_tokens", 0), 0)
    total_tokens = max(current.get("total_tokens", 0) - previous.get("total_tokens", 0), 0)
    return {
        "input_tokens": input_tokens,
        "cache_read_tokens": cache_read,
        "cache_creation_tokens": cache_creation,
        "fresh_input_tokens": max(input_tokens - cache_read - cache_creation, 0),
        "output_tokens": output_tokens,
        "total_tokens": total_tokens or input_tokens + output_tokens,
    }


def calculate_cost(model: object, usage: dict[str, int]) -> dict[str, float]:
    pricing = find_model_pricing(model)
    if pricing is None:
        return {
            "input_cost": 0.0,
            "output_cost": 0.0,
            "cache_read_cost": 0.0,
            "cache_creation_cost": 0.0,
            "total_cost": 0.0,
            "pricing_model": "",
        }
    million = 1_000_000.0
    input_cost = usage.get("fresh_input_tokens", 0) * float(pricing["input"]) / million
    output_cost = usage.get("output_tokens", 0) * float(pricing["output"]) / million
    cache_read_cost = usage.get("cache_read_tokens", 0) * float(pricing["cache_read"]) / million
    cache_creation_cost = usage.get("cache_creation_tokens", 0) * float(pricing["cache_creation"]) / million
    total_cost = input_cost + output_cost + cache_read_cost + cache_creation_cost
    return {
        "input_cost": input_cost,
        "output_cost": output_cost,
        "cache_read_cost": cache_read_cost,
        "cache_creation_cost": cache_creation_cost,
        "total_cost": total_cost,
        "pricing_model": str(pricing["model_id"]),
    }


def infer_session_id_from_filename(path: Path) -> str:
    match = UUID_RE.search(path.name)
    return match.group(0) if match else rollout_id_from_path(path)


def load_thread_titles(codex_dir: Path) -> dict[str, str]:
    index_path = codex_dir / "session_index.jsonl"
    titles: dict[str, str] = {}
    if not index_path.exists():
        return titles
    with index_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            session_id = str(row.get("id") or "").strip()
            title = str(row.get("thread_name") or "").strip()
            if session_id and title:
                titles[session_id] = title
    return titles


def load_threads(codex_dir: Path) -> dict[str, dict]:
    state_db = codex_dir / "state_5.sqlite"
    if not state_db.exists():
        return {}

    threads: dict[str, dict] = {}
    with sqlite3.connect(state_db) as conn:
        conn.row_factory = sqlite3.Row
        for row in conn.execute(
            """
            SELECT id, rollout_path, model, reasoning_effort, cwd, title, created_at,
                   updated_at, tokens_used, archived
            FROM threads
            """
        ):
            rollout_path = row["rollout_path"]
            if rollout_path:
                row_data = dict(row)
                for key in path_lookup_keys(rollout_path):
                    threads[key] = row_data
    return threads


def read_session_rollout_info(file_path: Path) -> dict:
    last_usage = None
    last_token_timestamp = ""
    last_event_timestamp = ""
    session_id = ""
    cwd = ""
    model_provider = ""
    source = ""
    first_user_title = ""
    last_message_summary = ""
    message_count = 0

    with file_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            timestamp = event.get("timestamp") or ""
            if timestamp:
                last_event_timestamp = timestamp

            if event.get("type") == "session_meta":
                payload = event.get("payload") or {}
                if isinstance(payload, dict):
                    if not session_id:
                        session_id = str(payload.get("id") or "").strip()
                    if not cwd:
                        cwd = str(payload.get("cwd") or "").replace("\\\\?\\", "").strip()
                    if not model_provider:
                        model_provider = str(payload.get("model_provider") or "").strip()
                    if not source:
                        source = str(payload.get("source") or "").strip()

            payload = event.get("payload") or {}
            if payload.get("type") != "token_count":
                if event.get("type") == "response_item" and isinstance(payload, dict):
                    payload_type = payload.get("type")
                    if payload_type == "message":
                        role = str(payload.get("role") or "unknown")
                        content = extract_text(payload.get("content"))
                        if content.strip():
                            message_count += 1
                            last_message_summary = content
                            if role == "user" and not first_user_title:
                                first_user_title = title_candidate_from_user_message(content) or ""
                    elif payload_type in ("function_call", "function_call_output"):
                        message_count += 1
                continue

            usage = ((payload.get("info") or {}).get("total_token_usage") or {})
            if usage:
                last_usage = usage
                last_token_timestamp = timestamp

    return {
        "usage": last_usage,
        "token_timestamp": last_token_timestamp,
        "last_event_timestamp": last_event_timestamp,
        "last_event_unix": parse_timestamp_to_unix(last_event_timestamp),
        "session_id": session_id or infer_session_id_from_filename(file_path),
        "cwd": cwd,
        "model_provider": model_provider,
        "source": source,
        "first_user_title": first_user_title,
        "summary": truncate_text(last_message_summary, 160) if last_message_summary else "",
        "message_count": message_count,
    }


def load_session_messages(file_path: Path) -> list[dict]:
    messages: list[dict] = []
    with file_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") != "response_item":
                continue
            payload = event.get("payload") or {}
            if not isinstance(payload, dict):
                continue
            payload_type = str(payload.get("type") or "")
            role = ""
            content = ""
            if payload_type == "message":
                role = str(payload.get("role") or "unknown")
                content = extract_text(payload.get("content"))
            elif payload_type == "function_call":
                role = "assistant"
                content = "[Tool: %s]" % (payload.get("name") or "unknown")
            elif payload_type == "function_call_output":
                role = "tool"
                content = str(payload.get("output") or "")
            else:
                continue
            if not content.strip():
                continue
            messages.append(
                {
                    "role": role,
                    "content": content,
                    "timestamp": str(event.get("timestamp") or ""),
                    "unix": parse_timestamp_to_unix(event.get("timestamp")),
                }
            )
    return messages


def read_session_usage_events(file_path: Path, meta: dict, storage: str) -> list[dict]:
    session_id = str(meta.get("id") or infer_session_id_from_filename(file_path))
    current_model = str(meta.get("model") or "").strip()
    current_cwd = str(meta.get("cwd") or "").replace("\\\\?\\", "").strip()
    previous_total: dict[str, int] | None = None
    events: list[dict] = []

    with file_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            payload = event.get("payload") or {}
            if event.get("type") == "session_meta" and isinstance(payload, dict):
                session_id = str(payload.get("id") or payload.get("session_id") or session_id).strip()
                current_cwd = str(payload.get("cwd") or current_cwd).replace("\\\\?\\", "").strip()
                continue

            if event.get("type") == "event_msg" and isinstance(payload, dict):
                if payload.get("type") == "thread_settings_applied":
                    thread_settings = payload.get("thread_settings") or {}
                    if isinstance(thread_settings, dict):
                        current_model = str(thread_settings.get("model") or current_model).strip()
                    continue

                if payload.get("type") != "token_count":
                    continue

                info = payload.get("info") or {}
                if not isinstance(info, dict):
                    continue
                total_usage = usage_counters(info.get("total_token_usage"))
                last_usage = usage_counters(info.get("last_token_usage"))
                if last_usage:
                    usage = last_usage
                elif total_usage:
                    usage = delta_usage(previous_total, total_usage)
                else:
                    continue
                if total_usage:
                    previous_total = total_usage

                unix = parse_timestamp_to_unix(event.get("timestamp"))
                if unix <= 0:
                    continue
                model = current_model or "unknown"
                cost = calculate_cost(model, usage)
                event_id = "%s|%s|%s|%s|%s|%s" % (
                    session_id,
                    event.get("timestamp") or "",
                    model,
                    usage.get("input_tokens", 0),
                    usage.get("cache_read_tokens", 0),
                    usage.get("output_tokens", 0),
                )
                events.append(
                    {
                        "event_id": event_id,
                        "session_id": session_id,
                        "timestamp": str(event.get("timestamp") or ""),
                        "unix": unix,
                        "model": ui_string(model, 80),
                        "cwd": ui_string(current_cwd, 320),
                        "source": "Codex Session",
                        "storage": storage,
                        "cached_input_tokens": int(usage.get("cache_read_tokens", 0)),
                        "cost": float(cost.get("total_cost", 0.0)),
                        **usage,
                        **cost,
                    }
                )

    return events


def collect_usage_events(codex_dir: Path) -> list[dict]:
    threads = load_threads(codex_dir)
    roots = [
        ("active", codex_dir / "sessions"),
        ("archived", codex_dir / "archived_sessions"),
        ("backup", codex_dir / "deleted_sessions_backup" / "sessions"),
    ]
    events: list[dict] = []
    seen: set[str] = set()
    for storage, root in roots:
        if not root.exists():
            continue
        for file_path in root.rglob("rollout-*.jsonl"):
            meta = {}
            for key in path_lookup_keys(file_path):
                if key in threads:
                    meta = threads[key]
                    break
            for event in read_session_usage_events(file_path, meta, storage):
                event_key = str(event.get("event_id", ""))
                if event_key in seen:
                    continue
                seen.add(event_key)
                events.append(event)
    events.sort(key=lambda item: int(item.get("unix", 0)))
    return events


def filtered_usage_events(events: list[dict], start_unix: int = 0, end_unix: int = 0, model: str = "", source: str = "") -> list[dict]:
    result: list[dict] = []
    model = model.strip()
    source = source.strip()
    for event in events:
        unix = int(event.get("unix") or 0)
        if start_unix > 0 and unix < start_unix:
            continue
        if end_unix > 0 and unix > end_unix:
            continue
        if model and model != "all" and str(event.get("model", "")) != model:
            continue
        if source and source != "all" and str(event.get("source", "")) != source:
            continue
        result.append(event)
    return result


def usage_summary(events: list[dict]) -> dict:
    summary = {
        "total_requests": len(events),
        "total_cost": 0.0,
        "fresh_input_tokens": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_creation_tokens": 0,
        "real_total_tokens": 0,
        "cache_hit_rate": 0.0,
    }
    for event in events:
        summary["total_cost"] += float(event.get("total_cost") or 0)
        summary["fresh_input_tokens"] += int(event.get("fresh_input_tokens") or 0)
        summary["input_tokens"] += int(event.get("input_tokens") or 0)
        summary["output_tokens"] += int(event.get("output_tokens") or 0)
        summary["cache_read_tokens"] += int(event.get("cache_read_tokens") or 0)
        summary["cache_creation_tokens"] += int(event.get("cache_creation_tokens") or 0)
    summary["real_total_tokens"] = (
        int(summary["fresh_input_tokens"])
        + int(summary["output_tokens"])
        + int(summary["cache_read_tokens"])
        + int(summary["cache_creation_tokens"])
    )
    cacheable = (
        int(summary["fresh_input_tokens"])
        + int(summary["cache_read_tokens"])
        + int(summary["cache_creation_tokens"])
    )
    if cacheable > 0:
        summary["cache_hit_rate"] = int(summary["cache_read_tokens"]) / cacheable
    return summary


def usage_bucket_unix(unix: int, hourly: bool) -> int:
    dt = datetime.fromtimestamp(unix)
    if hourly:
        dt = dt.replace(minute=0, second=0, microsecond=0)
    else:
        dt = dt.replace(hour=0, minute=0, second=0, microsecond=0)
    return int(dt.timestamp())


def usage_trends(events: list[dict], start_unix: int = 0, end_unix: int = 0) -> list[dict]:
    if start_unix <= 0 and events:
        start_unix = int(events[0].get("unix") or 0)
    if end_unix <= 0 and events:
        end_unix = int(events[-1].get("unix") or 0)
    hourly = end_unix > 0 and start_unix > 0 and (end_unix - start_unix) <= 2 * 86400
    buckets: dict[int, dict] = {}
    for event in events:
        bucket = usage_bucket_unix(int(event.get("unix") or 0), hourly)
        item = buckets.setdefault(
            bucket,
            {
                "bucket_unix": bucket,
                "label": datetime.fromtimestamp(bucket).strftime("%m/%d %H:00" if hourly else "%m/%d"),
                "request_count": 0,
                "fresh_input_tokens": 0,
                "output_tokens": 0,
                "cache_read_tokens": 0,
                "cache_creation_tokens": 0,
                "total_cost": 0.0,
                "real_total_tokens": 0,
            },
        )
        item["request_count"] += 1
        item["fresh_input_tokens"] += int(event.get("fresh_input_tokens") or 0)
        item["output_tokens"] += int(event.get("output_tokens") or 0)
        item["cache_read_tokens"] += int(event.get("cache_read_tokens") or 0)
        item["cache_creation_tokens"] += int(event.get("cache_creation_tokens") or 0)
        item["total_cost"] += float(event.get("total_cost") or 0)
    for item in buckets.values():
        item["real_total_tokens"] = (
            int(item["fresh_input_tokens"])
            + int(item["output_tokens"])
            + int(item["cache_read_tokens"])
            + int(item["cache_creation_tokens"])
        )
    return [buckets[key] for key in sorted(buckets)]


def usage_model_stats(events: list[dict]) -> list[dict]:
    groups: dict[str, dict] = {}
    for event in events:
        model = str(event.get("model") or "unknown")
        item = groups.setdefault(
            model,
            {
                "model": model,
                "request_count": 0,
                "fresh_input_tokens": 0,
                "output_tokens": 0,
                "cache_read_tokens": 0,
                "cache_creation_tokens": 0,
                "total_tokens": 0,
                "total_cost": 0.0,
                "avg_cost_per_request": 0.0,
            },
        )
        item["request_count"] += 1
        item["fresh_input_tokens"] += int(event.get("fresh_input_tokens") or 0)
        item["output_tokens"] += int(event.get("output_tokens") or 0)
        item["cache_read_tokens"] += int(event.get("cache_read_tokens") or 0)
        item["cache_creation_tokens"] += int(event.get("cache_creation_tokens") or 0)
        item["total_cost"] += float(event.get("total_cost") or 0)
    for item in groups.values():
        item["total_tokens"] = (
            int(item["fresh_input_tokens"])
            + int(item["output_tokens"])
            + int(item["cache_read_tokens"])
            + int(item["cache_creation_tokens"])
        )
        if int(item["request_count"]) > 0:
            item["avg_cost_per_request"] = float(item["total_cost"]) / int(item["request_count"])
    return sorted(groups.values(), key=lambda item: float(item.get("total_cost") or 0), reverse=True)


def usage_sources(events: list[dict]) -> list[str]:
    return sorted({str(event.get("source") or "") for event in events if str(event.get("source") or "")})


def usage_models(events: list[dict]) -> list[str]:
    return sorted({str(event.get("model") or "") for event in events if str(event.get("model") or "")})


def usage_pricing_rows(events: list[dict]) -> list[dict]:
    used = {normalize_model_for_pricing(event.get("model")) for event in events}
    rows: list[dict] = []
    for row in DEFAULT_MODEL_PRICING:
        model_id = str(row["model_id"])
        rows.append(
            {
                "model_id": model_id,
                "display_name": str(row["display_name"]),
                "input_cost_per_million": float(row["input"]),
                "output_cost_per_million": float(row["output"]),
                "cache_read_cost_per_million": float(row["cache_read"]),
                "cache_creation_cost_per_million": float(row["cache_creation"]),
                "used": model_id in used,
            }
        )
    rows.sort(key=lambda item: (not bool(item.get("used")), str(item.get("model_id", ""))))
    return rows


def collect_sessions(codex_dir: Path) -> list[dict]:
    threads = load_threads(codex_dir)
    thread_titles = load_thread_titles(codex_dir)
    roots = [
        ("active", codex_dir / "sessions"),
        ("archived", codex_dir / "archived_sessions"),
        ("backup", codex_dir / "deleted_sessions_backup" / "sessions"),
    ]
    sessions: list[dict] = []

    for storage, root in roots:
        if not root.exists():
            continue
        for file_path in root.rglob("rollout-*.jsonl"):
            rollout_info = read_session_rollout_info(file_path)
            usage = rollout_info.get("usage")
            timestamp = rollout_info.get("token_timestamp") or rollout_info.get("last_event_timestamp")
            meta = {}
            for key in path_lookup_keys(file_path):
                if key in threads:
                    meta = threads[key]
                    break

            input_tokens = int((usage or {}).get("input_tokens") or 0)
            cached_input_tokens = int((usage or {}).get("cached_input_tokens") or 0)
            output_tokens = int((usage or {}).get("output_tokens") or 0)
            reasoning_output_tokens = int((usage or {}).get("reasoning_output_tokens") or 0)
            total_tokens = int((usage or {}).get("total_tokens") or 0)
            session_id = str(meta.get("id") or rollout_info.get("session_id") or rollout_id_from_path(file_path))
            cwd = str(meta.get("cwd") or rollout_info.get("cwd") or "").replace("\\\\?\\", "")
            title = (
                str(meta.get("title") or "").strip()
                or thread_titles.get(session_id, "")
                or str(rollout_info.get("first_user_title") or "").strip()
                or path_basename(cwd)
                or file_path.name
            )
            updated_at = int(meta.get("updated_at") or 0) if meta else 0
            if updated_at <= 0:
                updated_at = int(rollout_info.get("last_event_unix") or 0)

            sessions.append(
                {
                    "row_key": f"{storage}|{file_path}",
                    "id": session_id,
                    "timestamp": timestamp,
                    "model": ui_string(meta.get("model") or "", 80),
                    "reasoning_effort": ui_string(meta.get("reasoning_effort") or "", 40),
                    "cwd": ui_string(cwd, 320),
                    "source": ui_string(rollout_info.get("model_provider") or rollout_info.get("source") or "Codex", 80),
                    "title": ui_string(title, 240),
                    "summary": ui_string(rollout_info.get("summary") or "", 240),
                    "message_count": int(rollout_info.get("message_count") or 0),
                    "resume_command": f"codex resume {session_id}" if session_id else "",
                    "storage": storage,
                    "archived": bool(meta.get("archived")) if meta else storage == "archived",
                    "input_tokens": input_tokens,
                    "cached_input_tokens": cached_input_tokens,
                    "uncached_input_tokens": max(input_tokens - cached_input_tokens, 0),
                    "output_tokens": output_tokens,
                    "reasoning_output_tokens": reasoning_output_tokens,
                    "total_tokens": total_tokens,
                    "state_tokens_used": int(meta.get("tokens_used") or 0) if meta else 0,
                    "session_file": str(file_path),
                    "updated_at": updated_at,
                }
            )

    sessions.sort(key=lambda row: int(row.get("updated_at") or 0), reverse=True)
    return sessions


def build_summary(sessions: list[dict]) -> dict:
    keys = [
        "input_tokens",
        "cached_input_tokens",
        "uncached_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "total_tokens",
    ]
    summary = {"sessions": len(sessions)}
    for key in keys:
        summary[key] = sum(int(row[key]) for row in sessions)
    return summary


def remove_from_state(codex_dir: Path, session_paths: list[Path], session_ids: list[str]) -> None:
    state_db = codex_dir / "state_5.sqlite"
    if not state_db.exists():
        return

    path_values = [str(path) for path in session_paths]
    id_values = [sid for sid in session_ids if sid]
    with sqlite3.connect(state_db) as conn:
        for path in path_values:
            conn.execute("DELETE FROM threads WHERE rollout_path = ?", (path,))
        for sid in id_values:
            conn.execute("DELETE FROM threads WHERE id = ?", (sid,))
        conn.commit()
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")


def rewrite_session_index(codex_dir: Path, deleted_ids: set[str]) -> int:
    index_path = codex_dir / "session_index.jsonl"
    if not index_path.exists() or not deleted_ids:
        return 0

    kept_lines: list[str] = []
    removed = 0
    with index_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                kept_lines.append(line)
                continue
            if row.get("id") in deleted_ids:
                removed += 1
                continue
            kept_lines.append(line)

    with index_path.open("w", encoding="utf-8", newline="") as file:
        file.writelines(kept_lines)
    return removed


def session_signature(row: dict) -> str:
    return "|".join(
        [
            str(row.get("id", "")),
            str(row.get("model", "")),
            str(row.get("reasoning_effort", "")),
            str(row.get("cwd", "")),
            str(row.get("title", "")),
            str(row.get("input_tokens", 0)),
            str(row.get("cached_input_tokens", 0)),
            str(row.get("uncached_input_tokens", 0)),
            str(row.get("output_tokens", 0)),
            str(row.get("reasoning_output_tokens", 0)),
            str(row.get("total_tokens", 0)),
        ]
    )


def delete_sessions(
    codex_dir: Path,
    ids: list[str],
    keys: list[str],
    archived_only: bool = False,
) -> dict:
    sessions = collect_sessions(codex_dir)
    id_set = set(ids)
    key_set = set(keys)
    if archived_only:
        targets = [row for row in sessions if row["storage"] == "archived"]
    elif key_set:
        selected = [row for row in sessions if row["row_key"] in key_set]
        selected_signatures = {session_signature(row) for row in selected}
        targets = [row for row in sessions if session_signature(row) in selected_signatures]
    else:
        targets = [row for row in sessions if row["id"] in id_set]

    deleted_paths: list[Path] = []
    deleted_ids: list[str] = []

    for row in targets:
        file_path = Path(row["session_file"])
        if not file_path.exists():
            continue
        file_path.unlink()
        deleted_paths.append(file_path)
        if row["storage"] != "backup":
            deleted_ids.append(row["id"])

    remove_from_state(codex_dir, deleted_paths, deleted_ids)
    removed_index_rows = rewrite_session_index(codex_dir, set(deleted_ids))

    return {
        "deleted": len(deleted_paths),
        "deleted_ids": deleted_ids,
        "removed_index_rows": removed_index_rows,
    }


def delete_all_backups(codex_dir: Path) -> dict:
    backup_root = codex_dir / "deleted_sessions_backup"
    deleted = 0
    if not backup_root.exists():
        return {"deleted": 0}

    for path in backup_root.rglob("*"):
        if path.is_file():
            deleted += 1
            path.unlink()
    for path in sorted(backup_root.rglob("*"), reverse=True):
        if path.is_dir():
            try:
                path.rmdir()
            except OSError:
                pass
    try:
        backup_root.rmdir()
    except OSError:
        pass
    return {"deleted": deleted}


def cmd_list(args: argparse.Namespace) -> None:
    codex_dir = resolve_codex_dir(args.codex_dir)
    sessions = collect_sessions(codex_dir)
    emit_json(
        {
            "success": True,
            "codex_dir": str(codex_dir),
            "codex_dir_exists": is_codex_dir(codex_dir),
            "summary": build_summary(sessions),
            "sessions": sessions,
        },
        args.output_json,
    )


def cmd_delete(args: argparse.Namespace) -> None:
    codex_dir = resolve_codex_dir(args.codex_dir)
    result = delete_sessions(
        codex_dir,
        args.ids or [],
        args.keys or [],
        archived_only=False,
    )
    emit_json({"success": True, "result": result}, args.output_json)


def cmd_delete_archived(args: argparse.Namespace) -> None:
    codex_dir = resolve_codex_dir(args.codex_dir)
    result = delete_sessions(
        codex_dir,
        [],
        [],
        archived_only=True,
    )
    emit_json({"success": True, "result": result}, args.output_json)


def cmd_delete_backups(args: argparse.Namespace) -> None:
    codex_dir = resolve_codex_dir(args.codex_dir)
    result = delete_all_backups(codex_dir)
    emit_json({"success": True, "result": result}, args.output_json)


def cmd_messages(args: argparse.Namespace) -> None:
    file_path = Path(args.session_file).expanduser()
    messages = load_session_messages(file_path)
    emit_json(
        {
            "success": True,
            "session_file": str(file_path),
            "message_count": len(messages),
            "messages": messages,
        },
        args.output_json,
    )


def cmd_usage_events(args: argparse.Namespace) -> None:
    codex_dir = resolve_codex_dir(args.codex_dir)
    events = collect_usage_events(codex_dir)
    emit_json(
        {
            "success": True,
            "codex_dir": str(codex_dir),
            "event_count": len(events),
            "events": events,
        },
        args.output_json,
    )


def cmd_usage(args: argparse.Namespace) -> None:
    codex_dir = resolve_codex_dir(args.codex_dir)
    all_events = collect_usage_events(codex_dir)
    start_unix = int(args.start_unix or 0)
    end_unix = int(args.end_unix or 0)
    events = filtered_usage_events(
        all_events,
        start_unix=start_unix,
        end_unix=end_unix,
        model=str(args.model or ""),
        source=str(args.source or ""),
    )
    emit_json(
        {
            "success": True,
            "codex_dir": str(codex_dir),
            "event_count": len(events),
            "summary": usage_summary(events),
            "trends": usage_trends(events, start_unix, end_unix),
            "model_stats": usage_model_stats(events),
            "models": usage_models(all_events),
            "sources": usage_sources(all_events),
            "pricing": usage_pricing_rows(all_events),
        },
        args.output_json,
    )


def emit_json(payload: dict, output_json: str = "") -> None:
    text = json.dumps(payload, ensure_ascii=False)
    if output_json:
        Path(output_json).write_text(text, encoding="utf-8")
    else:
        print(text)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Codex token/session backend for Godot UI.")
    parser.add_argument("--codex-dir", default="")
    parser.add_argument("--output-json", default="")
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list")
    list_parser.set_defaults(func=cmd_list)

    delete_parser = subparsers.add_parser("delete")
    delete_parser.add_argument("--ids", nargs="*")
    delete_parser.add_argument("--keys", nargs="*")
    delete_parser.set_defaults(func=cmd_delete)

    archived_parser = subparsers.add_parser("delete-archived")
    archived_parser.set_defaults(func=cmd_delete_archived)

    backups_parser = subparsers.add_parser("delete-backups")
    backups_parser.set_defaults(func=cmd_delete_backups)

    messages_parser = subparsers.add_parser("messages")
    messages_parser.add_argument("--session-file", required=True)
    messages_parser.set_defaults(func=cmd_messages)

    usage_events_parser = subparsers.add_parser("usage-events")
    usage_events_parser.set_defaults(func=cmd_usage_events)

    usage_parser = subparsers.add_parser("usage")
    usage_parser.add_argument("--start-unix", type=int, default=0)
    usage_parser.add_argument("--end-unix", type=int, default=0)
    usage_parser.add_argument("--model", default="")
    usage_parser.add_argument("--source", default="")
    usage_parser.set_defaults(func=cmd_usage)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as exc:
        eprint(str(exc))
        emit_json({"success": False, "error": str(exc)}, getattr(args, "output_json", ""))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
