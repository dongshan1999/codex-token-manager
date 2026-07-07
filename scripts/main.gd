extends Control


const BACKEND_PATH := "res://tools/codex_usage_backend.py"
const MAX_VISIBLE_ROWS := 500
const DISPLAY_ARCHIVE_PATH := "user://codex_current_display_archive.json"
const DELETED_ARCHIVE_PATH := "user://codex_deleted_session_archive.json"
const SETTINGS_PATH := "user://codex_tool_settings.json"
const EXPORT_ARCHIVE_VERSION := "1.0.0"
const SAVE_VERSION := "1.0.0"

var sessions: Array = []
var filtered_sessions: Array = []
var selected_id := ""
var selected_row_key := ""
var pending_action := ""
var pending_keys: Array[String] = []
var current_codex_dir := ""
var sort_rules: Array[Dictionary] = [
	{"column": 0, "ascending": false},
]

var column_titles := [
	"总M",
	"输入M",
	"缓存M",
	"输出M",
	"模型",
	"档位",
	"状态",
	"工作目录",
	"标题",
]

var summary_label: Label
var filter_edit: LineEdit
var include_archived_check: CheckBox
var include_backup_check: CheckBox
var include_deleted_archive_check: CheckBox
var time_range_option: OptionButton
var session_tree: Tree
var details_label: RichTextLabel
var log_label: Label
var confirm_dialog: ConfirmationDialog
var export_dialog: FileDialog
var import_dialog: FileDialog
var open_folder_button: Button


func _ready() -> void:
	_build_ui()
	_load_settings()
	_normalize_deleted_archive()
	_refresh_sessions()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_top", 16)
	root.add_theme_constant_override("margin_right", 16)
	root.add_theme_constant_override("margin_bottom", 16)
	add_child(root)

	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	root.add_child(main)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 10)
	main.add_child(title_row)

	var title := Label.new()
	title.text = "Codex Token Manager"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	var refresh_button := Button.new()
	refresh_button.text = "刷新"
	refresh_button.tooltip_text = "重新读取 .codex 会话、归档、备份数据，并保存到当前存档 JSON。"
	refresh_button.pressed.connect(_refresh_sessions)
	title_row.add_child(refresh_button)

	var delete_button := Button.new()
	delete_button.text = "删除选中会话"
	delete_button.tooltip_text = "删除选中会话在当前、归档、备份里的全部副本。"
	delete_button.pressed.connect(_confirm_delete_selected)
	title_row.add_child(delete_button)

	var delete_archived_button := Button.new()
	delete_archived_button.text = "删除全部归档"
	delete_archived_button.tooltip_text = "删除 .codex/archived_sessions 下的全部会话。"
	delete_archived_button.pressed.connect(_confirm_delete_archived)
	title_row.add_child(delete_archived_button)

	var delete_backups_button := Button.new()
	delete_backups_button.text = "删除全部备份"
	delete_backups_button.tooltip_text = "删除 .codex/deleted_sessions_backup 下的全部文件。"
	delete_backups_button.pressed.connect(_confirm_delete_backups)
	title_row.add_child(delete_backups_button)

	var open_archive_button := Button.new()
	open_archive_button.text = "打开工具存档"
	open_archive_button.tooltip_text = "打开保存当前显示和删除会话记录 JSON 的 Godot 工具存档目录。"
	open_archive_button.pressed.connect(_open_tool_archive_folder)
	title_row.add_child(open_archive_button)

	var export_archive_button := Button.new()
	export_archive_button.text = "导出存档"
	export_archive_button.tooltip_text = "把当前显示存档和删除会话存档导出为一个 JSON 文件。"
	export_archive_button.pressed.connect(_open_export_archive_dialog)
	title_row.add_child(export_archive_button)

	var import_archive_button := Button.new()
	import_archive_button.text = "导入存档"
	import_archive_button.tooltip_text = "从 JSON 文件导入工具存档。支持合并存档，也支持单独的当前显示或删除存档。"
	import_archive_button.pressed.connect(_open_import_archive_dialog)
	title_row.add_child(import_archive_button)

	summary_label = Label.new()
	summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	main.add_child(summary_label)

	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 8)
	main.add_child(filter_row)

	var filter_label := Label.new()
	filter_label.text = "筛选"
	filter_row.add_child(filter_label)

	filter_edit = LineEdit.new()
	filter_edit.placeholder_text = "输入模型、目录、标题、文件路径或会话 ID"
	filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_edit.text_changed.connect(func(_text: String) -> void: _apply_filter())
	filter_row.add_child(filter_edit)

	include_archived_check = CheckBox.new()
	include_archived_check.text = "显示归档"
	include_archived_check.button_pressed = true
	include_archived_check.toggled.connect(func(_pressed: bool) -> void: _apply_filter())
	filter_row.add_child(include_archived_check)

	include_backup_check = CheckBox.new()
	include_backup_check.text = "显示备份"
	include_backup_check.button_pressed = true
	include_backup_check.toggled.connect(func(_pressed: bool) -> void: _apply_filter())
	filter_row.add_child(include_backup_check)

	include_deleted_archive_check = CheckBox.new()
	include_deleted_archive_check.text = "显示删除存档"
	include_deleted_archive_check.button_pressed = false
	include_deleted_archive_check.toggled.connect(func(_pressed: bool) -> void: _apply_filter())
	filter_row.add_child(include_deleted_archive_check)

	var range_label := Label.new()
	range_label.text = "时间"
	filter_row.add_child(range_label)

	time_range_option = OptionButton.new()
	time_range_option.add_item("最近1天", 1)
	time_range_option.add_item("最近一周", 7)
	time_range_option.add_item("最近一个月", 30)
	time_range_option.add_item("全部对话", 0)
	time_range_option.select(3)
	time_range_option.item_selected.connect(func(_index: int) -> void: _apply_filter())
	filter_row.add_child(time_range_option)

	var sort_hint := Label.new()
	sort_hint.text = "表头左键加入/切换多列排序，右键移除排序条件；数字表示优先级。"
	sort_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	main.add_child(sort_hint)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(split)

	session_tree = Tree.new()
	session_tree.columns = 9
	session_tree.hide_root = true
	session_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	session_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	session_tree.select_mode = Tree.SELECT_SINGLE
	_setup_tree_columns()
	session_tree.item_selected.connect(_on_session_selected)
	session_tree.column_title_clicked.connect(_on_column_title_clicked)
	split.add_child(session_tree)

	var detail_panel := VBoxContainer.new()
	detail_panel.custom_minimum_size = Vector2(360, 0)
	detail_panel.add_theme_constant_override("separation", 8)
	split.add_child(detail_panel)

	open_folder_button = Button.new()
	open_folder_button.text = "打开会话文件夹"
	open_folder_button.disabled = true
	open_folder_button.pressed.connect(_open_selected_session_folder)
	detail_panel.add_child(open_folder_button)

	details_label = RichTextLabel.new()
	details_label.fit_content = false
	details_label.bbcode_enabled = true
	details_label.scroll_active = true
	details_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_child(details_label)

	log_label = Label.new()
	log_label.text = "就绪"
	log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	main.add_child(log_label)

	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.confirmed.connect(_run_pending_action)
	add_child(confirm_dialog)

	export_dialog = FileDialog.new()
	export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title = "导出 Codex 存档 JSON"
	export_dialog.filters = PackedStringArray(["*.json ; JSON 文件"])
	export_dialog.file_selected.connect(_export_archive_to_file)
	add_child(export_dialog)

	import_dialog = FileDialog.new()
	import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	import_dialog.title = "导入 Codex 存档 JSON"
	import_dialog.filters = PackedStringArray(["*.json ; JSON 文件"])
	import_dialog.file_selected.connect(_import_archive_from_file)
	add_child(import_dialog)


func _setup_tree_columns() -> void:
	var widths := [80, 80, 90, 80, 95, 75, 105, 260, 340]
	session_tree.set_column_titles_visible(true)
	for i in range(column_titles.size()):
		session_tree.set_column_title(i, column_titles[i])
		session_tree.set_column_custom_minimum_width(i, widths[i])
	_update_column_titles()


func _refresh_sessions() -> void:
	log_label.text = "正在读取 .codex 会话、归档、备份数据..."
	var result := _run_backend(["list"])
	if not result.get("success", false):
		log_label.text = "读取失败: %s" % result.get("error", "unknown error")
		return

	var was_empty_cache := current_codex_dir == ""
	current_codex_dir = str(result.get("codex_dir", ""))
	if was_empty_cache and current_codex_dir != "":
		_save_settings()
	sessions = result.get("sessions", [])
	sessions.append_array(_deleted_archive_rows())
	_save_current_display_archive()
	_apply_filter()
	log_label.text = "已读取 %s 并保存当前存档，共 %d 条记录" % [current_codex_dir, sessions.size()]


func _update_summary(summary: Dictionary) -> void:
	summary_label.text = (
		"行数 %d | 总 %.2fM | 输入 %.2fM | 缓存 %.2fM | 非缓存 %.2fM | 输出 %.2fM | 推理 %.2fM"
		% [
			int(summary.get("sessions", 0)),
			_to_million(summary.get("total_tokens", 0)),
			_to_million(summary.get("input_tokens", 0)),
			_to_million(summary.get("cached_input_tokens", 0)),
			_to_million(summary.get("uncached_input_tokens", 0)),
			_to_million(summary.get("output_tokens", 0)),
			_to_million(summary.get("reasoning_output_tokens", 0)),
		]
	)


func _apply_filter() -> void:
	var query := filter_edit.text.strip_edges().to_lower()
	filtered_sessions.clear()
	for row in sessions:
		if not include_archived_check.button_pressed and row.get("storage", "") == "archived":
			continue
		if not include_backup_check.button_pressed and row.get("storage", "") == "backup":
			continue
		if not include_deleted_archive_check.button_pressed and row.get("storage", "") == "deleted_archive":
			continue
		if not _row_in_selected_time_range(row):
			continue
		if query != "" and not _row_matches_query(row, query):
			continue
		filtered_sessions.append(row)
	_sort_filtered_sessions()
	_update_summary(_build_rows_summary(filtered_sessions))
	_render_tree()


func _on_column_title_clicked(column: int, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_LEFT:
		_toggle_sort_rule(column)
	elif mouse_button_index == MOUSE_BUTTON_RIGHT:
		_remove_sort_rule(column)
	else:
		return
	_sort_filtered_sessions()
	_update_column_titles()
	_render_tree()


func _toggle_sort_rule(column: int) -> void:
	var index := _find_sort_rule_index(column)
	if index == -1:
		sort_rules.append({"column": column, "ascending": true})
		return
	sort_rules[index]["ascending"] = not bool(sort_rules[index].get("ascending", true))


func _remove_sort_rule(column: int) -> void:
	var index := _find_sort_rule_index(column)
	if index != -1:
		sort_rules.remove_at(index)


func _find_sort_rule_index(column: int) -> int:
	for i in range(sort_rules.size()):
		if int(sort_rules[i].get("column", -1)) == column:
			return i
	return -1


func _sort_filtered_sessions() -> void:
	filtered_sessions.sort_custom(_compare_session_rows)


func _compare_session_rows(a: Dictionary, b: Dictionary) -> bool:
	for rule in sort_rules:
		var column := int(rule.get("column", 0))
		var ascending := bool(rule.get("ascending", true))
		var av = _sort_value(a, column)
		var bv = _sort_value(b, column)
		var cmp := _compare_values(av, bv)
		if cmp == 0:
			continue
		return cmp < 0 if ascending else cmp > 0
	var fallback_cmp := _compare_values(str(a.get("row_key", "")), str(b.get("row_key", "")))
	return fallback_cmp < 0


func _sort_value(row: Dictionary, column: int):
	match column:
		0:
			return int(row.get("total_tokens", 0))
		1:
			return int(row.get("input_tokens", 0))
		2:
			return int(row.get("cached_input_tokens", 0))
		3:
			return int(row.get("output_tokens", 0))
		4:
			return str(row.get("model", "")).to_lower()
		5:
			return str(row.get("reasoning_effort", "")).to_lower()
		6:
			match str(row.get("storage", "")):
				"active":
					return 0
				"archived":
					return 1
				"backup":
					return 2
				"deleted_archive":
					return 3
				_:
					return 9
		7:
			return str(row.get("cwd", "")).to_lower()
		8:
			return str(row.get("title", "")).to_lower()
		_:
			return int(row.get("total_tokens", 0))


func _compare_values(a, b) -> int:
	if a == b:
		return 0
	if typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT:
		return -1 if a < b else 1
	return -1 if str(a) < str(b) else 1


func _update_column_titles() -> void:
	if session_tree == null:
		return
	for i in range(column_titles.size()):
		var suffix := ""
		var rule_index := _find_sort_rule_index(i)
		if rule_index != -1:
			var ascending := bool(sort_rules[rule_index].get("ascending", true))
			suffix = " %s%d" % ["^" if ascending else "v", rule_index + 1]
		session_tree.set_column_title(i, "%s%s" % [column_titles[i], suffix])


func _row_matches_query(row: Dictionary, query: String) -> bool:
	var haystack := "%s %s %s %s %s %s %s %s" % [
		row.get("id", ""),
		row.get("model", ""),
		row.get("reasoning_effort", ""),
		row.get("cwd", ""),
		row.get("title", ""),
		row.get("session_file", ""),
		row.get("deleted_action", ""),
		row.get("deleted_at_text", ""),
	]
	return haystack.to_lower().contains(query)


func _render_tree() -> void:
	session_tree.clear()
	var root := session_tree.create_item()
	var count := mini(filtered_sessions.size(), MAX_VISIBLE_ROWS)
	for i in range(count):
		var row: Dictionary = filtered_sessions[i]
		var item := session_tree.create_item(root)
		item.set_metadata(0, row.get("row_key", ""))
		item.set_text(0, "%.2f" % _to_million(row.get("total_tokens", 0)))
		item.set_text(1, "%.2f" % _to_million(row.get("input_tokens", 0)))
		item.set_text(2, "%.2f" % _to_million(row.get("cached_input_tokens", 0)))
		item.set_text(3, "%.2f" % _to_million(row.get("output_tokens", 0)))
		item.set_text(4, str(row.get("model", "")))
		item.set_text(5, str(row.get("reasoning_effort", "")))
		item.set_text(6, _storage_label(str(row.get("storage", ""))))
		item.set_text(7, _shorten_path(str(row.get("cwd", ""))))
		item.set_text(8, str(row.get("title", "")))
	if filtered_sessions.size() > MAX_VISIBLE_ROWS:
		log_label.text = "筛选结果 %d 条，仅显示前 %d 条。" % [filtered_sessions.size(), MAX_VISIBLE_ROWS]
	selected_id = ""
	selected_row_key = ""
	open_folder_button.disabled = true
	details_label.text = "选择一个会话查看详情。"


func _on_session_selected() -> void:
	var item := session_tree.get_selected()
	if item == null:
		return
	selected_row_key = str(item.get_metadata(0))
	var row := _find_session_by_key(selected_row_key)
	if row.is_empty():
		return
	selected_id = str(row.get("id", ""))
	open_folder_button.disabled = false
	details_label.text = _format_details(row)


func _open_selected_session_folder() -> void:
	if selected_row_key == "":
		log_label.text = "请先选择一个会话。"
		return
	var row := _find_session_by_key(selected_row_key)
	if row.is_empty():
		log_label.text = "没有找到选中会话。"
		return
	var session_file := str(row.get("session_file", ""))
	if session_file == "":
		log_label.text = "选中记录没有文件路径。"
		return
	var folder_path := _to_native_path(session_file.get_base_dir())
	if not DirAccess.dir_exists_absolute(folder_path):
		log_label.text = "文件夹不存在: %s" % folder_path
		return
	_open_folder(folder_path, "文件夹")


func _format_details(row: Dictionary) -> String:
	var deleted_info := ""
	if str(row.get("storage", "")) == "deleted_archive":
		deleted_info = "\n\n[b]Deleted Record[/b]\nAction: %s\nTime: %s" % [
			row.get("deleted_action", ""),
			row.get("deleted_at_text", ""),
		]
	return (
		"[b]Title[/b]\n%s\n\n"
		+ "[b]Session ID[/b]\n%s\n\n"
		+ "[b]Model[/b]\n%s %s\n\n"
		+ "[b]Status[/b]\n%s\n\n"
		+ "[b]Token[/b]\nTotal: %.2fM\nInput: %.2fM\nCached Input: %.2fM\nUncached Input: %.2fM\nOutput: %.2fM\nReasoning Output: %.2fM\n\n"
		+ "[b]Directory[/b]\n%s\n\n"
		+ "[b]Session File[/b]\n%s%s"
	) % [
		row.get("title", ""),
		row.get("id", ""),
		row.get("model", ""),
		row.get("reasoning_effort", ""),
		_storage_label(str(row.get("storage", ""))),
		_to_million(row.get("total_tokens", 0)),
		_to_million(row.get("input_tokens", 0)),
		_to_million(row.get("cached_input_tokens", 0)),
		_to_million(row.get("uncached_input_tokens", 0)),
		_to_million(row.get("output_tokens", 0)),
		_to_million(row.get("reasoning_output_tokens", 0)),
		row.get("cwd", ""),
		row.get("session_file", ""),
		deleted_info,
	]


func _confirm_delete_selected() -> void:
	if selected_row_key == "":
		log_label.text = "请先选择一个会话。"
		return
	var row := _find_session_by_key(selected_row_key)
	if row.is_empty():
		log_label.text = "没有找到选中会话。"
		return
	if row.get("storage", "") == "deleted_archive":
		log_label.text = "删除存档是只读记录，不能作为会话删除。"
		return
	pending_action = "delete"
	pending_keys = [str(row.get("row_key", ""))]
	confirm_dialog.title = "删除会话"
	confirm_dialog.dialog_text = "会删除这个会话在当前、归档、备份中的所有副本。删除前会先把 token 元信息保存到 Godot 删除存档。\n\n%s" % row.get("title", "")
	confirm_dialog.popup_centered(Vector2i(560, 220))


func _confirm_delete_archived() -> void:
	pending_action = "delete_archived"
	pending_keys = []
	confirm_dialog.title = "删除全部归档"
	confirm_dialog.dialog_text = "会删除 archived_sessions 下的全部会话，并先把 token 元信息保存到 Godot 删除存档。如果 Codex 正在写入，最近文件可能删除失败。"
	confirm_dialog.popup_centered(Vector2i(560, 220))


func _confirm_delete_backups() -> void:
	pending_action = "delete_backups"
	pending_keys = []
	confirm_dialog.title = "删除全部备份"
	confirm_dialog.dialog_text = "会删除 .codex/deleted_sessions_backup 下的全部文件，并先把新的 token 元信息保存到 Godot 删除存档。"
	confirm_dialog.popup_centered(Vector2i(560, 220))


func _run_pending_action() -> void:
	if pending_action == "delete":
		log_label.text = "正在删除选中会话..."
		_archive_rows_before_delete(_rows_matching_keys_signature(pending_keys), "delete_selected")
		var args: Array[String] = ["delete", "--keys"]
		args.append_array(pending_keys)
		var result := _run_backend(args)
		_handle_delete_result(result)
	elif pending_action == "delete_archived":
		log_label.text = "正在删除全部归档..."
		_archive_rows_before_delete(_rows_by_storage("archived"), "delete_archived")
		var result := _run_backend(["delete-archived"])
		_handle_delete_result(result)
	elif pending_action == "delete_backups":
		log_label.text = "正在删除全部备份..."
		_archive_rows_before_delete(_rows_by_storage("backup"), "delete_backups")
		var result := _run_backend(["delete-backups"])
		_handle_delete_result(result)
	pending_action = ""
	pending_keys = []


func _handle_delete_result(result: Dictionary) -> void:
	if not result.get("success", false):
		log_label.text = "删除失败: %s" % result.get("error", "unknown error")
		return
	var data: Dictionary = result.get("result", {})
	log_label.text = "已删除 %d 个文件，移除 %d 条索引；token 元信息已保存到删除存档。" % [
		int(data.get("deleted", 0)),
		int(data.get("removed_index_rows", 0)),
	]
	_refresh_sessions()


func _save_current_display_archive() -> void:
	var payload := {
		"version": SAVE_VERSION,
		"saved_at_unix": Time.get_unix_time_from_system(),
		"saved_at_text": Time.get_datetime_string_from_system(false, true),
		"type": "当前读取数据",
		"filter": {
			"query": filter_edit.text,
			"include_archived": include_archived_check.button_pressed,
			"include_backup": include_backup_check.button_pressed,
			"include_deleted_archive": include_deleted_archive_check.button_pressed,
			"time_range_days": int(time_range_option.get_selected_id()) if time_range_option != null else 0,
		},
		"sort_rules": sort_rules,
		"summary": _build_rows_summary(sessions),
		"rows": _serializable_rows(sessions),
	}
	_write_json_file(DISPLAY_ARCHIVE_PATH, payload)


func _open_export_archive_dialog() -> void:
	_save_current_display_archive()
	var default_name := "codex_token_manager_archive_%s.json" % Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var default_dir := _archive_dialog_default_dir()
	if _show_native_file_dialog(
		"导出 Codex 存档 JSON",
		DisplayServer.FILE_DIALOG_MODE_SAVE_FILE,
		default_dir,
		default_name,
		_on_native_export_file_selected
	):
		return
	export_dialog.current_dir = default_dir
	export_dialog.current_file = default_name
	export_dialog.popup_centered(Vector2i(760, 520))


func _open_import_archive_dialog() -> void:
	var default_dir := _archive_dialog_default_dir()
	if _show_native_file_dialog(
		"导入 Codex 存档 JSON",
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
		default_dir,
		"",
		_on_native_import_file_selected
	):
		return
	import_dialog.current_dir = default_dir
	import_dialog.popup_centered(Vector2i(760, 520))


func _show_native_file_dialog(title: String, mode: DisplayServer.FileDialogMode, default_dir: String, filename: String, callback: Callable) -> bool:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		return false
	var filters := PackedStringArray(["*.json;JSON 文件;application/json"])
	var error := DisplayServer.file_dialog_show(title, default_dir, filename, false, mode, filters, callback)
	if error != OK:
		log_label.text = "无法打开系统文件选择器，已切换到内置文件窗口。"
		return false
	return true


func _archive_dialog_default_dir() -> String:
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		dir = ProjectSettings.globalize_path("user://")
	return dir


func _on_native_export_file_selected(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if not status or selected_paths.is_empty():
		return
	var path := str(selected_paths[0])
	if path.get_extension().to_lower() != "json":
		path += ".json"
	_export_archive_to_file(path)


func _on_native_import_file_selected(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if not status or selected_paths.is_empty():
		return
	_import_archive_from_file(str(selected_paths[0]))


func _export_archive_to_file(path: String) -> void:
	var payload := _build_export_archive_payload()
	if payload.is_empty():
		log_label.text = "没有可导出的存档数据。"
		return
	if _write_json_file(path, payload):
		log_label.text = "已导出存档: %s" % path


func _build_export_archive_payload() -> Dictionary:
	var current_archive := _read_json_file(DISPLAY_ARCHIVE_PATH)
	var deleted_archive := _read_json_file(DELETED_ARCHIVE_PATH)
	return {
		"archive_kind": "codex_token_manager_archive",
		"version": EXPORT_ARCHIVE_VERSION,
		"exported_at_unix": Time.get_unix_time_from_system(),
		"exported_at_text": Time.get_datetime_string_from_system(false, true),
		"current_display_archive": current_archive,
		"deleted_session_archive": deleted_archive,
	}


func _import_archive_from_file(path: String) -> void:
	var payload := _read_json_file(path)
	if payload.is_empty():
		log_label.text = "导入失败: JSON 为空或无法解析。"
		return

	var imported_current := false
	var imported_deleted := false
	if payload.get("archive_kind", "") == "codex_token_manager_archive":
		imported_current = _import_current_archive(payload.get("current_display_archive", {}))
		imported_deleted = _import_deleted_archive(payload.get("deleted_session_archive", {}))
	elif payload.has("records"):
		imported_deleted = _import_deleted_archive(payload)
	elif payload.has("rows"):
		imported_current = _import_current_archive(payload)
	else:
		log_label.text = "导入失败: 不认识的存档 JSON 格式。"
		return

	_normalize_deleted_archive()
	_load_sessions_from_current_archive()
	if sessions.is_empty():
		sessions.append_array(_deleted_archive_rows())
	else:
		sessions.append_array(_deleted_archive_rows())
	_apply_filter()
	log_label.text = "已导入存档: 当前显示=%s，删除存档=%s" % [
		"是" if imported_current else "否",
		"是" if imported_deleted else "否",
	]


func _import_current_archive(data) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not data.has("rows"):
		return false
	var archive: Dictionary = data.duplicate(true)
	if not archive.has("version"):
		archive["version"] = SAVE_VERSION
	archive["imported_at_unix"] = Time.get_unix_time_from_system()
	archive["imported_at_text"] = Time.get_datetime_string_from_system(false, true)
	return _write_json_file(DISPLAY_ARCHIVE_PATH, archive)


func _import_deleted_archive(data) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not data.has("records"):
		return false
	var imported_records = data.get("records", [])
	if typeof(imported_records) != TYPE_ARRAY:
		return false

	var archive := _read_json_file(DELETED_ARCHIVE_PATH)
	if archive.is_empty():
		archive = {
			"version": SAVE_VERSION,
			"created_at_unix": Time.get_unix_time_from_system(),
			"records": [],
		}
	if not archive.has("records") or typeof(archive.get("records")) != TYPE_ARRAY:
		archive["records"] = []

	var records: Array = archive["records"]
	var known_signatures := _deleted_archive_signatures(records)
	var imported_count := 0
	for record in imported_records:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var rows = record.get("rows", [])
		if typeof(rows) != TYPE_ARRAY:
			continue
		var unique_rows := _unique_rows_for_deleted_archive(rows, known_signatures)
		if unique_rows.is_empty():
			continue
		var imported_record: Dictionary = record.duplicate(true)
		imported_record["rows"] = _serializable_rows(unique_rows)
		imported_record["summary"] = _build_rows_summary(unique_rows)
		imported_record["imported_at_unix"] = Time.get_unix_time_from_system()
		imported_record["imported_at_text"] = Time.get_datetime_string_from_system(false, true)
		records.append(imported_record)
		imported_count += unique_rows.size()

	archive["updated_at_unix"] = Time.get_unix_time_from_system()
	archive["updated_at_text"] = Time.get_datetime_string_from_system(false, true)
	archive["last_imported_rows"] = imported_count
	return _write_json_file(DELETED_ARCHIVE_PATH, archive)


func _load_sessions_from_current_archive() -> void:
	var archive := _read_json_file(DISPLAY_ARCHIVE_PATH)
	var rows = archive.get("rows", [])
	if typeof(rows) != TYPE_ARRAY:
		sessions = []
		return
	sessions = []
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		if str(row.get("storage", "")) == "deleted_archive":
			continue
		sessions.append(row)


func _archive_rows_before_delete(rows: Array, action: String) -> void:
	if rows.is_empty():
		return
	var archive := _read_json_file(DELETED_ARCHIVE_PATH)
	if archive.is_empty():
		archive = {
			"version": SAVE_VERSION,
			"created_at_unix": Time.get_unix_time_from_system(),
			"records": [],
		}
	if not archive.has("records") or typeof(archive.get("records")) != TYPE_ARRAY:
		archive["records"] = []
	var records: Array = archive["records"]
	var known_signatures := _deleted_archive_signatures(records)
	var unique_rows := _unique_rows_for_deleted_archive(rows, known_signatures)
	if unique_rows.is_empty():
		return
	records.append({
		"deleted_at_unix": Time.get_unix_time_from_system(),
		"deleted_at_text": Time.get_datetime_string_from_system(false, true),
		"action": action,
		"skipped_duplicate_rows": rows.size() - unique_rows.size(),
		"summary": _build_rows_summary(unique_rows),
		"rows": _serializable_rows(unique_rows),
	})
	archive["updated_at_unix"] = Time.get_unix_time_from_system()
	_write_json_file(DELETED_ARCHIVE_PATH, archive)


func _deleted_archive_signatures(records: Array) -> Dictionary:
	var signatures := {}
	for record in records:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var rows = record.get("rows", [])
		if typeof(rows) != TYPE_ARRAY:
			continue
		for row in rows:
			if typeof(row) != TYPE_DICTIONARY:
				continue
			signatures[_row_archive_signature(row)] = true
	return signatures


func _unique_rows_for_deleted_archive(rows: Array, known_signatures: Dictionary) -> Array:
	var unique_rows: Array = []
	for row in rows:
		var signature := _row_archive_signature(row)
		if known_signatures.has(signature):
			continue
		known_signatures[signature] = true
		unique_rows.append(row)
	return unique_rows


func _row_archive_signature(row: Dictionary) -> String:
	return "|".join([
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
	])


func _build_rows_summary(rows: Array) -> Dictionary:
	var summary := {
		"sessions": rows.size(),
		"input_tokens": 0,
		"cached_input_tokens": 0,
		"uncached_input_tokens": 0,
		"output_tokens": 0,
		"reasoning_output_tokens": 0,
		"total_tokens": 0,
	}
	for row in rows:
		summary["input_tokens"] += int(row.get("input_tokens", 0))
		summary["cached_input_tokens"] += int(row.get("cached_input_tokens", 0))
		summary["uncached_input_tokens"] += int(row.get("uncached_input_tokens", 0))
		summary["output_tokens"] += int(row.get("output_tokens", 0))
		summary["reasoning_output_tokens"] += int(row.get("reasoning_output_tokens", 0))
		summary["total_tokens"] += int(row.get("total_tokens", 0))
	return summary


func _serializable_rows(rows: Array) -> Array:
	var result: Array = []
	for row in rows:
		result.append({
			"row_key": str(row.get("row_key", "")),
			"id": str(row.get("id", "")),
			"timestamp": str(row.get("timestamp", "")),
			"model": str(row.get("model", "")),
			"reasoning_effort": str(row.get("reasoning_effort", "")),
			"cwd": str(row.get("cwd", "")),
			"title": str(row.get("title", "")),
			"storage": str(row.get("storage", "")),
			"storage_label": _storage_label(str(row.get("storage", ""))),
			"deleted_action": str(row.get("deleted_action", "")),
			"deleted_at_text": str(row.get("deleted_at_text", "")),
			"deleted_at_unix": int(row.get("deleted_at_unix", 0)),
			"input_tokens": int(row.get("input_tokens", 0)),
			"cached_input_tokens": int(row.get("cached_input_tokens", 0)),
			"uncached_input_tokens": int(row.get("uncached_input_tokens", 0)),
			"output_tokens": int(row.get("output_tokens", 0)),
			"reasoning_output_tokens": int(row.get("reasoning_output_tokens", 0)),
			"total_tokens": int(row.get("total_tokens", 0)),
			"state_tokens_used": int(row.get("state_tokens_used", 0)),
			"session_file": str(row.get("session_file", "")),
			"updated_at": int(row.get("updated_at", 0)),
		})
	return result


func _write_json_file(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		log_label.text = "无法写入存档: %s" % ProjectSettings.globalize_path(path)
		return false
	file.store_string(JSON.stringify(data, "\t", false))
	file.close()
	return true


func _read_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func _deleted_archive_rows() -> Array:
	var archive := _read_json_file(DELETED_ARCHIVE_PATH)
	if archive.is_empty():
		return []
	var records = archive.get("records", [])
	if typeof(records) != TYPE_ARRAY:
		return []
	var rows: Array = []
	for record_index in range(records.size()):
		var record = records[record_index]
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var deleted_at_text := str(record.get("deleted_at_text", ""))
		var deleted_at_unix := int(record.get("deleted_at_unix", 0))
		var action := str(record.get("action", ""))
		var record_rows = record.get("rows", [])
		if typeof(record_rows) != TYPE_ARRAY:
			continue
		for row_index in range(record_rows.size()):
			var row = record_rows[row_index]
			if typeof(row) != TYPE_DICTIONARY:
				continue
			var item: Dictionary = row.duplicate(true)
			item["row_key"] = "deleted_archive|%d|%d|%s" % [record_index, row_index, str(row.get("id", ""))]
			item["storage"] = "deleted_archive"
			item["storage_label"] = "删除存档"
			item["deleted_action"] = action
			item["deleted_at_text"] = deleted_at_text
			item["deleted_at_unix"] = deleted_at_unix
			if str(item.get("timestamp", "")) == "" and deleted_at_text != "":
				item["timestamp"] = deleted_at_text
			rows.append(item)
	return rows


func _row_in_selected_time_range(row: Dictionary) -> bool:
	if time_range_option == null:
		return true
	var days := int(time_range_option.get_selected_id())
	if days <= 0:
		return true
	var row_time := _row_unix_time(row)
	if row_time <= 0:
		return false
	var cutoff := int(Time.get_unix_time_from_system()) - days * 86400
	return row_time >= cutoff


func _row_unix_time(row: Dictionary) -> int:
	var updated_at := int(row.get("updated_at", 0))
	if updated_at > 0:
		return updated_at
	var deleted_at := int(row.get("deleted_at_unix", 0))
	if deleted_at > 0:
		return deleted_at
	var timestamp := str(row.get("timestamp", ""))
	if timestamp == "":
		return 0
	return _parse_timestamp_to_unix(timestamp)


func _parse_timestamp_to_unix(timestamp: String) -> int:
	var text := timestamp.replace("T", " ").replace("Z", "")
	var dot_index := text.find(".")
	if dot_index != -1:
		text = text.substr(0, dot_index)
	return int(Time.get_unix_time_from_datetime_string(text))


func _normalize_deleted_archive() -> void:
	var archive := _read_json_file(DELETED_ARCHIVE_PATH)
	if archive.is_empty():
		return
	if not archive.has("records") or typeof(archive.get("records")) != TYPE_ARRAY:
		return
	var known_signatures := {}
	var normalized_records: Array = []
	var changed := false
	for record in archive["records"]:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var rows = record.get("rows", [])
		if typeof(rows) != TYPE_ARRAY:
			continue
		var unique_rows := _unique_rows_for_deleted_archive(rows, known_signatures)
		if unique_rows.size() != rows.size():
			changed = true
		if unique_rows.is_empty():
			changed = true
			continue
		var normalized_record: Dictionary = record.duplicate(true)
		normalized_record["rows"] = _serializable_rows(unique_rows)
		normalized_record["summary"] = _build_rows_summary(unique_rows)
		normalized_records.append(normalized_record)
	if not changed:
		return
	archive["records"] = normalized_records
	archive["updated_at_unix"] = Time.get_unix_time_from_system()
	archive["normalized_at_text"] = Time.get_datetime_string_from_system(false, true)
	_write_json_file(DELETED_ARCHIVE_PATH, archive)


func _open_tool_archive_folder() -> void:
	var folder := ProjectSettings.globalize_path("user://")
	var error := DirAccess.make_dir_recursive_absolute(folder)
	if error != OK and error != ERR_ALREADY_EXISTS:
		log_label.text = "无法创建工具存档目录: %s" % folder
		return
	_open_folder(folder, "工具存档目录")


func _to_native_path(path: String) -> String:
	if OS.get_name() == "Windows":
		return path.replace("/", "\\")
	return path.replace("\\", "/")


func _open_folder(folder: String, label: String) -> void:
	var normalized_folder := _to_native_path(folder)
	var executable := ""
	var args: Array[String] = [normalized_folder]
	match OS.get_name():
		"Windows":
			executable = "explorer.exe"
		"macOS":
			executable = "open"
		_:
			executable = "xdg-open"
	var exit_code := OS.execute(executable, args, [], false, false)
	if exit_code != 0:
		var shell_error := OS.shell_open(normalized_folder)
		if shell_error != OK:
			log_label.text = "无法打开%s: %s" % [label, normalized_folder]
			return
	log_label.text = "已打开%s: %s" % [label, normalized_folder]


func _rows_by_keys(keys: Array[String]) -> Array:
	var key_set := {}
	for key in keys:
		key_set[key] = true
	var rows: Array = []
	for row in sessions:
		if key_set.has(str(row.get("row_key", ""))):
			rows.append(row)
	return rows


func _rows_matching_keys_signature(keys: Array[String]) -> Array:
	var selected_rows := _rows_by_keys(keys)
	var signatures := {}
	for row in selected_rows:
		signatures[_row_archive_signature(row)] = true
	var rows: Array = []
	for row in sessions:
		if signatures.has(_row_archive_signature(row)):
			rows.append(row)
	return rows


func _rows_by_storage(storage: String) -> Array:
	var rows: Array = []
	for row in sessions:
		if str(row.get("storage", "")) == storage:
			rows.append(row)
	return rows


func _run_backend(args: Array[String]) -> Dictionary:
	var script_path := _prepare_backend_script()
	if script_path == "":
		return {"success": false, "error": "无法准备 Python 后端脚本。"}
	var output_path := ProjectSettings.globalize_path("user://backend_result.json")
	var full_args: Array[String] = [script_path, "--output-json", output_path]
	if current_codex_dir != "":
		full_args.append_array(["--codex-dir", current_codex_dir])
	full_args.append_array(args)
	var old_encoding := OS.get_environment("PYTHONIOENCODING")
	OS.set_environment("PYTHONIOENCODING", "utf-8")
	var python_result := _execute_python_backend(full_args)
	if old_encoding == "":
		OS.unset_environment("PYTHONIOENCODING")
	else:
		OS.set_environment("PYTHONIOENCODING", old_encoding)
	var exit_code := int(python_result.get("exit_code", -1))
	var text := str(python_result.get("output", ""))
	if exit_code != 0:
		return {"success": false, "error": text}
	if not FileAccess.file_exists(output_path):
		return {"success": false, "error": "后端没有生成结果文件: %s" % output_path}
	var file := FileAccess.open(output_path, FileAccess.READ)
	if file == null:
		return {"success": false, "error": "无法读取结果文件: %s" % output_path}
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"success": false, "error": "后端返回的 JSON 无法解析。"}
	return parsed


func _execute_python_backend(args: Array[String]) -> Dictionary:
	var errors: Array[String] = []
	for executable in _python_executable_candidates():
		if executable.is_absolute_path() and not FileAccess.file_exists(executable):
			continue
		var output: Array = []
		var exit_code := OS.execute(executable, args, output, true, false)
		var text := "\n".join(output)
		if exit_code == -1:
			if text != "":
				errors.append("%s: %s" % [executable, text])
			continue
		return {
			"exit_code": exit_code,
			"output": text,
			"executable": executable,
		}
	return {
		"exit_code": -1,
		"output": "找不到 Python 解释器。请安装 Python 3，或确认 python/python3 在 PATH 中。%s" % ("\n" + "\n".join(errors) if not errors.is_empty() else ""),
	}


func _python_executable_candidates() -> Array[String]:
	var candidates: Array[String] = []
	match OS.get_name():
		"Windows":
			candidates.append_array(["python", "python3"])
		"macOS":
			candidates.append_array([
				"python3",
				"python",
				"/opt/homebrew/bin/python3",
				"/usr/local/bin/python3",
				"/usr/bin/python3",
			])
		_:
			candidates.append_array(["python3", "python", "/usr/bin/python3", "/usr/local/bin/python3"])
	var unique: Array[String] = []
	for candidate in candidates:
		if not unique.has(candidate):
			unique.append(candidate)
	return unique


func _prepare_backend_script() -> String:
	var source := FileAccess.open(BACKEND_PATH, FileAccess.READ)
	if source == null:
		log_label.text = "无法读取后端脚本: %s" % BACKEND_PATH
		return ""
	var script_text := source.get_as_text()
	source.close()

	var backend_dir := ProjectSettings.globalize_path("user://backend")
	var dir_error := DirAccess.make_dir_recursive_absolute(backend_dir)
	if dir_error != OK and dir_error != ERR_ALREADY_EXISTS:
		log_label.text = "无法创建后端目录: %s" % backend_dir
		return ""

	var runtime_path := "user://backend/codex_usage_backend.py"
	var target := FileAccess.open(runtime_path, FileAccess.WRITE)
	if target == null:
		log_label.text = "无法写入后端脚本: %s" % ProjectSettings.globalize_path(runtime_path)
		return ""
	target.store_string(script_text)
	target.close()
	return ProjectSettings.globalize_path(runtime_path)


func _load_settings() -> void:
	var settings := _read_json_file(SETTINGS_PATH)
	current_codex_dir = str(settings.get("codex_dir", ""))


func _save_settings() -> void:
	var payload := {
		"version": SAVE_VERSION,
		"updated_at_unix": Time.get_unix_time_from_system(),
		"updated_at_text": Time.get_datetime_string_from_system(false, true),
		"codex_dir": current_codex_dir,
	}
	_write_json_file(SETTINGS_PATH, payload)


func _find_session_by_key(row_key: String) -> Dictionary:
	for row in sessions:
		if str(row.get("row_key", "")) == row_key:
			return row
	return {}


func _to_million(value) -> float:
	return float(value) / 1000000.0


func _shorten_path(path: String) -> String:
	if path.length() <= 44:
		return path
	return "..." + path.substr(path.length() - 41, 41)


func _storage_label(storage: String) -> String:
	match storage:
		"active":
			return "当前"
		"archived":
			return "归档"
		"backup":
			return "备份"
		"deleted_archive":
			return "删除存档"
		_:
			return storage
