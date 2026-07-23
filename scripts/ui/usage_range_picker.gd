class_name UsageRangePicker
extends HBoxContainer


signal selection_changed

const DAY_SECONDS := 86400

@onready var trigger_button: Button = %TriggerButton
@onready var popup_panel: PopupPanel = %PopupPanel
@onready var today_button: Button = %TodayButton
@onready var one_day_button: Button = %OneDayButton
@onready var seven_day_button: Button = %SevenDayButton
@onready var fourteen_day_button: Button = %FourteenDayButton
@onready var thirty_day_button: Button = %ThirtyDayButton
@onready var all_button: Button = %AllButton
@onready var start_panel: PanelContainer = %StartPanel
@onready var end_panel: PanelContainer = %EndPanel
@onready var start_date_edit: LineEdit = %StartDateEdit
@onready var start_time_edit: LineEdit = %StartTimeEdit
@onready var end_date_edit: LineEdit = %EndDateEdit
@onready var end_time_edit: LineEdit = %EndTimeEdit
@onready var live_end_check: CheckBox = %LiveEndCheck
@onready var error_label: Label = %ErrorLabel
@onready var cancel_button: Button = %CancelButton
@onready var confirm_button: Button = %ConfirmButton
@onready var prev_month_button: Button = %PrevMonthButton
@onready var next_month_button: Button = %NextMonthButton
@onready var month_button: Button = %MonthButton
@onready var weekday_grid: GridContainer = %WeekdayGrid
@onready var day_grid: GridContainer = %DayGrid
@onready var live_timer: Timer = %LiveTimer

var selection := {
	"preset": "today",
	"custom_start_unix": 0,
	"custom_end_unix": 0,
	"live_end_time": false,
}
var draft_start_unix := 0
var draft_end_unix := 0
var draft_live_end := false
var active_field := "start"
var display_year := 0
var display_month := 0
var day_buttons: Array[Button] = []
var show_all_preset := false


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_SHRINK_END
	_setup_ui()
	_create_calendar_buttons()
	_connect_signals()
	_update_trigger()
	_update_live_timer()


func selected_preset() -> String:
	return str(selection.get("preset", "today"))


func selection_data() -> Dictionary:
	return selection.duplicate(true)


func set_show_all_preset(enabled: bool) -> void:
	show_all_preset = enabled
	if all_button != null:
		all_button.visible = enabled
	_update_trigger()


func set_selection_preset(preset: String) -> void:
	_apply_preset(preset)


func resolve_selection(now_unix: int = 0) -> Dictionary:
	if now_unix <= 0:
		now_unix = int(Time.get_unix_time_from_system())
	var preset := selected_preset()
	if preset == "all":
		return {"start": 0, "end": now_unix}
	if preset == "today":
		return {"start": _start_of_local_day(now_unix), "end": now_unix}
	if preset == "1d":
		return {"start": now_unix - DAY_SECONDS, "end": now_unix}
	if preset == "7d" or preset == "14d" or preset == "30d":
		var days := 7
		if preset == "14d":
			days = 14
		elif preset == "30d":
			days = 30
		return {"start": _start_of_local_day(now_unix - (days - 1) * DAY_SECONDS), "end": now_unix}

	var start_unix := int(selection.get("custom_start_unix", now_unix - DAY_SECONDS))
	var end_unix := now_unix if bool(selection.get("live_end_time", false)) else int(selection.get("custom_end_unix", now_unix))
	if start_unix > end_unix:
		var swapped := start_unix
		start_unix = end_unix
		end_unix = swapped
	return {"start": start_unix, "end": end_unix}


func _setup_ui() -> void:
	trigger_button.custom_minimum_size = Vector2(132, 0)
	error_label.visible = false
	error_label.modulate = Color(0.94, 0.27, 0.27)
	weekday_grid.columns = 7
	day_grid.columns = 7
	live_timer.wait_time = 60.0
	live_timer.one_shot = false
	_apply_panel_state()
	_refresh_weekday_labels()


func _connect_signals() -> void:
	trigger_button.pressed.connect(_open_popup)
	today_button.pressed.connect(func() -> void: _apply_preset("today"))
	one_day_button.pressed.connect(func() -> void: _apply_preset("1d"))
	seven_day_button.pressed.connect(func() -> void: _apply_preset("7d"))
	fourteen_day_button.pressed.connect(func() -> void: _apply_preset("14d"))
	thirty_day_button.pressed.connect(func() -> void: _apply_preset("30d"))
	all_button.pressed.connect(func() -> void: _apply_preset("all"))
	cancel_button.pressed.connect(func() -> void: popup_panel.hide())
	confirm_button.pressed.connect(_confirm_custom_range)
	prev_month_button.pressed.connect(func() -> void: _shift_display_month(-1))
	next_month_button.pressed.connect(func() -> void: _shift_display_month(1))
	month_button.pressed.connect(_go_to_current_month)
	live_end_check.toggled.connect(_on_live_end_toggled)
	start_date_edit.focus_entered.connect(func() -> void: _set_active_field("start"))
	start_time_edit.focus_entered.connect(func() -> void: _set_active_field("start"))
	end_date_edit.focus_entered.connect(func() -> void: _set_active_field("end"))
	end_time_edit.focus_entered.connect(func() -> void: _set_active_field("end"))
	start_date_edit.text_submitted.connect(func(_text: String) -> void: _apply_field_edits())
	start_time_edit.text_submitted.connect(func(_text: String) -> void: _apply_field_edits())
	end_date_edit.text_submitted.connect(func(_text: String) -> void: _apply_field_edits())
	end_time_edit.text_submitted.connect(func(_text: String) -> void: _apply_field_edits())
	live_timer.timeout.connect(_on_live_timer_timeout)
	popup_panel.popup_hide.connect(_update_live_timer)


func _open_popup() -> void:
	_reset_draft_from_selection()
	var popup_size := Vector2i(620, 320)
	var x := int(global_position.x + size.x - popup_size.x)
	var y := int(global_position.y + size.y + 8)
	x = maxi(x, 8)
	y = maxi(y, 8)
	popup_panel.popup(Rect2i(Vector2i(x, y), popup_size))
	_update_live_timer()


func _reset_draft_from_selection() -> void:
	var resolved := resolve_selection()
	draft_start_unix = int(resolved.get("start", 0))
	draft_end_unix = int(resolved.get("end", 0))
	draft_live_end = selected_preset() == "custom" and bool(selection.get("live_end_time", false))
	var start_dict := _local_dict_from_unix(draft_start_unix)
	display_year = int(start_dict.get("year", 1970))
	display_month = int(start_dict.get("month", 1))
	active_field = "start"
	error_label.visible = false
	_update_field_text()
	_update_calendar()
	_update_preset_buttons()
	_apply_panel_state()


func _apply_preset(preset: String) -> void:
	selection = {
		"preset": preset,
		"custom_start_unix": 0,
		"custom_end_unix": 0,
		"live_end_time": false,
	}
	popup_panel.hide()
	_update_trigger()
	_update_live_timer()
	selection_changed.emit()


func _confirm_custom_range() -> void:
	if not _apply_field_edits():
		return
	if draft_start_unix > draft_end_unix:
		_show_error("开始时间不能晚于结束时间")
		return
	selection = {
		"preset": "custom",
		"custom_start_unix": draft_start_unix,
		"custom_end_unix": draft_end_unix,
		"live_end_time": draft_live_end,
	}
	popup_panel.hide()
	_update_trigger()
	_update_live_timer()
	selection_changed.emit()


func _apply_field_edits() -> bool:
	var start_parsed := _parse_date_time(start_date_edit.text, start_time_edit.text, draft_start_unix)
	if start_parsed <= 0:
		_show_error("开始时间格式应为 YYYY/MM/DD 和 HH:MM")
		return false
	draft_start_unix = start_parsed
	if draft_live_end:
		draft_end_unix = int(Time.get_unix_time_from_system())
	else:
		var end_parsed := _parse_date_time(end_date_edit.text, end_time_edit.text, draft_end_unix)
		if end_parsed <= 0:
			_show_error("结束时间格式应为 YYYY/MM/DD 和 HH:MM")
			return false
		draft_end_unix = end_parsed
	error_label.visible = false
	_update_field_text()
	_update_calendar()
	return true


func _on_live_end_toggled(pressed: bool) -> void:
	draft_live_end = pressed
	if draft_live_end:
		draft_end_unix = int(Time.get_unix_time_from_system())
		active_field = "start"
	error_label.visible = false
	_update_field_text()
	_update_calendar()
	_apply_panel_state()
	_update_live_timer()


func _on_live_timer_timeout() -> void:
	if popup_panel.visible and draft_live_end:
		draft_end_unix = int(Time.get_unix_time_from_system())
		_update_field_text()
		_update_calendar()
	if selected_preset() == "custom" and not bool(selection.get("live_end_time", false)):
		return
	selection_changed.emit()


func _update_live_timer() -> void:
	if live_timer == null:
		return
	var draft_needs_timer := popup_panel.visible and draft_live_end
	var selection_needs_timer := selected_preset() != "custom" or bool(selection.get("live_end_time", false))
	if not draft_needs_timer and not selection_needs_timer:
		live_timer.stop()
	else:
		live_timer.start()


func _set_active_field(field: String) -> void:
	if field == "end" and draft_live_end:
		return
	active_field = field
	_apply_panel_state()


func _create_calendar_buttons() -> void:
	for child in day_grid.get_children():
		child.queue_free()
	day_buttons.clear()
	for i in range(42):
		var button := Button.new()
		button.custom_minimum_size = Vector2(36, 30)
		button.focus_mode = Control.FOCUS_NONE
		button.flat = false
		button.pressed.connect(_pick_calendar_day_button.bind(button))
		day_grid.add_child(button)
		day_buttons.append(button)


func _refresh_weekday_labels() -> void:
	for child in weekday_grid.get_children():
		child.queue_free()
	for label_text in ["日", "一", "二", "三", "四", "五", "六"]:
		var label := Label.new()
		label.text = label_text
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.modulate = Color(0.58, 0.60, 0.67)
		weekday_grid.add_child(label)


func _update_calendar() -> void:
	month_button.text = "%04d年%d月" % [display_year, display_month]
	var first_unix := _local_date_time_to_unix(display_year, display_month, 1, 0, 0)
	var first_weekday := int(_local_dict_from_unix(first_unix).get("weekday", 0))
	var grid_start := first_unix - first_weekday * DAY_SECONDS
	var start_day := _start_of_local_day(draft_start_unix)
	var end_day := _start_of_local_day(draft_end_unix)
	var today_day := _start_of_local_day(int(Time.get_unix_time_from_system()))
	for i in range(day_buttons.size()):
		var day_unix := grid_start + i * DAY_SECONDS
		var dict := _local_dict_from_unix(day_unix)
		var button := day_buttons[i]
		button.text = str(int(dict.get("day", 1)))
		button.set_meta("day_unix", day_unix)
		button.disabled = false
		var is_current_month := int(dict.get("month", 0)) == display_month
		var is_endpoint := day_unix == start_day or day_unix == end_day
		var in_range := day_unix >= start_day and day_unix <= end_day
		if is_endpoint:
			_apply_day_button_style(button, Color.html("#0a84ff"), Color.html("#0a84ff"), Color.WHITE)
		elif in_range:
			_apply_day_button_style(button, Color(0.04, 0.52, 1.0, 0.20), Color(0.04, 0.52, 1.0, 0.18), Color.html("#6aa9ff"))
		elif day_unix == today_day:
			_apply_day_button_style(button, Color(0, 0, 0, 0), Color(0.04, 0.52, 1.0, 0.70), Color.html("#6aa9ff"))
		else:
			var font_color := Color.html("#e5e7eb") if is_current_month else Color(0.55, 0.58, 0.64, 0.55)
			_apply_day_button_style(button, Color(0, 0, 0, 0), Color(0, 0, 0, 0), font_color)


func _apply_day_button_style(button: Button, background: Color, border: Color, font_color: Color) -> void:
	var normal := _day_style(background, border, 1)
	var hover := _day_style(background.lightened(0.12), border.lightened(0.10), 1)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", normal)
	button.add_theme_stylebox_override("focus", _day_style(Color(0, 0, 0, 0), Color.html("#0a84ff"), 1))
	button.add_theme_color_override("font_color", font_color)
	button.add_theme_color_override("font_hover_color", font_color)
	button.add_theme_color_override("font_pressed_color", font_color)


func _day_style(background: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(5)
	return style


func _pick_calendar_day_button(button: Button) -> void:
	_pick_calendar_day(day_buttons.find(button))


func _pick_calendar_day(index: int) -> void:
	if index < 0 or index >= day_buttons.size():
		return
	var day_unix := int(day_buttons[index].get_meta("day_unix", 0))
	if day_unix <= 0:
		return
	if draft_live_end:
		draft_start_unix = _set_date_keep_time(draft_start_unix, day_unix)
	else:
		var next_unix := _set_date_keep_time(draft_start_unix if active_field == "start" else draft_end_unix, day_unix)
		if active_field == "start":
			draft_start_unix = next_unix
			if draft_start_unix > draft_end_unix:
				draft_end_unix = draft_start_unix
			active_field = "end"
		elif next_unix < draft_start_unix:
			draft_start_unix = next_unix
			active_field = "end"
		else:
			draft_end_unix = next_unix
	error_label.visible = false
	var dict := _local_dict_from_unix(day_unix)
	display_year = int(dict.get("year", display_year))
	display_month = int(dict.get("month", display_month))
	_update_field_text()
	_update_calendar()
	_apply_panel_state()


func _set_date_keep_time(original_unix: int, day_unix: int) -> int:
	var time_dict := _local_dict_from_unix(original_unix)
	var day_dict := _local_dict_from_unix(day_unix)
	return _local_date_time_to_unix(
		int(day_dict.get("year", 1970)),
		int(day_dict.get("month", 1)),
		int(day_dict.get("day", 1)),
		int(time_dict.get("hour", 0)),
		int(time_dict.get("minute", 0))
	)


func _shift_display_month(delta: int) -> void:
	display_month += delta
	while display_month < 1:
		display_month += 12
		display_year -= 1
	while display_month > 12:
		display_month -= 12
		display_year += 1
	_update_calendar()


func _go_to_current_month() -> void:
	var now_dict := _local_dict_from_unix(int(Time.get_unix_time_from_system()))
	display_year = int(now_dict.get("year", display_year))
	display_month = int(now_dict.get("month", display_month))
	_update_calendar()


func _update_field_text() -> void:
	if draft_live_end:
		draft_end_unix = int(Time.get_unix_time_from_system())
	start_date_edit.text = _format_local_date(draft_start_unix)
	start_time_edit.text = _format_local_time(draft_start_unix)
	end_date_edit.text = _format_local_date(draft_end_unix)
	end_time_edit.text = _format_local_time(draft_end_unix)
	live_end_check.button_pressed = draft_live_end


func _update_trigger() -> void:
	var preset := selected_preset()
	if preset == "custom":
		var start_text := _format_short_local_date(int(selection.get("custom_start_unix", 0)))
		var end_text := "现在" if bool(selection.get("live_end_time", false)) else _format_short_local_date(int(selection.get("custom_end_unix", 0)))
		trigger_button.text = "%s - %s" % [start_text, end_text]
	else:
		trigger_button.text = _preset_label(preset)
	_update_preset_buttons()


func _update_preset_buttons() -> void:
	var preset := selected_preset()
	var buttons := {
		"today": today_button,
		"1d": one_day_button,
		"7d": seven_day_button,
		"14d": fourteen_day_button,
		"30d": thirty_day_button,
	}
	if show_all_preset:
		buttons["all"] = all_button
	for key in buttons.keys():
		var button: Button = buttons[key]
		button.button_pressed = key == preset


func _apply_panel_state() -> void:
	var active_style := _panel_style("#1b2535", "#0a84ff")
	var inactive_style := _panel_style("#1b1c22", "#30323b")
	var disabled_style := _panel_style("#171820", "#252731")
	start_panel.add_theme_stylebox_override("panel", active_style if active_field == "start" else inactive_style)
	end_panel.add_theme_stylebox_override("panel", disabled_style if draft_live_end else (active_style if active_field == "end" else inactive_style))
	end_date_edit.editable = not draft_live_end
	end_time_edit.editable = not draft_live_end


func _show_error(text: String) -> void:
	error_label.text = text
	error_label.visible = true


func _parse_date_time(date_text: String, time_text: String, fallback_unix: int) -> int:
	var date_parts := date_text.strip_edges().replace("-", "/").split("/", false)
	if date_parts.size() != 3:
		return 0
	var time_parts := time_text.strip_edges().split(":", false)
	if time_parts.size() < 2:
		return 0
	var year := int(date_parts[0])
	var month := int(date_parts[1])
	var day := int(date_parts[2])
	var hour := int(time_parts[0])
	var minute := int(time_parts[1])
	if year < 1970 or month < 1 or month > 12 or day < 1 or day > 31 or hour < 0 or hour > 23 or minute < 0 or minute > 59:
		return fallback_unix
	return _local_date_time_to_unix(year, month, day, hour, minute)


func _format_local_date(unix_time: int) -> String:
	var dict := _local_dict_from_unix(unix_time)
	return "%04d/%02d/%02d" % [int(dict.get("year", 0)), int(dict.get("month", 0)), int(dict.get("day", 0))]


func _format_short_local_date(unix_time: int) -> String:
	if unix_time <= 0:
		return "未设置"
	var dict := _local_dict_from_unix(unix_time)
	return "%02d/%02d" % [int(dict.get("month", 0)), int(dict.get("day", 0))]


func _format_local_time(unix_time: int) -> String:
	var dict := _local_dict_from_unix(unix_time)
	return "%02d:%02d" % [int(dict.get("hour", 0)), int(dict.get("minute", 0))]


func _preset_label(preset: String) -> String:
	match preset:
		"today":
			return "当天"
		"1d":
			return "1d"
		"7d":
			return "7d"
		"14d":
			return "14d"
		"30d":
			return "30d"
		"all":
			return "全部"
		_:
			return "日历筛选"


func _start_of_local_day(unix_time: int) -> int:
	return _local_bucket_start(unix_time, DAY_SECONDS)


func _local_bucket_start(unix_time: int, step: int) -> int:
	var offset := _local_time_offset_seconds()
	var local_unix := unix_time + offset
	return int(floor(float(local_unix) / float(step))) * step - offset


func _local_dict_from_unix(unix_time: int) -> Dictionary:
	return Time.get_datetime_dict_from_unix_time(unix_time + _local_time_offset_seconds())


func _local_date_time_to_unix(year: int, month: int, day: int, hour: int, minute: int) -> int:
	return int(Time.get_unix_time_from_datetime_dict({
		"year": year,
		"month": month,
		"day": day,
		"hour": hour,
		"minute": minute,
		"second": 0,
	})) - _local_time_offset_seconds()


func _local_time_offset_seconds() -> int:
	var zone := Time.get_time_zone_from_system()
	return int(zone.get("bias", 0)) * 60


func _panel_style(background: String, border: String) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.html(background)
	style.border_color = Color.html(border)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	return style
