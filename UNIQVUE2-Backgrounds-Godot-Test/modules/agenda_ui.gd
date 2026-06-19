extends Control
## Agenda UI (toggle with A). Left-side panel: a rundown of cues. Click a cue to switch
## the whole show to it (z-transition, per-cue trans time). Add the current live state as
## a new cue, reorder/recapture/remove cues, and save/load named agendas.

const PANEL_W := 348.0
const ACCENT := Color(1.0, 0.804, 0.0)
const TEXT := Color(0.90, 0.93, 0.96)
const MUTED := Color(0.58, 0.64, 0.72)

var _panel: PanelContainer
var _list_box: VBoxContainer
var _agendas_box: VBoxContainer
var _new_name: LineEdit
var _agenda_name: LineEdit
var _cur_label: Label
var _dragging := false
var _drag_off  := Vector2.ZERO


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # only the panel blocks; wall stays clickable
	theme = _make_theme()
	_build_panel()
	Agenda.state_changed.connect(_on_state_changed)
	Agenda.agendas_changed.connect(_rebuild_agendas)
	get_window().size_changed.connect(_on_window_resized)


func on_opened() -> void:
	_rebuild_list()
	_rebuild_agendas()


func _on_state_changed() -> void:
	_rebuild_list()


func _on_window_resized() -> void:
	if _panel == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var panel_h := maxf(400.0, vp.y - 32.0)
	_panel.custom_minimum_size = Vector2(PANEL_W, panel_h)
	_panel.size = Vector2(PANEL_W, panel_h)
	_panel.position = _panel.position.clamp(Vector2.ZERO, (vp - _panel.size).max(Vector2.ZERO))


func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if _dragging:
			_drag_off = _panel.position - event.global_position
	elif event is InputEventMouseMotion and _dragging:
		var vp := get_viewport().get_visible_rect().size
		_panel.position = (event.global_position + _drag_off).clamp(
			Vector2.ZERO, (vp - _panel.size).max(Vector2.ZERO))
		get_viewport().set_input_as_handled()


# ----------------------------------------------------------------- Theme

func _make_theme() -> Theme:
	var t := Theme.new()
	var mk := func(bg: Color) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = bg
		s.set_corner_radius_all(5)
		s.content_margin_left = 8; s.content_margin_right = 8
		s.content_margin_top = 5; s.content_margin_bottom = 5
		return s
	for cls in ["Button", "OptionButton"]:
		t.set_stylebox("normal", cls, mk.call(Color(0.13, 0.15, 0.18)))
		t.set_stylebox("hover", cls, mk.call(Color(0.19, 0.22, 0.26)))
		t.set_stylebox("pressed", cls, mk.call(Color(0.19, 0.22, 0.26)))
		t.set_stylebox("focus", cls, StyleBoxEmpty.new())
		t.set_color("font_color", cls, TEXT)
	return t


# ----------------------------------------------------------------- Panel

func _build_panel() -> void:
	var vp := get_viewport().get_visible_rect().size
	var panel_h := maxf(400.0, vp.y - 32.0)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.custom_minimum_size = Vector2(PANEL_W, panel_h)
	_panel.size = Vector2(PANEL_W, panel_h)
	_panel.position = Vector2(16.0, 16.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.065, 0.085, 0.98)
	sb.border_color = Color(0.18, 0.21, 0.26)
	sb.border_width_right = 1
	sb.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	_panel.add_child(outer)

	var drag_handle := Label.new()
	drag_handle.text = "  AGENDA  ·  drag · A"
	drag_handle.add_theme_font_size_override("font_size", 11)
	drag_handle.add_theme_color_override("font_color", ACCENT)
	drag_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	drag_handle.custom_minimum_size = Vector2(0, 22)
	drag_handle.clip_text = true
	drag_handle.gui_input.connect(_on_title_input)
	outer.add_child(drag_handle)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_left", 2)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	margin.add_child(v)

	_add_hint(v, "Click a cue to switch the show. Each cue = style + background + params + slot layout.")

	# Transport.
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 6)
	var bprev := Button.new(); bprev.text = "‹ Prev"; bprev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bprev.pressed.connect(func(): Agenda.prev())
	var bnext := Button.new(); bnext.text = "Next ›"; bnext.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bnext.pressed.connect(func(): Agenda.next())
	trow.add_child(bprev); trow.add_child(bnext)
	v.add_child(trow)
	_cur_label = Label.new()
	_cur_label.add_theme_font_size_override("font_size", 11)
	_cur_label.add_theme_color_override("font_color", MUTED)
	v.add_child(_cur_label)

	# Add current state.
	_add_header(v, "ADD CUE  (snapshot live state)")
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 6)
	_new_name = LineEdit.new()
	_new_name.placeholder_text = "cue name"
	_new_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arow.add_child(_new_name)
	var addb := Button.new(); addb.text = "+ Add"
	addb.pressed.connect(func():
		Agenda.add_current(_new_name.text)
		_new_name.clear())
	arow.add_child(addb)
	v.add_child(arow)

	_add_header(v, "RUNDOWN")
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 5)
	v.add_child(_list_box)

	_add_header(v, "SAVED AGENDAS")
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 6)
	_agenda_name = LineEdit.new()
	_agenda_name.placeholder_text = "agenda name"
	_agenda_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srow.add_child(_agenda_name)
	var savb := Button.new(); savb.text = "Save"
	savb.pressed.connect(func():
		Agenda.save_agenda(_agenda_name.text)
		_agenda_name.clear())
	srow.add_child(savb)
	v.add_child(srow)
	_agendas_box = VBoxContainer.new()
	_agendas_box.add_theme_constant_override("separation", 4)
	v.add_child(_agendas_box)

	_rebuild_list()
	_rebuild_agendas()


func _rebuild_list() -> void:
	if _list_box == null:
		return
	for c in _list_box.get_children():
		c.queue_free()
	var cur := Agenda.current_index()
	if _cur_label:
		var ce := Agenda.get_entry(cur)
		_cur_label.text = "Live: %s" % (ce.get("name", "—") if not ce.is_empty() else "—")
	var n := Agenda.entry_count()
	if n == 0:
		var l := Label.new()
		l.text = "(no cues — add one)"
		l.add_theme_color_override("font_color", MUTED)
		_list_box.add_child(l)
		return
	for i in range(n):
		_list_box.add_child(_make_entry_row(i, i == cur))


func _make_entry_row(i: int, is_cur: bool) -> Control:
	var e := Agenda.get_entry(i)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 5)
	var go := Button.new()
	go.text = "%d. %s" % [i + 1, e.get("name", "Cue")]
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go.clip_text = true
	go.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if is_cur:
		go.add_theme_color_override("font_color", ACCENT)
	go.pressed.connect(func(): Agenda.go_to(i))
	top.add_child(go)
	box.add_child(top)

	var bot := HBoxContainer.new()
	bot.add_theme_constant_override("separation", 4)
	var tl := Label.new()
	tl.text = "t"
	tl.add_theme_color_override("font_color", MUTED)
	tl.add_theme_font_size_override("font_size", 11)
	bot.add_child(tl)
	var sp := SpinBox.new()
	sp.min_value = 0.0; sp.max_value = 10.0; sp.step = 0.1
	sp.value = float(e.get("trans", 1.2))
	sp.custom_minimum_size = Vector2(64, 0)
	sp.value_changed.connect(func(x: float) -> void: Agenda.set_entry_trans(i, x))
	bot.add_child(sp)
	var rec := Button.new(); rec.text = "↻"; rec.tooltip_text = "Re-capture live state into this cue"
	rec.pressed.connect(func(): Agenda.update_entry(i))
	bot.add_child(rec)
	var up := Button.new(); up.text = "↑"
	up.pressed.connect(func(): Agenda.move_entry(i, -1))
	bot.add_child(up)
	var dn := Button.new(); dn.text = "↓"
	dn.pressed.connect(func(): Agenda.move_entry(i, 1))
	bot.add_child(dn)
	var rm := Button.new(); rm.text = "✕"
	rm.add_theme_color_override("font_color", Color(1, 0.55, 0.55))
	rm.pressed.connect(func(): Agenda.remove_entry(i))
	bot.add_child(rm)
	box.add_child(bot)

	var sep := HSeparator.new()
	box.add_child(sep)
	return box


func _rebuild_agendas() -> void:
	if _agendas_box == null:
		return
	for c in _agendas_box.get_children():
		c.queue_free()
	var names := Agenda.list_agendas()
	if names.is_empty():
		var l := Label.new()
		l.text = "(none saved)"
		l.add_theme_font_size_override("font_size", 11)
		l.add_theme_color_override("font_color", MUTED)
		_agendas_box.add_child(l)
		return
	for nm in names:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var lb := Button.new()
		lb.text = nm
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lb.clip_text = true
		lb.pressed.connect(func(): Agenda.load_agenda(nm))
		var db := Button.new(); db.text = "✕"
		db.pressed.connect(func(): Agenda.delete_agenda(nm))
		row.add_child(lb); row.add_child(db)
		_agendas_box.add_child(row)


# ----------------------------------------------------------------- builders

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
