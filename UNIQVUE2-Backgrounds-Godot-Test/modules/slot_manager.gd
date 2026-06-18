extends Node
## SlotManager — Autoload. Single source of truth for the slot layout.
##
## A "slot" is a rectangle in NORMALIZED WALL SPACE (0..1 across the full virtual
## wall = DisplaySetup.cols*screen_w by rows*screen_h). Runtime maps each slot to a
## pixel rect on a CanvasLayer (z=50) that overlays the background, and hosts the
## assigned module there (scaled to fill the slot). Overlap allowed.
##
## Monitors = the DisplaySetup virtual grid cells (a mosaic of N physical screens is
## one OS display but N grid cells). The editor uses that grid to let you edit/zoom
## per monitor; presets divide the whole wall as one canvas.
##
## To raise the slot cap, change ONE number: MAX_SLOTS.

const MAX_SLOTS := 64

# Registry of placeable module types. Add an entry to expose a new module in the UI.
const MODULE_REGISTRY := {
	"slideshow": {
		"name": "Slideshow",
		"scene": "res://modules/slideshow/slideshow_module.tscn",
		"color": Color(0.12, 0.43, 1.0),
	},
}

# Built-in split presets, expressed as a [cols, rows] grid over the WHOLE wall.
const PRESET_GRIDS := {
	"Full": [1, 1],
	"2x1": [2, 1],
	"1x2": [1, 2],
	"2x2": [2, 2],
	"1x3": [1, 3],
	"3x1": [3, 1],
}
const PRESET_ORDER := ["Full", "2x1", "1x2", "2x2", "1x3", "3x1"]

# Saved layout PRESETS (named, loadable like style/param presets). The LIVE layout is
# intentionally NOT persisted — slots start empty every session, ids reset to 1.
const LAYOUTS_PATH := "user://slot_layouts.json"
const EDITOR_SCENE := "res://modules/slot_layout_editor.tscn"
const SlotNodeScript := preload("res://modules/slot_node.gd")

# Slideshow state keys captured per slot (incl. the live slide "index" so a snapshot on
# slide 3 restores slide 3, not slide 1).
const STATE_KEYS := ["mode", "fit", "transition", "transition_time", "auto_run",
	"auto_run_seconds", "loop", "slide_count", "show_nav", "show_pagination", "index"]
const MIN_SLOT_NORM := 0.03  # smallest slot edge in normalized wall units

# slots: Array of { id:int, rect:Rect2 (normalized), module:String }
var slots: Array = []
var _next_id := 1

var _layer: CanvasLayer          # runtime overlay (z=50)
var _nodes: Dictionary = {}      # id -> SlotNode
var _editor_layer: CanvasLayer   # editor overlay (z=101)
var _editor: Control

var _layouts: Dictionary = {}    # name -> {slots:[...]} (persisted presets)

signal slots_changed()           # data changed (add/remove/assign); UI rebuilds
signal slot_rect_changed(id: int) # a single slot's rect moved/resized (live drag)
signal layouts_changed()         # saved layout presets added/removed


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 50
	_layer.name = "SlotRuntimeLayer"
	add_child(_layer)

	_load_layouts()
	# Live layout starts empty each session (no persistence).
	call_deferred("_post_ready")


func _post_ready() -> void:
	# Window + stage hooks for proportional reflow.
	var win := get_window()
	if win and not win.size_changed.is_connected(_reflow):
		win.size_changed.connect(_reflow)
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage and stage.has_signal("aspect_changed") and not stage.is_connected("aspect_changed", _on_aspect_changed):
		stage.connect("aspect_changed", _on_aspect_changed)

	_rebuild_nodes()
	_instantiate_editor()


func _on_aspect_changed(_a: float) -> void:
	_reflow()


# ---------------------------------------------------------------- Public data API

func get_slots() -> Array:
	return slots


func find_slot(id: int) -> Dictionary:
	for s in slots:
		if s.id == id:
			return s
	return {}


func can_add() -> bool:
	return slots.size() < MAX_SLOTS


func add_slot(rect: Rect2, module: String = "", state: Dictionary = {}) -> int:
	if not can_add():
		return -1
	var id := _next_id
	_next_id += 1
	slots.append({"id": id, "rect": _sanitize_rect(rect), "module": module, "state": state})
	_spawn_node(slots[-1])
	emit_signal("slots_changed")
	return id


func remove_slot(id: int) -> void:
	for i in range(slots.size()):
		if slots[i].id == id:
			slots.remove_at(i)
			break
	if _nodes.has(id):
		var n = _nodes[id]
		if is_instance_valid(n):
			n.queue_free()
		_nodes.erase(id)
	if slots.is_empty():
		_next_id = 1
	emit_signal("slots_changed")


func clear_slots() -> void:
	for id in _nodes.keys():
		var n = _nodes[id]
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	slots.clear()
	_next_id = 1  # session-wise count; reset when emptied
	emit_signal("slots_changed")


# Live update during drag. persist=false avoids disk writes per mouse-move;
# the editor calls commit() (persist) on drag release.
func set_slot_rect(id: int, rect: Rect2, persist: bool = false) -> void:
	var s := find_slot(id)
	if s.is_empty():
		return
	s.rect = _sanitize_rect(rect)
	_reflow_one(id)
	emit_signal("slot_rect_changed", id)


func assign_module(id: int, type: String) -> void:
	var s := find_slot(id)
	if s.is_empty():
		return
	s.module = type
	if _nodes.has(id):
		_nodes[id].set_module(type)
		_apply_state(_nodes[id].get_module(), s.get("state", {}))
	emit_signal("slots_changed")


func apply_preset(name: String) -> void:
	var grid = PRESET_GRIDS.get(name, null)
	if grid == null:
		return
	var cols: int = grid[0]
	var rows: int = grid[1]
	clear_slots()
	var cw := 1.0 / float(cols)
	var ch := 1.0 / float(rows)
	for r in range(rows):
		for c in range(cols):
			if not can_add():
				break
			add_slot(Rect2(c * cw, r * ch, cw, ch))


func commit() -> void:
	pass  # live layout is not persisted; saved only via named layout presets


# ---------------------------------------------------------------- Runtime nodes

func _rebuild_nodes() -> void:
	for id in _nodes.keys():
		var n = _nodes[id]
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	for s in slots:
		_spawn_node(s)


func _spawn_node(s: Dictionary) -> void:
	var node := SlotNodeScript.new()
	node.slot_id = s.id
	_layer.add_child(node)
	_nodes[s.id] = node
	node.set_module(s.module)
	_apply_state(node.get_module(), s.get("state", {}))
	_reflow_one(s.id)


func _apply_state(module, st) -> void:
	if module == null or typeof(st) != TYPE_DICTIONARY or st.is_empty():
		return
	for k in STATE_KEYS:
		if st.has(k):
			module.state[k] = st[k]
	if st.has("mode"):
		module.set_mode(st.mode)
	# Land on the captured slide statically (no leftover transition from old indices).
	if st.has("index"):
		module.state["from_index"] = module.state["index"]
		module.state["t"] = 1.0
		module.state["auto_timer"] = 0.0


# Called by the settings panel after an edit. Snapshots the persisted subset.
func persist_slot_state(id: int, state) -> void:
	var s := find_slot(id)
	if s.is_empty():
		return
	var snap := {}
	for k in STATE_KEYS:
		if state.has(k):
			snap[k] = state[k]
	s["state"] = snap


func _wall_pixel_size() -> Vector2:
	var win := get_window()
	if win == null:
		return Vector2(1920, 1080)
	return Vector2(win.size)


# Physical monitors mapped into the app window (= the wall surface), normalized 0..1.
# Uses real OS displays (DisplayServer), NEVER the virtual DisplaySetup grid.
# In SPAN mode the window covers the union of all screens, so each cell is the exact
# screen slice. Returns [{ index:int, rect:Rect2 (normalized), px:Vector2i }].
func monitor_cells() -> Array:
	var cells: Array = []
	var win := get_window()
	if win == null:
		return cells
	var wpos := Vector2(win.position)
	var wsize := Vector2(win.size)
	if wsize.x <= 0 or wsize.y <= 0:
		return cells
	var n := DisplayServer.get_screen_count()
	for i in range(n):
		var sp := Vector2(DisplayServer.screen_get_position(i))
		var ss := Vector2(DisplayServer.screen_get_size(i))
		cells.append({
			"index": i,
			"rect": Rect2((sp - wpos) / wsize, ss / wsize),
			"px": DisplayServer.screen_get_size(i),
		})
	return cells


func _reflow() -> void:
	for s in slots:
		_reflow_one(s.id)


func _reflow_one(id: int) -> void:
	if not _nodes.has(id):
		return
	var node = _nodes[id]
	if not is_instance_valid(node):
		return
	var s := find_slot(id)
	if s.is_empty():
		return
	var px := _wall_pixel_size()
	var r: Rect2 = s.rect
	node.position = Vector2(r.position.x * px.x, r.position.y * px.y)
	node.size = Vector2(maxf(1.0, r.size.x * px.x), maxf(1.0, r.size.y * px.y))


# ---------------------------------------------------------------- Editor (F2)

func _instantiate_editor() -> void:
	_editor_layer = CanvasLayer.new()
	_editor_layer.layer = 101
	_editor_layer.name = "SlotEditorLayer"
	add_child(_editor_layer)
	var scene: PackedScene = load(EDITOR_SCENE)
	if scene == null:
		push_warning("SlotManager: editor scene missing")
		return
	_editor = scene.instantiate()
	_editor_layer.add_child(_editor)
	_editor.visible = false


func get_module(id: int) -> Node:
	if _nodes.has(id) and is_instance_valid(_nodes[id]):
		return _nodes[id].get_module()
	return null


func toggle_editor() -> void:
	if _editor == null:
		return
	_editor.visible = not _editor.visible
	if _editor.visible and _editor.has_method("on_opened"):
		_editor.on_opened()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F2:
			toggle_editor()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _editor != null and _editor.visible:
			_editor.visible = false
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- Helpers / IO

func _sanitize_rect(r: Rect2) -> Rect2:
	var w := clampf(r.size.x, MIN_SLOT_NORM, 1.0)
	var h := clampf(r.size.y, MIN_SLOT_NORM, 1.0)
	var x := clampf(r.position.x, 0.0, 1.0 - w)
	var y := clampf(r.position.y, 0.0, 1.0 - h)
	return Rect2(x, y, w, h)


# ---------------------------------------------------------------- Layout snapshots

# In-memory snapshot of the live layout (rect + module + per-slot state). Used by
# layout presets and by the Agenda (which embeds it in a cue).
func capture_layout() -> Array:
	var arr: Array = []
	for s in slots:
		# Prefer the LIVE module state (current slide index, mode, etc.) over the stored
		# subset so a snapshot reflects exactly what's on screen right now.
		var st: Dictionary = (s.get("state", {}) as Dictionary).duplicate(true)
		if _nodes.has(s.id) and is_instance_valid(_nodes[s.id]):
			var m = _nodes[s.id].get_module()
			if m != null and "state" in m:
				for k in STATE_KEYS:
					if m.state.has(k):
						st[k] = m.state[k]
		arr.append({
			"rect": [s.rect.position.x, s.rect.position.y, s.rect.size.x, s.rect.size.y],
			"module": s.module,
			"state": st,
		})
	return arr


func apply_layout(arr) -> void:
	clear_slots()
	if typeof(arr) != TYPE_ARRAY:
		return
	for item in arr:
		if not can_add():
			break
		var ra = item.get("rect", [0, 0, 0.5, 0.5])
		add_slot(_sanitize_rect(Rect2(ra[0], ra[1], ra[2], ra[3])),
			String(item.get("module", "")), (item.get("state", {}) as Dictionary).duplicate(true))


# ---------------------------------------------------------------- Layout presets

func list_layouts() -> Array:
	var names := _layouts.keys()
	names.sort()
	return names


# Snapshot the current live layout under a name (overwrites). Saved to disk.
func save_layout(name: String) -> void:
	name = name.strip_edges()
	if name == "":
		return
	_layouts[name] = {"slots": capture_layout()}
	_save_layouts()
	emit_signal("layouts_changed")


# Replace the live layout with a saved preset (fresh session-wise ids).
func load_layout(name: String) -> void:
	if not _layouts.has(name):
		return
	apply_layout(_layouts[name].get("slots", []))


func delete_layout(name: String) -> void:
	if _layouts.has(name):
		_layouts.erase(name)
		_save_layouts()
		emit_signal("layouts_changed")


func _save_layouts() -> void:
	var f := FileAccess.open(LAYOUTS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"layouts": _layouts}))
	f.close()


func _load_layouts() -> void:
	if not FileAccess.file_exists(LAYOUTS_PATH):
		return
	var f := FileAccess.open(LAYOUTS_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("layouts"):
		_layouts = parsed["layouts"]
