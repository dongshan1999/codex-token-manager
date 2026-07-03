import argparse
import json
import os
import sqlite3
import sys
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
                threads[str(Path(rollout_path)).lower()] = dict(row)
    return threads


def read_last_token_usage(file_path: Path) -> tuple[dict | None, str]:
    last_usage = None
    last_timestamp = ""

    with file_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            if '"type":"token_count"' not in line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            payload = event.get("payload") or {}
            if payload.get("type") != "token_count":
                continue

            usage = ((payload.get("info") or {}).get("total_token_usage") or {})
            if usage:
                last_usage = usage
                last_timestamp = event.get("timestamp") or ""

    return last_usage, last_timestamp


def collect_sessions(codex_dir: Path) -> list[dict]:
    threads = load_threads(codex_dir)
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
            usage, timestamp = read_last_token_usage(file_path)
            meta = threads.get(str(file_path).lower(), {})

            input_tokens = int((usage or {}).get("input_tokens") or 0)
            cached_input_tokens = int((usage or {}).get("cached_input_tokens") or 0)
            output_tokens = int((usage or {}).get("output_tokens") or 0)
            reasoning_output_tokens = int((usage or {}).get("reasoning_output_tokens") or 0)
            total_tokens = int((usage or {}).get("total_tokens") or 0)

            sessions.append(
                {
                    "row_key": f"{storage}|{file_path}",
                    "id": meta.get("id") or rollout_id_from_path(file_path),
                    "timestamp": timestamp,
                    "model": ui_string(meta.get("model") or "", 80),
                    "reasoning_effort": ui_string(meta.get("reasoning_effort") or "", 40),
                    "cwd": ui_string((meta.get("cwd") or "").replace("\\\\?\\", ""), 320),
                    "title": ui_string(meta.get("title") or file_path.name, 240),
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
                    "updated_at": int(meta.get("updated_at") or 0) if meta else 0,
                }
            )

    sessions.sort(key=lambda row: row["total_tokens"], reverse=True)
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
