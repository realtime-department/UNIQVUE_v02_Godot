extends Button
class_name ModuleDragButton
## A palette entry in the layout editor. Starts a native drag carrying the module
## type; the editor canvas accepts the drop onto a slot.

var module_type := ""


func _get_drag_data(_pos: Vector2) -> Variant:
	var prev := Panel.new()
	prev.custom_minimum_size = Vector2(120, 28)
	var lbl := Label.new()
	lbl.text = text
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prev.add_child(lbl)
	set_drag_preview(prev)
	return {"kind": "module", "type": module_type}
