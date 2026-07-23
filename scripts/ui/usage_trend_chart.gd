class_name UsageTrendChart
extends Control


var chart_points: Array = []
var hover_index := -1

const SERIES := [
	{"key": "input_tokens", "label": "输入", "color": Color(0.22, 0.52, 1.0)},
	{"key": "output_tokens", "label": "输出", "color": Color(0.08, 0.80, 0.45)},
	{"key": "cache_creation_tokens", "label": "缓存创建", "color": Color(0.98, 0.45, 0.12)},
	{"key": "cached_input_tokens", "label": "缓存命中", "color": Color(0.68, 0.32, 1.0)},
	{"key": "cost", "label": "成本", "color": Color(1.0, 0.20, 0.38), "cost": true},
]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(0, 340)


func set_points(points: Array) -> void:
	chart_points = points
	hover_index = -1
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hover_index = _nearest_point_index(event.position)
		queue_redraw()
	elif event is InputEventMouseButton and not event.pressed:
		hover_index = _nearest_point_index(event.position)
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hover_index = -1
		queue_redraw()


func _draw() -> void:
	var font := get_theme_font("font", "Label")
	var font_size := 12
	var rect := Rect2(Vector2.ZERO, size)
	var plot := Rect2(58, 18, maxf(size.x - 112.0, 20.0), maxf(size.y - 62.0, 20.0))
	draw_rect(rect, Color(0.09, 0.09, 0.105, 0.28), true)
	draw_rect(plot, Color(0.12, 0.125, 0.145, 0.35), true)

	if chart_points.is_empty():
		_draw_text(font, Vector2(plot.position.x + 12, plot.position.y + 28), "暂无趋势数据", font_size, Color(0.62, 0.65, 0.72))
		return

	var max_tokens := 0.0
	var max_cost := 0.0
	for point in chart_points:
		if typeof(point) != TYPE_DICTIONARY:
			continue
		max_tokens = maxf(max_tokens, float(point.get("input_tokens", 0)))
		max_tokens = maxf(max_tokens, float(point.get("output_tokens", 0)))
		max_tokens = maxf(max_tokens, float(point.get("cache_creation_tokens", 0)))
		max_tokens = maxf(max_tokens, float(point.get("cached_input_tokens", 0)))
		max_cost = maxf(max_cost, float(point.get("cost", 0.0)))
	max_tokens = maxf(max_tokens, 1.0)
	max_cost = maxf(max_cost, 0.000001)

	for i in range(5):
		var y := plot.position.y + plot.size.y * float(i) / 4.0
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(0.45, 0.47, 0.52, 0.18), 1.0)
		var token_value := max_tokens * (1.0 - float(i) / 4.0)
		var cost_value := max_cost * (1.0 - float(i) / 4.0)
		_draw_text(font, Vector2(4, y + 4), _format_axis_tokens(token_value), font_size, Color(0.58, 0.60, 0.67))
		_draw_text(font, Vector2(plot.end.x + 8, y + 4), "$%s" % _format_axis_cost(cost_value), font_size, Color(0.58, 0.60, 0.67))

	for series in SERIES:
		var points := PackedVector2Array()
		var is_cost := bool(series.get("cost", false))
		for i in range(chart_points.size()):
			var point: Dictionary = chart_points[i]
			var value := float(point.get(str(series.get("key", "")), 0.0))
			var x := _point_x(i, plot)
			var max_value := max_cost if is_cost else max_tokens
			var y := plot.end.y - (value / max_value) * plot.size.y
			points.append(Vector2(x, y))
		if points.size() >= 2:
			if is_cost:
				for i in range(points.size() - 1):
					draw_dashed_line(points[i], points[i + 1], series.get("color"), 2.0, 6.0, true)
			else:
				draw_polyline(points, series.get("color"), 2.0, true)
		elif points.size() == 1:
			draw_circle(points[0], 3.0, series.get("color"))

	_draw_x_labels(font, plot, font_size)
	_draw_legend(font, plot, font_size)
	_draw_hover(font, plot, font_size)


func _draw_x_labels(font: Font, plot: Rect2, font_size: int) -> void:
	var max_labels := chart_points.size() if chart_points.size() <= 12 else mini(chart_points.size(), 6)
	if max_labels <= 0:
		return
	for i in range(max_labels):
		var index := 0
		if max_labels > 1:
			index = int(round(float(i) * float(chart_points.size() - 1) / float(max_labels - 1)))
		var point: Dictionary = chart_points[index]
		var label := str(point.get("label", ""))
		var x := _point_x(index, plot)
		_draw_text(font, Vector2(x - 32, plot.end.y + 22), label, font_size, Color(0.58, 0.60, 0.67))


func _draw_legend(font: Font, plot: Rect2, font_size: int) -> void:
	var x := plot.position.x + 10
	var y := plot.end.y + 44
	for series in SERIES:
		var color: Color = series.get("color")
		draw_circle(Vector2(x, y - 4), 4.0, color)
		_draw_text(font, Vector2(x + 8, y), str(series.get("label", "")), font_size, color)
		x += 82


func _draw_hover(font: Font, plot: Rect2, font_size: int) -> void:
	if hover_index < 0 or hover_index >= chart_points.size():
		return
	var point: Dictionary = chart_points[hover_index]
	var x := _point_x(hover_index, plot)
	draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), Color(0.82, 0.84, 0.90, 0.42), 1.0)
	var box_w := 178.0
	var box_h := 118.0
	var box_x := clampf(x + 12, plot.position.x + 4, plot.end.x - box_w - 4)
	var box_y := plot.position.y + 8
	var box := Rect2(box_x, box_y, box_w, box_h)
	draw_rect(box, Color(0.12, 0.125, 0.145, 0.96), true)
	draw_rect(box, Color(0.66, 0.68, 0.75, 0.82), false, 1.0)
	_draw_text(font, box.position + Vector2(10, 18), str(point.get("label", "")), font_size + 1, Color(0.92, 0.93, 0.96))
	var line_y := box.position.y + 39
	for series in SERIES:
		var key := str(series.get("key", ""))
		var value = point.get(key, 0)
		var text := "%s: %s" % [
			str(series.get("label", "")),
			_format_axis_cost(float(value)) if bool(series.get("cost", false)) else _format_int(int(value)),
		]
		_draw_text(font, Vector2(box.position.x + 12, line_y), text, font_size, series.get("color"))
		line_y += 16


func _nearest_point_index(pos: Vector2) -> int:
	if chart_points.is_empty() or size.x <= 0:
		return -1
	var plot := Rect2(58, 18, maxf(size.x - 112.0, 20.0), maxf(size.y - 62.0, 20.0))
	if pos.x < plot.position.x or pos.x > plot.end.x or pos.y < plot.position.y - 8 or pos.y > plot.end.y + 18:
		return -1
	if chart_points.size() == 1:
		return 0
	var ratio := clampf((pos.x - plot.position.x) / plot.size.x, 0.0, 1.0)
	return clampi(int(round(ratio * float(chart_points.size() - 1))), 0, chart_points.size() - 1)


func _point_x(index: int, plot: Rect2) -> float:
	if chart_points.size() <= 1:
		return plot.position.x + plot.size.x * 0.5
	return plot.position.x + plot.size.x * float(index) / float(chart_points.size() - 1)


func _draw_text(font: Font, pos: Vector2, text: String, font_size: int, color: Color) -> void:
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _format_int(value: int) -> String:
	var text := str(value)
	var result := ""
	var count := 0
	for i in range(text.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = "," + result
		result = text.substr(i, 1) + result
		count += 1
	return result


func _format_axis_tokens(value: float) -> String:
	if value >= 1000000.0:
		return "%.1fM" % (value / 1000000.0)
	if value >= 1000.0:
		return "%.0fk" % (value / 1000.0)
	return "%d" % int(round(value))


func _format_axis_cost(value: float) -> String:
	if value >= 10.0:
		return "%.0f" % value
	if value >= 1.0:
		return "%.2f" % value
	return "%.4f" % value
