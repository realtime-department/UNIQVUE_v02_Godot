extends CanvasLayer
## Background stage (Autoload, layer 0 -> below the UI).
##
## Each background is rendered into its OWN off-screen SubViewport (own
## World3D -> own camera + own WorldEnvironment/Glow). The viewport textures
## are displayed via two ALWAYS full-screen TextureRects with a zoom shader ->
## seamless, no black borders (depth is created via UV zoom, not by scaling
## the rect).
##
## TRANSITION (both backgrounds run live, symmetrically over TRANSITION_TIME):
##   - old layer: zoom 1.0 -> ZOOM_SPAN (moves into camera, ease-in)  + fade 1 -> 0
##   - new layer: zoom ZOOM_SPAN -> 1.0 (pulls back from zoom, ease-out) + fade 0 -> 1
## Both zoom paths are exact time mirrors (ease-in <-> ease-out): at t=0.5 OLD and
## NEW are at the same zoom -> "same z-position at 50%".
## Both layers always stay zoom >= 1 -> always cover the full screen.
##
## COMPOSITING: ADDITIVE with complementary weights (fade_out + fade_in == 1).
## result = old*(1-t) + new*t  -> true linear blend, luminance is preserved:
## NO brightness dip / no transparent black showing through in the middle (unlike
## 'over', where two 50% layers give only 75% coverage). At t=0.5 each layer is
## truly at 50% alpha. The fades use sine ease-in-out -> the crossover point is
## exactly at 50%, but is traversed briskly (no sluggish fade-up/fade-over).
##
## active_changed(root) fires after each switch -> the UI rebuilds itself from it.

signal active_changed(root: Node)
## Fires when the aspect ratio of the render area changes (window resize,
## SPAN/PREVIEW switch, render-size override). 3D modules then scale their
## horizontal geometry extent so content fills the width instead of clustering
## in the centre (wide/wall resolutions). Base aspect is 16:9 (window default).
signal aspect_changed(aspect: float)

## Aspect ratio for which the modules are tuned (1920x1080). At this value the
## width multiplier is exactly 1.0.
const BASE_ASPECT := 16.0 / 9.0

const SCENES := [
	"res://tunnel_wave.tscn",
	"res://particle_wave.tscn",
	"res://stripes.tscn",
	"res://lines.tscn",
	"res://plexus.tscn",
	"res://cubic.tscn",
	"res://structure.tscn",
	"res://smoothwave.tscn",
	"res://quantum.tscn",
]
const SCENE_LABELS := ["Tunnel", "Wave", "Stripes", "Lines", "Plexus", "Cubic", "Structure", "SmoothWave", "Quantum"]
const TRANSITION_TIME := 1.2   # Default; adjustable at runtime via transition_time.
const ZOOM_SPAN := 2.0   # Symmetric zoom range: old 1->ZOOM_SPAN, new ZOOM_SPAN->1.
						 # Both stay >= 1 -> always full coverage (never black borders).

# Runtime duration of the transition (seconds); adjustable via RuntimeUI number field.
var transition_time := TRANSITION_TIME

# Full-screen zoom/fade shader for both layers. At zoom=1, fade=1 gives exactly the
# unmodified viewport image (no pop at start/end).
# ADDITIVE (blend_add): each layer's contribution is rgb * (fade*inside). Since the
# two fades sum to 1 during the transition, the layers add up to an exact linear
# blend -> no 'over' coverage gap, so never transparent black showing through in the
# middle. At rest (one layer, fade=1) = unmodified image.
const LAYER_SHADER := "shader_type canvas_item;
render_mode blend_add;
uniform float zoom = 1.0;
uniform float fade = 1.0;
void fragment() {
	vec2 uv = (UV - vec2(0.5)) / zoom + vec2(0.5);
	vec2 cl = clamp(uv, vec2(0.0), vec2(1.0));
	// Safety net: outside [0..1] (only if zoom < 1) transparent instead of clamped.
	// In normal operation zoom stays >= 1, so inside is practically always 1.
	float inside = step(uv.x, 1.0) * step(0.0, uv.x) * step(uv.y, 1.0) * step(0.0, uv.y);
	vec4 c = texture(TEXTURE, cl);
	COLOR = vec4(c.rgb, c.a * fade * inside);
}"

# Final on-screen overlay onto the HDR master texture (which already contains
# the additive bloom from the master WorldEnvironment): ACES tonemap -> Vignette -> Grain.
# Matches the web tonemap (studio-v005.html:261-275): aces(scene+bloom), then
# Vignette and Grain.
const OVERLAY_SHADER := "shader_type canvas_item;
uniform float vignette : hint_range(0.0, 1.0) = 0.5;
uniform float grain : hint_range(0.0, 0.3) = 0.0;
uniform float deband : hint_range(0.0, 4.0) = 1.0;
uniform bool aces_enabled = true;
vec3 aces(vec3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
// STATIC IGN on floored pixel coordinates — NO TIME term. This present pass
// runs after the TAA resolve, so static screen-space noise does not flicker.
// Animating it (like Grain) would cause it to crawl.
float ign(vec2 p) { p = floor(p); return fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y)); }
void fragment() {
	vec3 c = aces_enabled ? aces(texture(TEXTURE, UV).rgb) : texture(TEXTURE, UV).rgb;
	float d = distance(UV, vec2(0.5));
	float vig = smoothstep(0.25, 0.72, d);
	c *= 1.0 - vig * vignette;
	float g = hash(fract(UV * vec2(640.0, 360.0)) + TIME * 0.37) - 0.5;
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c += g * grain * (1.0 + (1.0 - lum) * 1.5);
	// Triangular-PDF dither (two decorrelated IGN samples) against 8-bit banding
	// of the final output. 'deband' = amplitude in LSB (1.0 = +/-1 LSB).
	float tri = ign(FRAGCOORD.xy) + ign(FRAGCOORD.xy + vec2(11.0, 23.0)) - 1.0;
	c += tri * (deband / 255.0);
	COLOR = vec4(aces_enabled ? clamp(c, 0.0, 1.0) : max(c, 0.0), 1.0);
}"

var _vps: Array[SubViewport] = []
var _rects: Array[TextureRect] = []
var _mats: Array[ShaderMaterial] = []
var _roots: Array[Node] = [null, null]
var _bg: ColorRect
var _blackout: ColorRect
var _active := 0          # active slot (0/1)
var _scene_idx := 0       # index into SCENES that is currently active
var _busy := false
var _forced_size := Vector2i.ZERO   # != 0 -> SubViewports render at this (wall) size
var _last_aspect := 0.0             # last reported render aspect ratio (spam guard)

# --- S1: Master-Composite (Variant A) ---
# Both layer rects are composited additively in HDR-2D into _master; its
# WorldEnvironment provides global bloom (2D-HDR-Glow). _final reads the HDR
# master texture and applies ACES tonemap + Vignette + Grain on-screen.
var _master: SubViewport
var _final: TextureRect
var _post_env: Environment
var _overlay_mat: ShaderMaterial


func _ready() -> void:
	assert(SCENES.size() == SCENE_LABELS.size(), "SCENES and SCENE_LABELS must have equal length")
	layer = 0  # below the UI (layer 100)
	var vp_size := get_window().size

	# --- Master-Composite-Viewport (Variant A) ---
	# HDR-2D, own world -> isolated WorldEnvironment (Glow/Bloom only). The two
	# layer rects composite here additively; bloom acts globally across the blend.
	# _final reads the HDR master texture (ACES tonemap + Vignette + Grain).
	_master = SubViewport.new()
	_master.own_world_3d = true
	_master.transparent_bg = false
	_master.size = vp_size
	_master.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_master.use_hdr_2d = true  # additive overlap > 1.0 -> real bloom feed
	_master.use_debanding = true  # flicker-free engine debander at master tonemap
	add_child(_master)

	# Black background as safety fill (in the master).
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 1)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_master.add_child(_bg)

	# Global post: WorldEnvironment in the master (Bloom/Glow across the blend).
	var we := WorldEnvironment.new()
	_post_env = _make_post_env()
	we.environment = _post_env
	_master.add_child(we)

	var shader := Shader.new()
	shader.code = LAYER_SHADER

	# Two slots: one SubViewport (off-screen) + one full-screen TextureRect
	# (in the master) with zoom shader each.
	for i in range(2):
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.transparent_bg = false
		vp.size = vp_size
		vp.use_hdr_2d = true  # FP16 target: gradient stays unquantised until the
							  # present pass -> no 8-bit banding before compositing.
		vp.use_debanding = true  # Engine debander at 3D tonemap (after TAA resolve,
								 # before any 8-bit quantisation) -> flicker-free.
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(vp)
		_vps.append(vp)

		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("zoom", 1.0)
		mat.set_shader_parameter("fade", 1.0)
		_mats.append(mat)

		var rect := TextureRect.new()
		rect.texture = vp.get_texture()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED  # clamp edges (dark)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.material = mat
		rect.visible = false
		_master.add_child(rect)
		_rects.append(rect)

	# Final on-screen rect: master texture + Vignette/Grain.
	_overlay_mat = ShaderMaterial.new()
	var osh := Shader.new()
	osh.code = OVERLAY_SHADER
	_overlay_mat.shader = osh
	_overlay_mat.set_shader_parameter("vignette", 0.5)
	_overlay_mat.set_shader_parameter("grain", 0.0)
	_overlay_mat.set_shader_parameter("deband", 1.0)

	_final = TextureRect.new()
	_final.texture = _master.get_texture()
	_final.set_anchors_preset(Control.PRESET_FULL_RECT)
	_final.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_final.stretch_mode = TextureRect.STRETCH_SCALE
	_final.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	_final.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_final.material = _overlay_mat
	add_child(_final)

	# Master blackout overlay — CanvasLayer child, drawn above _final but below RuntimeUI.
	_blackout = ColorRect.new()
	_blackout.color = Color(0.0, 0.0, 0.0, 0.0)
	_blackout.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blackout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_blackout)

	# Also debanding for the main viewport (displays _final) — in case the engine
	# includes the 2D present. Harmless if it is a no-op.
	var root_vp := get_viewport()
	if root_vp != null:
		root_vp.use_debanding = true

	get_window().size_changed.connect(_on_window_resized)
	RenderingServer.global_shader_parameter_set("sky_viewport_h", float(vp_size.y))

	# Load first background and make it active.
	_scene_idx = 0
	_active = 0
	_load_into(0, SCENES[0])
	_show_only(0)


# Global post-environment for the master composite — Bloom ONLY (2D-HDR-Glow).
# Tonemap (ACES) + Vignette + Grain are intentionally handled by the overlay shader
# (_final), because on a camera-less 2D viewport only the glow works reliably. Order
# matches the web: additive bloom -> ACES -> Vignette/Grain.
func _make_post_env() -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_CANVAS   # 2D canvas is the master's "scene"
	e.glow_enabled = true
	e.glow_intensity = 1.4
	e.glow_strength = 1.2
	e.glow_bloom = 0.2
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	e.glow_hdr_threshold = 0.7
	e.glow_hdr_scale = 1.0
	return e


func _on_window_resized() -> void:
	_apply_vp_size()


# --------------------------------------------------------------- Public API

func active_root() -> Node:
	return _roots[_active]


# Index of the currently active scene in SCENES (for the Sequencer).
func current_scene_index() -> int:
	return _scene_idx


# Root node name of SCENES[idx], WITHOUT instantiating the scene (SceneState is
# cheap). Matches active_scene_key() of the running scene -> stable key by which
# the Sequencer maps a preset to its scene.
func scene_key_for_index(idx: int) -> String:
	if idx < 0 or idx >= SCENES.size():
		return ""
	var ps := load(SCENES[idx]) as PackedScene
	if ps == null:
		return ""
	var st := ps.get_state()
	return st.get_node_name(0) if st.get_node_count() > 0 else ""


# Index of the scene with this root name (-1 if none matches).
func scene_index_for_key(key: String) -> int:
	for i in range(SCENES.size()):
		if scene_key_for_index(i) == key:
			return i
	return -1


# Texture of the fully composited + tonemapped master image (for the
# multi-window preview). Vignette/Grain are only in the _final overlay and
# therefore intentionally NOT in the wall preview (otherwise vignette per screen).
func active_texture() -> Texture2D:
	return _master.get_texture()


# Global post-environment (master) — used by the RuntimeUI panel as the POST zone.
func post_environment() -> Environment:
	return _post_env


# Overlay material (Vignette/Grain) — used by the RuntimeUI panel as POST controls.
func post_overlay() -> ShaderMaterial:
	return _overlay_mat


func set_hdr_mode(enabled: bool) -> void:
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("aces_enabled", not enabled)
	for vp in _vps:
		vp.use_hdr_2d = enabled
	if _master != null:
		_master.use_hdr_2d = enabled
	get_viewport().use_hdr_2d = enabled
	if DisplayServer.has_method("window_is_hdr_output_supported") \
			and DisplayServer.call("window_is_hdr_output_supported"):
		DisplayServer.call("window_request_hdr_output", enabled)


func get_hdr_mode() -> bool:
	if _overlay_mat == null:
		return false
	var v: Variant = _overlay_mat.get_shader_parameter("aces_enabled")
	return not (bool(v) if v != null else true)


## Master dim/blackout alpha (0=transparent, 1=fully black). For broadcast cuts.
func set_blackout(alpha: float) -> void:
	if _blackout != null:
		_blackout.color.a = clampf(alpha, 0.0, 1.0)

func get_blackout() -> float:
	return _blackout.color.a if _blackout != null else 0.0


# Render SubViewports at a fixed (wall) resolution independent of window size ->
# the image then matches the total aspect ratio of the wall.
func set_render_size_override(s: Vector2i) -> void:
	_forced_size = s
	_apply_vp_size()


func clear_render_size_override() -> void:
	_forced_size = Vector2i.ZERO
	_apply_vp_size()


## Debanding strength of the final present pass in LSB (0 = off, 1 = +/-1 LSB).
## Static triangular-PDF dither after the TAA resolve -> flicker-free.
func set_deband(value: float) -> void:
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("deband", value)


func set_antialiasing(msaa: int, ssaa: int, taa: bool) -> void:
	for vp in _vps:
		vp.msaa_3d         = msaa
		vp.screen_space_aa = ssaa
		vp.use_taa         = taa
	if _master != null:
		_master.msaa_3d         = msaa
		_master.screen_space_aa = ssaa
		_master.use_taa         = taa


func _apply_vp_size() -> void:
	var s: Vector2i = _forced_size if _forced_size != Vector2i.ZERO else get_window().size
	for vp in _vps:
		vp.size = s
	if _master != null:
		_master.size = s
	RenderingServer.global_shader_parameter_set("sky_viewport_h", float(s.y))
	_notify_aspect(s)


## Current aspect ratio of the render area (width/height). Modules read this
## and scale their X extent by aspect / BASE_ASPECT.
func canvas_aspect() -> float:
	var s: Vector2i = _forced_size if _forced_size != Vector2i.ZERO else get_window().size
	if s.y <= 0:
		return BASE_ASPECT
	return float(s.x) / float(s.y)


## Width multiplier for the current render area: 1.0 at 16:9, larger for wider
## (wall) resolutions. Modules multiply their horizontal extent by this value.
func width_factor() -> float:
	return canvas_aspect() / BASE_ASPECT


func _notify_aspect(s: Vector2i) -> void:
	if s.y <= 0:
		return
	var a := float(s.x) / float(s.y)
	if absf(a - _last_aspect) < 0.001:
		return
	_last_aspect = a
	aspect_changed.emit(a)


# Advance to the next scene in SCENES order.
func transition() -> void:
	transition_to((_scene_idx + 1) % SCENES.size())


# Switch to SCENES[target_idx]. mode: "zoom" (default) or "cross"
# (pure crossfade without zoom). Called by the Sequencer with per-step mode.
func transition_to(target_idx: int, mode: String = "zoom") -> void:
	if _busy or SCENES.size() < 2:
		return
	if target_idx < 0 or target_idx >= SCENES.size():
		return
	if target_idx == _scene_idx:
		active_changed.emit(active_root())  # unblock any awaiter; already on this scene
		return
	_busy = true
	var nxt_idx := target_idx
	var out_slot := _active
	var in_slot := 1 - _active
	_load_into(in_slot, SCENES[nxt_idx])

	# Apply this scene's cached parameters IMMEDIATELY to the still-invisible new layer
	# — before the warmup frame. Otherwise the incoming scene first renders the
	# .tscn defaults and jumps to the real values only after the switch (active_changed)
	# -> visible ramping during the zoom. Now it zooms in directly in the target state.
	_preapply_scene_params(_roots[in_slot])

	var in_rect := _rects[in_slot]
	var out_rect := _rects[out_slot]
	var in_mat := _mats[in_slot]
	var out_mat := _mats[out_slot]

	_vps[in_slot].render_target_update_mode = SubViewport.UPDATE_ALWAYS
	in_mat.set_shader_parameter("zoom", 1.0)
	in_mat.set_shader_parameter("fade", 0.0)
	in_rect.visible = true
	out_mat.set_shader_parameter("zoom", 1.0)
	out_mat.set_shader_parameter("fade", 1.0)
	out_rect.visible = true

	await get_tree().process_frame

	var dur := maxf(0.05, transition_time)
	var tw := create_tween().set_parallel(true)
	# Fallback: reset _busy if tween is killed (scene reload / orphan) without firing finished.
	get_tree().create_timer(dur + 1.0).timeout.connect(func() -> void: _busy = false)

	if mode == "cross":
		# Pure crossfade: no zoom, just fade.
		tw.tween_property(out_mat, "shader_parameter/fade", 0.0, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(in_mat, "shader_parameter/fade", 1.0, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		# Zoom/push mode: old layer moves into the camera (ease-in 1->ZOOM_SPAN),
		# new layer pulls back mirrored (ease-out ZOOM_SPAN->1). At t=0.5 both
		# are at the same zoom. Additive blending keeps luminance constant.
		in_mat.set_shader_parameter("zoom", ZOOM_SPAN)
		tw.tween_property(out_mat, "shader_parameter/zoom", ZOOM_SPAN, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tw.tween_property(out_mat, "shader_parameter/fade", 0.0, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(in_mat, "shader_parameter/zoom", 1.0, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(in_mat, "shader_parameter/fade", 1.0, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	tw.tween_callback(func() -> void:
		_vps[out_slot].render_target_update_mode = SubViewport.UPDATE_DISABLED) \
		.set_delay(dur * 0.9)
	tw.finished.connect(func() -> void:
		_finish_transition(out_slot, in_slot, nxt_idx))


# --------------------------------------------------------------- Intern

func _finish_transition(out_slot: int, in_slot: int, nxt_idx: int) -> void:
	# Unload the departed scene, its viewport goes idle.
	if _roots[out_slot] != null:
		_roots[out_slot].queue_free()
		_roots[out_slot] = null
	_vps[out_slot].render_target_update_mode = SubViewport.UPDATE_DISABLED
	_rects[out_slot].visible = false
	_mats[out_slot].set_shader_parameter("zoom", 1.0)
	_mats[out_slot].set_shader_parameter("fade", 1.0)

	_active = in_slot
	_scene_idx = nxt_idx
	_busy = false
	active_changed.emit(active_root())


# Let ParamStore apply the cached scene/*+mat/* values for this scene to the freshly
# loaded (still invisible) root before it renders. No-op if there is no cache entry
# for this scene yet (first visit) or ParamStore is missing.
func _preapply_scene_params(root: Node) -> void:
	if root == null:
		return
	var ps := get_node_or_null("/root/ParamStore")
	if ps != null:
		ps.call("preapply_to_scene", root)


func _load_into(slot: int, path: String) -> void:
	if _roots[slot] != null:
		_roots[slot].queue_free()
		_roots[slot] = null
	var packed := load(path) as PackedScene
	if packed == null:
		return
	var inst := packed.instantiate()
	_vps[slot].add_child(inst)
	_roots[slot] = inst
	# Activate the scene's camera in its own viewport.
	var cam := _find_camera(inst)
	if cam != null:
		cam.current = true


func _find_camera(node: Node) -> Camera3D:
	if node is Camera3D:
		return node as Camera3D
	for c in node.get_children():
		var r := _find_camera(c)
		if r != null:
			return r
	return null


func _show_only(slot: int) -> void:
	for i in range(_vps.size()):
		var on := i == slot
		_vps[i].render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED)
		_rects[i].visible = on
		_mats[i].set_shader_parameter("zoom", 1.0)
		_mats[i].set_shader_parameter("fade", 1.0)
