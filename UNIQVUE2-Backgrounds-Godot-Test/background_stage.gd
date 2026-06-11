extends CanvasLayer
## Hintergrund-Buehne (Autoload, layer 0 -> unter der UI).
##
## Jeder Hintergrund wird in ein EIGENES Off-Screen-SubViewport gerendert (eigene
## World3D -> eigene Kamera + eigenes WorldEnvironment/Glow). Angezeigt werden die
## Viewport-Texturen als zwei vollflaechige TextureRects.
##
## TRANSITION blendet mit Tiefe + Transparenz ueber (beide Hintergruende laufen live):
##   - alte Ebene  : skaliert 1.0 -> FAR_SCALE (taucht in die Tiefe ab) + Alpha 1 -> 0
##   - neue Ebene  : skaliert FAR_SCALE -> 1.0 (kommt aus der Tiefe) + Alpha 0 -> 1
## Beides linear ueber TRANSITION_TIME.
##
## active_changed(root) feuert nach Boot und nach jedem Wechsel -> die UI befuellt
## sich daraus neu (RuntimeUI haengt am Signal).

signal active_changed(root: Node)

const SCENES := [
	"res://tunnel_wave.tscn",
	"res://particle_wave.tscn",
]
const TRANSITION_TIME := 1.2
const FAR_SCALE := 0.65   # "ferne" Skalierung (Tiefe) der ab-/auftauchenden Ebene

var _vps: Array[SubViewport] = []
var _rects: Array[TextureRect] = []
var _roots: Array[Node] = [null, null]
var _bg: ColorRect
var _active := 0          # aktiver Slot (0/1)
var _scene_idx := 0       # Index in SCENES, der gerade aktiv ist
var _busy := false


func _ready() -> void:
	layer = 0  # unter der UI (layer 100)
	var vp_size := get_window().size

	# Schwarzer Hintergrund, fuellt Luecken waehrend der Skalierung.
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 1)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# Zwei Slots: je ein SubViewport + ein TextureRect.
	for i in range(2):
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.transparent_bg = false
		vp.size = vp_size
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(vp)
		_vps.append(vp)

		var rect := TextureRect.new()
		rect.texture = vp.get_texture()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.pivot_offset = Vector2(vp_size) * 0.5  # Skalierung um die Mitte
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
	var s := get_window().size
	for i in range(_vps.size()):
		_vps[i].size = s
		_rects[i].pivot_offset = Vector2(s) * 0.5


# --------------------------------------------------------------- Oeffentliche API

func active_root() -> Node:
	return _roots[_active]


func transition() -> void:
	if _busy or SCENES.size() < 2:
		return
	_busy = true
	var nxt_idx := (_scene_idx + 1) % SCENES.size()
	var out_slot := _active
	var in_slot := 1 - _active
	_load_into(in_slot, SCENES[nxt_idx])

	var in_rect := _rects[in_slot]
	var out_rect := _rects[out_slot]

	# Startzustand: neue Ebene klein/transparent (in der Tiefe), alte voll/opak.
	_vps[in_slot].render_target_update_mode = SubViewport.UPDATE_ALWAYS
	in_rect.scale = Vector2(FAR_SCALE, FAR_SCALE)
	in_rect.modulate.a = 0.0
	in_rect.visible = true
	out_rect.scale = Vector2.ONE
	out_rect.modulate.a = 1.0
	out_rect.visible = true
	# Zeichenreihenfolge: neue Ebene HINTER die alte (alte oben).
	move_child(in_rect, 1)
	move_child(out_rect, get_child_count() - 1)

	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(out_rect, "scale", Vector2(FAR_SCALE, FAR_SCALE), TRANSITION_TIME)
	tw.tween_property(out_rect, "modulate:a", 0.0, TRANSITION_TIME)
	tw.tween_property(in_rect, "scale", Vector2.ONE, TRANSITION_TIME)
	tw.tween_property(in_rect, "modulate:a", 1.0, TRANSITION_TIME)
	tw.finished.connect(func() -> void:
		_finish_transition(out_slot, in_slot, nxt_idx))


# --------------------------------------------------------------- Intern

func _finish_transition(out_slot: int, in_slot: int, nxt_idx: int) -> void:
	# Abgetauchte Szene entladen, ihr Viewport schlaeft.
	if _roots[out_slot] != null:
		_roots[out_slot].queue_free()
		_roots[out_slot] = null
	_vps[out_slot].render_target_update_mode = SubViewport.UPDATE_DISABLED
	var out_rect := _rects[out_slot]
	out_rect.visible = false
	out_rect.scale = Vector2.ONE
	out_rect.modulate.a = 1.0

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
		_rects[i].scale = Vector2.ONE
		_rects[i].modulate.a = 1.0
