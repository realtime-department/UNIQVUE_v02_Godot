extends Node
## S2: Parameter snapshot/apply layer (ParamStore, Autoload).
##
## Collects ALL runtime-tunable parameters of the active stage into ONE flat,
## named registry {key -> entry}. Each entry carries type + getter/setter
## (Callable), so capture/apply/lerp work type-independently. This is the
## bridge that S3 (Presets) and S4 (Sequencer) need: a preset/keyframe is
## simply a {key: value} dictionary.
##
## D4 — key schema (flat, mirrored from the 5 UI sources):
##   style/<key>            global palette (Style autoload)             [cross-scene]
##   scene/<export>         @export of the scene root script            [scene-specific]
##   mat/<Node>/<uniform>   shader uniform of a ShaderMaterial          [scene-specific]
##   post/<prop>            master glow (BackgroundStage.post_environment)
##   overlay/<prop>         vignette/grain (BackgroundStage.post_overlay)
##
## The registry is rebuilt on every active_changed (like the UI). apply()
## ignores keys that don't resolve in the current scene -> a Tunnel snapshot
## applied to the Wave scene only sets the shared style/* + post/* and drops
## scene/* + mat/* (clean scene switch).

const STORE_VERSION := 1

# Master glow parameters (mirror of RuntimeUI.POST_PARAMS) — all float.
const POST_KEYS := [
	"glow_intensity", "glow_strength", "glow_bloom", "glow_hdr_threshold",
]
# Overlay shader parameters (vignette/grain) — all float.
const OVERLAY_KEYS := ["vignette", "grain"]

var _stage: Node
var _registry: Array = []   # stable order (for deterministic iteration)
var _by_key: Dictionary = {}

# In-session cache of SCENE-SPECIFIC values (scene/* + mat/*), per scene name.
# Global values (style/post/overlay) live in autoloads/master and survive
# TRANSITION anyway; only scene/* + mat/* are lost because background_stage
# re-instantiates the scene from .tscn. Cached here -> re-applied on re-entry
# so slider tweaks persist across scene switches.
var _scene_cache: Dictionary = {}
var _cur_scene_key: String = ""


func _ready() -> void:
	# Deferred: only after all autoloads exist and the first scene is loaded.
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
	# 1) On leaving, save the scene-specific values of the OLD scene. The
	#    current registry still points to them; background_stage fires active_changed
	#    synchronously after queue_free() (deferred) -> the old nodes live this frame
	#    still, the getter returns the last-set values.
	if _cur_scene_key != "" and not _registry.is_empty():
		_scene_cache[_cur_scene_key] = _capture_prefixed(["scene/", "mat/"])
	# 2) Rebuild registry for the new (freshly instantiated) scene.
	_rebuild(root)
	_cur_scene_key = str(root.name)
	# 3) Re-apply cached values for this scene -> otherwise fresh sliders
	#    would sit at the .tscn author defaults.
	if _scene_cache.has(_cur_scene_key):
		apply(_scene_cache[_cur_scene_key])


# --------------------------------------------------------------- Public API

## Capture current state of all registered parameters as {key: value}.
func capture() -> Dictionary:
	var out := {}
	for e in _registry:
		var v: Variant = (e.getter as Callable).call()
		if v != null:
			out[e.key] = v
	return out


## Only entries whose key starts with one of the prefixes (e.g. scene/, mat/).
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


## Apply {key: value}. Keys without a matching entry are skipped
## (e.g. scene-specific keys from another scene).
func apply(values: Dictionary) -> void:
	for key in values:
		var e: Variant = _by_key.get(key)
		if e == null:
			continue
		(e.setter as Callable).call(_coerce(int(e.type), values[key]))


## Apply cached scene/*+mat/* values to a freshly loaded (not yet active) root —
## called by BackgroundStage DURING the transition so the incoming layer renders
## immediately in the target state instead of ramping from .tscn defaults.
## No-op if the scene has never been visited (no cache entry).
func preapply_to_scene(root: Node) -> void:
	if root == null:
		return
	var key := str(root.name)
	if _scene_cache.has(key):
		apply_to_root(root, _scene_cache[key])


## Apply snapshot directly to a (possibly NOT yet active) scene root WITHOUT touching
## the active scene's registry. Intended for the incoming scene DURING a transition:
## scene/* + mat/* are resolved against 'root', style/post/overlay act globally anyway.
## This way the new layer renders immediately in the target state instead of ramping
## from .tscn defaults. Keys without a match (other scene) are ignored.
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


## Coerce value to the type of the current property value (no registry available).
func _coerce_like(current: Variant, v: Variant) -> Variant:
	if current is int and (v is float or v is int):
		return int(round(float(v)))
	if current is float and (v is float or v is int):
		return float(v)
	if current is bool:
		return bool(v)
	return v


## Type-correct interpolation of two snapshots -> morphed {key: value}.
## Only keys present in BOTH are interpolated; a-only keys stay (a),
## b-only keys are added (b) — nothing is lost during the morph.
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


## Convenience: morph a->b directly to the stage (for S4 param track).
func apply_lerp(a: Dictionary, b: Dictionary, t: float) -> void:
	apply(lerp_values(a, b, t))


## Key of the active scene (for tagging snapshots in S3/S4).
func active_scene_key() -> String:
	var root: Variant = _stage.call("active_root") if _stage != null else null
	if not is_instance_valid(root):
		return ""
	return str(root.name) if root is Node else ""


## All known keys (stable order) — for debug/preset UI.
func keys() -> Array:
	var out: Array = []
	for e in _registry:
		out.append(e.key)
	return out


func has_key(key: String) -> bool:
	return _by_key.has(key)


# --------------------------------------------------------------- Registry Build

func _rebuild(root: Node) -> void:
	_registry.clear()
	_by_key.clear()

	# 1) Global palette (cross-scene).
	var st := get_node_or_null("/root/Style")
	if st != null:
		for k in st.call("keys"):
			var key := "style/" + str(k)
			var sk := str(k)
			_add(key, TYPE_COLOR,
				func() -> Variant: return st.call("get_color", sk),
				func(v: Variant) -> void: st.call("set_color", sk, v))

	# 2) @exports of the root script (scene-specific).
	if root.get_script() != null:
		_collect_object_props(root)

	# 3) Shader uniforms of all ShaderMaterials (scene-specific).
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
			# Groups with a leading '_' (e.g. _Sync) are fully ignored.
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


# Current uniform value; falls back to the shader default (uniform never set).
func _uniform_get(mat: ShaderMaterial, rid: RID, uname: String) -> Variant:
	var v: Variant = mat.get_shader_parameter(uname)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(rid, uname)
	return v


# --------------------------------------------------------------- Type Helpers

func _supported(t: int) -> bool:
	return (t == TYPE_FLOAT or t == TYPE_INT or t == TYPE_VECTOR2
		or t == TYPE_VECTOR3 or t == TYPE_COLOR or t == TYPE_BOOL)


# Coerce value to the registry type (sliders deliver float, pickers deliver Color, etc.).
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


# --------------------------------------------------------------- Stage Access

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


# Master post-environment (S1); falls back to the scene environment.
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
