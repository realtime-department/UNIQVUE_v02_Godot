extends Node
## Agenda — Autoload. A rundown of full show-state "cues". Each cue snapshots the LIVE
## state: Style + Background scene + all params (ParamStore.capture, which includes
## style/*) + the slot layout (SlotManager.capture_layout, modules + their state).
##
## Switching to a cue uses the z-transition with the cue's own trans time:
##   - different scene -> BackgroundStage.transition_to(idx, "zoom"), then apply params,
##   - same scene      -> parameter morph (ParamStore.apply_lerp).
## The slot layout is swapped immediately.
##
## Multiple NAMED agendas persist to user://agendas.json. The working rundown starts
## empty each session; load a named agenda to populate it.

signal state_changed       # entries / current index changed -> UI refresh
signal agendas_changed      # named agendas added/removed

const AGENDAS_PATH := "user://agendas.json"
const DEF_TRANS := 1.2

var entries: Array = []        # [{name, trans, scene, params(raw), slots}]
var _idx := -1
var _gen := 0
var _agendas: Dictionary = {}  # name -> {entries:[encoded...]}

var _params: Node
var _stage: Node
var _bgcore: Node
var _ui_layer: CanvasLayer
var _ui: Control


func _ready() -> void:
	_params = get_node_or_null("/root/ParamStore")
	_stage = get_node_or_null("/root/BackgroundStage")
	_bgcore = get_node_or_null("/root/BgCore")
	_load_agendas()
	call_deferred("_post_ready")


func _post_ready() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 103
	_ui_layer.name = "AgendaLayer"
	add_child(_ui_layer)
	var scene: PackedScene = load("res://modules/agenda_ui.tscn")
	if scene != null:
		_ui = scene.instantiate()
		_ui_layer.add_child(_ui)
		_ui.visible = false


# ---------------------------------------------------------------- Rundown API

func current_index() -> int:
	return _idx


func entry_count() -> int:
	return entries.size()


func get_entry(i: int) -> Dictionary:
	if i < 0 or i >= entries.size():
		return {}
	return entries[i]


# Capture the current live state as a new cue.
func add_current(name: String) -> void:
	var nm := name.strip_edges()
	if nm == "":
		nm = "Cue %d" % (entries.size() + 1)
	entries.append({
		"name": nm,
		"trans": DEF_TRANS,
		"scene": _cur_scene(),
		"params": _params.call("capture") if _params else {},
		"slots": SlotManager.capture_layout(),
	})
	state_changed.emit()


# Re-capture the live state into an existing cue (keeps name + trans).
func update_entry(i: int) -> void:
	if i < 0 or i >= entries.size():
		return
	entries[i]["scene"] = _cur_scene()
	entries[i]["params"] = _params.call("capture") if _params else {}
	entries[i]["slots"] = SlotManager.capture_layout()
	state_changed.emit()


func remove_entry(i: int) -> void:
	if i < 0 or i >= entries.size():
		return
	entries.remove_at(i)
	if _idx >= entries.size():
		_idx = entries.size() - 1
	state_changed.emit()


func move_entry(i: int, dir: int) -> void:
	var j := i + dir
	if i < 0 or i >= entries.size() or j < 0 or j >= entries.size():
		return
	var tmp: Variant = entries[i]
	entries[i] = entries[j]
	entries[j] = tmp
	state_changed.emit()


func set_entry_trans(i: int, t: float) -> void:
	if i < 0 or i >= entries.size():
		return
	entries[i]["trans"] = maxf(0.0, t)


func rename_entry(i: int, name: String) -> void:
	if i < 0 or i >= entries.size():
		return
	var nm := name.strip_edges()
	if nm != "":
		entries[i]["name"] = nm
		state_changed.emit()


func clear_entries() -> void:
	entries.clear()
	_idx = -1
	state_changed.emit()


# ---------------------------------------------------------------- Playback

func go_to(i: int) -> void:
	if i < 0 or i >= entries.size():
		return
	_gen += 1
	var gen := _gen
	var e: Dictionary = entries[i]
	var scene := str(e.get("scene", ""))
	var params: Dictionary = e.get("params", {})
	var trans := maxf(0.0, float(e.get("trans", DEF_TRANS)))

	var switching := _stage != null and scene != "" and scene != _cur_scene()
	var idx := -1
	if switching:
		idx = int(_stage.call("scene_index_for_key", scene))
		switching = idx >= 0

	# Capture the CURRENT state as the morph start, BEFORE kicking off the bg transition.
	var a: Dictionary = _params.call("capture") if _params != null else {}
	if switching and trans > 0.0:
		_stage.set("transition_time", trans)
	if switching:
		_stage.call("transition_to", idx, "zoom")

	# Morph CONCURRENTLY with the background transition, split in two so each gets its
	# own pacing (disjoint key sets -> no conflict when applied):
	#   - style/*  : keep the bg trans timing, linear (the look the user already likes),
	#   - the rest : auto-estimated, eased duration so parameter sweeps feel smooth.
	var style_a := _filter(a, true)
	var style_b := _filter(params, true)
	var rest_a := _filter(a, false)
	var rest_b := _filter(params, false)
	_run_morph(style_a, style_b, trans, gen, false)
	_run_param_morph(rest_a, rest_b, gen)

	# Slots load only once the background is FULLY swapped in (after active_changed),
	# then fade in for a smooth reveal.
	if switching:
		await _wait_active(gen, trans)
		if gen != _gen:
			return
		await get_tree().process_frame
	if gen != _gen:
		return
	SlotManager.apply_layout(e.get("slots", []))
	_idx = i
	state_changed.emit()


func next() -> void:
	if entries.is_empty():
		return
	go_to((_idx + 1) % entries.size())


func prev() -> void:
	if entries.is_empty():
		return
	go_to((_idx - 1 + entries.size()) % entries.size())


func _run_morph(a: Dictionary, b: Dictionary, dur: float, gen: int, eased: bool) -> void:
	if _params == null or b.is_empty():
		return
	if dur <= 0.0:
		_params.call("apply", b)
		return
	var t := 0.0
	while t < dur:
		await get_tree().process_frame
		if gen != _gen:
			return
		t += get_process_delta_time()
		var x := minf(t / dur, 1.0)
		if eased:
			x = _ease_io(x)
		_params.call("apply_lerp", a, b, x)
	if gen == _gen:
		_params.call("apply", b)


# Cubic in-out easing for smooth parameter sweeps.
func _ease_io(x: float) -> float:
	if x < 0.5:
		return 4.0 * x * x * x
	return 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0


# Split a snapshot into style/* (keep_style=true) or everything else (false).
func _filter(snap: Dictionary, keep_style: bool) -> Dictionary:
	var out := {}
	for k in snap:
		var is_style := str(k).begins_with("style/")
		if is_style == keep_style:
			out[k] = snap[k]
	return out


# Per-parameter morph: each key interpolates over its OWN estimated duration (bigger
# change -> longer), all starting together. Loop runs until the slowest key finishes;
# faster keys hold at target once done.
func _run_param_morph(a: Dictionary, b: Dictionary, gen: int) -> void:
	if _params == null or b.is_empty():
		return
	var durs := {}
	var maxd := 0.0
	for k in b:
		if a.has(k):
			var d := _estimate_key_time(a[k], b[k])
			durs[k] = d
			maxd = maxf(maxd, d)
	if maxd <= 0.0:
		_params.call("apply", b)
		return
	var t := 0.0
	while t < maxd:
		await get_tree().process_frame
		if gen != _gen:
			return
		t += get_process_delta_time()
		var out := {}
		for k in b:
			if a.has(k):
				var dk: float = durs.get(k, maxd)
				var xk := 1.0 if dk <= 0.0 else minf(t / dk, 1.0)
				var one: Dictionary = _params.call("lerp_values", {k: a[k]}, {k: b[k]}, _ease_io(xk))
				out[k] = one[k]
			else:
				out[k] = b[k]   # incoming scene-specific key: snap to target
		_params.call("apply", out)
	if gen == _gen:
		_params.call("apply", b)


# Estimate one parameter's transition time from its normalized change magnitude.
# e.g. 0.1 -> 4 (delta ~0.95) is much longer than 0.1 -> 0.2 (delta ~0.33).
func _estimate_key_time(a, b) -> float:
	var d := _norm_delta(a, b)
	if d <= 0.001:
		return 0.0
	return clampf(0.8 + d * 4.0, 0.8, 6.0)


# Normalized 0..1-ish change magnitude per value type.
func _norm_delta(a, b) -> float:
	if a is bool or b is bool:
		return 1.0 if a != b else 0.0
	if a is Color and b is Color:
		return clampf(Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() / 1.732, 0.0, 1.0)
	if a is Vector3 and b is Vector3:
		return clampf((a - b).length() / (a.length() + b.length() + 0.0001), 0.0, 1.0)
	if a is Vector2 and b is Vector2:
		return clampf((a - b).length() / (a.length() + b.length() + 0.0001), 0.0, 1.0)
	if (a is float or a is int) and (b is float or b is int):
		var fa := float(a)
		var fb := float(b)
		return clampf(absf(fa - fb) / (absf(fa) + absf(fb) + 0.0001), 0.0, 1.0)
	return 0.0


func _wait_active(gen: int, trans: float) -> void:
	if _stage == null:
		return
	var done := {"v": false}
	var cb := func(_n: Node) -> void: done.v = true
	_stage.connect("active_changed", cb, CONNECT_ONE_SHOT)
	var t := 0.0
	while not done.v and t < maxf(trans + 2.0, 5.0) and gen == _gen:
		await get_tree().process_frame
		t += get_process_delta_time()
	if not done.v and _stage.is_connected("active_changed", cb):
		_stage.disconnect("active_changed", cb)


func _cur_scene() -> String:
	return str(_params.call("active_scene_key")) if _params != null else ""


# ---------------------------------------------------------------- Named agendas

func list_agendas() -> Array:
	var names := _agendas.keys()
	names.sort()
	return names


func save_agenda(name: String) -> void:
	var nm := name.strip_edges()
	if nm == "":
		return
	var enc: Array = []
	for e in entries:
		enc.append({
			"name": e.get("name", ""),
			"trans": e.get("trans", DEF_TRANS),
			"scene": e.get("scene", ""),
			"params": _bgcore.call("encode_snapshot", e.get("params", {})) if _bgcore else {},
			"slots": e.get("slots", []),
		})
	_agendas[nm] = {"entries": enc}
	_save_agendas()
	agendas_changed.emit()


func load_agenda(name: String) -> void:
	if not _agendas.has(name):
		return
	entries.clear()
	_idx = -1
	for item in _agendas[name].get("entries", []):
		entries.append({
			"name": str(item.get("name", "Cue")),
			"trans": float(item.get("trans", DEF_TRANS)),
			"scene": str(item.get("scene", "")),
			"params": _bgcore.call("decode_snapshot", item.get("params", {})) if _bgcore else {},
			"slots": item.get("slots", []),
		})
	state_changed.emit()


func delete_agenda(name: String) -> void:
	if _agendas.has(name):
		_agendas.erase(name)
		_save_agendas()
		agendas_changed.emit()


func _save_agendas() -> void:
	var f := FileAccess.open(AGENDAS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"agendas": _agendas}))
	f.close()


func _load_agendas() -> void:
	if not FileAccess.file_exists(AGENDAS_PATH):
		return
	var f := FileAccess.open(AGENDAS_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("agendas"):
		_agendas = parsed["agendas"]


# ---------------------------------------------------------------- UI toggle (A)

func toggle_ui() -> void:
	if _ui == null:
		return
	_ui.visible = not _ui.visible
	if _ui.visible and _ui.has_method("on_opened"):
		_ui.on_opened()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_A:
			var fo := get_viewport().gui_get_focus_owner()
			if fo is LineEdit or fo is TextEdit or fo is SpinBox:
				return  # typing, don't hijack 'a'
			toggle_ui()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _ui != null and _ui.visible:
			_ui.visible = false
			get_viewport().set_input_as_handled()
