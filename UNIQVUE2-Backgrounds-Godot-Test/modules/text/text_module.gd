extends SubViewport

const _COLOR_KEYS   := ["color", "bg_color", "outline_color", "shadow_color"]
const _VECTOR2_KEYS := ["shadow_offset"]

var _bg: ColorRect
var _static_root: Control
var _label: Label
var _label_settings: LabelSettings
var _sys_font: SystemFont
var _ticker_clip: Control
var _ticker_a: Label
var _ticker_b: Label
var _ticker_offset := 0.0
var _cycle_timer    := 0.0
var _cycle_index    := 0

var state := {
	"mode":             "static",   # static | ticker | clock | countdown | cycle
	"text":             "Sample Text",
	"font_size":        72,
	"color":            Color(1.0, 1.0, 1.0, 1.0),
	"bg_color":         Color(0.0, 0.0, 0.0, 0.0),
	"align_h":          1,          # 0=LEFT 1=CENTER 2=RIGHT
	"align_v":          1,          # 0=TOP  1=CENTER 2=BOTTOM
	"uppercase":        false,
	"bold":             false,
	"italic":           false,
	"outline_size":     0,
	"outline_color":    Color(0.0, 0.0, 0.0, 1.0),
	"shadow_size":      0,
	"shadow_color":     Color(0.0, 0.0, 0.0, 0.6),
	"shadow_offset":    Vector2(2.0, 2.0),
	"padding":          24,
	"scroll_speed":     80.0,
	"cycle_items":      [],
	"cycle_interval":   5.0,
	"clock_format":     "HH:MM:SS",  # tokens: HH MM SS hh AP
	"countdown_target": 0.0,         # Unix epoch; 0 = not set
}


func _ready() -> void:
	transparent_bg = true
	_build_nodes()
	call_deferred("_apply")


func _build_nodes() -> void:
	_sys_font = SystemFont.new()
	_label_settings = LabelSettings.new()

	_bg = ColorRect.new()
	_bg.name = "BG"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	_static_root = Control.new()
	_static_root.name = "StaticRoot"
	_static_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_static_root)

	_label = Label.new()
	_label.name = "Label"
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_static_root.add_child(_label)

	_ticker_clip = Control.new()
	_ticker_clip.name = "TickerClip"
	_ticker_clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ticker_clip.clip_contents = true
	_ticker_clip.visible = false
	add_child(_ticker_clip)

	_ticker_a = _make_ticker_label()
	_ticker_b = _make_ticker_label()
	_ticker_clip.add_child(_ticker_a)
	_ticker_clip.add_child(_ticker_b)


func _make_ticker_label() -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	return l


func _process(delta: float) -> void:
	if _label == null:
		return
	var dt := minf(delta, 0.05)
	match state.mode:
		"ticker":
			_tick_scroll(dt)
		"clock":
			_label.text = _get_clock_text()
		"countdown":
			_label.text = _get_countdown_text()
		"cycle":
			_tick_cycle(dt)


func _tick_scroll(dt: float) -> void:
	var label_w := _ticker_a.get_minimum_size().x
	if label_w < 2.0:
		return
	var stride := label_w + 80.0
	_ticker_offset -= float(state.scroll_speed) * dt
	if _ticker_offset <= -stride:
		_ticker_offset += stride
	var cy := (float(size.y) - _ticker_a.get_minimum_size().y) * 0.5
	_ticker_a.position = Vector2(_ticker_offset, cy)
	_ticker_b.position = Vector2(_ticker_offset + stride, cy)


func _tick_cycle(dt: float) -> void:
	var items: Array = state.cycle_items
	if items.is_empty():
		return
	_cycle_timer += dt
	if _cycle_timer >= float(state.cycle_interval):
		_cycle_timer = 0.0
		_cycle_index = (_cycle_index + 1) % items.size()
		_label.text = _format_text(String(items[_cycle_index]))


func _get_clock_text() -> String:
	var t := Time.get_time_dict_from_system()
	var h: int = t.hour
	var m: int = t.minute
	var s: int = t.second
	var h12 := h % 12
	if h12 == 0:
		h12 = 12
	var ap := "AM" if h < 12 else "PM"
	var fmt: String = state.clock_format
	fmt = fmt.replace("HH", "%02d" % h)
	fmt = fmt.replace("MM", "%02d" % m)
	fmt = fmt.replace("SS", "%02d" % s)
	fmt = fmt.replace("hh", "%02d" % h12)
	fmt = fmt.replace("AP", ap)
	return fmt


func _get_countdown_text() -> String:
	var target := float(state.countdown_target)
	if target <= 0.0:
		return "00:00:00"
	var remaining := target - Time.get_unix_time_from_system()
	if remaining <= 0.0:
		return "00:00:00"
	var total_s := int(remaining)
	return "%02d:%02d:%02d" % [total_s / 3600, (total_s % 3600) / 60, total_s % 60]


func _format_text(txt: String) -> String:
	return txt.to_upper() if state.uppercase else txt


func _apply() -> void:
	if _bg == null:
		return

	var mode: String = state.mode
	var is_ticker := mode == "ticker"
	var pad := float(state.padding)

	_bg.color = state.bg_color
	_static_root.visible = not is_ticker
	_ticker_clip.visible = is_ticker

	# LabelSettings — shared across all labels.
	_sys_font.font_weight = 700 if state.bold else 400
	_sys_font.font_italic = state.italic
	_label_settings.font          = _sys_font if (state.bold or state.italic) else null
	_label_settings.font_size     = int(state.font_size)
	_label_settings.font_color    = state.color
	_label_settings.outline_size  = int(state.outline_size)
	_label_settings.outline_color = state.outline_color
	_label_settings.shadow_size   = int(state.shadow_size)
	_label_settings.shadow_color  = state.shadow_color
	_label_settings.shadow_offset = state.shadow_offset

	# Static label.
	_label.label_settings     = _label_settings
	_label.offset_left        = pad
	_label.offset_top         = pad
	_label.offset_right       = -pad
	_label.offset_bottom      = -pad
	_label.horizontal_alignment = state.align_h as HorizontalAlignment
	_label.vertical_alignment   = state.align_v as VerticalAlignment

	match mode:
		"static":
			_label.text = _format_text(state.text)
		"clock":
			_label.text = _get_clock_text()
		"countdown":
			_label.text = _get_countdown_text()
		"cycle":
			var items: Array = state.cycle_items
			_cycle_index = clampi(_cycle_index, 0, maxi(0, items.size() - 1))
			_label.text = _format_text(String(items[_cycle_index]) if not items.is_empty() else "")
		"ticker":
			pass  # handled by ticker nodes below

	# Ticker labels.
	var ticker_txt := _format_text(state.text)
	for t_lbl: Label in [_ticker_a, _ticker_b]:
		t_lbl.label_settings = _label_settings
		t_lbl.text = ticker_txt

	if is_ticker:
		_ticker_offset = 0.0
		_ticker_a.position = Vector2(0.0, (float(size.y) - _ticker_a.get_minimum_size().y) * 0.5)
		_ticker_b.position = Vector2(_ticker_a.get_minimum_size().x + 80.0, _ticker_a.position.y)


# ---------------------------------------------------------------- State contract

func capture_state() -> Dictionary:
	var snap := state.duplicate(true)
	for k in _COLOR_KEYS:
		if snap.has(k) and snap[k] is Color:
			var c: Color = snap[k]
			snap[k] = [c.r, c.g, c.b, c.a]
	for k in _VECTOR2_KEYS:
		if snap.has(k) and snap[k] is Vector2:
			var v: Vector2 = snap[k]
			snap[k] = [v.x, v.y]
	return snap


func apply_state(st: Dictionary) -> void:
	# Migrate legacy scroll_mode key.
	if "scroll_mode" in st and "mode" not in st:
		state.mode = "ticker" if int(st.get("scroll_mode", 0)) == 1 else "static"

	for k in st.keys():
		if not state.has(k):
			continue
		var val = st[k]
		if k in _COLOR_KEYS and val is Array and val.size() == 4:
			val = Color(val[0], val[1], val[2], val[3])
		elif k in _VECTOR2_KEYS and val is Array and val.size() == 2:
			val = Vector2(val[0], val[1])
		state[k] = val
	_apply()


func set_mode(_m: String) -> void:
	pass  # required by slot_manager interface
