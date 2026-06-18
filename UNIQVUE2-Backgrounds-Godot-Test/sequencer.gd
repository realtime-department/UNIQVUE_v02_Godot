extends Node
## S4: Sequencer (Autoload) — Preset playlist + Playback.
##
## A playlist is an ordered list of steps:
##   {preset: String, hold: float (s), trans: float (s)}
## play() loops through the list. Per step: hold for 'hold' seconds,
## then blend to the NEXT step over 'trans' seconds —
##   - same scene    -> parameter morph (ParamStore.apply_lerp A->B),
##   - different scene -> the existing zoom transition (BackgroundStage.transition_to),
##                        then preset values are applied to the new scene.
##
## Abort/restart use a generation counter `_gen`: each new operation
## (play/stop/next) increments it; a running coroutine aborts once its
## captured generation is no longer current. `_playing` is pure UI display.
##
## The playlist is persisted as JSON to `user://sequence.json` (steps are
## plain string/float values, no type tagging needed) and loaded on startup.

signal state_changed   # playing/idx/list changed -> UI updates itself

const SEQ_PATH := "user://sequence.json"
const DEF_HOLD := 3.0
const DEF_TRANS := 1.2
const VALID_STEP_KEYS := ["preset", "hold", "trans", "mode"]

var _params: Node   # ParamStore
var _stage: Node    # BackgroundStage
var _core: Node     # BgCore

var _steps: Array = []   # [{preset, hold, trans}]
var _idx := 0
var _playing := false
var _gen := 0            # incremented on play/stop/next -> aborts old coroutines


func _ready() -> void:
	_params = get_node_or_null("/root/ParamStore")
	_stage = get_node_or_null("/root/BackgroundStage")
	_core = get_node_or_null("/root/BgCore")
	_load()


# --------------------------------------------------------------- Playlist API

func step_count() -> int:
	return _steps.size()


func current_index() -> int:
	return _idx


func is_playing() -> bool:
	return _playing


func get_step(i: int) -> Dictionary:
	if i < 0 or i >= _steps.size():
		return {}
	return _steps[i]


func add_step(preset: String, hold: float, trans: float, mode: String = "zoom") -> void:
	_steps.append({"preset": preset, "hold": hold, "trans": trans, "mode": mode})
	_save()
	state_changed.emit()


func remove_step(i: int) -> void:
	if i < 0 or i >= _steps.size():
		return
	_steps.remove_at(i)
	if _idx >= _steps.size():
		_idx = maxi(0, _steps.size() - 1)
	_save()
	state_changed.emit()


func move_step(i: int, dir: int) -> void:
	var j := i + dir
	if i < 0 or i >= _steps.size() or j < 0 or j >= _steps.size():
		return
	var tmp: Variant = _steps[i]
	_steps[i] = _steps[j]
	_steps[j] = tmp
	_save()
	state_changed.emit()


func set_step_value(i: int, key: String, value: Variant) -> void:
	if i < 0 or i >= _steps.size():
		return
	if key not in VALID_STEP_KEYS:
		push_warning("sequencer: unknown step key '%s'" % key)
		return
	_steps[i][key] = value
	_save()


func clear() -> void:
	_steps.clear()
	_idx = 0
	_save()
	state_changed.emit()


# --------------------------------------------------------------- Transport

func play() -> void:
	if _steps.is_empty():
		return
	_gen += 1
	var gen := _gen
	_playing = true
	state_changed.emit()
	_run(gen)


func stop() -> void:
	_playing = false
	_gen += 1   # running coroutine aborts on next check
	state_changed.emit()


## Manually advance one step (also while stopped): blends to the next preset.
func next() -> void:
	if _steps.is_empty():
		return
	var was_playing := _playing
	_gen += 1
	var gen := _gen
	_playing = false
	var nxt := (_idx + 1) % _steps.size()
	var trans := maxf(0.0, float(_steps[nxt].get("trans", DEF_TRANS)))
	await _go_to(nxt, trans, gen)
	if gen != _gen:
		return
	_idx = nxt
	if was_playing:
		_playing = true
		_run(_gen)
	state_changed.emit()


## Manually go back one step.
func prev() -> void:
	if _steps.is_empty():
		return
	var was_playing := _playing
	_gen += 1
	var gen := _gen
	_playing = false
	var prv := (_idx - 1 + _steps.size()) % _steps.size()
	var trans := maxf(0.0, float(_steps[prv].get("trans", DEF_TRANS)))
	await _go_to(prv, trans, gen)
	if gen != _gen:
		return
	_idx = prv
	if was_playing:
		_playing = true
		_run(_gen)
	state_changed.emit()


# --------------------------------------------------------------- Playback coroutine

func _run(gen: int) -> void:
	state_changed.emit()
	await _apply_step(_idx, gen)   # set start step immediately (no morph)
	while gen == _gen:
		var hold := maxf(0.0, float(_steps[_idx].get("hold", 0.0)))
		await _wait(hold, gen)
		if gen != _gen:
			return
		var nxt := (_idx + 1) % _steps.size()
		var trans := maxf(0.0, float(_steps[_idx].get("trans", 0.0)))
		await _go_to(nxt, trans, gen)
		if gen != _gen:
			return
		_idx = nxt
		state_changed.emit()


func _wait(seconds: float, gen: int) -> void:
	if seconds <= 0.0:
		return
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		if gen != _gen:
			return
		t += get_process_delta_time()


# Apply step i immediately (no morph) — for the start step.
func _apply_step(i: int, gen: int) -> void:
	var doc := _read(i)
	if doc.is_empty():
		return
	await _ensure_scene(str(doc.get("scene", "")), 0.0, gen)
	if gen != _gen:
		return
	if _params != null:
		_params.call("apply", doc.get("params", {}))


# Blend from current stage to step nxt (scene switch OR morph).
func _go_to(nxt: int, trans: float, gen: int) -> void:
	var doc := _read(nxt)
	if doc.is_empty():
		return
	var scene_key := str(doc.get("scene", ""))
	var snap: Dictionary = doc.get("params", {})
	var mode := str(_steps[nxt].get("mode", "zoom")) if nxt < _steps.size() else "zoom"
	if scene_key != "" and scene_key != _cur_scene():
		# Different scene: transition (zoom or cross), then apply preset values.
		await _ensure_scene(scene_key, trans, gen, mode)
		if gen != _gen:
			return
		if _params != null:
			_params.call("apply", snap)
	else:
		# Same scene: parameter morph A->B.
		await _morph(snap, trans, gen)


func _morph(b: Dictionary, trans: float, gen: int) -> void:
	if _params == null:
		return
	if trans <= 0.0:
		_params.call("apply", b)
		return
	var a: Dictionary = _params.call("capture")
	var t := 0.0
	while t < trans:
		await get_tree().process_frame
		if gen != _gen:
			return
		t += get_process_delta_time()
		_params.call("apply_lerp", a, b, minf(t / trans, 1.0))
	_params.call("apply", b)   # snap exactly to target


# Ensure the scene tagged in the preset is active.
func _ensure_scene(scene_key: String, trans: float, gen: int, mode: String = "zoom") -> void:
	if scene_key == "" or _stage == null:
		return
	if _cur_scene() == scene_key:
		return
	var idx: int = _stage.call("scene_index_for_key", scene_key)
	if idx < 0:
		return
	if trans > 0.0:
		_stage.set("transition_time", trans)
	_stage.call("transition_to", idx, mode)
	# Timeout-guard: active_changed may never fire if stage is busy at call time.
	var _done := false
	var _cb := func(_n: Node) -> void: _done = true
	_stage.connect("active_changed", _cb, CONNECT_ONE_SHOT)
	var _t := 0.0
	while not _done and _t < maxf(trans + 2.0, 5.0) and gen == _gen:
		await get_tree().process_frame
		_t += get_process_delta_time()
	if not _done and _stage.is_connected("active_changed", _cb):
		_stage.disconnect("active_changed", _cb)
	if gen != _gen:
		return
	# One frame so ParamStore has rebuilt its register for the new scene
	# before we apply the preset values.
	await get_tree().process_frame


func _cur_scene() -> String:
	return str(_params.call("active_scene_key")) if _params != null else ""


func _read(i: int) -> Dictionary:
	if _core == null or i < 0 or i >= _steps.size():
		return {}
	return _core.call("read_doc", str(_steps[i].get("preset", "")))


# --------------------------------------------------------------- Persistence

func _save() -> void:
	var f := FileAccess.open(SEQ_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_steps, "\t"))
	f.close()


func _load() -> void:
	if not FileAccess.file_exists(SEQ_PATH):
		return
	var f := FileAccess.open(SEQ_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Array):
		return
	_steps.clear()
	for s in parsed:
		if s is Dictionary:
			_steps.append({
				"preset": str(s.get("preset", "")),
				"hold": float(s.get("hold", DEF_HOLD)),
				"trans": float(s.get("trans", DEF_TRANS)),
				"mode": str(s.get("mode", "zoom")),
			})
