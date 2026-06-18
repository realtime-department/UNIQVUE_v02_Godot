extends Node
## S2: Parameter-Schnappschuss-/Anwende-Schicht (ParamStore, Autoload).
##
## Sammelt ALLE laufzeit-tunbaren Parameter der aktiven Buehne in EIN flaches,
## benanntes Register {key -> entry}. Jeder Eintrag traegt Typ + getter/setter
## (Callable), sodass capture/apply/lerp typunabhaengig arbeiten. Das ist die
## Bruecke, die S3 (Presets) und S4 (Sequencer) brauchen: ein Preset/Keyframe ist
## einfach ein {key: value}-Dictionary.
##
## D4 — Schluessel-Schema (flach, gespiegelt aus den 5 UI-Quellen):
##   style/<key>            globale Palette (Style-Autoload)            [szenenuebergreifend]
##   scene/<export>         @export des Szenen-Wurzelskripts            [szenenspezifisch]
##   mat/<Node>/<uniform>   Shader-Uniform eines ShaderMaterials        [szenenspezifisch]
##   post/<prop>            Master-Glow (BackgroundStage.post_environment)
##   overlay/<prop>         Vignette/Grain (BackgroundStage.post_overlay)
##
## Das Register wird bei jedem active_changed neu gebaut (wie das UI). apply()
## ignoriert Schluessel, die in der aktuellen Szene nicht aufloesen -> ein
## Tunnel-Snapshot, auf die Wave-Szene angewandt, setzt nur die geteilten
## style/* + post/* und laesst scene/* + mat/* fallen (sauberer Szenenwechsel).

const STORE_VERSION := 1

# Master-Glow-Parameter (Spiegel von RuntimeUI.POST_PARAMS) — alle float.
const POST_KEYS := [
	"glow_intensity", "glow_strength", "glow_bloom", "glow_hdr_threshold",
]
# Overlay-Shader-Parameter (Vignette/Grain) — alle float.
const OVERLAY_KEYS := ["vignette", "grain"]

var _stage: Node
var _registry: Array = []   # Reihenfolge stabil (fuer determinist. Iteration)
var _by_key: Dictionary = {}

# In-Session-Cache der SZENENSPEZIFISCHEN Werte (scene/* + mat/*), je Szenenname.
# Globale Werte (style/post/overlay) liegen in Autoloads/Master und ueberleben den
# TRANSITION ohnehin; nur scene/* + mat/* gehen verloren, weil background_stage die
# Szene aus der .tscn NEU instanziiert. Hier gemerkt -> beim Wiederbetreten erneut
# angewandt, sodass Slider-Tweaks ueber Szenenwechsel hinweg bestehen bleiben.
var _scene_cache: Dictionary = {}
var _cur_scene_key: String = ""


func _ready() -> void:
	# Deferred: erst wenn alle Autoloads existieren und die erste Szene geladen ist.
	_connect_stage.call_deferred()


func _connect_stage() -> void:
	_stage = get_node_or_null("/root/BackgroundStage")
	if _stage == null:
		return
	if not _stage.is_connected("active_changed", _on_active_changed):
		_stage.connect("active_changed", _on_active_changed)
	var root: Variant = _stage.call("active_root")
	if root is Node:
		_rebuild(root)
		_cur_scene_key = str(root.name)


func _on_active_changed(root: Node) -> void:
	if root == null or not root.is_inside_tree():
		return
	# 1) Beim Verlassen die szenenspezifischen Werte der ALTEN Szene sichern. Das
	#    bisherige Register zeigt noch auf sie; background_stage ruft active_changed
	#    synchron nach queue_free() (deferred) -> die alten Knoten leben diesen Frame
	#    noch, der getter liefert die zuletzt eingestellten Werte.
	if _cur_scene_key != "" and not _registry.is_empty():
		_scene_cache[_cur_scene_key] = _capture_prefixed(["scene/", "mat/"])
	# 2) Register auf die neue (frisch instanziierte) Szene neu bauen.
	_rebuild(root)
	_cur_scene_key = str(root.name)
	# 3) Gemerkte Werte dieser Szene wieder anwenden -> sonst staenden die frischen
	#    Regler auf den .tscn-Autoren-Defaults.
	if _scene_cache.has(_cur_scene_key):
		apply(_scene_cache[_cur_scene_key])


# --------------------------------------------------------------- Oeffentliche API

## Aktuellen Zustand aller registrierten Parameter als {key: value} einfangen.
func capture() -> Dictionary:
	var out := {}
	for e in _registry:
		var v: Variant = (e.getter as Callable).call()
		if v != null:
			out[e.key] = v
	return out


## Nur Eintraege, deren Schluessel mit einem der Praefixe beginnt (z.B. scene/, mat/).
func _capture_prefixed(prefixes: Array) -> Dictionary:
	var out := {}
	for e in _registry:
		var k := String(e.key)
		for p in prefixes:
			if k.begins_with(str(p)):
				var v: Variant = (e.getter as Callable).call()
				if v != null:
					out[k] = v
				break
	return out


## {key: value} anwenden. Schluessel ohne passenden Eintrag werden uebersprungen
## (z.B. szenenspezifische Keys einer anderen Szene).
func apply(values: Dictionary) -> void:
	for key in values:
		var e: Variant = _by_key.get(key)
		if e == null:
			continue
		(e.setter as Callable).call(_coerce(int(e.type), values[key]))


## Die gemerkten scene/*+mat/*-Werte einer Szene auf ihren frisch geladenen (noch nicht
## aktiven) Root anwenden — von BackgroundStage WAEHREND der Transition aufgerufen, damit
## die einkommende Ebene sofort im Zielzustand rendert statt von den .tscn-Defaults
## hochzurampen. No-op, wenn die Szene noch nie besucht wurde (kein Cache-Eintrag).
func preapply_to_scene(root: Node) -> void:
	if root == null:
		return
	var key := str(root.name)
	if _scene_cache.has(key):
		apply_to_root(root, _scene_cache[key])


## Snapshot direkt auf einen (ggf. noch NICHT aktiven) Szenen-Root anwenden, OHNE das
## Register der aktiven Szene anzutasten. Gedacht fuer die einkommende Szene WAEHREND
## einer Transition: scene/* + mat/* werden gegen 'root' aufgeloest, style/post/overlay
## wirken ohnehin global. So zeigt die neue Ebene sofort den Zielzustand, statt von den
## .tscn-Defaults hochzurampen. Schluessel ohne Treffer (andere Szene) werden ignoriert.
func apply_to_root(root: Node, values: Dictionary) -> void:
	if root == null:
		return
	var mats := {}
	for entry in _find_shader_materials(root):
		mats[str(entry[0])] = entry[1]
	var st := get_node_or_null("/root/Style")
	var penv := _post_env(root)
	var omat := _overlay_mat()
	for key in values:
		var k := str(key)
		var v: Variant = values[key]
		if k.begins_with("style/"):
			if st != null:
				st.call("set_color", k.substr(6), v)
		elif k.begins_with("post/"):
			if penv != null:
				penv.set(k.substr(5), float(v) if (v is float or v is int) else v)
		elif k.begins_with("overlay/"):
			if omat != null:
				omat.set_shader_parameter(k.substr(8), v)
		elif k.begins_with("scene/"):
			var prop := k.substr(6)
			root.set(prop, _coerce_like(root.get(prop), v))
		elif k.begins_with("mat/"):
			var rest := k.substr(4)
			var slash := rest.find("/")
			if slash > 0:
				var mat: Variant = mats.get(rest.substr(0, slash))
				if mat != null:
					(mat as ShaderMaterial).set_shader_parameter(rest.substr(slash + 1), v)


## Wert auf den Typ des aktuellen Property-Werts ziehen (kein Register verfuegbar).
func _coerce_like(current: Variant, v: Variant) -> Variant:
	if current is int and (v is float or v is int):
		return int(round(float(v)))
	if current is float and (v is float or v is int):
		return float(v)
	if current is bool:
		return bool(v)
	return v


## Typgerechte Interpolation zweier Snapshots -> gemorphtes {key: value}.
## Nur Schluessel, die in BEIDEN vorkommen, werden interpoliert; reine a-Keys
## bleiben (a), reine b-Keys kommen (b) hinzu — so geht beim Morph nichts verloren.
func lerp_values(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key in a:
		if b.has(key):
			var e: Variant = _by_key.get(key)
			var ty := int(e.type) if e != null else _infer_type(a[key])
			out[key] = _lerp_value(ty, a[key], b[key], t)
		else:
			out[key] = a[key]
	for key in b:
		if not a.has(key):
			out[key] = b[key]
	return out


## Bequemlichkeit: a->b direkt auf die Buehne morphen (fuer S4-Param-Track).
func apply_lerp(a: Dictionary, b: Dictionary, t: float) -> void:
	apply(lerp_values(a, b, t))


## Kennung der aktiven Szene (zum Taggen von Snapshots in S3/S4).
func active_scene_key() -> String:
	var root: Variant = _stage.call("active_root") if _stage != null else null
	return str(root.name) if root is Node else ""


## Alle bekannten Schluessel (stabile Reihenfolge) — fuer Debug/Preset-UI.
func keys() -> Array:
	var out: Array = []
	for e in _registry:
		out.append(e.key)
	return out


func has_key(key: String) -> bool:
	return _by_key.has(key)


# --------------------------------------------------------------- Register-Aufbau

func _rebuild(root: Node) -> void:
	_registry.clear()
	_by_key.clear()

	# 1) Globale Palette (szenenuebergreifend).
	var st := get_node_or_null("/root/Style")
	if st != null:
		for k in st.call("keys"):
			var key := "style/" + str(k)
			var sk := str(k)
			_add(key, TYPE_COLOR,
				func() -> Variant: return st.call("get_color", sk),
				func(v: Variant) -> void: st.call("set_color", sk, v))

	# 2) @export des Wurzel-Skripts (szenenspezifisch).
	if root.get_script() != null:
		_collect_object_props(root)

	# 3) Shader-Uniforms aller ShaderMaterials (szenenspezifisch).
	for entry in _find_shader_materials(root):
		_collect_shader_uniforms(str(entry[0]), entry[1])

	# 4) Master-Glow (post/*).
	var penv := _post_env(root)
	if penv != null:
		for prop in POST_KEYS:
			var p := str(prop)
			_add("post/" + p, TYPE_FLOAT,
				func() -> Variant: return penv.get(p),
				func(v: Variant) -> void: penv.set(p, v))

	# 5) Overlay-Material (overlay/*).
	var omat := _overlay_mat()
	if omat != null:
		for prop in OVERLAY_KEYS:
			var p := str(prop)
			_add("overlay/" + p, TYPE_FLOAT,
				func() -> Variant: return omat.get_shader_parameter(p),
				func(v: Variant) -> void: omat.set_shader_parameter(p, v))


func _add(key: String, type: int, getter: Callable, setter: Callable) -> void:
	var e := {"key": key, "type": type, "getter": getter, "setter": setter}
	_registry.append(e)
	_by_key[key] = e


func _collect_object_props(obj: Object) -> void:
	for prop in obj.get_property_list():
		var usage: int = int(prop["usage"])
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var ptype: int = int(prop["type"])
		if not _supported(ptype):
			continue
		var pname: String = str(prop["name"])
		_add("scene/" + pname, ptype,
			func() -> Variant: return obj.get(pname),
			func(v: Variant) -> void: obj.set(pname, v))


func _collect_shader_uniforms(node_name: String, mat: ShaderMaterial) -> void:
	if mat == null or mat.shader == null:
		return
	var rid := mat.shader.get_rid()
	var skip_group := false
	for u in mat.shader.get_shader_uniform_list(true):
		var usage: int = int(u["usage"])
		if usage & PROPERTY_USAGE_GROUP:
			# Gruppen mit fuehrendem '_' (z.B. _Sync) werden vollstaendig ignoriert.
			skip_group = str(u["name"]).begins_with("_")
			continue
		if skip_group:
			continue
		var uname: String = str(u["name"])
		if uname == "":
			continue
		var utype: int = int(u["type"])
		if not _supported(utype):
			continue
		var key := "mat/" + node_name + "/" + uname
		_add(key, utype,
			func() -> Variant: return _uniform_get(mat, rid, uname),
			func(v: Variant) -> void: mat.set_shader_parameter(uname, v))


# Aktueller Uniform-Wert; faellt auf den Shader-Default zurueck (Uniform nie gesetzt).
func _uniform_get(mat: ShaderMaterial, rid: RID, uname: String) -> Variant:
	var v: Variant = mat.get_shader_parameter(uname)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(rid, uname)
	return v


# --------------------------------------------------------------- Typ-Helfer

func _supported(t: int) -> bool:
	return (t == TYPE_FLOAT or t == TYPE_INT or t == TYPE_VECTOR2
		or t == TYPE_VECTOR3 or t == TYPE_COLOR or t == TYPE_BOOL)


# Wert auf den Registertyp ziehen (Slider liefern float, Picker liefern Color usw.).
func _coerce(type: int, v: Variant) -> Variant:
	match type:
		TYPE_FLOAT:
			return float(v) if (v is float or v is int) else v
		TYPE_INT:
			return int(round(float(v))) if (v is float or v is int) else v
		TYPE_BOOL:
			return bool(v)
	return v


func _lerp_value(type: int, a: Variant, b: Variant, t: float) -> Variant:
	match type:
		TYPE_FLOAT:
			return lerpf(float(a), float(b), t)
		TYPE_INT:
			return int(round(lerpf(float(a), float(b), t)))
		TYPE_COLOR:
			return (a as Color).lerp(b, t)
		TYPE_VECTOR2:
			return (a as Vector2).lerp(b, t)
		TYPE_VECTOR3:
			return (a as Vector3).lerp(b, t)
		TYPE_BOOL:
			return b if t >= 0.5 else a
	return b if t >= 0.5 else a


func _infer_type(v: Variant) -> int:
	if v is Color: return TYPE_COLOR
	if v is Vector2: return TYPE_VECTOR2
	if v is Vector3: return TYPE_VECTOR3
	if v is int: return TYPE_INT
	if v is bool: return TYPE_BOOL
	return TYPE_FLOAT


# --------------------------------------------------------------- Buehnen-Zugriff

func _find_shader_materials(root: Node) -> Array:
	var out: Array = []
	_collect_shader_materials(root, out, {})
	return out


func _collect_shader_materials(node: Node, out: Array, seen: Dictionary) -> void:
	if node is GeometryInstance3D:
		var gi := node as GeometryInstance3D
		if gi.material_override is ShaderMaterial:
			var rid := gi.material_override.get_rid()
			if not seen.has(rid):
				seen[rid] = true
				out.append([node.name, gi.material_override])
	for c in node.get_children():
		_collect_shader_materials(c, out, seen)


# Master-Post-Environment (S1); faellt auf die Szenen-Env zurueck.
func _post_env(root: Node) -> Environment:
	if _stage != null:
		var pe: Variant = _stage.call("post_environment")
		if pe is Environment:
			return pe
	var we := _find_world_env(root)
	return we.environment if we != null else null


func _overlay_mat() -> ShaderMaterial:
	if _stage != null:
		var om: Variant = _stage.call("post_overlay")
		if om is ShaderMaterial:
			return om
	return null


func _find_world_env(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for c in node.get_children():
		var r := _find_world_env(c)
		if r != null:
			return r
	return null
