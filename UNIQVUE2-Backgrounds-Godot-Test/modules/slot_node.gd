extends Control
class_name SlotNode
## Runtime host for one slot. Sits on the SlotManager CanvasLayer (z=50) at the
## pixel rect that corresponds to the slot's normalized wall rect. Hosts the assigned
## module inside a SubViewportContainer so the module renders scaled to the slot.
## A small gear button (top-right) opens the floating settings for this slot.
## Empty slot (no module) is hidden — never draws anything.

var slot_id: int = 0
var module_type: String = ""

var _container: SubViewportContainer
var _module: Node = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container = SubViewportContainer.new()
	_container.stretch = true
	# STOP so the container forwards mouse events into the SubViewport (overlay nav).
	_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_container)


func get_module() -> Node:
	return _module


## Assign (or clear with "") the module shown in this slot.
func set_module(type: String) -> void:
	if type == module_type and _module != null:
		return
	module_type = type
	if _module != null and is_instance_valid(_module):
		_module.queue_free()
		_module = null
	if type == "":
		visible = false
		return
	var info = SlotManager.MODULE_REGISTRY.get(type, null)
	if info == null:
		push_warning("SlotNode: unknown module type '%s'" % type)
		visible = false
		return
	var scene: PackedScene = load(info.scene)
	if scene == null:
		push_warning("SlotNode: failed to load scene for '%s'" % type)
		visible = false
		return
	_module = scene.instantiate()
	# Per-slot id so each slideshow keeps its own image pool / state.
	if "instance_id" in _module:
		_module.instance_id = str(slot_id)
	_container.add_child(_module)
	visible = true
	# Smooth reveal: fade the slot in.
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.35)
