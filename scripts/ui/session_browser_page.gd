class_name SessionBrowserPage
extends VBoxContainer


signal filter_changed
signal session_selected(row_key: String)
signal column_title_clicked(column: int, mouse_button_index: int)
signal open_folder_requested
signal copy_project_requested
signal copy_resume_requested

const CODEX_IDE_CONTEXT_PREFIX := "# Context from my IDE setup:"
const CODEX_REQUEST_MARKER := "my request for codex"
const MESSAGE_CARD_SCENE := preload("res://scenes/components/message_card.tscn")

@onready var summary_label: Label = %SummaryLabel
@onready var filter_edit: LineEdit = %FilterEdit
@onready var include_archived_check: CheckBox = %IncludeArchivedCheck
@onready var include_backup_check: CheckBox = %IncludeBackupCheck
@onready var include_deleted_archive_check: CheckBox = %IncludeDeletedArchiveCheck
@onready var time_range_picker = %TimeRangePicker
@onready var session_tree: Tree = %SessionTree
@onready var detail_header_label: RichTextLabel = %DetailHeaderLabel
@onready var details_label: RichTextLabel = %DetailsLabel
@onready var message_scroll: ScrollContainer = %MessageScroll
@onready var message_list: VBoxContainer = %MessageList
@onready var toc_tree: Tree = %TocTree
@onready var open_folder_button: Button = %OpenFolderButton
@onready var copy_project_button: Button = %CopyProjectButton
@onready var copy_resume_button: Button = %CopyResumeButton

var message_nodes: Array[Control] = []
var column_titles: Array = []


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)

	summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	filter_edit.placeholder_text = "输入模型、目录、标题、文件路径或会话 ID"
	filter_edit.text_changed.connect(func(_text: String) -> void: filter_changed.emit())
	include_archived_check.button_pressed = true
	include_archived_check.toggled.connect(func(_pressed: bool) -> void: filter_changed.emit())
	include_backup_check.button_pressed = true
	include_backup_check.toggled.connect(func(_pressed: bool) -> void: filter_changed.emit())
	include_deleted_archive_check.button_pressed = false
	include_deleted_archive_check.toggled.connect(func(_pressed: bool) -> void: filter_changed.emit())

	time_range_picker.set_show_all_preset(true)
	time_range_picker.set_selection_preset("all")
	time_range_picker.selection_changed.connect(func() -> void: filter_changed.emit())

	session_tree.hide_root = true
	session_tree.select_mode = Tree.SELECT_SINGLE
	session_tree.item_selected.connect(_emit_selected_session)
	session_tree.column_title_clicked.connect(func(column: int, mouse_button_index: int) -> void:
		column_title_clicked.emit(column, mouse_button_index)
	)

	detail_header_label.bbcode_enabled = true
	detail_header_label.fit_content = true
	detail_header_label.scroll_active = false
	detail_header_label.selection_enabled = true
	details_label.bbcode_enabled = true
	details_label.scroll_active = true
	details_label.selection_enabled = true
	details_label.visible = false
	message_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	toc_tree.columns = 1
	toc_tree.hide_root = true
	toc_tree.item_selected.connect(_on_toc_selected)

	open_folder_button.disabled = true
	copy_project_button.disabled = true
	copy_resume_button.disabled = true
	open_folder_button.pressed.connect(func() -> void: open_folder_requested.emit())
	copy_project_button.pressed.connect(func() -> void: copy_project_requested.emit())
	copy_resume_button.pressed.connect(func() -> void: copy_resume_requested.emit())


func configure_columns(titles: Array, widths: Array) -> void:
	column_titles = titles.duplicate()
	session_tree.columns = titles.size()
	session_tree.set_column_titles_visible(true)
	for i in range(titles.size()):
		session_tree.set_column_title(i, str(titles[i]))
		if i < widths.size():
			session_tree.set_column_custom_minimum_width(i, int(widths[i]))


func update_column_titles(sort_rules: Array) -> void:
	if session_tree == null:
		return
	for i in range(column_titles.size()):
		var suffix := ""
		for rule_index in range(sort_rules.size()):
			var rule: Dictionary = sort_rules[rule_index]
			if int(rule.get("column", -1)) != i:
				continue
			var ascending := bool(rule.get("ascending", true))
			suffix = " %s%d" % ["^" if ascending else "v", rule_index + 1]
			break
		session_tree.set_column_title(i, "%s%s" % [column_titles[i], suffix])


func filter_query() -> String:
	return filter_edit.text.strip_edges().to_lower()


func filter_text() -> String:
	return filter_edit.text


func include_archived() -> bool:
	return include_archived_check.button_pressed


func include_backup() -> bool:
	return include_backup_check.button_pressed


func include_deleted_archive() -> bool:
	return include_deleted_archive_check.button_pressed


func selected_time_range_bounds() -> Dictionary:
	return time_range_picker.resolve_selection()


func render_summary(summary: Dictionary) -> void:
	summary_label.text = (
		"行数 %d | 总 %s | 输入 %s | 缓存 %s | 非缓存 %s | 输出 %s | 推理 %s"
		% [
			int(summary.get("sessions", 0)),
			_format_tokens_short(int(summary.get("total_tokens", 0)), 2),
			_format_tokens_short(int(summary.get("input_tokens", 0)), 2),
			_format_tokens_short(int(summary.get("cached_input_tokens", 0)), 2),
			_format_tokens_short(int(summary.get("uncached_input_tokens", 0)), 2),
			_format_tokens_short(int(summary.get("output_tokens", 0)), 2),
			_format_tokens_short(int(summary.get("reasoning_output_tokens", 0)), 2),
		]
	)


func render_tree(rows: Array, max_visible_rows: int) -> void:
	session_tree.clear()
	var root := session_tree.create_item()
	var count := mini(rows.size(), max_visible_rows)
	var project_order: Array[String] = []
	var project_groups := {}
	for i in range(count):
		var row: Dictionary = rows[i]
		var project_key := _project_group_key(row)
		if not project_groups.has(project_key):
			project_groups[project_key] = []
			project_order.append(project_key)
		project_groups[project_key].append(row)
	for project_key in project_order:
		var group_rows: Array = project_groups[project_key]
		var group_item := session_tree.create_item(root)
		group_item.set_metadata(0, "project|%s" % project_key)
		group_item.set_text(0, _project_group_label(project_key))
		group_item.set_text(1, _format_tokens_short(_sum_group_value(group_rows, "total_tokens"), 1))
		group_item.set_text(2, "%d" % _sum_group_value(group_rows, "message_count"))
		group_item.set_text(3, "%d 项" % group_rows.size())
		group_item.set_text(4, "")
		group_item.collapsed = false
		for column in range(column_titles.size()):
			group_item.set_selectable(column, false)
			group_item.set_custom_color(column, Color(0.62, 0.68, 0.76))
		for row in group_rows:
			var item := session_tree.create_item(group_item)
			item.set_metadata(0, row.get("row_key", ""))
			item.set_text(0, _session_title(row))
			item.set_text(1, _format_tokens_short(int(row.get("total_tokens", 0)), 1))
			item.set_text(2, "%d" % int(row.get("message_count", 0)))
			item.set_text(3, _storage_label(str(row.get("storage", ""))))
			item.set_text(4, _row_time_text(row))
			item.set_tooltip_text(0, "%s\n%s" % [row.get("title", ""), row.get("cwd", "")])


func reset_detail() -> void:
	set_action_buttons_enabled(false, false, false)
	set_detail_header("")
	show_detail_text("选择一个会话查看详情。")
	clear_toc()


func set_action_buttons_enabled(open_enabled: bool, copy_project_enabled: bool, copy_resume_enabled: bool) -> void:
	open_folder_button.disabled = not open_enabled
	copy_project_button.disabled = not copy_project_enabled
	copy_resume_button.disabled = not copy_resume_enabled


func set_detail_header(text: String) -> void:
	detail_header_label.text = text


func clear_toc() -> void:
	if toc_tree != null:
		toc_tree.clear()


func show_detail_text(text: String) -> void:
	_clear_message_cards()
	if message_scroll != null:
		message_scroll.visible = false
	if details_label != null:
		details_label.visible = true
		details_label.text = text


func render_conversation(messages: Array) -> void:
	_clear_message_cards()
	details_label.visible = false
	message_scroll.visible = true
	if toc_tree != null:
		toc_tree.clear()
		toc_tree.create_item()
	if messages.is_empty():
		show_detail_text("这个会话没有可显示的对话消息。")
		return

	var toc_index := 1
	var toc_root := toc_tree.get_root() if toc_tree != null else null
	for message in messages:
		if typeof(message) != TYPE_DICTIONARY:
			continue
		var role := str(message.get("role", "unknown"))
		var content := str(message.get("content", ""))
		var timestamp := str(message.get("timestamp", ""))
		if content.strip_edges() == "":
			continue
		var message_index := message_nodes.size()
		var card = MESSAGE_CARD_SCENE.instantiate()
		message_nodes.append(card)
		message_list.add_child(card)
		card.set_message(role, content, timestamp)
		if role.to_lower() == "user" and not _should_hide_codex_message_from_toc(content):
			var preview := _format_toc_preview(_extract_codex_prompt_preview(content))
			var toc_item := toc_tree.create_item(toc_root)
			toc_item.set_text(0, "%d  %s" % [toc_index, preview])
			toc_item.set_metadata(0, message_index)
			toc_item.set_tooltip_text(0, _single_line(_extract_codex_prompt_preview(content)))
			toc_index += 1
	call_deferred("_scroll_message_to_index", 0)


func _emit_selected_session() -> void:
	var item := session_tree.get_selected()
	if item == null:
		return
	session_selected.emit(str(item.get_metadata(0)))


func _on_toc_selected() -> void:
	if toc_tree == null:
		return
	var item := toc_tree.get_selected()
	if item == null:
		return
	_scroll_message_to_index(int(item.get_metadata(0)))


func _scroll_message_to_index(index: int) -> void:
	if message_scroll == null or message_nodes.is_empty():
		return
	if index < 0 or index >= message_nodes.size():
		return
	var target := message_nodes[index]
	if target == null:
		return
	message_scroll.ensure_control_visible(target)


func _clear_message_cards() -> void:
	message_nodes.clear()
	if message_list == null:
		return
	for child in message_list.get_children():
		message_list.remove_child(child)
		child.queue_free()


func _should_hide_codex_message_from_toc(content: String) -> bool:
	var trimmed := content.strip_edges()
	return (
		trimmed.begins_with("# AGENTS.md instructions for ")
		or trimmed.begins_with("<environment_context>")
		or (trimmed.begins_with(CODEX_IDE_CONTEXT_PREFIX) and _extract_codex_prompt_from_ide_context(trimmed) == "")
	)


func _extract_codex_prompt_preview(content: String) -> String:
	var prompt := _extract_codex_prompt_from_ide_context(content)
	return prompt if prompt != "" else content


func _extract_codex_prompt_from_ide_context(content: String) -> String:
	var trimmed := content.strip_edges()
	if not trimmed.begins_with(CODEX_IDE_CONTEXT_PREFIX):
		return ""
	var lines := trimmed.replace("\r\n", "\n").split("\n")
	var prompt := ""
	for index in range(lines.size()):
		var inline_prompt = _codex_request_heading_payload(str(lines[index]))
		if inline_prompt == null:
			continue
		if str(inline_prompt) != "":
			prompt = str(inline_prompt)
			continue
		var following: Array[String] = []
		for next_index in range(index + 1, lines.size()):
			following.append(str(lines[next_index]))
		prompt = "\n".join(following).strip_edges()
	return prompt


func _codex_request_heading_payload(line: String):
	var heading := line.strip_edges()
	if not heading.begins_with("#"):
		return null
	while heading.begins_with("#"):
		heading = heading.substr(1)
	heading = heading.strip_edges()
	if not heading.to_lower().begins_with(CODEX_REQUEST_MARKER):
		return null
	var suffix := heading.substr(CODEX_REQUEST_MARKER.length()).strip_edges()
	if suffix == "":
		return ""
	var first := suffix.substr(0, 1)
	if not [":", "：", "-", "—"].has(first):
		return null
	while suffix.length() > 0 and ([":", "：", "-", "—", " ", "\t"].has(suffix.substr(0, 1))):
		suffix = suffix.substr(1)
	return suffix.strip_edges()


func _format_toc_preview(content: String) -> String:
	var text := _single_line(content)
	if text.length() > 50:
		return text.substr(0, 50) + "..."
	return text


func _single_line(content: String) -> String:
	var text := content.replace("\r", " ").replace("\n", " ").replace("\t", " ").strip_edges()
	while text.contains("  "):
		text = text.replace("  ", " ")
	return text


func _project_group_key(row: Dictionary) -> String:
	var cwd := str(row.get("cwd", "")).strip_edges()
	return cwd if cwd != "" else "未知目录"


func _project_group_label(project_key: String) -> String:
	if project_key == "未知目录":
		return "项目: 未知目录"
	var base := _path_basename(project_key)
	return "项目: %s" % (base if base != "" else project_key)


func _path_basename(path: String) -> String:
	var normalized := path.strip_edges().trim_suffix("/").trim_suffix("\\")
	if normalized == "":
		return ""
	var parts := normalized.replace("\\", "/").split("/", false)
	if parts.is_empty():
		return normalized
	return str(parts[parts.size() - 1])


func _sum_group_value(rows: Array, key: String) -> int:
	var total := 0
	for row in rows:
		if typeof(row) == TYPE_DICTIONARY:
			total += int(row.get(key, 0))
	return total


func _session_title(row: Dictionary) -> String:
	var title := str(row.get("title", "")).strip_edges()
	if title != "":
		return title
	var cwd_base := _path_basename(str(row.get("cwd", "")))
	if cwd_base != "":
		return cwd_base
	var session_id := str(row.get("id", ""))
	return session_id.substr(0, 8) if session_id.length() > 8 else session_id


func _row_time_text(row: Dictionary) -> String:
	var unix := _row_unix_time(row)
	if unix > 0:
		return Time.get_datetime_string_from_unix_time(unix + _local_time_offset_seconds(), true)
	var timestamp := str(row.get("timestamp", ""))
	return timestamp if timestamp != "" else "未知"


func _local_time_offset_seconds() -> int:
	var zone := Time.get_time_zone_from_system()
	return int(zone.get("bias", 0)) * 60


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


func _to_million(value) -> float:
	return float(value) / 1000000.0


func _format_tokens_short(value: int, decimals: int = 1) -> String:
	if value >= 1000000000000:
		var trillion_format := "%." + str(decimals) + "f 万亿"
		return trillion_format % (float(value) / 1000000000000.0)
	if value >= 100000000:
		var hundred_million_format := "%." + str(decimals) + "f 亿"
		return hundred_million_format % (float(value) / 100000000.0)
	if value >= 10000:
		var ten_thousand_format := "%." + str(decimals) + "f 万"
		return ten_thousand_format % (float(value) / 10000.0)
	return _format_int_with_commas(value)


func _format_int_with_commas(value: int) -> String:
	var text := str(abs(value))
	var result := ""
	var count := 0
	for i in range(text.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = "," + result
		result = text.substr(i, 1) + result
		count += 1
	return ("-" if value < 0 else "") + result
