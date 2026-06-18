extends Control
# CanvasLayer-Overlay (Pfeile + Pagination), gezeichnet mit _draw() in Pixeln relativ zur
# SubViewport-Groesse. Lebt im SubViewport, skaliert also mit dem Slot und sitzt pro
# Modul-Klon korrekt.
#
# Nav + Pagination erscheinen nur in slidedeck/coverflow/carousel; Grid und Gallery haben
# eigene Navigation (kommt mit ihren Stufen).

@export var module_path: NodePath
var mod  # SlideshowModule

const YELLOW := Color("FFCD00")
const WHITE := Color(1, 1, 1)

# Hit-Targets, jeden Frame neu gesetzt (Pixel im Overlay-Raum).
var _arrow_l := Vector2.ZERO
var _arrow_r := Vector2.ZERO
var _arrow_r_hit := 24.0
var _dot_hits: Array = []   # [{pos:Vector2, r:float, i:int}]
var _nav_visible := false
var _pag_visible := false
var _vertical := false


func _ready() -> void:
	mod = get_node(module_path)
	# STOP, damit _gui_input zuverlaessig feuert. Bei Nicht-Treffer wird das Event nicht
	# konsumiert (kein accept_event), sodass spaetere Leerklick-/Swipe-Logik im Modul es
	# noch sehen kann.
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(_dt: float) -> void:
	_layout()
	queue_redraw()


func _arrows_mode() -> bool:
	var m: String = mod.state.mode
	return m == "slidedeck" or m == "coverflow" or m == "carousel" or m == "gallery"


func _pag_mode() -> bool:
	var m: String = mod.state.mode
	return m == "slidedeck" or m == "coverflow" or m == "carousel"


func _layout() -> void:
	var w := size.x
	var h := size.y
	_nav_visible = _arrows_mode() and mod.state.show_nav
	_pag_visible = _pag_mode() and mod.state.show_pagination
	_vertical = mod.state.mode == "slidedeck" and mod.state.transition == "swipeV"

	var mid_y := h / 2.0
	var inset := maxf(34.0, w * 0.04)
	_arrow_l = Vector2(inset, mid_y)
	_arrow_r = Vector2(w - inset, mid_y)
	_arrow_r_hit = 24.0

	# Dots: nur aktive (NV) Slides, zentriert am unteren Rand.
	_dot_hits.clear()
	var n: int = mod.nv()
	if n <= 0:
		return
	var gap := minf(26.0, w / float(n + 2))
	var y := h - maxf(24.0, h * 0.05)
	var total := float(n - 1) * gap
	var start_x := w / 2.0 - total / 2.0
	for i in range(n):
		var x := start_x + float(i) * gap
		_dot_hits.append({"pos": Vector2(x, y), "r": 9.0, "i": i})


func _draw() -> void:
	if _nav_visible:
		_draw_arrow(_arrow_l, 1, _vertical)
		_draw_arrow(_arrow_r, -1, _vertical)
	if _pag_visible:
		var idx: int = mod.state.index
		for d in _dot_hits:
			var active: bool = d.i == idx
			var ring_op := 0.9 if active else 0.5
			_draw_ring(d.pos, 4.2, 5.4, Color(1, 1, 1, ring_op))
			if active:
				draw_circle(d.pos, 3.2, YELLOW)


func _draw_ring(center: Vector2, r_in: float, r_out: float, col: Color) -> void:
	var seg := 40
	var pts := PackedVector2Array()
	for i in range(seg + 1):
		var a := TAU * float(i) / float(seg)
		pts.append(center + Vector2(cos(a), sin(a)) * r_out)
	var pts_in := PackedVector2Array()
	for i in range(seg + 1):
		var a := TAU * float(i) / float(seg)
		pts_in.append(center + Vector2(cos(a), sin(a)) * r_in)
	var strip := PackedVector2Array()
	var cols := PackedColorArray()
	for i in range(seg):
		strip.append(pts[i]); cols.append(col)
		strip.append(pts_in[i]); cols.append(col)
		strip.append(pts[i + 1]); cols.append(col)
		strip.append(pts_in[i]); cols.append(col)
		strip.append(pts_in[i + 1]); cols.append(col)
		strip.append(pts[i + 1]); cols.append(col)
	draw_polygon(strip, cols)


# Pfeil: Kreisring + Chevron-Polygon. dir=1 zeigt nach links (prev), dir=-1 nach rechts (next).
func _draw_arrow(center: Vector2, dir: int, vertical: bool) -> void:
	_draw_ring(center, 18.0, 21.0, Color(1, 1, 1, 0.9))
	var d := float(dir)
	var l := 6.5
	var hw := 5.5
	var th := 2.0
	var shape := PackedVector2Array([
		Vector2(d * l, -hw),
		Vector2(d * (l - th * 1.6), -hw + th),
		Vector2(-d * (l - th), 0),
		Vector2(d * (l - th * 1.6), hw - th),
		Vector2(d * l, hw),
		Vector2(-d * (l - th * 2.2), 0),
	])
	var rot := PI / 2.0 if vertical else 0.0
	var out := PackedVector2Array()
	for p in shape:
		var pr := p.rotated(rot)
		out.append(center + pr)
	draw_colored_polygon(out, Color(1, 1, 1, 0.95))


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var mode: String = mod.state.mode

	if not event.pressed:
		# Release: grid hold-to-fit returns to the grid.
		if mode == "grid":
			mod.grid_release()
			accept_event()
		return

	var p: Vector2 = event.position
	# Arrows / pagination first.
	if _nav_visible:
		if p.distance_to(_arrow_l) < 24.0:
			mod.prev()
			accept_event()
			return
		if p.distance_to(_arrow_r) < _arrow_r_hit:
			mod.next()
			accept_event()
			return
	if _pag_visible:
		for d in _dot_hits:
			if p.distance_to(d.pos) < d.r + 4.0:
				mod.go_to(d.i)
				accept_event()
				return

	# Grid / Gallery: pick a slide by its projected rect.
	if mode == "grid" or mode == "gallery":
		var idx := _pick_at(p)
		if idx >= 0:
			if mode == "grid":
				mod.grid_press(idx)   # hold to fit into the slot
			else:
				mod.go_to(idx)        # gallery: switch main image
			accept_event()


func _pick_at(p: Vector2) -> int:
	var targets: Array = mod.pick_targets
	for i in range(targets.size() - 1, -1, -1):
		if (targets[i].rect as Rect2).has_point(p):
			return int(targets[i].idx)
	return -1
