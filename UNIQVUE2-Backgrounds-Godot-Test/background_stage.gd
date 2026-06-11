extends CanvasLayer
## Hintergrund-Buehne (Autoload, layer 0 -> unter der UI).
##
## Jeder Hintergrund wird in ein EIGENES Off-Screen-SubViewport gerendert (eigene
## World3D -> eigene Kamera + eigenes WorldEnvironment/Glow). Angezeigt werden die
## Viewport-Texturen ueber zwei IMMER vollflaechige TextureRects mit einem
## Zoom-Shader -> nahtlos, keine schwarzen Raender (die Tiefe entsteht im UV-Zoom,
## nicht durch Skalieren des Rechtecks).
##
## TRANSITION (beide Hintergruende laufen live, linear ueber TRANSITION_TIME):
##   - alte Ebene : zoom 1.0 -> OUT_ZOOM  (faehrt in die Kamera / vergroessert)  + fade 1 -> 0
##   - neue Ebene : zoom IN_ZOOM -> 1.0   (taucht aus der Tiefe auf)             + fade 0 -> 1
## Die alte Ebene deckt waehrend des Vergroesserns stets den ganzen Schirm; die
## neue waechst dahinter auf -> uebergangslos.
##
## active_changed(root) feuert nach jedem Wechsel -> die UI befuellt sich daraus neu.

signal active_changed(root: Node)

const SCENES := [
	"res://tunnel_wave.tscn",
	"res://particle_wave.tscn",
]
const TRANSITION_TIME := 1.2   # Default; zur Laufzeit ueber transition_time anpassbar.
const OUT_ZOOM := 2.4    # Endvergroesserung der alten Ebene (Fahrt in die Kamera)
const IN_ZOOM := 0.5     # Startgroesse der neuen Ebene (aus der Tiefe)

# Laufzeit-Dauer der Transition (Sekunden); per RuntimeUI-Zahlenfeld einstellbar.
var transition_time := TRANSITION_TIME

# Vollflaechiger Zoom/Fade-Shader fuer beide Ebenen. Bei zoom=1, fade=1 exakt das
# unveraenderte Viewport-Bild (kein Pop am Anfang/Ende).
const LAYER_SHADER := "shader_type canvas_item;
uniform float zoom = 1.0;
uniform float fade = 1.0;
void fragment() {
	vec2 uv = (UV - vec2(0.5)) / zoom + vec2(0.5);
	vec2 cl = clamp(uv, vec2(0.0), vec2(1.0));
	// Ausserhalb [0..1] (bei zoom < 1) NICHT den Rand klemmen, sondern transparent
	// machen -> keine dunklen Schlieren/Raender, der schwarze Fond zeigt durch.
	float inside = step(uv.x, 1.0) * step(0.0, uv.x) * step(uv.y, 1.0) * step(0.0, uv.y);
	vec4 c = texture(TEXTURE, cl);
	COLOR = vec4(c.rgb, c.a * fade * inside);
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


func _ready() -> void:
	layer = 0  # unter der UI (layer 100)
	var vp_size := get_window().size

	# Schwarzer Hintergrund als Sicherheitsfond.
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 1)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var shader := Shader.new()
	shader.code = LAYER_SHADER

	# Zwei Slots: je ein SubViewport + ein vollflaechiges TextureRect mit Zoom-Shader.
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
		add_child(rect)
		_rects.append(rect)

	get_window().size_changed.connect(_on_window_resized)

	# Ersten Hintergrund laden und aktiv schalten.
	_scene_idx = 0
	_active = 0
	_load_into(0, SCENES[0])
	_show_only(0)


func _on_window_resized() -> void:
	_apply_vp_size()


# --------------------------------------------------------------- Oeffentliche API

func active_root() -> Node:
	return _roots[_active]


# Textur der aktuell aktiven Hintergrund-Ebene (fuer die Multi-Window-Vorschau).
func active_texture() -> Texture2D:
	return _vps[_active].get_texture()


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

	var in_rect := _rects[in_slot]
	var out_rect := _rects[out_slot]
	var in_mat := _mats[in_slot]
	var out_mat := _mats[out_slot]

	# Startzustand: neue Ebene klein/transparent (in der Tiefe), alte voll/opak.
	_vps[in_slot].render_target_update_mode = SubViewport.UPDATE_ALWAYS
	in_mat.set_shader_parameter("zoom", IN_ZOOM)
	in_mat.set_shader_parameter("fade", 0.0)
	in_rect.visible = true
	out_mat.set_shader_parameter("zoom", 1.0)
	out_mat.set_shader_parameter("fade", 1.0)
	out_rect.visible = true
	# Zeichenreihenfolge: neue Ebene HINTER die alte (alte oben, deckt voll).
	move_child(in_rect, 1)
	move_child(out_rect, get_child_count() - 1)

	# (#3) Aufwaermframe: die frisch instanziierte Szene einmal rendern lassen,
	# bevor eingeblendet wird -> kein Leer-/Weissblitz im ersten sichtbaren Frame.
	await get_tree().process_frame

	var dur := maxf(0.05, transition_time)
	# (#1) Easing der Bewegung (Zoom): die alte Ebene beschleunigt in die Kamera
	# (ease-in), die neue taucht zuegig auf und setzt sich weich (ease-out). Die
	# Fades bleiben linear -> sauberer, gleichmaessiger Cross-Dissolve.
	var tw := create_tween().set_parallel(true)
	tw.tween_property(out_mat, "shader_parameter/zoom", OUT_ZOOM, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(out_mat, "shader_parameter/fade", 0.0, dur) \
		.set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(in_mat, "shader_parameter/zoom", 1.0, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(in_mat, "shader_parameter/fade", 1.0, dur) \
		.set_trans(Tween.TRANS_LINEAR)
	# (#4) Sobald die alte Ebene praktisch unsichtbar ist (~90 % der Zeit, Fade
	# linear -> ca. 10 % Restdeckung), ihr Viewport schlafen legen -> spart GPU,
	# statt bis zum Schluss eine fast unsichtbare Ebene doppelt zu rendern.
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
