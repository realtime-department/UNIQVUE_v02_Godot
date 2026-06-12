extends CanvasLayer
## Hintergrund-Buehne (Autoload, layer 0 -> unter der UI).
##
## Jeder Hintergrund wird in ein EIGENES Off-Screen-SubViewport gerendert (eigene
## World3D -> eigene Kamera + eigenes WorldEnvironment/Glow). Angezeigt werden die
## Viewport-Texturen ueber zwei IMMER vollflaechige TextureRects mit einem
## Zoom-Shader -> nahtlos, keine schwarzen Raender (die Tiefe entsteht im UV-Zoom,
## nicht durch Skalieren des Rechtecks).
##
## TRANSITION (beide Hintergruende laufen live, symmetrisch ueber TRANSITION_TIME):
##   - alte Ebene : zoom 1.0 -> ZOOM_SPAN (faehrt in die Kamera, ease-in)  + fade 1 -> 0
##   - neue Ebene : zoom ZOOM_SPAN -> 1.0 (setzt sich aus dem Zoom, ease-out) + fade 0 -> 1
## Beide Zoom-Pfade sind exakte Zeit-Spiegel (ease-in <-> ease-out): bei t=0.5 sind
## ALTE und NEUE auf demselben Zoom -> "gleiche z-Position bei 50 %".
## Beide Ebenen bleiben stets zoom >= 1 -> decken immer den ganzen Schirm.
##
## COMPOSITING: ADDITIV mit komplementaeren Gewichten (fade_out + fade_in == 1).
## result = alt*(1-t) + neu*t  -> echte Linear-Mischung, Luminanz bleibt erhalten:
## KEIN Helligkeits-Einbruch / kein durchscheinendes Schwarz in der Mitte (anders als
## bei 'over', wo zwei 50%-Ebenen nur 75 % Deckung ergeben). Bei t=0.5 ist jede Ebene
## echt auf 50 % Alpha. Die Fades nutzen sine ease-in-out -> der Cross-Punkt liegt
## exakt bei 50 %, wird aber zuegig durchschritten (kein traeges Auf-/Ueberblenden).
##
## active_changed(root) feuert nach jedem Wechsel -> die UI befuellt sich daraus neu.

signal active_changed(root: Node)

const SCENES := [
	"res://tunnel_wave.tscn",
	"res://particle_wave.tscn",
]
const TRANSITION_TIME := 1.2   # Default; zur Laufzeit ueber transition_time anpassbar.
const ZOOM_SPAN := 2.0   # Symmetrischer Zoom-Hub: alt 1->ZOOM_SPAN, neu ZOOM_SPAN->1.
                         # Beide bleiben >= 1 -> stets volle Deckung (nie schwarze Raender).

# Laufzeit-Dauer der Transition (Sekunden); per RuntimeUI-Zahlenfeld einstellbar.
var transition_time := TRANSITION_TIME

# Vollflaechiger Zoom/Fade-Shader fuer beide Ebenen. Bei zoom=1, fade=1 exakt das
# unveraenderte Viewport-Bild (kein Pop am Anfang/Ende).
# ADDITIV (blend_add): der Beitrag jeder Ebene ist rgb * (fade*inside). Da sich die
# beiden Fades waehrend der Transition zu 1 ergaenzen, addieren sich die Ebenen zur
# exakten Linear-Mischung -> keine 'over'-Deckungsluecke, also nie durchscheinendes
# Schwarz in der Mitte. Im Ruhezustand (eine Ebene, fade=1) = unveraendertes Bild.
const LAYER_SHADER := "shader_type canvas_item;
render_mode blend_add;
uniform float zoom = 1.0;
uniform float fade = 1.0;
void fragment() {
	vec2 uv = (UV - vec2(0.5)) / zoom + vec2(0.5);
	vec2 cl = clamp(uv, vec2(0.0), vec2(1.0));
	// Sicherheitsnetz: ausserhalb [0..1] (nur falls zoom < 1) transparent statt geklemmt.
	// Im aktuellen Ablauf bleibt zoom stets >= 1, daher ist inside praktisch immer 1.
	float inside = step(uv.x, 1.0) * step(0.0, uv.x) * step(uv.y, 1.0) * step(0.0, uv.y);
	vec4 c = texture(TEXTURE, cl);
	COLOR = vec4(c.rgb, c.a * fade * inside);
}"

# Finaler On-Screen-Overlay auf die HDR-Master-Textur (enthaelt bereits das
# additive Bloom des Master-WorldEnvironments): ACES-Tonemap -> Vignette -> Grain.
# Entspricht dem Web-Tonemap (studio-v005.html:261-275): aces(scene+bloom), dann
# Vignette und Grain.
const OVERLAY_SHADER := "shader_type canvas_item;
uniform float vignette : hint_range(0.0, 1.0) = 0.5;
uniform float grain : hint_range(0.0, 0.3) = 0.0;
vec3 aces(vec3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	vec3 c = aces(texture(TEXTURE, UV).rgb);
	float d = distance(UV, vec2(0.5));
	float vig = smoothstep(0.25, 0.72, d);
	c *= 1.0 - vig * vignette;
	float g = hash(fract(UV * vec2(640.0, 360.0)) + TIME * 0.37) - 0.5;
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c += g * grain * (1.0 + (1.0 - lum) * 1.5);
	COLOR = vec4(clamp(c, 0.0, 1.0), 1.0);
}"

var _vps: Array[SubViewport] = []
var _rects: Array[TextureRect] = []
var _mats: Array[ShaderMaterial] = []
var _roots: Array[Node] = [null, null]
var _bg: ColorRect
var _active := 0          # aktiver Slot (0/1)
var _scene_idx := 0       # Index in SCENES, der gerade aktiv ist
var _busy := false
var _forced_size := Vector2i.ZERO   # != 0 -> SubViewports rendern in dieser (Wand-)Groesse

# --- S1: Master-Composite (Variante A) ---
# Beide Layer-Rects werden in _master additiv in HDR-2D komponiert; dessen
# WorldEnvironment liefert globalen Bloom (2D-HDR-Glow). _final liest die HDR-
# Master-Textur und macht ACES-Tonemap + Vignette + Grain on-screen.
var _master: SubViewport
var _final: TextureRect
var _post_env: Environment
var _overlay_mat: ShaderMaterial


func _ready() -> void:
	layer = 0  # unter der UI (layer 100)
	var vp_size := get_window().size

	# --- Master-Composite-Viewport (Variante A) ---
	# HDR-2D, eigener World -> isoliertes WorldEnvironment (nur Glow/Bloom). Hier
	# komponieren die beiden Layer-Rects additiv; das Bloom wirkt global ueber die
	# Mischung. _final liest die HDR-Master-Textur (ACES-Tonemap + Vignette + Grain).
	_master = SubViewport.new()
	_master.own_world_3d = true
	_master.transparent_bg = false
	_master.size = vp_size
	_master.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_master.use_hdr_2d = true  # additive Ueberlappung > 1.0 -> echtes Bloom-Futter
	add_child(_master)

	# Schwarzer Hintergrund als Sicherheitsfond (im Master).
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 1)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_master.add_child(_bg)

	# Globaler Post: WorldEnvironment im Master (Bloom/Glow ueber die Mischung).
	var we := WorldEnvironment.new()
	_post_env = _make_post_env()
	we.environment = _post_env
	_master.add_child(we)

	var shader := Shader.new()
	shader.code = LAYER_SHADER

	# Zwei Slots: je ein SubViewport (off-screen) + ein vollflaechiges TextureRect
	# (im Master) mit Zoom-Shader.
	for i in range(2):
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.transparent_bg = false
		vp.size = vp_size
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
		rect.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED  # Rand klemmen (dunkel)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.material = mat
		rect.visible = false
		_master.add_child(rect)
		_rects.append(rect)

	# Finaler On-Screen-Rect: Master-Textur + Vignette/Grain.
	_overlay_mat = ShaderMaterial.new()
	var osh := Shader.new()
	osh.code = OVERLAY_SHADER
	_overlay_mat.shader = osh
	_overlay_mat.set_shader_parameter("vignette", 0.5)
	_overlay_mat.set_shader_parameter("grain", 0.0)

	_final = TextureRect.new()
	_final.texture = _master.get_texture()
	_final.set_anchors_preset(Control.PRESET_FULL_RECT)
	_final.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_final.stretch_mode = TextureRect.STRETCH_SCALE
	_final.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	_final.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_final.material = _overlay_mat
	add_child(_final)

	get_window().size_changed.connect(_on_window_resized)

	# Ersten Hintergrund laden und aktiv schalten.
	_scene_idx = 0
	_active = 0
	_load_into(0, SCENES[0])
	_show_only(0)


# Globales Post-Environment fuer den Master-Composite — NUR Bloom (2D-HDR-Glow).
# Tonemap (ACES) + Vignette + Grain macht bewusst der Overlay-Shader (_final), da
# auf ein kamera-loses 2D-Viewport nur das Glow zuverlaessig wirkt. Reihenfolge
# entspricht dem Web: additives Bloom -> ACES -> Vignette/Grain.
func _make_post_env() -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_CANVAS   # 2D-Canvas ist die "Szene" des Masters
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


# --------------------------------------------------------------- Oeffentliche API

func active_root() -> Node:
	return _roots[_active]


# Index der gerade aktiven Szene in SCENES (fuer den Sequencer).
func current_scene_index() -> int:
	return _scene_idx


# Wurzel-Knotenname von SCENES[idx], OHNE die Szene zu instanziieren (SceneState ist
# billig). Entspricht active_scene_key() der laufenden Szene -> stabiler Schluessel,
# ueber den der Sequencer ein Preset auf seine Szene abbildet.
func scene_key_for_index(idx: int) -> String:
	if idx < 0 or idx >= SCENES.size():
		return ""
	var ps := load(SCENES[idx]) as PackedScene
	if ps == null:
		return ""
	var st := ps.get_state()
	return st.get_node_name(0) if st.get_node_count() > 0 else ""


# Index der Szene mit diesem Wurzel-Namen (-1, wenn keine passt).
func scene_index_for_key(key: String) -> int:
	for i in range(SCENES.size()):
		if scene_key_for_index(i) == key:
			return i
	return -1


# Textur des fertig komponierten + getonemappten Master-Bildes (fuer die
# Multi-Window-Vorschau). Vignette/Grain liegen erst im _final-Overlay und damit
# bewusst NICHT in der Wand-Vorschau (sonst Vignette pro Einzelschirm).
func active_texture() -> Texture2D:
	return _master.get_texture()


# Globales Post-Environment (Master) — vom RuntimeUI-Panel als POST-Zone genutzt.
func post_environment() -> Environment:
	return _post_env


# Overlay-Material (Vignette/Grain) — vom RuntimeUI-Panel als POST-Regler genutzt.
func post_overlay() -> ShaderMaterial:
	return _overlay_mat


# SubViewports unabhaengig von der Fenstergroesse in einer festen (Wand-)Aufloesung
# rendern lassen -> das Bild entspricht dann dem Gesamt-Seitenverhaeltnis der Wand.
func set_render_size_override(s: Vector2i) -> void:
	_forced_size = s
	_apply_vp_size()


func clear_render_size_override() -> void:
	_forced_size = Vector2i.ZERO
	_apply_vp_size()


func _apply_vp_size() -> void:
	var s: Vector2i = _forced_size if _forced_size != Vector2i.ZERO else get_window().size
	for vp in _vps:
		vp.size = s
	if _master != null:
		_master.size = s


# Naechste Szene in SCENES-Reihenfolge.
func transition() -> void:
	transition_to((_scene_idx + 1) % SCENES.size())


# Gezielt zu SCENES[target_idx] wechseln (z.B. fuer einen Szenen-Wahlschalter im UI).
func transition_to(target_idx: int) -> void:
	if _busy or SCENES.size() < 2:
		return
	if target_idx < 0 or target_idx >= SCENES.size() or target_idx == _scene_idx:
		return
	_busy = true
	var nxt_idx := target_idx
	var out_slot := _active
	var in_slot := 1 - _active
	_load_into(in_slot, SCENES[nxt_idx])

	# Gemerkte Parameter dieser Szene SOFORT auf die noch unsichtbare neue Ebene
	# anwenden — vor dem Aufwaermframe. Sonst rendert die einkommende Szene zuerst die
	# .tscn-Defaults und springt erst nach dem Wechsel (active_changed) auf die echten
	# Werte -> sichtbares Hochrampen waehrend des Zooms. Jetzt zoomt sie direkt im
	# Zielzustand herein.
	_preapply_scene_params(_roots[in_slot])

	var in_rect := _rects[in_slot]
	var out_rect := _rects[out_slot]
	var in_mat := _mats[in_slot]
	var out_mat := _mats[out_slot]

	# Startzustand: neue Ebene voll herangezoomt/transparent, alte normal/opak.
	# (Zeichenreihenfolge egal: additives Blending ist kommutativ.)
	_vps[in_slot].render_target_update_mode = SubViewport.UPDATE_ALWAYS
	in_mat.set_shader_parameter("zoom", ZOOM_SPAN)
	in_mat.set_shader_parameter("fade", 0.0)
	in_rect.visible = true
	out_mat.set_shader_parameter("zoom", 1.0)
	out_mat.set_shader_parameter("fade", 1.0)
	out_rect.visible = true

	# (#3) Aufwaermframe: die frisch instanziierte Szene einmal rendern lassen,
	# bevor eingeblendet wird -> kein Leer-/Weissblitz im ersten sichtbaren Frame.
	await get_tree().process_frame

	var dur := maxf(0.05, transition_time)
	# (#1) Zoom (z-Position) symmetrisch: die alte Ebene beschleunigt in die Kamera
	# (ease-in 1->ZOOM_SPAN), die neue setzt sich gespiegelt aus dem Zoom (ease-out
	# ZOOM_SPAN->1). ease-in und ease-out sind exakte Zeit-Spiegel -> bei t=0.5 liegen
	# beide auf demselben Zoom ("gleiche z-Position bei 50 %").
	# Fades: sine ease-in-out, beide kreuzen exakt bei t=0.5 / 50 %, durchschreiten den
	# Ueberblend-Bereich aber zuegig -> kein traeger Dissolve-Eindruck. Additives Blending
	# (s. Shader) haelt die Luminanz konstant -> nie ein Schwarz-Einbruch in der Mitte.
	var tw := create_tween().set_parallel(true)
	tw.tween_property(out_mat, "shader_parameter/zoom", ZOOM_SPAN, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(out_mat, "shader_parameter/fade", 0.0, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(in_mat, "shader_parameter/zoom", 1.0, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(in_mat, "shader_parameter/fade", 1.0, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# (#4) Sobald die alte Ebene praktisch unsichtbar ist (~90 % der Zeit; bei sine
	# ease-in-out ist fade_out dort schon ~2-3 %), ihr Viewport schlafen legen -> spart
	# GPU, statt bis zum Schluss eine fast unsichtbare Ebene doppelt zu rendern.
	tw.tween_callback(func() -> void:
		_vps[out_slot].render_target_update_mode = SubViewport.UPDATE_DISABLED) \
		.set_delay(dur * 0.9)
	tw.finished.connect(func() -> void:
		_finish_transition(out_slot, in_slot, nxt_idx))


# --------------------------------------------------------------- Intern

func _finish_transition(out_slot: int, in_slot: int, nxt_idx: int) -> void:
	# Abgefahrene Szene entladen, ihr Viewport schlaeft.
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


# ParamStore die gemerkten scene/*+mat/*-Werte dieser Szene auf den frisch geladenen
# (noch unsichtbaren) Root anwenden lassen, bevor er gerendert wird. No-op, wenn es
# fuer die Szene noch keinen Cache gibt (erster Besuch) oder ParamStore fehlt.
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
	# Kamera der Szene im eigenen Viewport aktiv schalten.
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
