class_name UsageStatsPage
extends VBoxContainer


signal refresh_requested
signal filter_changed
signal add_pricing_requested
signal edit_pricing_requested
signal delete_pricing_requested
signal reset_pricing_requested

@onready var source_option: OptionButton = %UsageSourceOption
@onready var model_option: OptionButton = %UsageModelOption
@onready var range_picker = %UsageRangePicker
@onready var total_tokens_label: Label = %UsageTotalTokensLabel
@onready var total_tokens_hint_label: Label = %UsageTotalTokensHintLabel
@onready var requests_label: Label = %UsageRequestsLabel
@onready var cost_label: Label = %UsageCostLabel
@onready var input_label: Label = %UsageInputLabel
@onready var output_label: Label = %UsageOutputLabel
@onready var cache_creation_label: Label = %UsageCacheCreationLabel
@onready var cache_read_label: Label = %UsageCacheReadLabel
@onready var hit_rate_label: Label = %UsageHitRateLabel
@onready var hit_rate_bar: ProgressBar = %UsageHitRateBar
@onready var chart = %UsageChart
@onready var pricing_tree: Tree = %UsagePricingTree
@onready var refresh_button: Button = %UsageRefreshButton
@onready var add_price_button: Button = %AddPriceButton
@onready var edit_price_button: Button = %EditPriceButton
@onready var delete_price_button: Button = %DeletePriceButton
@onready var reset_price_button: Button = %ResetPriceButton


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)

	source_option.item_selected.connect(func(_index: int) -> void: filter_changed.emit())
	model_option.item_selected.connect(func(_index: int) -> void: filter_changed.emit())
	range_picker.selection_changed.connect(func() -> void: filter_changed.emit())

	refresh_button.pressed.connect(func() -> void: refresh_requested.emit())
	add_price_button.pressed.connect(func() -> void: add_pricing_requested.emit())
	edit_price_button.pressed.connect(func() -> void: edit_pricing_requested.emit())
	delete_price_button.pressed.connect(func() -> void: delete_pricing_requested.emit())
	reset_price_button.pressed.connect(func() -> void: reset_pricing_requested.emit())

	_configure_pricing_tree()
	pricing_tree.item_activated.connect(func() -> void: edit_pricing_requested.emit())

	hit_rate_bar.min_value = 0
	hit_rate_bar.max_value = 100
	hit_rate_bar.show_percentage = false
	hit_rate_bar.add_theme_stylebox_override("background", _style("#2a2b31", "#2a2b31", 4))
	hit_rate_bar.add_theme_stylebox_override("fill", _style("#10b981", "#10b981", 4))


func selected_source() -> String:
	return _selected_option_value(source_option, "all")


func selected_model() -> String:
	return _selected_option_value(model_option, "all")


func selected_range() -> String:
	return range_picker.selected_preset()


func selected_range_selection() -> Dictionary:
	return range_picker.selection_data()


func selected_range_bounds() -> Dictionary:
	return range_picker.resolve_selection()


func populate_filter_options(raw_sources: Array, raw_models: Array) -> void:
	var selected_source_value := selected_source()
	var selected_model_value := selected_model()
	_populate_option(source_option, "全部来源", "all", raw_sources, selected_source_value)
	_populate_option(model_option, "全部模型", "all", raw_models, selected_model_value)


func set_summary_values(
	total_tokens: String,
	total_tokens_hint: String,
	requests: String,
	cost: String,
	input_tokens: String,
	output_tokens: String,
	cache_creation: String,
	cache_read: String,
	hit_rate: String,
	hit_percent: float
) -> void:
	total_tokens_label.text = total_tokens
	total_tokens_hint_label.text = total_tokens_hint
	requests_label.text = requests
	cost_label.text = cost
	input_label.text = input_tokens
	output_label.text = output_tokens
	cache_creation_label.text = cache_creation
	cache_read_label.text = cache_read
	hit_rate_label.text = hit_rate
	hit_rate_bar.value = hit_percent


func set_trend_points(points: Array) -> void:
	chart.set_points(points)


func render_pricing_rows(rows: Array) -> void:
	pricing_tree.clear()
	var root := pricing_tree.create_item()
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var item := pricing_tree.create_item(root)
		item.set_metadata(0, str(row.get("model", "")))
		item.set_text(0, str(row.get("model", "")))
		item.set_text(1, str(row.get("display_name", "")))
		item.set_text(2, str(row.get("input", "")))
		item.set_text(3, str(row.get("output", "")))
		item.set_text(4, str(row.get("cache_read", "")))
		item.set_text(5, str(row.get("cache_creation", "")))
		item.set_text(6, str(row.get("requests", "")))
		item.set_text(7, str(row.get("cost", "")))


func selected_pricing_model() -> String:
	if pricing_tree == null:
		return ""
	var item := pricing_tree.get_selected()
	if item == null:
		return ""
	return str(item.get_metadata(0))


func _configure_pricing_tree() -> void:
	var titles := ["模型", "显示名称", "输入成本", "输出成本", "缓存命中", "缓存创建", "请求数", "总成本"]
	var widths := [190, 160, 86, 86, 86, 86, 72, 96]
	pricing_tree.columns = 8
	pricing_tree.hide_root = true
	pricing_tree.set_column_titles_visible(true)
	for i in range(titles.size()):
		pricing_tree.set_column_title(i, titles[i])
		pricing_tree.set_column_custom_minimum_width(i, widths[i])


func _populate_option(option: OptionButton, all_label: String, all_value: String, raw_values: Array, selected_value: String) -> void:
	if option == null:
		return
	var values: Array[String] = []
	for value in raw_values:
		var text := str(value).strip_edges()
		if text != "":
			values.append(text)
	values.sort()
	option.clear()
	option.add_item(all_label)
	option.set_item_metadata(0, all_value)
	var selected_index := 0
	for value in values:
		option.add_item(value)
		var index := option.item_count - 1
		option.set_item_metadata(index, value)
		if value == selected_value:
			selected_index = index
	option.select(selected_index)


func _selected_option_value(option: OptionButton, fallback: String = "all") -> String:
	if option == null or option.item_count <= 0:
		return fallback
	var value = option.get_item_metadata(option.selected)
	if value == null:
		return fallback
	return str(value)


func _style(background: String, border: String, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.html(background)
	style.border_color = Color.html(border)
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style
