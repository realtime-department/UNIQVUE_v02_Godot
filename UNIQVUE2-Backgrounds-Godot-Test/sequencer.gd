extends Node
## S4: Sequencer (Autoload) — Preset-Playlist + Playback.
##
## Eine Playlist ist eine geordnete Liste von Schritten:
##   {preset: String, hold: float (s), trans: float (s)}
## play() laeuft die Liste in Schleife durch. Pro Schritt: 'hold' Sekunden halten,
## dann ueber 'trans' Sekunden zum NAECHSTEN Schritt ueberblenden —
##   - gleiche Szene  -> Parameter-Morph (ParamStore.apply_lerp A->B),
##   - andere Szene   -> die vorhandene Zoom-Transition (BackgroundStage.transition_to),
##                       danach werden die Preset-Werte auf die neue Szene angewandt.
##
## Abbruch/Neustart laufen ueber einen Generationszaehler `_gen`: jede neue Operation
## (play/stop/next) erhoeht ihn; eine laufende Coroutine bricht ab, sobald ihre
## gefangene Generation nicht mehr die aktuelle ist. `_playing` ist reine UI-Anzeige.
##
## Die Playlist wird als JSON nach `user://sequence.json` persistiert (Schritte sind
## reine String/Float-Werte, kein Typ-Tagging noetig) und beim Start geladen.

signal state_changed   # playing/idx/Liste geaendert -> UI aktualisiert sich

const SEQ_PATH := "user://sequence.json"
const DEF_HOLD := 3.0
const DEF_TRANS := 1.2

var _params: Node   # ParamStore
var _stage: Node    # BackgroundStage
var _core: Node     # BgCore

var _steps: Array = []   # [{preset, hold, trans}]
var _idx := 0
var _playing := false
var _gen := 0            # erhoeht bei play/stop/next -> bricht alte Coroutinen ab


func _ready() -> void:
	_params = get_node_or_null("/root/ParamStore")
	_stage = get_node_or_null("/root/BackgroundStage")
	_core = get_node_or_null("/root/BgCore")
	_load()


# --------------------------------------------------------------- Playlist-API

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
	_gen += 1   # laufende Coroutine bricht beim naechsten Check ab
	state_changed.emit()


## Manuell einen Schritt weiter (auch im Stillstand): blendet zum naechsten Preset.
func next() -> void:
	if _steps.is_empty():
		return
	_gen += 1
	var gen := _gen
	_playing = false
	var nxt := (_idx + 1) % _steps.size()
	var trans := maxf(0.0, float(_steps[_idx].get("trans", DEF_TRANS)))
	await _go_to(nxt, trans, gen)
	if gen != _gen:
		return
	_idx = nxt
	state_changed.emit()


## Manuell einen Schritt zurueck.
func prev() -> void:
	if _steps.is_empty():
		return
	_gen += 1
	var gen := _gen
	_playing = false
	var prv := (_idx - 1 + _steps.size()) % _steps.size()
	var trans := maxf(0.0, float(_steps[_idx].get("trans", DEF_TRANS)))
	await _go_to(prv, trans, gen)
	if gen != _gen:
		return
	_idx = prv
	state_changed.emit()


# --------------------------------------------------------------- Playback-Coroutine

func _run(gen: int) -> void:
	_idx = 0
	state_changed.emit()
	await _apply_step(_idx, gen)   # Startschritt hart setzen (kein Morph)
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


# Schritt i sofort anwenden (kein Morph) — fuer den Startschritt.
func _apply_step(i: int, gen: int) -> void:
	var doc := _read(i)
	if doc.is_empty():
		return
	await _ensure_scene(str(doc.get("scene", "")), 0.0, gen)
	if gen != _gen:
		return
	if _params != null:
		_params.call("apply", doc.get("params", {}))


# Von der aktuellen Buehne zu Schritt nxt ueberblenden (Szenenwechsel ODER Morph).
func _go_to(nxt: int, trans: float, gen: int) -> void:
	var doc := _read(nxt)
	if doc.is_empty():
		return
	var scene_key := str(doc.get("scene", ""))
	var snap: Dictionary = doc.get("params", {})
	var mode := str(_steps[nxt].get("mode", "zoom")) if nxt < _steps.size() else "zoom"
	if scene_key != "" and scene_key != _cur_scene():
		# Andere Szene: Transition (Zoom oder Cross), danach Preset-Werte setzen.
		await _ensure_scene(scene_key, trans, gen, mode)
		if gen != _gen:
			return
		if _params != null:
			_params.call("apply", snap)
	else:
		# Gleiche Szene: Parameter-Morph A->B.
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
	_params.call("apply", b)   # exakt auf Ziel einrasten


# Sicherstellen, dass die zum Preset getaggte Szene aktiv ist.
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
	await _stage.active_changed
	# Ein Frame, damit ParamStore sein Register fuer die neue Szene neu gebaut hat,
	# bevor wir die Preset-Werte anwenden.
	await get_tree().process_frame


func _cur_scene() -> String:
	return str(_params.call("active_scene_key")) if _params != null else ""


func _read(i: int) -> Dictionary:
	if _core == null or i < 0 or i >= _steps.size():
		return {}
	return _core.call("read_doc", str(_steps[i].get("preset", "")))


# --------------------------------------------------------------- Persistenz

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
