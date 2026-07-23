extends Control


const BACKEND_PATH := "res://tools/codex_usage_backend.py"
const MAX_VISIBLE_ROWS := 500
const DISPLAY_ARCHIVE_PATH := "user://codex_current_display_archive.json"
const DELETED_ARCHIVE_PATH := "user://codex_deleted_session_archive.json"
const SETTINGS_PATH := "user://codex_tool_settings.json"
const USAGE_PRICING_PATH := "user://codex_usage_pricing.json"
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
	{"column": 4, "ascending": false},
]

var column_titles := [
	"项目 / 会话",
	"总",
	"消息",
	"状态",
	"时间",
]

var main_tabs: TabContainer
var session_page
var usage_page
var log_label: Label
var confirm_dialog: ConfirmationDialog
var export_dialog: FileDialog
var import_dialog: FileDialog
var usage_pricing_dialog
var usage_events: Array = []
var usage_events_dirty := true
var usage_pricing: Dictionary = {}
var usage_pricing_edit_original_id := ""


func _ready() -> void:
	_bind_ui()
	_load_usage_pricing()
	_load_settings()
	_normalize_deleted_archive()
	_refresh_sessions()


func _bind_ui() -> void:
	main_tabs = $RootMargin/MainStack/MainTabs
	session_page = get_node("RootMargin/MainStack/MainTabs/会话记录")
	usage_page = get_node("RootMargin/MainStack/MainTabs/使用统计")
	log_label = $RootMargin/MainStack/LogLabel
	confirm_dialog = $ConfirmDialog
	export_dialog = $ExportDialog
	import_dialog = $ImportDialog
	usage_pricing_dialog = $UsagePricingDialog

	$RootMargin/MainStack/TitleRow/RefreshButton.pressed.connect(_refresh_sessions)
	$RootMargin/MainStack/TitleRow/DeleteSelectedButton.pressed.connect(_confirm_delete_selected)
	$RootMargin/MainStack/TitleRow/DeleteArchivedButton.pressed.connect(_confirm_delete_archived)
	$RootMargin/MainStack/TitleRow/DeleteBackupsButton.pressed.connect(_confirm_delete_backups)
	$RootMargin/MainStack/TitleRow/OpenArchiveButton.pressed.connect(_open_tool_archive_folder)
	$RootMargin/MainStack/TitleRow/ExportArchiveButton.pressed.connect(_open_export_archive_dialog)
	$RootMargin/MainStack/TitleRow/ImportArchiveButton.pressed.connect(_open_import_archive_dialog)

	main_tabs.tab_changed.connect(_on_main_tab_changed)
	session_page.configure_columns(column_titles, [280, 70, 60, 76, 148])
	session_page.update_column_titles(sort_rules)
	session_page.filter_changed.connect(_apply_filter)
	session_page.session_selected.connect(_on_session_selected)
	session_page.column_title_clicked.connect(_on_column_title_clicked)
	session_page.open_folder_requested.connect(_open_selected_session_folder)
	session_page.copy_project_requested.connect(_copy_selected_project_dir)
	session_page.copy_resume_requested.connect(_copy_selected_resume_command)

	usage_page.refresh_requested.connect(func() -> void:
		usage_events_dirty = true
		_refresh_usage_stats()
	)
	usage_page.filter_changed.connect(func() -> void: _refresh_usage_stats(false))
	usage_page.add_pricing_requested.connect(func() -> void: _open_usage_pricing_dialog(""))
	usage_page.edit_pricing_requested.connect(_edit_selected_usage_pricing)
	usage_page.delete_pricing_requested.connect(_delete_selected_usage_pricing)
	usage_page.reset_pricing_requested.connect(_reset_usage_pricing)

	confirm_dialog.confirmed.connect(_run_pending_action)
	export_dialog.file_selected.connect(_export_archive_to_file)
	import_dialog.file_selected.connect(_import_archive_from_file)
	usage_pricing_dialog.confirmed.connect(_save_usage_pricing_dialog)


func _on_main_tab_changed(tab: int) -> void:
	if main_tabs == null:
		return
	if main_tabs.get_tab_title(tab) == "使用统计":
		_refresh_usage_stats()


func _refresh_usage_stats(load_events: bool = true) -> void:
	if usage_page == null:
		return
	if load_events and usage_events_dirty:
		_load_usage_events()
	_populate_usage_filter_options()
	var filtered := _usage_filtered_events()
	_ensure_usage_pricing_for_models(usage_events)
	var summary := _build_usage_summary(filtered)
	_render_usage_summary(summary)
	usage_page.set_trend_points(_build_usage_trend_points(filtered))
	_render_usage_pricing_tree(filtered)


func _load_usage_events() -> void:
	var result := _run_backend(["usage-events"])
	if not result.get("success", false):
		if log_label != null:
			log_label.text = "读取使用统计失败: %s" % str(result.get("error", "unknown error"))
		usage_events = []
		usage_events_dirty = false
		return
	var events = result.get("events", [])
	usage_events = events if typeof(events) == TYPE_ARRAY else []
	usage_events_dirty = false
	if log_label != null:
		log_label.text = "已读取使用统计事件: %d 条。" % usage_events.size()


func _populate_usage_filter_options() -> void:
	var source_set := {}
	var model_set := {}
	for event in usage_events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		source_set[str(event.get("source", "Codex"))] = true
		model_set[str(event.get("model", "unknown"))] = true
	usage_page.populate_filter_options(source_set.keys(), model_set.keys())


func _usage_filtered_events() -> Array:
	var source_filter: String = usage_page.selected_source()
	var model_filter: String = usage_page.selected_model()
	var bounds := _usage_range_bounds()
	var start_unix := int(bounds.get("start", 0))
	var end_unix := int(bounds.get("end", 0))
	var filtered: Array = []
	for event in usage_events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		var unix := int(event.get("unix", 0))
		if start_unix > 0 and unix < start_unix:
			continue
		if end_unix > 0 and unix > end_unix:
			continue
		if source_filter != "all" and str(event.get("source", "")) != source_filter:
			continue
		if model_filter != "all" and str(event.get("model", "")) != model_filter:
			continue
		filtered.append(event)
	return filtered


func _usage_range_bounds() -> Dictionary:
	return usage_page.selected_range_bounds()


func _start_of_today_unix() -> int:
	return _start_of_local_day(int(Time.get_unix_time_from_system()))


func _start_of_local_day(unix_time: int) -> int:
	return _local_bucket_start(unix_time, 86400)


func _local_bucket_start(unix_time: int, step: int) -> int:
	var offset := _local_time_offset_seconds()
	var local_unix := unix_time + offset
	return int(floor(float(local_unix) / float(step))) * step - offset


func _local_time_offset_seconds() -> int:
	var zone := Time.get_time_zone_from_system()
	return int(zone.get("bias", 0)) * 60


func _build_usage_summary(events: Array) -> Dictionary:
	var summary := {
		"requests": 0,
		"fresh_input_tokens": 0,
		"output_tokens": 0,
		"cached_input_tokens": 0,
		"cache_creation_tokens": 0,
		"real_total_tokens": 0,
		"cost": 0.0,
		"cache_hit_rate": 0.0,
	}
	for event in events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		_accumulate_usage(summary, event)
	var cacheable := int(summary["fresh_input_tokens"]) + int(summary["cache_creation_tokens"]) + int(summary["cached_input_tokens"])
	if cacheable > 0:
		summary["cache_hit_rate"] = float(summary["cached_input_tokens"]) / float(cacheable)
	return summary


func _accumulate_usage(summary: Dictionary, event: Dictionary) -> void:
	var input_tokens := int(event.get("input_tokens", 0))
	var cache_read := int(event.get("cached_input_tokens", 0))
	var cache_creation := int(event.get("cache_creation_tokens", 0))
	var fresh_input = maxi(input_tokens - cache_read - cache_creation, 0)
	var output_tokens := int(event.get("output_tokens", 0))
	summary["requests"] = int(summary["requests"]) + 1
	summary["fresh_input_tokens"] = int(summary["fresh_input_tokens"]) + fresh_input
	summary["output_tokens"] = int(summary["output_tokens"]) + output_tokens
	summary["cached_input_tokens"] = int(summary["cached_input_tokens"]) + cache_read
	summary["cache_creation_tokens"] = int(summary["cache_creation_tokens"]) + cache_creation
	summary["real_total_tokens"] = int(summary["real_total_tokens"]) + fresh_input + output_tokens + cache_read + cache_creation
	summary["cost"] = float(summary["cost"]) + _usage_cost_for_event(event)


func _usage_cost_for_event(event: Dictionary) -> float:
	var pricing := _find_usage_pricing(str(event.get("model", "")))
	var input_tokens := int(event.get("input_tokens", 0))
	var cache_read := int(event.get("cached_input_tokens", 0))
	var cache_creation := int(event.get("cache_creation_tokens", 0))
	var fresh_input = maxi(input_tokens - cache_read - cache_creation, 0)
	var output_tokens := int(event.get("output_tokens", 0))
	return (
		float(fresh_input) * float(pricing.get("input", 0.0))
		+ float(output_tokens) * float(pricing.get("output", 0.0))
		+ float(cache_read) * float(pricing.get("cache_read", 0.0))
		+ float(cache_creation) * float(pricing.get("cache_creation", 0.0))
	) / 1000000.0


func _render_usage_summary(summary: Dictionary) -> void:
	var real_total := int(summary.get("real_total_tokens", 0))
	var cache_creation := int(summary.get("cache_creation_tokens", 0))
	var hit_percent := clampf(float(summary.get("cache_hit_rate", 0.0)) * 100.0, 0.0, 100.0)
	usage_page.set_summary_values(
		_format_int_with_commas(real_total),
		"≈ %s" % _format_usage_tokens_short(real_total, 2),
		_format_int_with_commas(int(summary.get("requests", 0))),
		_format_usd(float(summary.get("cost", 0.0)), 4),
		_format_usage_tokens_short(int(summary.get("fresh_input_tokens", 0))),
		_format_usage_tokens_short(int(summary.get("output_tokens", 0))),
		"N/A" if cache_creation <= 0 else _format_usage_tokens_short(cache_creation),
		_format_usage_tokens_short(int(summary.get("cached_input_tokens", 0))),
		_format_percent(hit_percent),
		hit_percent
	)


func _build_usage_trend_points(events: Array) -> Array:
	if events.is_empty():
		return []
	var bounds := _usage_range_bounds()
	var start_unix := int(bounds.get("start", 0))
	var end_unix := int(bounds.get("end", int(Time.get_unix_time_from_system())))
	if start_unix <= 0:
		start_unix = int(events[0].get("unix", end_unix))
	var duration := maxi(end_unix - start_unix, 0)
	var hourly := duration <= 86400
	var step := 3600 if hourly else 86400
	var first_bucket := _local_bucket_start(start_unix, step)
	var last_bucket := _local_bucket_start(end_unix, step)
	var buckets := {}
	var bucket_order: Array[int] = []
	var bucket := first_bucket
	while bucket <= last_bucket:
		buckets[bucket] = _empty_usage_bucket()
		bucket_order.append(bucket)
		bucket += step
	for event in events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		var unix := int(event.get("unix", 0))
		var key := _local_bucket_start(unix, step)
		if not buckets.has(key):
			buckets[key] = _empty_usage_bucket()
			bucket_order.append(key)
		var summary: Dictionary = buckets[key]
		_accumulate_usage(summary, event)
	bucket_order.sort()
	var points: Array = []
	for key in bucket_order:
		var summary: Dictionary = buckets[key]
		points.append({
			"label": _format_usage_bucket_label(key, hourly),
			"input_tokens": int(summary.get("fresh_input_tokens", 0)),
			"output_tokens": int(summary.get("output_tokens", 0)),
			"cached_input_tokens": int(summary.get("cached_input_tokens", 0)),
			"cache_creation_tokens": int(summary.get("cache_creation_tokens", 0)),
			"cost": float(summary.get("cost", 0.0)),
		})
	return points


func _empty_usage_bucket() -> Dictionary:
	return {
		"requests": 0,
		"fresh_input_tokens": 0,
		"output_tokens": 0,
		"cached_input_tokens": 0,
		"cache_creation_tokens": 0,
		"real_total_tokens": 0,
		"cost": 0.0,
	}


func _format_usage_bucket_label(unix_time: int, hourly: bool) -> String:
	var dict := Time.get_datetime_dict_from_unix_time(unix_time + _local_time_offset_seconds())
	if hourly:
		return "%02d/%02d %02d:00" % [int(dict.get("month", 0)), int(dict.get("day", 0)), int(dict.get("hour", 0))]
	return "%02d/%02d" % [int(dict.get("month", 0)), int(dict.get("day", 0))]


func _render_usage_pricing_tree(events: Array) -> void:
	if usage_page == null:
		return
	var model_usage := _build_model_usage(events)
	var keys: Array[String] = []
	for key in usage_pricing.keys():
		keys.append(str(key))
	for model_key in model_usage.keys():
		var model := str(model_key)
		if not keys.has(model):
			keys.append(model)
	keys.sort_custom(func(a: String, b: String) -> bool:
		var ar := int(model_usage.get(a, {}).get("requests", 0))
		var br := int(model_usage.get(b, {}).get("requests", 0))
		if ar != br:
			return ar > br
		return a < b
	)
	var rows: Array[Dictionary] = []
	for model in keys:
		var pricing: Dictionary = usage_pricing.get(model, _zero_pricing(model))
		var usage: Dictionary = model_usage.get(model, _empty_usage_bucket())
		rows.append({
			"model": model,
			"display_name": str(pricing.get("display_name", model)),
			"input": "$%s" % _format_price_number(float(pricing.get("input", 0.0))),
			"output": "$%s" % _format_price_number(float(pricing.get("output", 0.0))),
			"cache_read": "$%s" % _format_price_number(float(pricing.get("cache_read", 0.0))),
			"cache_creation": "$%s" % _format_price_number(float(pricing.get("cache_creation", 0.0))),
			"requests": _format_int_with_commas(int(usage.get("requests", 0))),
			"cost": _format_usd(float(usage.get("cost", 0.0)), 4),
		})
	usage_page.render_pricing_rows(rows)


func _build_model_usage(events: Array) -> Dictionary:
	var result := {}
	for event in events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		var pricing := _find_usage_pricing(str(event.get("model", "unknown")))
		var model := str(pricing.get("model_id", _normalize_usage_model_id(str(event.get("model", "unknown")))))
		if not result.has(model):
			result[model] = _empty_usage_bucket()
		var summary: Dictionary = result[model]
		_accumulate_usage(summary, event)
	return result


func _find_usage_pricing(model: String) -> Dictionary:
	var candidates := _usage_pricing_candidates(model)
	for candidate in candidates:
		if usage_pricing.has(candidate):
			return usage_pricing[candidate]
	var normalized := _normalize_usage_model_id(model)
	var keys: Array[String] = []
	for key in usage_pricing.keys():
		keys.append(str(key))
	keys.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	for key in keys:
		if normalized == key or normalized.begins_with("%s-" % key):
			return usage_pricing[key]
	return _zero_pricing(model)


func _usage_pricing_candidates(model: String) -> Array[String]:
	var normalized := _normalize_usage_model_id(model)
	var candidates: Array[String] = [model.strip_edges().to_lower(), normalized]
	var stripped := _strip_model_date_suffix(normalized)
	if stripped != normalized:
		candidates.append(stripped)
	if normalized.begins_with("claude-gpt-"):
		candidates.append(normalized.substr("claude-".length()))
	return candidates


func _normalize_usage_model_id(model: String) -> String:
	var text := model.strip_edges().to_lower().replace("@", "-")
	if text.contains("/"):
		var parts := text.split("/", false)
		text = str(parts[parts.size() - 1])
	if text.contains(":"):
		text = text.split(":", false)[0]
	return _strip_model_date_suffix(text)


func _strip_model_date_suffix(model: String) -> String:
	var parts := model.split("-", false)
	if parts.size() >= 3:
		var y := str(parts[parts.size() - 3])
		var m := str(parts[parts.size() - 2])
		var d := str(parts[parts.size() - 1])
		if y.length() == 4 and m.length() == 2 and d.length() == 2 and _is_digits(y + m + d):
			var kept := parts.slice(0, parts.size() - 3)
			return "-".join(kept)
	if parts.size() >= 2:
		var last := str(parts[parts.size() - 1])
		if last.length() == 8 and _is_digits(last):
			var kept_short := parts.slice(0, parts.size() - 1)
			return "-".join(kept_short)
	return model


func _is_digits(text: String) -> bool:
	if text == "":
		return false
	for i in range(text.length()):
		var code := text.unicode_at(i)
		if code < 48 or code > 57:
			return false
	return true


func _zero_pricing(model: String) -> Dictionary:
	return {
		"model_id": _normalize_usage_model_id(model),
		"display_name": model if model != "" else "Unknown",
		"input": 0.0,
		"output": 0.0,
		"cache_read": 0.0,
		"cache_creation": 0.0,
	}


func _load_usage_pricing() -> void:
	usage_pricing = _default_usage_pricing()
	var saved := _read_json_file(USAGE_PRICING_PATH)
	var rows = saved.get("models", [])
	if typeof(rows) == TYPE_ARRAY:
		for row in rows:
			if typeof(row) != TYPE_DICTIONARY:
				continue
			var model_id := _normalize_usage_model_id(str(row.get("model_id", "")))
			if model_id == "":
				continue
			usage_pricing[model_id] = {
				"model_id": model_id,
				"display_name": str(row.get("display_name", model_id)),
				"input": float(row.get("input", 0.0)),
				"output": float(row.get("output", 0.0)),
				"cache_read": float(row.get("cache_read", 0.0)),
				"cache_creation": float(row.get("cache_creation", 0.0)),
			}


func _default_usage_pricing() -> Dictionary:
	var data := {}
	_seed_usage_price(data, "gpt-5.6", "GPT-5.6 Sol", 5.0, 30.0, 0.50, 6.25)
	_seed_usage_price(data, "gpt-5.6-terra", "GPT-5.6 Terra", 2.50, 15.0, 0.25, 3.125)
	_seed_usage_price(data, "gpt-5.6-luna", "GPT-5.6 Luna", 1.0, 6.0, 0.10, 1.25)
	_seed_usage_price(data, "gpt-5.5", "GPT-5.5", 5.0, 30.0, 0.50, 0.0)
	_seed_usage_price(data, "gpt-5.4", "GPT-5.4", 2.50, 15.0, 0.25, 0.0)
	_seed_usage_price(data, "gpt-5.4-mini", "GPT-5.4 Mini", 0.75, 4.50, 0.075, 0.0)
	_seed_usage_price(data, "gpt-5.2", "GPT-5.2", 1.75, 14.0, 0.175, 0.0)
	_seed_usage_price(data, "gpt-5.3-codex", "GPT-5.3 Codex", 1.75, 14.0, 0.175, 0.0)
	_seed_usage_price(data, "gpt-5.1", "GPT-5.1", 1.25, 10.0, 0.125, 0.0)
	_seed_usage_price(data, "gpt-5", "GPT-5", 1.25, 10.0, 0.125, 0.0)
	_seed_usage_price(data, "gpt-5-codex", "GPT-5 Codex", 1.25, 10.0, 0.125, 0.0)
	_seed_usage_price(data, "gpt-5-mini", "GPT-5 Mini", 0.25, 2.0, 0.025, 0.0)
	_seed_usage_price(data, "gpt-5-nano", "GPT-5 Nano", 0.05, 0.40, 0.005, 0.0)
	_seed_usage_price(data, "gpt-4.1", "GPT-4.1", 2.0, 8.0, 0.50, 0.0)
	_seed_usage_price(data, "o3", "OpenAI o3", 2.0, 8.0, 0.50, 0.0)
	_seed_usage_price(data, "o4-mini", "OpenAI o4-mini", 1.10, 4.40, 0.275, 0.0)
	_seed_usage_price(data, "claude-fable-5", "Claude Fable 5", 10.0, 50.0, 1.0, 12.50)
	_seed_usage_price(data, "claude-mythos-5", "Claude Mythos 5", 10.0, 50.0, 1.0, 12.50)
	_seed_usage_price(data, "claude-opus-4-8", "Claude Opus 4.8", 5.0, 25.0, 0.50, 6.25)
	_seed_usage_price(data, "claude-sonnet-5", "Claude Sonnet 5", 3.0, 15.0, 0.30, 3.75)
	_seed_usage_price(data, "claude-sonnet-4-6", "Claude Sonnet 4.6", 3.0, 15.0, 0.30, 3.75)
	_seed_usage_price(data, "claude-3-5-sonnet", "Claude 3.5 Sonnet", 3.0, 15.0, 0.30, 3.75)
	_seed_usage_price(data, "claude-3-5-haiku", "Claude 3.5 Haiku", 0.80, 4.0, 0.08, 1.0)
	_seed_usage_price(data, "gemini-2.5-pro", "Gemini 2.5 Pro", 1.25, 10.0, 0.125, 0.0)
	_seed_usage_price(data, "gemini-2.5-flash", "Gemini 2.5 Flash", 0.30, 2.50, 0.03, 0.0)
	_seed_usage_price(data, "glm-5.1", "GLM-5.1", 1.40, 4.40, 0.26, 0.0)
	_seed_usage_price(data, "deepseek-v4-pro", "DeepSeek V4 Pro", 0.435, 0.87, 0.003625, 0.0)
	_seed_usage_price(data, "qwen3.5-plus", "Qwen3.5 Plus", 0.26, 1.56, 0.052, 0.0)
	_seed_usage_price(data, "kimi-k2.5", "Kimi K2.5", 0.60, 3.0, 0.10, 0.0)
	return data


func _seed_usage_price(data: Dictionary, model_id: String, display_name: String, input_cost: float, output_cost: float, cache_read: float, cache_creation: float) -> void:
	var normalized := _normalize_usage_model_id(model_id)
	data[normalized] = {
		"model_id": normalized,
		"display_name": display_name,
		"input": input_cost,
		"output": output_cost,
		"cache_read": cache_read,
		"cache_creation": cache_creation,
	}


func _save_usage_pricing() -> void:
	var rows: Array = []
	var keys: Array[String] = []
	for key in usage_pricing.keys():
		keys.append(str(key))
	keys.sort()
	for key in keys:
		var pricing: Dictionary = usage_pricing[key]
		rows.append({
			"model_id": key,
			"display_name": str(pricing.get("display_name", key)),
			"input": float(pricing.get("input", 0.0)),
			"output": float(pricing.get("output", 0.0)),
			"cache_read": float(pricing.get("cache_read", 0.0)),
			"cache_creation": float(pricing.get("cache_creation", 0.0)),
		})
	_write_json_file(USAGE_PRICING_PATH, {"version": SAVE_VERSION, "models": rows})


func _ensure_usage_pricing_for_models(events: Array) -> void:
	var changed := false
	for event in events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		var model := str(event.get("model", "")).strip_edges()
		if model == "":
			continue
		var matched := _find_usage_pricing(model)
		var matched_id := str(matched.get("model_id", ""))
		if matched_id != "" and usage_pricing.has(matched_id):
			continue
		var normalized := _normalize_usage_model_id(model)
		if not usage_pricing.has(normalized):
			usage_pricing[normalized] = _zero_pricing(model)
			changed = true
	if changed:
		_save_usage_pricing()


func _open_usage_pricing_dialog(model_id: String) -> void:
	usage_pricing_edit_original_id = _normalize_usage_model_id(model_id)
	var pricing: Dictionary = usage_pricing.get(usage_pricing_edit_original_id, _zero_pricing(model_id))
	usage_pricing_dialog.show_pricing(usage_pricing_edit_original_id, pricing)


func _save_usage_pricing_dialog() -> void:
	var values: Dictionary = usage_pricing_dialog.values()
	var model_id := _normalize_usage_model_id(str(values.get("model_id", "")))
	if model_id == "":
		log_label.text = "模型 ID 不能为空。"
		return
	if usage_pricing_edit_original_id != "" and usage_pricing_edit_original_id != model_id:
		usage_pricing.erase(usage_pricing_edit_original_id)
	usage_pricing[model_id] = {
		"model_id": model_id,
		"display_name": str(values.get("display_name", "")).strip_edges() if str(values.get("display_name", "")).strip_edges() != "" else model_id,
		"input": float(values.get("input", "0")),
		"output": float(values.get("output", "0")),
		"cache_read": float(values.get("cache_read", "0")),
		"cache_creation": float(values.get("cache_creation", "0")),
	}
	_save_usage_pricing()
	_refresh_usage_stats(false)
	log_label.text = "已保存模型成本: %s" % model_id


func _selected_usage_pricing_model() -> String:
	if usage_page == null:
		return ""
	return usage_page.selected_pricing_model()


func _edit_selected_usage_pricing() -> void:
	var model := _selected_usage_pricing_model()
	if model == "":
		log_label.text = "请先选择一个模型成本行。"
		return
	_open_usage_pricing_dialog(model)


func _delete_selected_usage_pricing() -> void:
	var model := _selected_usage_pricing_model()
	if model == "":
		log_label.text = "请先选择一个模型成本行。"
		return
	usage_pricing.erase(model)
	_save_usage_pricing()
	_refresh_usage_stats(false)
	log_label.text = "已删除模型成本: %s" % model


func _reset_usage_pricing() -> void:
	usage_pricing = _default_usage_pricing()
	_ensure_usage_pricing_for_models(usage_events)
	_save_usage_pricing()
	_refresh_usage_stats(false)
	log_label.text = "已重置使用统计模型成本。"


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


func _format_usage_tokens_short(value: int, decimals: int = 1) -> String:
	if value >= 100000000:
		return "%.2f 亿" % (float(value) / 100000000.0)
	if value >= 10000:
		var token_format := "%." + str(decimals) + "f 万"
		return token_format % (float(value) / 10000.0)
	return _format_int_with_commas(value)


func _format_usd(value: float, digits: int) -> String:
	var usd_format := "$%." + str(digits) + "f"
	return usd_format % value


func _format_percent(value: float) -> String:
	return "%.0f%%" % value if value >= 99.95 else "%.1f%%" % value


func _format_price_number(value: float) -> String:
	if absf(value - roundf(value)) < 0.00001:
		return "%d" % int(roundf(value))
	return "%.4f" % value

func _setup_tree_columns() -> void:
	if session_page == null:
		return
	session_page.configure_columns(column_titles, [280, 70, 60, 76, 148])
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
	usage_events_dirty = true
	_save_current_display_archive()
	_apply_filter()
	if main_tabs != null and main_tabs.get_tab_title(main_tabs.current_tab) == "使用统计":
		_refresh_usage_stats()
	log_label.text = "已读取 %s 并保存当前存档，共 %d 条记录" % [current_codex_dir, sessions.size()]


func _update_summary(summary: Dictionary) -> void:
	session_page.render_summary(summary)


func _apply_filter() -> void:
	var query: String = session_page.filter_query()
	filtered_sessions.clear()
	for row in sessions:
		if not session_page.include_archived() and row.get("storage", "") == "archived":
			continue
		if not session_page.include_backup() and row.get("storage", "") == "backup":
			continue
		if not session_page.include_deleted_archive() and row.get("storage", "") == "deleted_archive":
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
			return "%s %s" % [str(row.get("cwd", "")).to_lower(), str(row.get("title", "")).to_lower()]
		1:
			return int(row.get("total_tokens", 0))
		2:
			return int(row.get("message_count", 0))
		3:
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
		4:
			return _row_unix_time(row)
		_:
			return _row_unix_time(row)


func _compare_values(a, b) -> int:
	if a == b:
		return 0
	if typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT:
		return -1 if a < b else 1
	return -1 if str(a) < str(b) else 1


func _update_column_titles() -> void:
	if session_page == null:
		return
	session_page.update_column_titles(sort_rules)


func _row_matches_query(row: Dictionary, query: String) -> bool:
	var haystack := "%s %s %s %s %s %s %s %s %s %s" % [
		row.get("id", ""),
		row.get("model", ""),
		row.get("reasoning_effort", ""),
		row.get("cwd", ""),
		row.get("title", ""),
		row.get("summary", ""),
		row.get("resume_command", ""),
		row.get("session_file", ""),
		row.get("deleted_action", ""),
		row.get("deleted_at_text", ""),
	]
	return haystack.to_lower().contains(query)


func _render_tree() -> void:
	session_page.render_tree(filtered_sessions, MAX_VISIBLE_ROWS)
	if filtered_sessions.size() > MAX_VISIBLE_ROWS:
		log_label.text = "筛选结果 %d 条，仅显示前 %d 条。" % [filtered_sessions.size(), MAX_VISIBLE_ROWS]
	selected_id = ""
	selected_row_key = ""
	session_page.reset_detail()


func _on_session_selected(row_key: String) -> void:
	selected_row_key = row_key
	if selected_row_key.begins_with("project|"):
		return
	var row := _find_session_by_key(selected_row_key)
	if row.is_empty():
		return
	selected_id = str(row.get("id", ""))
	session_page.set_action_buttons_enabled(
		true,
		str(row.get("cwd", "")).strip_edges() != "",
		str(row.get("resume_command", "")).strip_edges() != ""
	)
	_render_session_detail(row)


func _render_session_detail(row: Dictionary) -> void:
	session_page.set_detail_header(_format_session_header(row))
	session_page.clear_toc()
	var session_file := str(row.get("session_file", ""))
	if str(row.get("storage", "")) == "deleted_archive" or session_file == "":
		_show_detail_text(_format_details(row))
		return
	if not FileAccess.file_exists(session_file):
		_show_detail_text("%s\n\n[color=#ef4444]会话文件不存在，无法读取对话内容。[/color]" % _format_details(row))
		return

	_show_detail_text("正在读取对话内容...")
	var result := _run_backend(["messages", "--session-file", session_file])
	if not result.get("success", false):
		_show_detail_text("%s\n\n[color=#ef4444]读取对话失败: %s[/color]" % [
			_format_details(row),
			_bbcode_escape(str(result.get("error", "unknown error"))),
		])
		return
	var messages = result.get("messages", [])
	if typeof(messages) != TYPE_ARRAY:
		messages = []
	row["message_count"] = int(result.get("message_count", messages.size()))
	session_page.render_conversation(messages)
	log_label.text = "已读取对话: %s，%d 条消息。" % [_session_title(row), messages.size()]


func _render_conversation(messages: Array) -> void:
	session_page.render_conversation(messages)


func _show_detail_text(text: String) -> void:
	session_page.show_detail_text(text)


func _open_selected_session_folder() -> void:
	if selected_row_key == "":
		log_label.text = "请先选择一个会话。"
		return
	var row := _find_session_by_key(selected_row_key)
	if row.is_empty():
		log_label.text = "没有找到选中会话。"
		return
	var project_dir := _to_native_path(str(row.get("cwd", "")).strip_edges())
	if project_dir != "" and DirAccess.dir_exists_absolute(project_dir):
		_open_folder(project_dir, "项目目录")
		return
	var session_file := str(row.get("session_file", ""))
	if session_file == "":
		log_label.text = "选中记录没有可打开的项目目录或文件路径。"
		return
	var folder_path := _to_native_path(session_file.get_base_dir())
	if not DirAccess.dir_exists_absolute(folder_path):
		log_label.text = "文件夹不存在: %s" % folder_path
		return
	_open_folder(folder_path, "文件夹")


func _copy_selected_project_dir() -> void:
	if selected_row_key == "":
		log_label.text = "请先选择一个会话。"
		return
	var row := _find_session_by_key(selected_row_key)
	var project_dir := str(row.get("cwd", "")).strip_edges()
	if project_dir == "":
		log_label.text = "选中会话没有项目目录。"
		return
	DisplayServer.clipboard_set(project_dir)
	log_label.text = "已复制项目目录: %s" % project_dir


func _copy_selected_resume_command() -> void:
	if selected_row_key == "":
		log_label.text = "请先选择一个会话。"
		return
	var row := _find_session_by_key(selected_row_key)
	var command := str(row.get("resume_command", "")).strip_edges()
	if command == "":
		log_label.text = "选中会话没有恢复命令。"
		return
	DisplayServer.clipboard_set(command)
	log_label.text = "已复制恢复命令: %s" % command


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
		+ "[b]Messages[/b]\n%d\n\n"
		+ "[b]Directory[/b]\n%s\n\n"
		+ "[b]Resume[/b]\n%s\n\n"
		+ "[b]Summary[/b]\n%s\n\n"
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
		int(row.get("message_count", 0)),
		row.get("cwd", ""),
		row.get("resume_command", ""),
		row.get("summary", ""),
		row.get("session_file", ""),
		deleted_info,
	]


func _format_session_header(row: Dictionary) -> String:
	return (
		"[b][font_size=18]%s[/font_size][/b]\n"
		+ "[color=#8b949e]Session[/color] %s    [color=#8b949e]时间[/color] %s    [color=#8b949e]状态[/color] %s\n"
		+ "[color=#8b949e]当前目录[/color] %s\n"
		+ "[color=#8b949e]恢复命令[/color] [code]%s[/code]\n"
		+ "[color=#8b949e]Token[/color] 总 %.2fM / 输入 %.2fM / 输出 %.2fM / 消息 %d"
	) % [
		_bbcode_escape(_session_title(row)),
		_bbcode_escape(str(row.get("id", ""))),
		_bbcode_escape(_row_time_text(row)),
		_bbcode_escape(_storage_label(str(row.get("storage", "")))),
		_bbcode_escape(str(row.get("cwd", ""))),
		_bbcode_escape(str(row.get("resume_command", ""))),
		_to_million(row.get("total_tokens", 0)),
		_to_million(row.get("input_tokens", 0)),
		_to_million(row.get("output_tokens", 0)),
		int(row.get("message_count", 0)),
	]


func _bbcode_escape(text: String) -> String:
	return text.replace("[", "[lb]").replace("]", "[rb]")


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
			"query": session_page.filter_text(),
			"include_archived": session_page.include_archived(),
			"include_backup": session_page.include_backup(),
			"include_deleted_archive": session_page.include_deleted_archive(),
			"time_range": session_page.selected_time_range_bounds() if session_page != null else {},
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
			"source": str(row.get("source", "")),
			"reasoning_effort": str(row.get("reasoning_effort", "")),
			"cwd": str(row.get("cwd", "")),
			"title": str(row.get("title", "")),
			"summary": str(row.get("summary", "")),
			"message_count": int(row.get("message_count", 0)),
			"resume_command": str(row.get("resume_command", "")),
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
	if session_page == null:
		return true
	var bounds: Dictionary = session_page.selected_time_range_bounds()
	var start_unix := int(bounds.get("start", 0))
	var end_unix := int(bounds.get("end", 0))
	var row_time := _row_unix_time(row)
	if row_time <= 0:
		return false
	if start_unix > 0 and row_time < start_unix:
		return false
	if end_unix > 0 and row_time > end_unix:
		return false
	return true


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
		return _format_unix_time(unix)
	var timestamp := str(row.get("timestamp", ""))
	return timestamp if timestamp != "" else "未知"


func _format_unix_time(unix_time: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix_time + _local_time_offset_seconds(), true)


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
