class_name MessageCard
extends PanelContainer


@onready var header_label: RichTextLabel = %HeaderLabel
@onready var body_label: RichTextLabel = %BodyLabel


func set_message(role: String, content: String, timestamp: String) -> void:
	var role_theme := _role_theme(role)
	add_theme_stylebox_override("panel", _message_card_style(role_theme))
	header_label.text = "[color=%s][b]%s[/b][/color]" % [
		role_theme.get("title", "#e5e7eb"),
		_bbcode_escape(("%s    %s" % [_role_label(role), _timestamp_label(timestamp)]).strip_edges()),
	]
	body_label.text = "[color=%s]%s[/color]" % [
		role_theme.get("content", "#e5e7eb"),
		_bbcode_escape(content.strip_edges()),
	]


func _message_card_style(role_theme: Dictionary) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.html(str(role_theme.get("background", "#20242a")))
	style.border_color = Color.html(str(role_theme.get("border", "#30363d")))
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	return style


func _role_theme(role: String) -> Dictionary:
	match role.to_lower():
		"user":
			return {"background": "#0f2a23", "border": "#1f6f4a", "title": "#22c55e", "content": "#d8fff0"}
		"assistant":
			return {"background": "#101f33", "border": "#275483", "title": "#60a5fa", "content": "#e6f0ff"}
		"tool":
			return {"background": "#231a33", "border": "#5b3a86", "title": "#c084fc", "content": "#f3e8ff"}
		"system", "developer":
			return {"background": "#33240d", "border": "#77540e", "title": "#f59e0b", "content": "#fff7df"}
		_:
			return {"background": "#20242a", "border": "#30363d", "title": "#cbd5e1", "content": "#e5e7eb"}


func _role_label(role: String) -> String:
	match role.to_lower():
		"user":
			return "用户"
		"assistant":
			return "AI"
		"tool":
			return "工具"
		"system":
			return "系统"
		"developer":
			return "开发者"
		_:
			return role


func _timestamp_label(timestamp: String) -> String:
	if timestamp == "":
		return ""
	var unix := _parse_timestamp_to_unix(timestamp)
	if unix <= 0:
		return timestamp
	return Time.get_datetime_string_from_unix_time(unix + _local_time_offset_seconds(), true)


func _local_time_offset_seconds() -> int:
	var zone := Time.get_time_zone_from_system()
	return int(zone.get("bias", 0)) * 60


func _parse_timestamp_to_unix(timestamp: String) -> int:
	var text := timestamp.replace("T", " ").replace("Z", "")
	var dot_index := text.find(".")
	if dot_index != -1:
		text = text.substr(0, dot_index)
	return int(Time.get_unix_time_from_datetime_string(text))


func _bbcode_escape(text: String) -> String:
	return text.replace("[", "[lb]").replace("]", "[rb]")
