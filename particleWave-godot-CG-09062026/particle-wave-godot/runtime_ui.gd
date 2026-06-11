extends CanvasLayer
## Minimalistisches Laufzeit-Bedienpanel fuer Particle Wave.
## Baut sich komplett aus GDScript auf (kein Szenen-Geklicke), damit die .tscn
## sauber bleibt und alle Parameter an EINER Stelle definiert sind.
##
## - Regler fuer alle Shader-Uniforms + Environment-Post-Parameter.
## - Werte werden nur angezeigt (rechtsbuendiges Label), justiert wird per Slider.
## - Panel ist frei verschiebbar (Titelleiste ziehen).
## - Tab blendet das Panel ein/aus.
## - Transition-Button ist nur Platzhalter (keine Logik, siehe Plan).

const PANEL_WIDTH := 300.0
const LABEL_WIDTH := 108.0
const VALUE_WIDTH := 50.0
const COL_MUTED := Color(0.62, 0.66, 0.72)

# Shader-Float-Uniforms: [uniform_name, min, max, step]
const WAVE_PARAMS := [
	["amp", 0.0, 20.0, 0.1],
	["freq", 0.05, 3.0, 0.01],
	["wavelength", 0.2, 6.0, 0.01],
	["speed", 0.0, 3.0, 0.01],
	["flow", 0.0, 2.0, 0.01],
	["warp", 0.0, 2.0, 0.01],
	["y_off", -20.0, 20.0, 0.1],
	["mirror", 0.0, 1.0, 1.0],
	["x_noise", 0.0, 1.0, 0.01],
]
const APPEARANCE_PARAMS := [
	["point_size", 1.0, 8.0, 0.1],
	["glow_boost", 0.0, 4.0, 0.01],
	["z_near", 0.0, 30.0, 0.1],
	["z_far", 10.0, 200.0, 1.0],
]
const COLOR_PARAMS := ["col_valley", "col_mid", "col_crest"]
# Environment-Properties: [property_name, min, max, step]
const POST_PARAMS := [
	["glow_intensity", 0.0, 3.0, 0.01],
	["glow_strength", 0.0, 3.0, 0.01],
	["glow_bloom", 0.0, 1.0, 0.01],
	["glow_hdr_threshold", 0.0, 1.0, 0.01],
	["adjustment_contrast", 0.5, 2.0, 0.01],
	["adjustment_saturation", 0.0, 2.0, 0.01],
]

var _mat: ShaderMaterial
var _env: Environment
var _panel: PanelContainer
var _dragging := false


func _ready() -> void:
	var root := get_parent()
	var grid := root.get_node_or_null("Grid")
	if grid and grid.material_override is ShaderMaterial:
		_mat = grid.material_override
	var we := root.get_node_or_null("WorldEnvironment")
	if we:
		_env = we.environment
	if _mat == null:
		push_error("runtime_ui: ShaderMaterial auf Grid nicht gefunden.")
		return
	_build_ui()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var vp := get_viewport().get_visible_rect().size
	_panel.position = Vector2(vp.x - PANEL_WIDTH - 16.0, 16.0)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 2)
	_panel.add_child(outer)

	# --- Titelleiste (Drag-Griff) ---
	var title := Label.new()
	title.text = "  PARTICLE WAVE   ·   drag · Tab"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", COL_MUTED)
	title.mouse_filter = Control.MOUSE_FILTER_STOP
	title.gui_input.connect(_on_title_input)
	title.custom_minimum_size = Vector2(0, 22)
	outer.add_child(title)

	# --- Scrollbarer Reglerbereich ---
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 560)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 3)
	scroll.add_child(rows)

	# --- WAVE ---
	_add_section(rows, "WAVE")
	for p in WAVE_PARAMS:
		_add_shader_slider(rows, p[0], p[1], p[2], p[3])
	_add_dir_sliders(rows)

	# --- APPEARANCE ---
	_add_section(rows, "APPEARANCE")
	for p in APPEARANCE_PARAMS:
		_add_shader_slider(rows, p[0], p[1], p[2], p[3])
	for c in COLOR_PARAMS:
		_add_color_picker(rows, c)

	# --- POST ---
	if _env:
		_add_section(rows, "POST")
		for p in POST_PARAMS:
			_add_env_slider(rows, p[0], p[1], p[2], p[3])

	# --- Transition (Platzhalter) ---
	var btn := Button.new()
	btn.text = "TRANSITION"
	btn.flat = true
	btn.add_theme_font_size_override("font_size", 12)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_stylebox_override("normal", _button_style(0.0))
	btn.add_theme_stylebox_override("hover", _button_style(0.12))
	btn.add_theme_stylebox_override("pressed", _button_style(0.22))
	btn.add_theme_stylebox_override("focus", _button_style(0.0))
	btn.custom_minimum_size = Vector2(0, 30)
	# Absichtlich kein 'pressed'-Signal verbunden (Logik kommt erst im Studio).
	outer.add_child(btn)


# ------------------------------------------------------------------ Bausteine

func _add_section(parent: Node, title: String) -> void:
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", COL_MUTED)
	l.custom_minimum_size = Vector2(0, 18)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	parent.add_child(l)


func _make_row(parent: Node, name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var name_lbl := Label.new()
	name_lbl.text = name
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	row.add_child(name_lbl)
	return row


func _make_slider(min_v: float, max_v: float, step: float, val: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(0, 16)
	return s


func _make_value_label(val: float) -> Label:
	var v := Label.new()
	v.text = "%.2f" % val
	v.add_theme_font_size_override("font_size", 11)
	v.add_theme_color_override("font_color", COL_MUTED)
	v.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return v


func _add_shader_slider(parent: Node, uniform: String, min_v: float, max_v: float, step: float) -> void:
	var cur: Variant = _mat.get_shader_parameter(uniform)
	var val := float(cur) if cur != null else min_v
	var row := _make_row(parent, uniform)
	var s := _make_slider(min_v, max_v, step, val)
	var v := _make_value_label(val)
	row.add_child(s)
	row.add_child(v)
	s.value_changed.connect(func(value: float) -> void:
		_mat.set_shader_parameter(uniform, value)
		v.text = "%.2f" % value)


func _add_env_slider(parent: Node, prop: String, min_v: float, max_v: float, step: float) -> void:
	var val := float(_env.get(prop))
	var row := _make_row(parent, prop)
	var s := _make_slider(min_v, max_v, step, val)
	var v := _make_value_label(val)
	row.add_child(s)
	row.add_child(v)
	s.value_changed.connect(func(value: float) -> void:
		_env.set(prop, value)
		v.text = "%.2f" % value)


func _add_dir_sliders(parent: Node) -> void:
	var cur = _mat.get_shader_parameter("dir")
	var d: Vector2 = cur if cur is Vector2 else Vector2(0.0, 1.0)
	for comp in ["x", "y"]:
		var start: float = d.x if comp == "x" else d.y
		var row := _make_row(parent, "dir." + comp)
		var s := _make_slider(-1.0, 1.0, 0.01, start)
		var v := _make_value_label(start)
		row.add_child(s)
		row.add_child(v)
		var axis := str(comp)
		s.value_changed.connect(func(value: float) -> void:
			var raw: Variant = _mat.get_shader_parameter("dir")
			var nd: Vector2 = raw if raw is Vector2 else Vector2.ZERO
			if axis == "x":
				nd.x = value
			else:
				nd.y = value
			_mat.set_shader_parameter("dir", nd)
			v.text = "%.2f" % value)


func _add_color_picker(parent: Node, uniform: String) -> void:
	var cur = _mat.get_shader_parameter(uniform)
	var col := Color.WHITE
	if cur is Color:
		col = cur
	elif cur is Vector3:
		col = Color(cur.x, cur.y, cur.z)
	var row := _make_row(parent, uniform)
	var btn := ColorPickerButton.new()
	btn.color = col
	btn.edit_alpha = false
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 18)
	row.add_child(btn)
	btn.color_changed.connect(func(c: Color) -> void:
		# source_color-Uniforms werden als Color gespeichert (wie in der .tscn).
		_mat.set_shader_parameter(uniform, c))


# ------------------------------------------------------------------ Interaktion

func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		var vp := get_viewport().get_visible_rect().size
		var np: Vector2 = _panel.position + event.relative
		_panel.position = np.clamp(Vector2.ZERO, (vp - _panel.size).max(Vector2.ZERO))


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		if _panel:
			_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ Styling

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	return sb


func _button_style(fill_alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, fill_alpha)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.55)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	return sb
