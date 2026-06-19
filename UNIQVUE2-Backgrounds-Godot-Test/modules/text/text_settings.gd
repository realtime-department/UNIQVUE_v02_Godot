extends VBoxContainer
## Text module settings panel — embedded in the F2 slot editor when a text slot is selected.

const ACCENT := Color(1.0, 0.804, 0.0)
const TEXT   := Color(0.90, 0.93, 0.96)
const MUTED  := Color(0.58, 0.64, 0.72)

const MODE_IDS    := ["static", "ticker", "clock", "countdown", "cycle"]
const MODE_LABELS := ["Static", "Ticker", "Clock", "Countdown", "Cycle"]
const ALIGN_H_LABELS := ["Left", "Center", "Right"]
const ALIGN_V_LABELS  := ["Top",  "Center", "Bottom"]

var slot_id   := -1
var mod       = null
var _refreshing := false

# Content
var _mode_opt:         OptionButton
var _rich_bar:         Control        # formatting toolbar
var _rich_size:        SpinBox
var _rich_color:       ColorPickerButton
var _preview:          RichTextLabel  # live rendered preview
var _preview_bg:       ColorRect
var _preview_box:      Control
var _text_edit:        TextEdit       # static text (also cycle items — one per line)
var _text_label:       Label          # changes to "Items (one per line)" in cycle mode
# Mode-specific rows (shown/hidden by _update_mode_rows)
var _ticker_row:       Control
var _speed_slider:     HSlider
var _speed_val:        Label
var _cycle_row:        Control
var _interval_slider:  HSlider
var _interval_val:     Label
var _clock_row:        Control
var _clock_fmt:        LineEdit
var _countdown_row:    Control
var _countdown_edit:   LineEdit       # HH:MM:SS time-of-day

# Style
var _size_slider:      HSlider
var _size_val:         Label
var _color_btn:        ColorPickerButton
var _bg_btn:           ColorPickerButton
var _bold_chk:         CheckButton
var _italic_chk:       CheckButton
var _upper_chk:        CheckButton

# Outline / shadow
var _outline_slider:   HSlider
var _outline_val:      Label
var _outline_btn:      ColorPickerButton
var _shadow_slider:    HSlider
var _shadow_val:       Label
var _shadow_btn:       ColorPickerButton
var _shadow_ox:        SpinBox
var _shadow_oy:        SpinBox

# Layout
var _pad_slider:       HSlider
var _pad_val:          Label
var _align_h_btns:     Array
var _align_v_btns:     Array


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_build_ui()


# ---------------------------------------------------------------- Public API

func bind(id: int, module) -> void:
	slot_id = id
	mod = module
	var is_text: bool = module != null and module.has_method("capture_state") \
		and not module.has_method("load_image_paths")
	visible = is_text
	if is_text:
		_refresh()


# ---------------------------------------------------------------- Build UI

func _build_ui() -> void:
	_section("CONTENT")
	_text_label = _lbl(self, "Text")

	_text_edit = TextEdit.new()
	_text_edit.custom_minimum_size = Vector2(0, 72)
	_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	# Keep the selection alive when the user clicks a formatting button (otherwise
	# clicking B/I/Size wipes the selection and the wrap targets nothing).
	_text_edit.deselect_on_focus_loss_enabled = false
	_text_edit.text_changed.connect(_on_text_changed)
	# Ctrl+B / Ctrl+I / Ctrl+U toggle formatting on the selection.
	_text_edit.gui_input.connect(_on_text_edit_gui_input)
	add_child(_text_edit)

	_lbl(self, "Mode")
	_mode_opt = OptionButton.new()
	for lbl in MODE_LABELS:
		_mode_opt.add_item(lbl)
	_mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_opt.item_selected.connect(_on_mode_changed)
	add_child(_mode_opt)

	# Formatting toolbar — select chars/lines above, then click. B/I/U/S toggle the tag;
	# Size/Color replace any existing one (no nesting); ✕ strips all tags. Rich mode only.
	_rich_bar = VBoxContainer.new()
	_rich_bar.add_theme_constant_override("separation", 4)

	# Row 1: toggles + clear.
	var tb1 := HBoxContainer.new()
	tb1.add_theme_constant_override("separation", 4)
	_tag_btn(tb1, "B", "[b]", "[/b]")
	_tag_btn(tb1, "I", "[i]", "[/i]")
	_tag_btn(tb1, "U", "[u]", "[/u]")
	_tag_btn(tb1, "S", "[s]", "[/s]")
	var clrbtn := Button.new()
	clrbtn.text = "✕ Clear"
	clrbtn.focus_mode = Control.FOCUS_NONE
	clrbtn.tooltip_text = "Remove all formatting from the selection (or all text)"
	clrbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clrbtn.pressed.connect(_clear_format)
	tb1.add_child(clrbtn)
	_rich_bar.add_child(tb1)

	# Row 2: font size.
	var tb2 := HBoxContainer.new()
	tb2.add_theme_constant_override("separation", 6)
	var szl := _lbl(tb2, "Size")
	szl.custom_minimum_size = Vector2(34, 0)
	_rich_size = SpinBox.new()
	_rich_size.min_value = 8; _rich_size.max_value = 400; _rich_size.value = 72
	_rich_size.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb2.add_child(_rich_size)
	var szbtn := Button.new()
	szbtn.text = "Apply"
	szbtn.focus_mode = Control.FOCUS_NONE
	szbtn.pressed.connect(func(): _set_span_value("size", str(int(_rich_size.value))))
	tb2.add_child(szbtn)
	_rich_bar.add_child(tb2)

	# Row 3: color.
	var tb3 := HBoxContainer.new()
	tb3.add_theme_constant_override("separation", 6)
	var cl := _lbl(tb3, "Color")
	cl.custom_minimum_size = Vector2(34, 0)
	_rich_color = ColorPickerButton.new()
	_rich_color.color = Color.WHITE
	_rich_color.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rich_color.custom_minimum_size = Vector2(0, 22)
	tb3.add_child(_rich_color)
	var clbtn := Button.new()
	clbtn.text = "Apply"
	clbtn.focus_mode = Control.FOCUS_NONE
	clbtn.pressed.connect(func(): _set_span_value("color", _rich_color.color.to_html()))
	tb3.add_child(clbtn)
	_rich_bar.add_child(tb3)
	add_child(_rich_bar)

	# Live preview — renders the current text exactly as the wall will (BBCode, color,
	# bold/italic, outline/shadow, alignment, bg). Godot has no editable rich-text
	# widget, so this is the WYSIWYG surface; the editor above stays source-of-truth.
	_lbl(self, "Preview")
	_preview_box = Control.new()
	_preview_box.custom_minimum_size = Vector2(0, 104)
	_preview_box.clip_contents = true
	_preview_bg = ColorRect.new()
	_preview_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_bg.color = Color(0.08, 0.09, 0.11)
	_preview_box.add_child(_preview_bg)
	_preview = RichTextLabel.new()
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview.bbcode_enabled = true
	_preview.scroll_active = true
	_preview.fit_content = false
	_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview.offset_left = 6; _preview.offset_top = 6
	_preview.offset_right = -6; _preview.offset_bottom = -6
	_preview_box.add_child(_preview)
	add_child(_preview_box)

	# Ticker row
	_ticker_row = _build_slider_section("Scroll speed", 20.0, 400.0, 1.0, "px/s",
		func(v):
			if _refreshing or not mod: return
			mod.state.scroll_speed = v
			_persist())
	_speed_slider = _ticker_row.get_child(1).get_child(0) as HSlider
	_speed_val    = _ticker_row.get_child(1).get_child(1) as Label
	add_child(_ticker_row)

	# Cycle interval row
	_cycle_row = _build_slider_section("Interval", 1.0, 30.0, 0.5, "s",
		func(v):
			if _refreshing or not mod: return
			mod.state.cycle_interval = v
			_persist())
	_interval_slider = _cycle_row.get_child(1).get_child(0) as HSlider
	_interval_val    = _cycle_row.get_child(1).get_child(1) as Label
	add_child(_cycle_row)

	# Clock format row
	_clock_row = VBoxContainer.new()
	_clock_row.add_theme_constant_override("separation", 3)
	_lbl(_clock_row, "Format  (HH MM SS hh AP)")
	_clock_fmt = LineEdit.new()
	_clock_fmt.placeholder_text = "HH:MM:SS"
	_clock_fmt.text_submitted.connect(func(_s): _on_clock_fmt_changed())
	_clock_fmt.focus_exited.connect(_on_clock_fmt_changed)
	_clock_row.add_child(_clock_fmt)
	add_child(_clock_row)

	# Countdown row
	_countdown_row = VBoxContainer.new()
	_countdown_row.add_theme_constant_override("separation", 3)
	_lbl(_countdown_row, "Target time  (HH:MM:SS)")
	var crow2 := HBoxContainer.new()
	crow2.add_theme_constant_override("separation", 6)
	_countdown_edit = LineEdit.new()
	_countdown_edit.placeholder_text = "15:30:00"
	_countdown_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	crow2.add_child(_countdown_edit)
	var setbtn := Button.new()
	setbtn.text = "Set"
	setbtn.pressed.connect(_on_countdown_set)
	crow2.add_child(setbtn)
	_countdown_row.add_child(crow2)
	add_child(_countdown_row)

	# ---- Style ----
	_section("STYLE")

	var szrow := _build_slider_section("Font size", 12.0, 300.0, 1.0, "px",
		func(v):
			if _refreshing or not mod: return
			mod.state.font_size = int(v)
			mod._apply(); _persist())
	_size_slider = szrow.get_child(1).get_child(0) as HSlider
	_size_val    = szrow.get_child(1).get_child(1) as Label
	add_child(szrow)

	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 8)
	_lbl(crow, "Text"); _color_btn = _color_picker(crow, Color.WHITE,
		func(c): if not _refreshing and mod: mod.state.color = c; mod._apply(); _persist())
	_lbl(crow, "BG");   _bg_btn   = _color_picker(crow, Color.TRANSPARENT,
		func(c): if not _refreshing and mod: mod.state.bg_color = c; mod._apply(); _persist())
	add_child(crow)

	var frow := HBoxContainer.new()
	frow.add_theme_constant_override("separation", 8)
	_bold_chk   = _check(frow, "Bold",      func(p): if not _refreshing and mod: mod.state.bold = p;      mod._apply(); _persist())
	_italic_chk = _check(frow, "Italic",    func(p): if not _refreshing and mod: mod.state.italic = p;    mod._apply(); _persist())
	_upper_chk  = _check(frow, "UPPERCASE", func(p): if not _refreshing and mod: mod.state.uppercase = p; mod._apply(); _persist())
	add_child(frow)

	# Outline
	_section("OUTLINE")
	var orow := _build_slider_section("Size", 0.0, 20.0, 1.0, "px",
		func(v):
			if _refreshing or not mod: return
			mod.state.outline_size = int(v)
			mod._apply(); _persist())
	_outline_slider = orow.get_child(1).get_child(0) as HSlider
	_outline_val    = orow.get_child(1).get_child(1) as Label
	add_child(orow)
	var ocrow := HBoxContainer.new()
	ocrow.add_theme_constant_override("separation", 8)
	_lbl(ocrow, "Color")
	_outline_btn = _color_picker(ocrow, Color.BLACK,
		func(c): if not _refreshing and mod: mod.state.outline_color = c; mod._apply(); _persist())
	add_child(ocrow)

	# Shadow
	_section("SHADOW")
	var shrow := _build_slider_section("Size", 0.0, 40.0, 1.0, "px",
		func(v):
			if _refreshing or not mod: return
			mod.state.shadow_size = int(v)
			mod._apply(); _persist())
	_shadow_slider = shrow.get_child(1).get_child(0) as HSlider
	_shadow_val    = shrow.get_child(1).get_child(1) as Label
	add_child(shrow)
	var scrow := HBoxContainer.new()
	scrow.add_theme_constant_override("separation", 8)
	_lbl(scrow, "Color")
	_shadow_btn = _color_picker(scrow, Color(0, 0, 0, 0.6),
		func(c): if not _refreshing and mod: mod.state.shadow_color = c; mod._apply(); _persist())
	add_child(scrow)
	var sorow := HBoxContainer.new()
	sorow.add_theme_constant_override("separation", 6)
	_lbl(sorow, "Offset X")
	_shadow_ox = _spinbox(sorow, -40.0, 40.0, func(v): if not _refreshing and mod: mod.state.shadow_offset.x = v; mod._apply(); _persist())
	_lbl(sorow, "Y")
	_shadow_oy = _spinbox(sorow, -40.0, 40.0, func(v): if not _refreshing and mod: mod.state.shadow_offset.y = v; mod._apply(); _persist())
	add_child(sorow)

	# ---- Layout ----
	_section("LAYOUT")
	var padrow := _build_slider_section("Padding", 0.0, 120.0, 1.0, "px",
		func(v):
			if _refreshing or not mod: return
			mod.state.padding = int(v)
			mod._apply(); _persist())
	_pad_slider = padrow.get_child(1).get_child(0) as HSlider
	_pad_val    = padrow.get_child(1).get_child(1) as Label
	add_child(padrow)

	_lbl(self, "Align H")
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 4)
	_align_h_btns = []
	for i in range(ALIGN_H_LABELS.size()):
		var b := Button.new()
		b.text = ALIGN_H_LABELS[i]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		var idx := i
		b.pressed.connect(func():
			if _refreshing or not mod: return
			mod.state.align_h = idx; mod._apply(); _persist()
			_refresh_align())
		hrow.add_child(b)
		_align_h_btns.append(b)
	add_child(hrow)

	_lbl(self, "Align V")
	var vrow := HBoxContainer.new()
	vrow.add_theme_constant_override("separation", 4)
	_align_v_btns = []
	for i in range(ALIGN_V_LABELS.size()):
		var b := Button.new()
		b.text = ALIGN_V_LABELS[i]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		var idx := i
		b.pressed.connect(func():
			if _refreshing or not mod: return
			mod.state.align_v = idx; mod._apply(); _persist()
			_refresh_align())
		vrow.add_child(b)
		_align_v_btns.append(b)
	add_child(vrow)


# ---------------------------------------------------------------- Callbacks

func _on_text_changed() -> void:
	if _refreshing or not mod:
		return
	var raw := _text_edit.text
	if mod.state.mode == "cycle":
		var lines := raw.split("\n", false)
		mod.state.cycle_items = Array(lines)
	else:
		if mod.state.mode == "static":
			_remap_spans(mod.state.text, raw)   # keep spans aligned to the edited text
		mod.state.text = raw
	mod._apply()
	_persist()


func _on_mode_changed(i: int) -> void:
	if _refreshing or not mod:
		return
	mod.state.mode = MODE_IDS[i]
	mod._apply()
	_persist()
	_update_mode_rows(MODE_IDS[i])
	_update_text_label(MODE_IDS[i])
	# Repopulate text edit for the new mode so the content matches.
	_refreshing = true
	if MODE_IDS[i] == "cycle":
		_text_edit.text = "\n".join(PackedStringArray(mod.state.cycle_items))
	else:
		_text_edit.text = mod.state.text
	_refreshing = false


func _on_clock_fmt_changed() -> void:
	if not mod:
		return
	mod.state.clock_format = _clock_fmt.text
	_persist()


func _on_countdown_set() -> void:
	if not mod:
		return
	var parts := _countdown_edit.text.split(":")
	if parts.size() < 2:
		return
	var h := int(parts[0])
	var m := int(parts[1])
	var s := int(parts[2]) if parts.size() > 2 else 0
	# Compare in local-time seconds to stay timezone-safe, then add diff to Unix now.
	var local_now := Time.get_time_dict_from_system()
	var now_secs  := int(local_now.hour) * 3600 + int(local_now.minute) * 60 + int(local_now.second)
	var tgt_secs  := h * 3600 + m * 60 + s
	var diff      := tgt_secs - now_secs
	if diff <= 0:
		diff += 86400  # push to tomorrow
	mod.state.countdown_target = Time.get_unix_time_from_system() + diff
	mod._apply()
	_persist()


# ---------------------------------------------------------------- Refresh

func _refresh() -> void:
	if not mod:
		return
	_refreshing = true
	var st = mod.state

	var mode: String = st.mode
	var idx := MODE_IDS.find(mode)
	_mode_opt.select(maxi(0, idx))
	_update_mode_rows(mode)
	_update_text_label(mode)

	if mode == "cycle":
		_text_edit.text = "\n".join(PackedStringArray(st.cycle_items))
	else:
		_text_edit.text = st.text

	_speed_slider.value    = st.scroll_speed
	_speed_val.text        = "%dpx/s" % int(st.scroll_speed)
	_interval_slider.value = st.cycle_interval
	_interval_val.text     = "%.1fs" % st.cycle_interval
	_clock_fmt.text        = st.clock_format

	_size_slider.value  = st.font_size
	_size_val.text      = "%dpx" % int(st.font_size)
	_color_btn.color    = st.color
	_bg_btn.color       = st.bg_color
	_bold_chk.button_pressed   = st.bold
	_italic_chk.button_pressed = st.italic
	_upper_chk.button_pressed  = st.uppercase
	_rich_size.value           = st.font_size
	_rich_color.color          = st.color

	_outline_slider.value = st.outline_size
	_outline_val.text     = "%dpx" % int(st.outline_size)
	_outline_btn.color    = st.outline_color

	_shadow_slider.value = st.shadow_size
	_shadow_val.text     = "%dpx" % int(st.shadow_size)
	_shadow_btn.color    = st.shadow_color
	_shadow_ox.value     = st.shadow_offset.x
	_shadow_oy.value     = st.shadow_offset.y

	_pad_slider.value = st.padding
	_pad_val.text     = "%dpx" % int(st.padding)

	_refresh_align()
	_refreshing = false
	_update_preview()


func _refresh_align() -> void:
	if not mod:
		return
	for i in _align_h_btns.size():
		_align_h_btns[i].button_pressed = (mod.state.align_h == i)
	for i in _align_v_btns.size():
		_align_v_btns[i].button_pressed = (mod.state.align_v == i)


func _update_mode_rows(mode: String) -> void:
	_ticker_row.visible    = mode == "ticker"
	_cycle_row.visible     = mode == "cycle"
	_clock_row.visible     = mode == "clock"
	_countdown_row.visible = mode == "countdown"
	# Inline formatting (spans) only applies to the static text block.
	_rich_bar.visible      = mode == "static"


func _update_text_label(mode: String) -> void:
	match mode:
		"cycle":
			_text_label.text = "Items (one per line)"
		"static":
			_text_label.text = "Text  (rich — select & format below)"
		_:
			_text_label.text = "Text"


func _persist() -> void:
	if mod:
		SlotManager.persist_slot_state(slot_id, {})
		_update_preview()


# ---------------------------------------------------------------- Tiny builders

func _section(txt: String) -> void:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.5, 0.57, 0.68))
	add_child(l)


func _lbl(parent: Node, txt: String) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", MUTED)
	parent.add_child(l)
	return l


func _tag_btn(parent: Node, label: String, open: String, _close: String) -> void:
	var t := open.substr(1, open.length() - 2)  # "[b]" -> "b"
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(34, 0)
	b.focus_mode = Control.FOCUS_NONE  # don't steal focus / clear the selection
	b.tooltip_text = "Toggle %s on the selection" % label
	b.pressed.connect(func(): _toggle_span(t))
	parent.add_child(b)


# ---------------------------------------------------------------- Inline spans
# The editor holds PLAIN text; formatting is stored as character-range spans in
# mod.state.spans and only turned into BBCode at render time (static mode only).

# [start, end) of the current selection, or a zero-width range at the caret.
func _sel_range() -> Vector2i:
	if _text_edit.has_selection():
		var a := _abs_offset(_text_edit.get_selection_from_line(), _text_edit.get_selection_from_column())
		var b := _abs_offset(_text_edit.get_selection_to_line(), _text_edit.get_selection_to_column())
		return Vector2i(mini(a, b), maxi(a, b))
	var c := _abs_offset(_text_edit.get_caret_line(), _text_edit.get_caret_column())
	return Vector2i(c, c)


# Toggle a non-parametric type (b/i/u/s): remove if the whole selection already has it,
# otherwise add.
func _toggle_span(t: String) -> void:
	if _refreshing or not mod or mod.state.mode != "static":
		return
	var r := _sel_range()
	if r.x == r.y:
		return
	if _covered(r.x, r.y, t):
		_remove_type(r.x, r.y, t)
	else:
		mod.state.spans.append({"s": r.x, "e": r.y, "t": t, "v": ""})
		_normalize(t)
	_commit_spans(r)


# Set a parametric type (size/color): clear any existing run over the range, then add.
func _set_span_value(t: String, v: String) -> void:
	if _refreshing or not mod or mod.state.mode != "static":
		return
	var r := _sel_range()
	if r.x == r.y:
		return
	_remove_type(r.x, r.y, t)
	mod.state.spans.append({"s": r.x, "e": r.y, "t": t, "v": v})
	_normalize(t)
	_commit_spans(r)


# Clear all formatting from the selection, or everything if nothing is selected.
func _clear_format() -> void:
	if _refreshing or not mod or mod.state.mode != "static":
		return
	var r := _sel_range()
	if r.x == r.y:
		mod.state.spans = []
	else:
		for t in ["b", "i", "u", "s", "size", "color"]:
			_remove_type(r.x, r.y, t)
	_commit_spans(r)


func _covered(a: int, b: int, t: String) -> bool:
	for i in range(a, b):
		var hit := false
		for sp in mod.state.spans:
			if sp.t == t and int(sp.s) <= i and i < int(sp.e):
				hit = true
				break
		if not hit:
			return false
	return b > a


# Subtracts the range [a,b) from every span of type t (splitting where needed).
func _remove_type(a: int, b: int, t: String) -> void:
	var out: Array = []
	for sp in mod.state.spans:
		if sp.t != t or b <= int(sp.s) or a >= int(sp.e):
			out.append(sp)
			continue
		if a > int(sp.s):
			out.append({"s": sp.s, "e": a, "t": t, "v": sp.v})
		if b < int(sp.e):
			out.append({"s": b, "e": sp.e, "t": t, "v": sp.v})
	mod.state.spans = out


# Merges same-type, same-value spans that overlap or touch.
func _normalize(t: String) -> void:
	var same: Array = []
	var rest: Array = []
	for sp in mod.state.spans:
		(same if sp.t == t else rest).append(sp)
	same.sort_custom(func(x, y): return int(x.s) < int(y.s))
	var merged: Array = []
	for sp in same:
		if not merged.is_empty():
			var last = merged[-1]
			if last.v == sp.v and int(sp.s) <= int(last.e):
				last.e = maxi(int(last.e), int(sp.e))
				continue
		merged.append({"s": sp.s, "e": sp.e, "t": t, "v": sp.v})
	mod.state.spans = rest + merged


# Re-render + persist, then restore the selection (editor text is untouched).
func _commit_spans(r: Vector2i) -> void:
	mod._apply()
	_persist()
	var a := _pos_from_offset(r.x)
	if r.x == r.y:
		_text_edit.set_caret_line(a.x)
		_text_edit.set_caret_column(a.y)
	else:
		var b := _pos_from_offset(r.y)
		_text_edit.select(a.x, a.y, b.x, b.y)
	_text_edit.grab_focus()


# Shifts spans to track a text edit (diff old vs new by common prefix/suffix).
func _remap_spans(old_text: String, new_text: String) -> void:
	var spans: Array = mod.state.spans
	if spans.is_empty():
		return
	var lo := old_text.length()
	var ln := new_text.length()
	var p := 0
	while p < lo and p < ln and old_text[p] == new_text[p]:
		p += 1
	var so := lo
	var sn := ln
	while so > p and sn > p and old_text[so - 1] == new_text[sn - 1]:
		so -= 1
		sn -= 1
	var edit_end := so          # end of removed region in old coords
	var delta := sn - so        # net length change (= inserted - removed)
	var out: Array = []
	for sp in spans:
		var s := int(sp.s)
		var e := int(sp.e)
		s = (s + delta) if s >= edit_end else mini(s, p)
		e = (e + delta) if e >= edit_end else mini(e, p)
		if e > s:
			out.append({"s": s, "e": e, "t": sp.t, "v": sp.v})
	mod.state.spans = out


# Absolute character offset for a (line, column) position.
func _abs_offset(line: int, col: int) -> int:
	var off := 0
	for i in range(line):
		off += _text_edit.get_line(i).length() + 1   # +1 for the newline
	return off + col


# Inverse of _abs_offset: (line, column) for an absolute offset.
func _pos_from_offset(off: int) -> Vector2i:
	var line := 0
	var rem := off
	while line < _text_edit.get_line_count() - 1:
		var ll := _text_edit.get_line(line).length()
		if rem <= ll:
			break
		rem -= ll + 1
		line += 1
	return Vector2i(line, rem)


# Ctrl+B / Ctrl+I / Ctrl+U shortcuts for the formatting tags.
func _on_text_edit_gui_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo and ev.ctrl_pressed):
		return
	var t := ""
	match ev.keycode:
		KEY_B: t = "b"
		KEY_I: t = "i"
		KEY_U: t = "u"
		_: return
	_toggle_span(t)
	_text_edit.accept_event()


# Resolves the body string shown in the preview for the current mode.
func _preview_body() -> String:
	var st = mod.state
	match st.mode:
		"clock":
			return mod._get_clock_text()
		"countdown":
			return mod._get_countdown_text()
		"cycle":
			var items: Array = st.cycle_items
			return String(items[0]) if not items.is_empty() else ""
	return st.text


# Mirrors the module's styling onto the preview label so it renders like the wall.
# Base font size is capped so the small panel stays readable; [font_size=N] runs
# render at their literal size (the panel scrolls if they overflow).
func _update_preview() -> void:
	if not mod or _preview == null:
		return
	var st = mod.state
	_preview.bbcode_enabled = true
	_preview_bg.color = st.bg_color if st.bg_color.a > 0.0 else Color(0.08, 0.09, 0.11)

	mod._rebuild_fonts()
	_preview.add_theme_font_override("normal_font", mod._sys_font)
	_preview.add_theme_font_override("bold_font", mod._sf_bold)
	_preview.add_theme_font_override("italics_font", mod._sf_italic)
	_preview.add_theme_font_override("bold_italics_font", mod._sf_bolditalic)
	# All size slots match so [b]/[i] runs don't shrink to the default theme size.
	var cap := clampi(int(st.font_size), 8, 30)
	_preview.add_theme_font_size_override("normal_font_size", cap)
	_preview.add_theme_font_size_override("bold_font_size", cap)
	_preview.add_theme_font_size_override("italics_font_size", cap)
	_preview.add_theme_font_size_override("bold_italics_font_size", cap)
	_preview.add_theme_color_override("default_color", st.color)
	_preview.add_theme_constant_override("outline_size", int(st.outline_size))
	_preview.add_theme_color_override("font_outline_color", st.outline_color)
	_preview.add_theme_constant_override("shadow_outline_size", int(st.shadow_size))
	_preview.add_theme_color_override("font_shadow_color", st.shadow_color)
	_preview.add_theme_constant_override("shadow_offset_x", int(st.shadow_offset.x))
	_preview.add_theme_constant_override("shadow_offset_y", int(st.shadow_offset.y))

	if st.mode == "static":
		_preview.text = mod._rich_wrap(mod._spans_to_bbcode())
	else:
		_preview.text = mod._rich_wrap(mod._escape(mod._apply_case(_preview_body())))


func _check(parent: Node, txt: String, cb: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = txt
	c.add_theme_color_override("font_color", TEXT)
	c.add_theme_font_size_override("font_size", 12)
	c.toggled.connect(cb)
	parent.add_child(c)
	return c


func _color_picker(parent: Node, col: Color, cb: Callable) -> ColorPickerButton:
	var cpb := ColorPickerButton.new()
	cpb.color = col
	cpb.custom_minimum_size = Vector2(44, 22)
	cpb.color_changed.connect(cb)
	parent.add_child(cpb)
	return cpb


func _spinbox(parent: Node, mn: float, mx: float, cb: Callable) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = mn; sb.max_value = mx; sb.step = 0.5
	sb.custom_minimum_size = Vector2(64, 0)
	sb.value_changed.connect(cb)
	parent.add_child(sb)
	return sb


# Returns a VBoxContainer with a label row on top and an HSlider+value label on bottom.
# Caller must store the slider/val references from the returned node's children.
func _build_slider_section(lbl_txt: String, mn: float, mx: float, step: float, suffix: String, cb: Callable) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	_lbl(box, lbl_txt)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var s := HSlider.new()
	s.min_value = mn; s.max_value = mx; s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	var v := Label.new()
	v.custom_minimum_size = Vector2(52, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_theme_color_override("font_color", ACCENT)
	v.add_theme_font_size_override("font_size", 12)
	s.value_changed.connect(func(val):
		v.text = ("%.1f" % val + suffix) if step < 1.0 else (str(int(val)) + suffix)
		cb.call(val))
	row.add_child(s); row.add_child(v)
	box.add_child(row)
	return box
