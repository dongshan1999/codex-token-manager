class_name UsagePricingDialog
extends ConfirmationDialog


@onready var model_edit: LineEdit = %UsagePricingModelEdit
@onready var display_edit: LineEdit = %UsagePricingDisplayEdit
@onready var input_edit: LineEdit = %UsagePricingInputEdit
@onready var output_edit: LineEdit = %UsagePricingOutputEdit
@onready var cache_read_edit: LineEdit = %UsagePricingCacheReadEdit
@onready var cache_creation_edit: LineEdit = %UsagePricingCacheCreationEdit


func show_pricing(model_id: String, pricing: Dictionary) -> void:
	model_edit.text = model_id
	display_edit.text = str(pricing.get("display_name", model_id))
	input_edit.text = str(pricing.get("input", 0.0))
	output_edit.text = str(pricing.get("output", 0.0))
	cache_read_edit.text = str(pricing.get("cache_read", 0.0))
	cache_creation_edit.text = str(pricing.get("cache_creation", 0.0))
	if model_id == "":
		display_edit.text = ""
	popup_centered(Vector2i(520, 320))


func values() -> Dictionary:
	return {
		"model_id": model_edit.text,
		"display_name": display_edit.text,
		"input": input_edit.text,
		"output": output_edit.text,
		"cache_read": cache_read_edit.text,
		"cache_creation": cache_creation_edit.text,
	}
