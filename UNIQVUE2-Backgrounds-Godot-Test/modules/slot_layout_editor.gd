extends Control
## Slot Layout Editor (toggle with F2).
##
## Left: a downscaled, letterboxed preview of the whole app window (= the wall). Real
## physical monitors (DisplayServer) are outlined for reference. Drag a slot body to
## move it, drag any corner grip to resize. Double-click empty space to zoom into the
## monitor under the cursor; double-click again (or "All") to zoom back out. Drag a
## module from the palette onto a slot to assign it — drop on empty space to create a
## slot there. Every edit updates the live wall in real time.
##
## Right: panel with built-in presets, new-slot, monitor zoom, the module palette, and
## the selected-slot inspector.

const PANEL_W := 312.0
const MARGIN := 28.0
const GRIP := 32.0          # corner grip size in pixels (larger = easier to grab)
const ACCENT := Color(1.0, 0.804, 0.0)        # RTD yellow
const TEXT := Color(0.90, 0.93, 0.96)
const MUTED := Color(0.58, 0.64, 0.72)
const ModuleDragButtonScript := preload("res://modules/module_drag_button.gd")
const SlotSettingsScript    := preload("res://modules/slot_settings.gd")
const TextSettingsScript    := preload("res://modules/text/text_settings.gd")

# Current zoom view in normalized wall space.
var _view_origin := Vector2.ZERO
var _view_size := Vector2.ONE

var _selected_id := -1
var _drop_hover_id := -1
var _drop_hover_empty := false

# Drag state for the canvas.
enum Drag { NONE, MOVE, RESIZE }
var _drag := Drag.NONE
var _drag_id := -1
var _drag_grab := Vector2.ZERO    # normalized offset within slot when moving
var _resize_fixed := Vector2.ZERO # normalized opposite corner held fixed when resizing
var _resize_aspect := 16.0 / 9.0  # pixel aspect locked while resizing with Shift

const DEFAULT_ASPECT := 16.0 / 9.0

var _panel: PanelContainer
var _sel_box: VBoxContainer
var _count_label: Label
var _slot_controls: VBoxContainer   # embedded slideshow settings widget
var _text_controls: VBoxContainer   # embedded text settings widget
var _layouts_box: VBoxContainer     # saved layout preset list
var _layout_name: LineEdit
var _w_spin: SpinBox
var _h_spin: SpinBox

var _font: Font
var _fs := 13


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = ThemeDB.fallback_font
	theme = _make_theme()
	_build_panel()
	resized.connect(queue_redraw)
	SlotManager.slots_changed.connect(_on_slots_changed)
	SlotManager.slot_rect_changed.connect(_on_rect_changed)
	SlotManager.layouts_changed.connect(_rebuild_layouts)


func on_opened() -> void:
	_refresh_count()
	_rebuild_selected()
	queue_redraw()


# ----------------------------------------------------------------- Theme

func _make_theme() -> Theme:
	var t := Theme.new()
	var mk := func(bg: Color) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.set_corner_radius_all(5)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		return sb
	t.set_stylebox("normal", "Button", mk.call(Color(0.13, 0.15, 0.18)))
	t.set_stylebox("hover", "Button", mk.call(Color(0.19, 0.22, 0.26)))
	var pressed: StyleBoxFlat = mk.call(ACCENT)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", Color(0.05, 0.05, 0.06))
	t.set_font_size("font_size", "Button", 13)
	return t


# ----------------------------------------------------------------- Side panel

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -PANEL_W
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.065, 0.085, 0.98)
	sb.border_color = Color(0.18, 0.21, 0.26)
	sb.border_width_left = 1
	sb.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)

	# Right margin reserves space for the vertical scrollbar so it never overlaps
	# content (slider value labels, ✕ buttons, etc.).
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_left", 2)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 7)
	v.custom_minimum_size = Vector2(PANEL_W - 64, 0)
	margin.add_child(v)

	_add_title(v, "SLOT LAYOUT  ·  F2")
	_add_hint(v, "Drag slot = move · drag corner = resize\nShift+resize = keep aspect (16:9)\nDrag a module onto a slot (or empty = new slot)")

	_add_header(v, "PRESETS  (whole wall)")
	var pg := GridContainer.new()
	pg.columns = 3
	pg.add_theme_constant_override("h_separation", 6)
	pg.add_theme_constant_override("v_separation", 6)
	v.add_child(pg)
	for pname in SlotManager.PRESET_ORDER:
		var b := Button.new()
		b.text = pname
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): SlotManager.apply_preset(pname))
		pg.add_child(b)

	_add_header(v, "SLOTS")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	var nb := Button.new()
	nb.text = "+ New Slot"
	nb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nb.pressed.connect(_on_new_slot)
	row.add_child(nb)
	var cab := Button.new()
	cab.text = "Clear all"
	cab.pressed.connect(func():
		_selected_id = -1
		SlotManager.clear_slots())
	row.add_child(cab)
	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 11)
	_count_label.add_theme_color_override("font_color", MUTED)
	v.add_child(_count_label)

	_add_header(v, "SAVED LAYOUTS")
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 6)
	_layout_name = LineEdit.new()
	_layout_name.placeholder_text = "layout name"
	_layout_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lrow.add_child(_layout_name)
	var savb := Button.new()
	savb.text = "Save"
	savb.pressed.connect(func():
		SlotManager.save_layout(_layout_name.text)
		_layout_name.clear())
	lrow.add_child(savb)
	v.add_child(lrow)
	_layouts_box = VBoxContainer.new()
	_layouts_box.add_theme_constant_override("separation", 4)
	v.add_child(_layouts_box)
	_rebuild_layouts()

	_add_header(v, "MODULES  (drag → slot)")
	for type in SlotManager.MODULE_REGISTRY.keys():
		var info = SlotManager.MODULE_REGISTRY[type]
		var mb := ModuleDragButtonScript.new()
		mb.text = "≡  " + info.name
		mb.module_type = type
		mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mb.add_theme_color_override("font_color", info.color.lightened(0.35))
		v.add_child(mb)

	v.add_child(HSeparator.new())
	_add_header(v, "SELECTED SLOT")
	_sel_box = VBoxContainer.new()
	_sel_box.add_theme_constant_override("separation", 4)
	v.add_child(_sel_box)

	_slot_controls = SlotSettingsScript.new()
	_slot_controls.visible = false
	v.add_child(_slot_controls)

	_text_controls = TextSettingsScript.new()
	_text_controls.visible = false
	v.add_child(_text_controls)

	_refresh_count()
	_rebuild_selected()


func _add_title(parent: Node, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", ACCENT)
	parent.add_child(l)


func _add_hint(parent: Node, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)


func _add_header(parent: Node, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.5, 0.57, 0.68))
	parent.add_child(l)


func _rebuild_layouts() -> void:
	if _layouts_box == null:
		return
	for c in _layouts_box.get_children():
		c.queue_free()
	var names := SlotManager.list_layouts()
	if names.is_empty():
		var l := Label.new()
		l.text = "(none saved)"
		l.add_theme_font_size_override("font_size", 11)
		l.add_theme_color_override("font_color", MUTED)
		_layouts_box.add_child(l)
		return
	for nm in names:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var lb := Button.new()
		lb.text = nm
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lb.pressed.connect(func(): SlotManager.load_layout(nm))
		var db := Button.new()
		db.text = "✕"
		db.pressed.connect(func(): SlotManager.delete_layout(nm))
		row.add_child(lb)
		row.add_child(db)
		_layouts_box.add_child(row)


func _window_px() -> Vector2:
	var win := get_window()
	return Vector2(win.size) if win else Vector2(1920, 1080)


func _on_rect_changed(id: int) -> void:
	queue_redraw()
	# Keep the px fields live while dragging the selected slot.
	if id == _selected_id and _w_spin != null and _h_spin != null:
		var s := SlotManager.find_slot(id)
		if not s.is_empty():
			var ws := _window_px()
			_w_spin.set_block_signals(true)
			_h_spin.set_block_signals(true)
			_w_spin.value = roundf(s.rect.size.x * ws.x)
			_h_spin.value = roundf(s.rect.size.y * ws.y)
			_w_spin.set_block_signals(false)
			_h_spin.set_block_signals(false)


func _refresh_count() -> void:
	if _count_label:
		_count_label.text = "%d / %d slots used" % [SlotManager.get_slots().size(), SlotManager.MAX_SLOTS]


func _rebuild_selected() -> void:
	for c in _sel_box.get_children():
		c.queue_free()
	_w_spin = null
	_h_spin = null
	var s := SlotManager.find_slot(_selected_id)
	if s.is_empty():
		var l := Label.new()
		l.text = "(none — click a slot)"
		l.add_theme_color_override("font_color", MUTED)
		_sel_box.add_child(l)
		if _slot_controls:
			_slot_controls.bind(-1, null)
		if _text_controls:
			_text_controls.bind(-1, null)
		return

	var info := Label.new()
	info.text = "Slot #%d" % s.id
	info.add_theme_color_override("font_color", ACCENT)
	info.add_theme_font_size_override("font_size", 14)
	_sel_box.add_child(info)

	var rectl := Label.new()
	rectl.add_theme_font_size_override("font_size", 11)
	rectl.add_theme_color_override("font_color", MUTED)
	rectl.text = "x %.2f  y %.2f   w %.2f  h %.2f" % [s.rect.position.x, s.rect.position.y, s.rect.size.x, s.rect.size.y]
	_sel_box.add_child(rectl)

	# Exact pixel size (W × H). Position (top-left) stays fixed.
	var ws := _window_px()
	var pxrow := HBoxContainer.new()
	pxrow.add_theme_constant_override("separation", 5)
	_w_spin = SpinBox.new()
	_w_spin.min_value = 16; _w_spin.max_value = roundf(ws.x); _w_spin.step = 1
	_w_spin.value = roundf(s.rect.size.x * ws.x)
	_w_spin.custom_minimum_size = Vector2(78, 0)
	_w_spin.value_changed.connect(func(v): _set_slot_px(v, -1.0))
	var xlab := Label.new(); xlab.text = "×"; xlab.add_theme_color_override("font_color", MUTED)
	_h_spin = SpinBox.new()
	_h_spin.min_value = 16; _h_spin.max_value = roundf(ws.y); _h_spin.step = 1
	_h_spin.value = roundf(s.rect.size.y * ws.y)
	_h_spin.custom_minimum_size = Vector2(78, 0)
	_h_spin.value_changed.connect(func(v): _set_slot_px(-1.0, v))
	pxrow.add_child(_w_spin); pxrow.add_child(xlab); pxrow.add_child(_h_spin)
	var pxlab := Label.new(); pxlab.text = "px"; pxlab.add_theme_color_override("font_color", MUTED)
	pxrow.add_child(pxlab)
	_sel_box.add_child(pxrow)

	var b169 := Button.new()
	b169.text = "Set 16:9 (from width)"
	b169.pressed.connect(func(): _set_slot_px(_w_spin.value, roundf(_w_spin.value * 9.0 / 16.0)))
	_sel_box.add_child(b169)

	for type in SlotManager.MODULE_REGISTRY.keys():
		var minfo = SlotManager.MODULE_REGISTRY[type]
		var b := Button.new()
		var mark := "● " if s.module == type else "○ "
		b.text = mark + minfo.name
		b.pressed.connect(func(): SlotManager.assign_module(_selected_id, type))
		_sel_box.add_child(b)

	var clr := Button.new()
	clr.text = "Clear module"
	clr.pressed.connect(func(): SlotManager.assign_module(_selected_id, ""))
	_sel_box.add_child(clr)

	var rm := Button.new()
	rm.text = "Remove slot"
	rm.add_theme_color_override("font_color", Color(1, 0.55, 0.55))
	rm.pressed.connect(func():
		var rid := _selected_id
		_selected_id = -1
		SlotManager.remove_slot(rid))
	_sel_box.add_child(rm)

	# Embedded module controls — each panel shows/hides itself by type.
	var _bound_module = SlotManager.get_module(_selected_id) if s.module != "" else null
	if _slot_controls:
		_slot_controls.bind(_selected_id, _bound_module)
	if _text_controls:
		_text_controls.bind(_selected_id, _bound_module)


func _on_slots_changed() -> void:
	_refresh_count()
	_rebuild_selected()
	queue_redraw()


func _on_new_slot() -> void:
	var id := _create_slot_in_view(Vector2(0.5, 0.5), "")
	if id != -1:
		_selected_id = id
		_rebuild_selected()
		queue_redraw()


# Create a 16:9 slot centered on a normalized point. Width derived from pixel aspect so
# the slot is a true 16:9 rectangle on screen regardless of the wall's aspect.
func _create_slot_in_view(center_norm: Vector2, module: String) -> int:
	if not SlotManager.can_add():
		return -1
	var ws := _window_px()
	var h := _view_size.y * 0.4
	var w := h * DEFAULT_ASPECT * (ws.y / ws.x)
	var x := center_norm.x - w * 0.5
	var y := center_norm.y - h * 0.5
	return SlotManager.add_slot(Rect2(x, y, w, h), module)


# Set the selected slot's size in pixels (negative = keep that dimension). Top-left fixed.
func _set_slot_px(w_px: float, h_px: float) -> void:
	var s := SlotManager.find_slot(_selected_id)
	if s.is_empty():
		return
	var ws := _window_px()
	var nw: float = s.rect.size.x if w_px < 0.0 else w_px / ws.x
	var nh: float = s.rect.size.y if h_px < 0.0 else h_px / ws.y
	SlotManager.set_slot_rect(_selected_id, Rect2(s.rect.position, Vector2(nw, nh)), true)


# ----------------------------------------------------------------- Geometry

# 1:1 with the window (= the wall surface). The editor overlay maps slots EXACTLY like
# the runtime layer (normalized * window size), so the yellow outline sits precisely on
# the live slot — no letterbox, no centering, no per-monitor offset. The side panel
# floats on top of the right edge.
func _stage_rect() -> Rect2:
	return Rect2(Vector2.ZERO, size)


func _norm_to_screen(n: Vector2) -> Vector2:
	var sr := _stage_rect()
	return sr.position + (n - _view_origin) / _view_size * sr.size


func _screen_to_norm(p: Vector2) -> Vector2:
	var sr := _stage_rect()
	return (p - sr.position) / sr.size * _view_size + _view_origin


func _slot_screen_rect(s: Dictionary) -> Rect2:
	var p := _norm_to_screen(s.rect.position)
	var sr := _stage_rect()
	var sz: Vector2 = s.rect.size / _view_size * sr.size
	return Rect2(p, sz)


func _slot_at(point: Vector2) -> int:
	var arr := SlotManager.get_slots()
	for i in range(arr.size() - 1, -1, -1):
		if _slot_screen_rect(arr[i]).has_point(point):
			return arr[i].id
	return -1


# Returns the corner index (0=TL,1=TR,2=BL,3=BR) of slot `s` under `point`, or -1.
func _corner_at(s: Dictionary, point: Vector2) -> int:
	var r := _slot_screen_rect(s)
	var corners := [r.position, r.position + Vector2(r.size.x, 0), r.position + Vector2(0, r.size.y), r.position + r.size]
	for i in range(4):
		if Rect2(corners[i] - Vector2(GRIP, GRIP) * 0.5, Vector2(GRIP, GRIP)).has_point(point):
			return i
	return -1


# ----------------------------------------------------------------- Input

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(event)
		else:
			_on_release()
	elif event is InputEventMouseMotion and _drag != Drag.NONE:
		_on_drag_motion(event.position)


func _on_press(event: InputEventMouseButton) -> void:
	var pos := event.position
	if not _stage_rect().grow(GRIP).has_point(pos):
		return
	var id := _slot_at(pos)

	if id == -1:
		if _selected_id != -1:
			_selected_id = -1
			_rebuild_selected()
			queue_redraw()
		return

	_selected_id = id
	_rebuild_selected()
	var s := SlotManager.find_slot(id)
	var corner := _corner_at(s, pos)
	if corner != -1:
		_drag = Drag.RESIZE
		_drag_id = id
		# Fixed = opposite corner in normalized space.
		var r: Rect2 = s.rect
		match corner:
			0:
				_resize_fixed = r.position + r.size       # dragging TL -> fix BR
			1:
				_resize_fixed = r.position + Vector2(0, r.size.y)
			2:
				_resize_fixed = r.position + Vector2(r.size.x, 0)
			3:
				_resize_fixed = r.position
		# Pixel aspect to lock when Shift is held during the drag.
		var ws := _window_px()
		_resize_aspect = maxf(0.01, (r.size.x * ws.x) / maxf(1.0, r.size.y * ws.y))
	else:
		_drag = Drag.MOVE
		_drag_id = id
		_drag_grab = _screen_to_norm(pos) - s.rect.position
	queue_redraw()


func _on_drag_motion(pos: Vector2) -> void:
	var s := SlotManager.find_slot(_drag_id)
	if s.is_empty():
		return
	var n := _screen_to_norm(pos)
	if _drag == Drag.MOVE:
		SlotManager.set_slot_rect(_drag_id, Rect2(n - _drag_grab, s.rect.size), false)
	elif _drag == Drag.RESIZE:
		var min_n := SlotManager.MIN_SLOT_NORM
		var w := maxf(min_n, absf(n.x - _resize_fixed.x))
		var h := maxf(min_n, absf(n.y - _resize_fixed.y))
		# Shift = proportional: lock the pixel aspect captured at press.
		if Input.is_key_pressed(KEY_SHIFT) and _resize_aspect > 0.0:
			var ws := _window_px()
			h = maxf(min_n, (w * ws.x / _resize_aspect) / ws.y)
		# Keep the opposite (fixed) corner anchored.
		var x0: float = _resize_fixed.x if n.x >= _resize_fixed.x else _resize_fixed.x - w
		var y0: float = _resize_fixed.y if n.y >= _resize_fixed.y else _resize_fixed.y - h
		SlotManager.set_slot_rect(_drag_id, Rect2(x0, y0, w, h), false)


func _on_release() -> void:
	if _drag != Drag.NONE:
		_drag = Drag.NONE
		_drag_id = -1
		SlotManager.commit()
		_rebuild_selected()
		queue_redraw()


# ----------------------------------------------------------------- Drag & drop

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY or data.get("kind", "") != "module":
		return false
	if not _stage_rect().has_point(at_position):
		return false
	var id := _slot_at(at_position)
	var empty := id == -1 and SlotManager.can_add()
	if id != _drop_hover_id or empty != _drop_hover_empty:
		_drop_hover_id = id
		_drop_hover_empty = empty
		queue_redraw()
	return id != -1 or empty


func _drop_data(at_position: Vector2, data: Variant) -> void:
	var type := String(data.get("type", ""))
	var id := _slot_at(at_position)
	_drop_hover_id = -1
	_drop_hover_empty = false
	if id == -1:
		# Drop on empty canvas -> create a slot there and assign.
		id = _create_slot_in_view(_screen_to_norm(at_position), type)
		if id == -1:
			return
	else:
		SlotManager.assign_module(id, type)
	_selected_id = id
	_rebuild_selected()
	queue_redraw()


# ----------------------------------------------------------------- Draw

func _draw() -> void:
	# Light dim only — the editor overlays the live wall 1:1, keep content visible.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.025, 0.03, 0.45))

	var sr := _stage_rect()
	_draw_monitors(sr)

	for s in SlotManager.get_slots():
		_draw_slot(s)

	if _drop_hover_empty:
		var c := get_local_mouse_position()
		draw_string(_font, c + Vector2(12, 0), "+ new slot", HORIZONTAL_ALIGNMENT_LEFT, -1, _fs, ACCENT)

	draw_string(_font, sr.position + Vector2(4, -8), "Full wall  ·  real monitors outlined", HORIZONTAL_ALIGNMENT_LEFT, -1, _fs, MUTED)


func _draw_monitors(sr: Rect2) -> void:
	var col := Color(0.45, 0.55, 0.7, 0.85)
	for cell in SlotManager.monitor_cells():
		var r: Rect2 = cell.rect
		var screen := Rect2(_norm_to_screen(r.position), r.size / _view_size * sr.size)
		var vis := screen.intersection(sr)
		if vis.size.x <= 0 or vis.size.y <= 0:
			continue
		# dashed-ish double border
		draw_rect(vis, col, false, 1.0)
		draw_string(_font, vis.position + Vector2(5, 15), "Monitor %d" % [cell.index + 1], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


func _draw_slot(s: Dictionary) -> void:
	var sr := _stage_rect()
	var rect := _slot_screen_rect(s)
	var draw_r := rect.intersection(sr)
	if draw_r.size.x <= 0 or draw_r.size.y <= 0:
		return

	var has_mod: bool = s.module != ""
	var base := Color(0.3, 0.34, 0.4)
	if has_mod:
		var info = SlotManager.MODULE_REGISTRY.get(s.module, null)
		if info != null:
			base = info.color
	draw_rect(draw_r, Color(base.r, base.g, base.b, 0.32 if has_mod else 0.13), true)

	if s.id == _drop_hover_id:
		draw_rect(draw_r, Color(1, 1, 1, 0.22), true)

	var is_sel: bool = s.id == _selected_id
	draw_rect(rect, ACCENT if is_sel else base, false, 2.0 if is_sel else 1.0)

	var txt := "#%d" % s.id
	if has_mod:
		var info2 = SlotManager.MODULE_REGISTRY.get(s.module, null)
		txt += "  " + (info2.name if info2 else s.module)
	else:
		txt += "  (empty)"
	if rect.size.x > 44 and rect.size.y > 20:
		draw_string(_font, rect.position + Vector2(7, 17), txt, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10, _fs, TEXT)

	if is_sel:
		for cp in [rect.position, rect.position + Vector2(rect.size.x, 0), rect.position + Vector2(0, rect.size.y), rect.position + rect.size]:
			draw_rect(Rect2(cp - Vector2(GRIP, GRIP) * 0.5, Vector2(GRIP, GRIP)), ACCENT, true)
