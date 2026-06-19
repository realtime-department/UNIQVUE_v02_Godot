extends SubViewport

const _COLOR_KEYS   := ["color", "bg_color", "outline_color", "shadow_color"]
const _VECTOR2_KEYS := ["shadow_offset"]

var _bg: ColorRect
var _static_root: Control
var _label: Label
var _rich: RichTextLabel
var _label_settings: LabelSettings
var _base_font: SystemFont        # plain system face; every variation derives from it
var _sys_font: Font               # normal slot (base + global bold/italic)
var _sf_bold: Font                # rich [b]    (forces bold, keeps global italic)
var _sf_italic: Font              # rich [i]    (forces italic, keeps global bold)
var _sf_bolditalic: Font          # rich [b][i] (forces both)
var _tag_rx: RegEx                # matches a single BBCode tag
var _ticker_clip: Control
var _ticker_a: Label
var _ticker_b: Label
var _ticker_offset := 0.0
var _cycle_timer    := 0.0
var _cycle_index    := 0

var state := {
	"mode":             "static",   # static | ticker | clock | countdown | cycle
	"text":             "Sample Text",   # PLAIN text (no BBCode); formatting lives in `spans`
	# Inline formatting runs for `text` (static mode). Each: {s:int, e:int, t:String, v:String}
	# t in {b,i,u,s,size,color}; v holds size px or color hex (rrggbbaa). Built into BBCode
	# only at render time so the editor never shows tags.
	"spans":            [],
	"font_size":        72,
	"color":            Color(1.0, 1.0, 1.0, 1.0),
	"bg_color":         Color(0.0, 0.0, 0.0, 0.0),
	"align_h":          1,          # 0=LEFT 1=CENTER 2=RIGHT
	"align_v":          1,          # 0=TOP  1=CENTER 2=BOTTOM
	"uppercase":        false,
	"rich_text":        true,         # always BBCode (RichTextLabel); ticker excepted
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
	# Re-layout when the slot (SubViewport) is resized — ticker centering and the rich
	# vertical alignment both depend on size.y.
	size_changed.connect(_apply)
	call_deferred("_apply")


func _build_nodes() -> void:
	# The default system face (Open Sans) exposes a single weight/style, so SystemFont's
	# font_weight / font_italic have NO visible effect. Bold and italic are therefore
	# synthesized with FontVariation (embolden + shear) off one shared base font — this
	# always renders, regardless of which system faces exist.
	_base_font = SystemFont.new()
	_rebuild_fonts()
	_tag_rx = RegEx.new()
	_tag_rx.compile("\\[/?[^\\]]*\\]")
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

	_rich = RichTextLabel.new()
	_rich.name = "Rich"
	_rich.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rich.bbcode_enabled = true
	_rich.fit_content = false
	_rich.scroll_active = false
	_rich.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rich.visible = false
	_static_root.add_child(_rich)

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


# Rebuilds the four font slots from the current global bold/italic state. Span-driven [b]/[i]
# slots force their own attribute on top of the global one, so a [b] run inside globally
# italic text is bold AND italic, etc.
func _rebuild_fonts() -> void:
	_sys_font      = _mk_variation(state.bold, state.italic)
	_sf_bold       = _mk_variation(true, state.italic)
	_sf_italic     = _mk_variation(state.bold, true)
	_sf_bolditalic = _mk_variation(true, true)


# Synthetic bold (embolden) + italic (horizontal shear) off the shared base font.
func _mk_variation(bold: bool, italic: bool) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = _base_font
	if bold:
		fv.variation_embolden = 0.85
	if italic:
		fv.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(0.30, 1.0), Vector2.ZERO)
	return fv


func _process(delta: float) -> void:
	if _label == null:
		return
	var dt := minf(delta, 0.05)
	match state.mode:
		"ticker":
			_tick_scroll(dt)
		"clock":
			_render_plain(_get_clock_text())
		"countdown":
			_render_plain(_get_countdown_text())
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
		_render_plain(String(items[_cycle_index]))


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


# Routes body text to whichever label is active. Rich mode keeps the raw string as
# BBCode (uppercase is skipped — it would corrupt tags like [b]).
const _TYPE_ORDER := ["size", "color", "b", "i", "u", "s"]

# Renders a plain body (clock/countdown/cycle) with global styling only — escapes any
# literal brackets, applies uppercase, wraps for alignment.
func _render_plain(body: String) -> void:
	_rich.text = _rich_wrap(_escape(_apply_case(body)))


# Escapes literal brackets so user text never accidentally parses as BBCode.
func _escape(s: String) -> String:
	return s.replace("[", "[lb]").replace("]", "[rb]")


# Builds the BBCode string for static mode from `text` (plain) + `spans`. Closes and
# reopens all active tags at every boundary — not minimal, but always well-nested.
func _spans_to_bbcode() -> String:
	var txt: String = state.text
	var spans: Array = state.spans
	var n := txt.length()
	var res := ""
	var prev: Array = []
	for i in range(n + 1):
		var act := _active_opens(spans, i)
		if act != prev:
			for j in range(prev.size() - 1, -1, -1):
				res += _close_for_open(prev[j])
			for o in act:
				res += o
			prev = act
		if i < n:
			var ch := txt[i]
			if state.uppercase:
				ch = ch.to_upper()
			if ch == "[":
				res += "[lb]"
			elif ch == "]":
				res += "[rb]"
			else:
				res += ch
	return res


# Open-tag strings active at character i, in canonical (stable-nesting) order.
func _active_opens(spans: Array, i: int) -> Array:
	var by_type := {}
	for sp in spans:
		if int(sp.s) <= i and i < int(sp.e):
			by_type[sp.t] = sp.get("v", "")
	var out: Array = []
	for t in _TYPE_ORDER:
		if by_type.has(t):
			match t:
				"size":  out.append("[font_size=%s]" % by_type[t])
				"color": out.append("[color=#%s]" % by_type[t])
				_:       out.append("[%s]" % t)
	return out


func _close_for_open(o: String) -> String:
	if o.begins_with("[font_size"):
		return "[/font_size]"
	if o.begins_with("[color"):
		return "[/color]"
	return "[/%s]" % o.substr(1, o.length() - 2)  # "[b]" -> "[/b]"


# Uppercases text OUTSIDE BBCode tags so the UPPERCASE toggle works without
# corrupting tag names (e.g. [color=#ff0000] must stay lowercase).
func _apply_case(s: String) -> String:
	if not state.uppercase:
		return s
	var out := ""
	var last := 0
	for m in _tag_rx.search_all(s):
		out += s.substr(last, m.get_start() - last).to_upper()
		out += s.substr(m.get_start(), m.get_end() - m.get_start())
		last = m.get_end()
	out += s.substr(last).to_upper()
	return out


# Horizontal alignment in RichTextLabel is expressed with BBCode paragraph tags
# (there is no horizontal_alignment property). Vertical alignment is not supported.
func _rich_wrap(body: String) -> String:
	match int(state.align_h):
		1:
			return "[center]%s[/center]" % body
		2:
			return "[right]%s[/right]" % body
	return body


func _style_rich() -> void:
	var fs := int(state.font_size)
	# All four font-size slots must match, else [b]/[i]/[b][i] runs fall back to the
	# tiny default theme size and the text appears to shrink when bolded/italicised.
	# NOTE: the italic theme slots are spelled "italics" (with an s) in Godot — using
	# "italic_*" silently does nothing, so [i] runs would drop to the 16px default.
	_rich.add_theme_font_size_override("normal_font_size", fs)
	_rich.add_theme_font_size_override("bold_font_size", fs)
	_rich.add_theme_font_size_override("italics_font_size", fs)
	_rich.add_theme_font_size_override("bold_italics_font_size", fs)
	_rich.add_theme_color_override("default_color", state.color)
	# Base font reflects the global bold/italic toggles (weight/italic set in _apply).
	_rich.add_theme_font_override("normal_font", _sys_font)
	_rich.add_theme_font_override("bold_font", _sf_bold)
	_rich.add_theme_font_override("italics_font", _sf_italic)
	_rich.add_theme_font_override("bold_italics_font", _sf_bolditalic)
	_rich.add_theme_constant_override("outline_size", int(state.outline_size))
	_rich.add_theme_color_override("font_outline_color", state.outline_color)
	_rich.add_theme_constant_override("shadow_outline_size", int(state.shadow_size))
	_rich.add_theme_color_override("font_shadow_color", state.shadow_color)
	_rich.add_theme_constant_override("shadow_offset_x", int(state.shadow_offset.x))
	_rich.add_theme_constant_override("shadow_offset_y", int(state.shadow_offset.y))


func _apply() -> void:
	if _bg == null:
		return

	var mode: String = state.mode
	var is_ticker := mode == "ticker"
	var use_rich := not is_ticker   # rich is always on except the scrolling ticker
	var pad := float(state.padding)

	_bg.color = state.bg_color
	_static_root.visible = not is_ticker
	_ticker_clip.visible = is_ticker
	_label.visible = not is_ticker and not use_rich
	_rich.visible = use_rich

	# LabelSettings — shared across all labels.
	_rebuild_fonts()
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

	# Rich label — same box + style as the static label, mapped to RichTextLabel theme.
	_rich.offset_left   = pad
	_rich.offset_top    = pad
	_rich.offset_right  = -pad
	_rich.offset_bottom = -pad
	if use_rich:
		_style_rich()

	# Render the active mode into the rich label. Static uses inline spans; the other
	# (generated/list) modes use global styling only.
	match mode:
		"static":
			_rich.text = _rich_wrap(_spans_to_bbcode())
		"clock":
			_render_plain(_get_clock_text())
		"countdown":
			_render_plain(_get_countdown_text())
		"cycle":
			var items: Array = state.cycle_items
			_cycle_index = clampi(_cycle_index, 0, maxi(0, items.size() - 1))
			_render_plain(String(items[_cycle_index]) if not items.is_empty() else "")
		"ticker":
			pass  # handled by ticker nodes below

	# Vertical alignment: RichTextLabel has no vertical_alignment property, so the content
	# box is positioned manually from its measured height (see _reflow_vertical). The
	# deferred call re-runs after the label has laid out, since the content height is only
	# exact post-layout (right after setting .text it can still be stale).
	if use_rich:
		_reflow_vertical()
		call_deferred("_reflow_vertical")

	# Ticker labels.
	var ticker_txt := _format_text(state.text)
	for t_lbl: Label in [_ticker_a, _ticker_b]:
		t_lbl.label_settings = _label_settings
		t_lbl.text = ticker_txt

	if is_ticker:
		_ticker_offset = 0.0
		_ticker_a.position = Vector2(0.0, (float(size.y) - _ticker_a.get_minimum_size().y) * 0.5)
		_ticker_b.position = Vector2(_ticker_a.get_minimum_size().x + 80.0, _ticker_a.position.y)


# Positions the rich content box vertically (TOP/CENTER/BOTTOM) inside the padded slot.
# RichTextLabel exposes no vertical_alignment, so the box is sized to its measured content
# height and offset by hand. Width always spans the padded slot (horizontal alignment is
# handled by the [center]/[right] BBCode wrap in _rich_wrap).
func _reflow_vertical() -> void:
	if _rich == null or not _rich.visible:
		return
	var pad := float(state.padding)
	var ch := float(_rich.get_content_height())
	var avail := float(size.y) - 2.0 * pad
	var y := pad
	match int(state.align_v):
		1:
			y = pad + maxf(0.0, (avail - ch) * 0.5)
		2:
			y = pad + maxf(0.0, avail - ch)
	_rich.offset_left = pad
	_rich.offset_right = -pad
	_rich.offset_top = y
	_rich.offset_bottom = y + ch - float(size.y)


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

	# Legacy snapshots stored BBCode inline in `text` with no spans — parse it into the
	# plain-text + spans model so old slots keep their formatting.
	if (state.spans as Array).is_empty() and String(state.text).contains("["):
		var parsed := _parse_bbcode(String(state.text))
		state.text = parsed.text
		state.spans = parsed.spans

	_apply()


func set_mode(_m: String) -> void:
	pass  # required by slot_manager interface


# Parses a BBCode string into {text: plain, spans: [...]} for the inline tags we own
# (b/i/u/s/font_size/color). Alignment tags ([center]/[right]) and unknowns are dropped;
# [lb]/[rb] become literal brackets.
func _parse_bbcode(s: String) -> Dictionary:
	var spans: Array = []
	var plain := ""
	var open_stack := {}   # type -> [start_index, value]
	var i := 0
	var n := s.length()
	while i < n:
		if s[i] != "[":
			plain += s[i]
			i += 1
			continue
		var close := s.find("]", i)
		if close == -1:
			plain += s[i]
			i += 1
			continue
		var tag := s.substr(i + 1, close - i - 1)
		i = close + 1
		if tag == "lb":
			plain += "["
		elif tag == "rb":
			plain += "]"
		elif tag.begins_with("/"):
			var t := _tag_type(tag.substr(1))
			if t != "" and open_stack.has(t):
				var od: Array = open_stack[t]
				spans.append({"s": od[0], "e": plain.length(), "t": t, "v": od[1]})
				open_stack.erase(t)
		else:
			var t := _tag_type(tag)
			if t != "":
				var v := ""
				if "=" in tag:
					v = tag.split("=")[1]
					if t == "color":
						v = v.lstrip("#")
				open_stack[t] = [plain.length(), v]
	return {"text": plain, "spans": spans}


func _tag_type(tag: String) -> String:
	match tag:
		"b", "i", "u", "s":
			return tag
	if tag.begins_with("font_size"):
		return "size"
	if tag.begins_with("color"):
		return "color"
	return ""
