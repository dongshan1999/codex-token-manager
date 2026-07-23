# Codex Token Manager

Godot desktop tool for viewing local Codex token usage and deleting session records.

## Features

- Groups Codex sessions by project directory.
- Shows per-session token usage:
  - input tokens
  - cached input tokens
  - uncached input tokens
  - output tokens
  - reasoning output tokens
  - total tokens
- Shows conversation messages from Codex JSONL logs, with role-specific blocks for user, AI, tool, system, and developer messages.
- Builds a conversation table of contents from real user prompts.
- Displays and copies the current project directory and `codex resume <session-id>` command.
- Filters by model, directory, title, file path, or session id.
- Deletes a selected session.
- Deletes all archived sessions.
- Lists and deletes `deleted_sessions_backup` records.
- Saves the currently displayed rows to a Godot JSON archive.
- Archives deleted-row metadata before delete operations.

## Button Guide

- `刷新`: reload sessions from `.codex`.
- `删除选中会话`: delete the currently selected row. If `删除前备份` is enabled and the row is not already a backup, the raw `rollout-*.jsonl` is copied to `.codex/deleted_sessions_backup` first. The displayed row data is always appended to `codex_deleted_session_archive.json`.
- `删除全部归档`: delete all rows from `.codex/archived_sessions`; also appends their displayed row data to `codex_deleted_session_archive.json`.
- `删除全部备份`: delete `.codex/deleted_sessions_backup`; also appends the displayed backup rows to `codex_deleted_session_archive.json`.
- `保存当前显示`: save the currently filtered/sorted table rows to `codex_current_display_archive.json`.
- `打开工具存档`: open the Godot `user://` folder where `codex_current_display_archive.json` and `codex_deleted_session_archive.json` are stored.
- `导出存档`: export the current-display archive and deleted-session archive into one JSON file. The system file picker opens in Documents by default.
- `导入存档`: import a JSON archive exported by this tool, or import a standalone current-display/deleted-session archive.
- `显示归档`: include archived sessions in the table.
- `显示备份`: include `.codex/deleted_sessions_backup` rows in the table.
- `删除前备份`: controls whether raw session JSONL files are copied into `.codex/deleted_sessions_backup` before deletion. This does not affect the Godot JSON deletion archive; deleted row metadata is always saved.

Table header sorting:

- Left-click a column title to add/toggle that column in multi-column sorting.
- Right-click a column title to remove that column from sorting.
- `▲1` / `▼1` show sort direction and priority.

## Data Sources

The tool reads Codex data from the local user profile. On Windows:

- `%USERPROFILE%\.codex\sessions`
- `%USERPROFILE%\.codex\archived_sessions`
- `%USERPROFILE%\.codex\state_5.sqlite`
- `%USERPROFILE%\.codex\session_index.jsonl`

On macOS:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`

If `CODEX_HOME` or `CODEX_DIR` is set, the tool checks that location first.

## Delete Behavior

Delete operations first back up session JSONL files under:

```text
%USERPROFILE%\.codex\deleted_sessions_backup
~/.codex/deleted_sessions_backup
```

Then they remove matching records from:

- `state_5.sqlite`
- `session_index.jsonl`

The tool does not touch `auth.json`, `config.toml`, `skills`, or `plugins`.

## Godot Tool Archives

Godot metadata archives are saved under the app's `user://` folder:

```text
codex_current_display_archive.json
codex_deleted_session_archive.json
```

Use `打开工具存档` in the UI to open this folder.

## Run

Open this folder in Godot 4 and run the main scene.

The Godot UI calls:

```text
tools/codex_usage_backend.py
```

Python 3 must be available as `python` in PATH.
On macOS, the app also tries `python3`, `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, and `/usr/bin/python3`.
