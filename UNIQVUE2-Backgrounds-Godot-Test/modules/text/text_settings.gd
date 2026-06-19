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
	_text_edit.text_changed.connect(_on_text_changed)
	add_child(_text_edit)

	_lbl(self, "Mode")
	_mode_opt = OptionButton.new()
	for lbl in MODE_LABELS:
		_mode_opt.add_item(lbl)
	_mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_opt.item_selected.connect(_on_mode_changed)
	add_child(_mode_opt)

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


func _update_text_label(mode: String) -> void:
	_text_label.text = "Items (one per line)" if mode == "cycle" else "Text"


func _persist() -> void:
	if mod:
		SlotManager.persist_slot_state(slot_id, {})


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
