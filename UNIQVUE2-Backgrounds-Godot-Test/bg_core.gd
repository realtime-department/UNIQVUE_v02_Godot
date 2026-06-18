extends Node
## S3: Zustandsmodell + Preset-I/O (BgCore, Autoload).
##
## Speichert/laedt BENANNTE Presets als JSON nach `user://presets/`. Ein Preset ist
## ein voller ParamStore-Snapshot ({key: value}) plus Szenen-Tag + Format-Version.
## Werte werden JSON-sicher kodiert (Color/Vector als getaggte Objekte, Zahlen/Bool
## nativ) und beim Laden wieder zu Godot-Typen dekodiert; `ParamStore.apply` zieht
## sie danach typgerecht auf die Register-Typen.
##
## Zusaetzlich die Zustands-Utilities, die der Sequencer (S4) braucht:
##   diff(base, other)   -> sparse Delta (nur geaenderte Keys)  [Root+Delta-Modell]
##   resolve(root, delta)-> voller State (Root mit Delta ueberlagert)
##   summarize(snap)     -> kurze Beschreibung
## Interpolation zwischen States liefert `ParamStore.lerp_values`.
##
## D4-Schluessel sind stabil ueber Reload/Szenenwechsel -> gespeicherte Presets
## bleiben gueltig. `apply()` ueberspringt Keys, die in der aktiven Szene fehlen,
## d.h. ein Wave-Preset auf der Tunnel-Szene setzt nur die geteilten style/post/
## overlay-Werte (sauberer, fehlerfreier Teil-Recall).

signal presets_changed
signal style_presets_changed

const PRESET_DIR       := "user://presets"
const STYLE_PRESET_DIR := "user://style_presets"
const PRESET_EXT       := ".json"
const FORMAT_VERSION   := 1

var _params: Node   # ParamStore


func _ready() -> void:
	_params = get_node_or_null("/root/ParamStore")
	_ensure_dir()


# --------------------------------------------------------------- Preset-I/O

## Aktuellen Buehnenzustand fangen und als benanntes Preset ablegen.
## Style-Palette (style/*) wird NICHT gespeichert — hat eigene Preset-Funktion.
func save_current(preset_name: String) -> bool:
	if _params == null:
		return false
	var snap: Dictionary = _params.call("capture")
	for k in snap.keys():
		if str(k).begins_with("style/"):
			snap.erase(k)
	return save_snapshot(preset_name, snap)


## Ein fertiges Snapshot unter einem Namen ablegen. Gibt false bei leerem/ungueltigem
## Namen oder Schreibfehler.
func save_snapshot(preset_name: String, snap: Dictionary) -> bool:
	var clean := _sanitize(preset_name)
	if clean == "":
		return false
	var doc := {
		"version": FORMAT_VERSION,
		"scene": _params.call("active_scene_key") if _params != null else "",
		"params": _encode(snap),
	}
	var f := FileAccess.open(_path(clean), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
	presets_changed.emit()
	return true


## Preset laden UND auf die Buehne anwenden. Gibt das angewandte Snapshot zurueck
## (leer, wenn es das Preset nicht gibt / unlesbar ist).
func load_preset(preset_name: String) -> Dictionary:
	var snap := read_preset(preset_name)
	if not snap.is_empty() and _params != null:
		_params.call("apply", snap)
	return snap


## Nur lesen + dekodieren (ohne anzuwenden) — fuer Vorschau/Sequencer.
func read_preset(preset_name: String) -> Dictionary:
	var doc := read_doc(preset_name)
	return doc.get("params", {}) if doc is Dictionary else {}


## Vollstaendiges Dokument lesen ({version, scene, params(dekodiert)}); {} bei Fehler.
func read_doc(preset_name: String) -> Dictionary:
	var p := _path(_sanitize(preset_name))
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return {}
	var doc: Dictionary = parsed
	doc["params"] = _decode(doc.get("params", {}))
	return doc


func delete_preset(preset_name: String) -> void:
	var p := _path(_sanitize(preset_name))
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
		presets_changed.emit()


## Aktuelle Style-Palette als benanntes Style-Preset ablegen.
func save_style(preset_name: String) -> bool:
	var clean := _sanitize(preset_name)
	if clean == "":
		return false
	var st := get_node_or_null("/root/Style")
	if st == null:
		return false
	var f := FileAccess.open(_style_path(clean), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(_encode(st.call("get_palette")), "\t"))
	f.close()
	style_presets_changed.emit()
	return true


## Style-Preset laden und auf Style-Autoload anwenden. Gibt die geladene Palette
## zurueck (leer bei Fehler).
func load_style(preset_name: String) -> Dictionary:
	var clean := _sanitize(preset_name)
	var p := _style_path(clean)
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var snap := _decode(parsed)
	var st := get_node_or_null("/root/Style")
	if st != null:
		st.call("set_palette", snap)
	return snap


## Alphabetisch sortierte Liste der Style-Preset-Namen.
func list_style_presets() -> Array:
	var out: Array = []
	var d := DirAccess.open(STYLE_PRESET_DIR)
	if d == null:
		return out
	for fn in d.get_files():
		if fn.ends_with(PRESET_EXT):
			out.append(fn.substr(0, fn.length() - PRESET_EXT.length()))
	out.sort()
	return out


func delete_style_preset(preset_name: String) -> void:
	var p := _style_path(_sanitize(preset_name))
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
		style_presets_changed.emit()


## Alphabetisch sortierte Liste der Preset-Namen (ohne Endung).
func list_presets() -> Array:
	var out: Array = []
	var d := DirAccess.open(PRESET_DIR)
	if d == null:
		return out
	for fn in d.get_files():
		if fn.ends_with(PRESET_EXT):
			out.append(fn.substr(0, fn.length() - PRESET_EXT.length()))
	out.sort()
	return out


func has_preset(preset_name: String) -> bool:
	return FileAccess.file_exists(_path(_sanitize(preset_name)))


# --------------------------------------------------------------- Zustands-Utilities (S4)

## Sparse Delta: nur Keys, deren Wert von 'base' abweicht (Root+Delta-Modell).
func diff(base: Dictionary, other: Dictionary) -> Dictionary:
	var out := {}
	for k in other:
		if not base.has(k) or not _eq(base[k], other[k]):
			out[k] = other[k]
	return out


## Voller State: Root, mit Delta ueberlagert.
func resolve(root: Dictionary, delta: Dictionary) -> Dictionary:
	var out := root.duplicate(true)
	for k in delta:
		out[k] = delta[k]
	return out


func summarize(snap: Dictionary) -> String:
	return "%d params" % snap.size()


# --------------------------------------------------------------- Intern

func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(PRESET_DIR):
		DirAccess.make_dir_recursive_absolute(PRESET_DIR)
	if not DirAccess.dir_exists_absolute(STYLE_PRESET_DIR):
		DirAccess.make_dir_recursive_absolute(STYLE_PRESET_DIR)


func _path(clean: String) -> String:
	return PRESET_DIR + "/" + clean + PRESET_EXT


func _style_path(clean: String) -> String:
	return STYLE_PRESET_DIR + "/" + clean + PRESET_EXT


func _sanitize(preset_name: String) -> String:
	return preset_name.strip_edges().validate_filename()


# {key: value} -> JSON-sicheres {key: enc}. Color/Vector getaggt, Rest nativ.
func _encode(snap: Dictionary) -> Dictionary:
	var out := {}
	for k in snap:
		out[k] = _enc_val(snap[k])
	return out


func _enc_val(v: Variant) -> Variant:
	if v is Color:
		return {"_t": "col", "v": [v.r, v.g, v.b, v.a]}
	if v is Vector2:
		return {"_t": "v2", "v": [v.x, v.y]}
	if v is Vector3:
		return {"_t": "v3", "v": [v.x, v.y, v.z]}
	return v   # float/int/bool — JSON-nativ


func _decode(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		out[k] = _dec_val(d[k])
	return out


func _dec_val(v: Variant) -> Variant:
	if v is Dictionary and v.has("_t"):
		var a: Array = v.get("v", [])
		match str(v["_t"]):
			"col":
				return Color(a[0], a[1], a[2], a[3] if a.size() > 3 else 1.0)
			"v2":
				return Vector2(a[0], a[1])
			"v3":
				return Vector3(a[0], a[1], a[2])
	return v


func _eq(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return is_equal_approx(a, b)
	if a is Color and b is Color:
		return a.is_equal_approx(b)
	if a is Vector2 and b is Vector2:
		return a.is_equal_approx(b)
	if a is Vector3 and b is Vector3:
		return a.is_equal_approx(b)
	return a == b
