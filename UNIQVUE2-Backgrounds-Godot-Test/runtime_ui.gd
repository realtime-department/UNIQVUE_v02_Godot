extends CanvasLayer
## EIN globales Laufzeit-Bedienpanel als Autoload (Singleton). Es lebt AUSSERHALB
## der einzelnen Szenen und bleibt beim Szenenwechsel bestehen, daher:
##   - keine UI-Logik/-Knoten in den einzelnen .tscn,
##   - Panel-Position und Sichtbarkeit bleiben beim TRANSITION-Wechsel erhalten.
##
## Beim (Neu-)Laden einer Szene werden nur die Regler neu aufgebaut, automatisch
## ausgelesen aus:
##   1) @export-Variablen des Szenen-Wurzelskripts (z.B. tunnel_sim.gd) inkl. Gruppen,
##   2) Shader-Uniforms aller ShaderMaterials (Name/Typ/hint_range/source_color),
##   3) feste POST-Parameter des WorldEnvironment (Glow/Kontrast/Saettigung).
##
## - Tab blendet das Panel ein/aus, Titelleiste zieht das Panel frei.
## - TRANSITION wechselt zur naechsten Szene (Reihenfolge: SCENES).

const PANEL_WIDTH := 300.0      # feste Gesamtbreite (unabhaengig von Szene/Labels)
const BODY_HEIGHT := 560.0      # feste Hoehe des scrollbaren Reglerbereichs
const LABEL_WIDTH := 116.0
const VALUE_WIDTH := 50.0
const COL_MUTED := Color(0.62, 0.66, 0.72)

# Szenen-Reihenfolge fuer den TRANSITION-Wechsel (zyklisch).
const SCENES := [
	"res://tunnel_wave.tscn",
	"res://particle_wave.tscn",
]

# Feste Environment-Post-Parameter: [property, min, max, step]
const POST_PARAMS := [
	["glow_intensity", 0.0, 3.0, 0.01],
	["glow_strength", 0.0, 3.0, 0.01],
	["glow_bloom", 0.0, 1.0, 0.01],
	["glow_hdr_threshold", 0.0, 1.0, 0.01],
	["adjustment_contrast", 0.5, 2.0, 0.01],
	["adjustment_saturation", 0.0, 2.0, 0.01],
]

var _panel: PanelContainer
var _title: Label
var _rows: VBoxContainer
var _dragging := false
var _last_scene: Node = null


func _ready() -> void:
	layer = 100  # immer ueber der 3D-Szene
	_build_chrome()
	# Auf Szenenwechsel reagieren (auch der erste Szenenaufbau beim Start).
	get_tree().tree_changed.connect(_on_tree_changed)
	_check_scene.call_deferred()


# --------------------------------------------------------------- Panel-Geruest

func _build_chrome() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	# Feste Breite. Hoehe ergibt sich aus dem fixierten BODY_HEIGHT (s.u.),
	# daher fuer alle Szenen identische Gesamtgroesse.
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var vp := get_viewport().get_visible_rect().size
	_panel.position = Vector2(vp.x - PANEL_WIDTH - 16.0, 16.0)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 2)
	_panel.add_child(outer)

	# --- Titelleiste (Drag-Griff) ---
	_title = Label.new()
	_title.text = "  UNIQVUE2   ·   drag · Tab"
	_title.add_theme_font_size_override("font_size", 11)
	_title.add_theme_color_override("font_color", COL_MUTED)
	_title.mouse_filter = Control.MOUSE_FILTER_STOP
	_title.gui_input.connect(_on_title_input)
	_title.custom_minimum_size = Vector2(0, 22)
	# Lange Szenennamen duerfen die Panelbreite nicht aufblaehen.
	_title.clip_text = true
	outer.add_child(_title)

	# --- Scrollbarer Reglerbereich (Inhalt wird pro Szene neu befuellt) ---
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Feste Hoehe: kuerzere Reglerlisten dehnen das Panel nicht, laengere scrollen.
	scroll.custom_minimum_size = Vector2(0, BODY_HEIGHT)
	scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	outer.add_child(scroll)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 3)
	scroll.add_child(_rows)

	# --- TRANSITION (Szenenwechsel), bleibt ueber alle Szenen bestehen ---
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
	btn.pressed.connect(_on_transition)
	outer.add_child(btn)


# Reagiert auf jeden Baumwechsel, baut aber nur neu, wenn sich die aktive Szene
# tatsaechlich aendert (verhindert Endlosschleifen beim eigenen add_child).
func _on_tree_changed() -> void:
	_check_scene()


func _check_scene() -> void:
	if not is_inside_tree():
		return
	var cur := get_tree().current_scene
	if cur == _last_scene:
		return
	if cur == null or not cur.is_inside_tree():
		return
	_last_scene = cur
	_populate(cur)


# --------------------------------------------------------------- Befuellung

func _populate(root: Node) -> void:
	_title.text = "  %s   ·   drag · Tab" % str(root.name).to_upper()
	while _rows.get_child_count() > 0:
		var c := _rows.get_child(0)
		_rows.remove_child(c)
		c.queue_free()

	# 1) @export-Variablen des Wurzel-Skripts (CPU-Parameter, z.B. Tunnel).
	if root.get_script() != null:
		_add_object_props(_rows, root)

	# 2) Shader-Uniforms aller ShaderMaterials in der Szene.
	for entry in _find_shader_materials(root):
		var node_name: String = str(entry[0])
		var mat: ShaderMaterial = entry[1]
		_add_shader_uniforms(_rows, node_name, mat)

	# 3) Feste POST-Parameter.
	var env := _find_environment(root)
	if env != null:
		_add_section(_rows, "POST")
		for p in POST_PARAMS:
			_add_env_slider(_rows, env, p[0], p[1], p[2], p[3])


# --------------------------------------------------------------- Auto-Discovery

func _find_shader_materials(root: Node) -> Array:
	var out: Array = []
	_collect_shader_materials(root, out)
	return out


func _collect_shader_materials(node: Node, out: Array) -> void:
	if node is GeometryInstance3D:
		var gi := node as GeometryInstance3D
		if gi.material_override is ShaderMaterial:
			out.append([node.name, gi.material_override])
	for c in node.get_children():
		_collect_shader_materials(c, out)


func _find_environment(root: Node) -> Environment:
	var we := _find_world_env(root)
	if we != null:
		return we.environment
	return null


func _find_world_env(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for c in node.get_children():
		var r := _find_world_env(c)
		if r != null:
			return r
	return null


# @export-Variablen + @export_group-Header des Skripts auf 'obj' aufbauen.
func _add_object_props(parent: Node, obj: Object) -> void:
	var header_done := false
	for prop in obj.get_property_list():
		var usage: int = int(prop["usage"])
		var pname: String = str(prop["name"])
		if usage & PROPERTY_USAGE_GROUP:
			if pname != "":
				_add_section(parent, pname.to_upper())
				header_done = true
			continue
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var ptype: int = int(prop["type"])
		if not _supported(ptype):
			continue
		if not header_done:
			_add_section(parent, str(obj.name).to_upper())
			header_done = true
		var key := pname
		var getter := func() -> Variant: return obj.get(key)
		var setter := func(v: Variant) -> void: obj.set(key, v)
		_add_control_for(parent, pname, ptype, int(prop["hint"]), str(prop["hint_string"]), getter, setter)


# Shader-Uniforms eines Materials aufbauen (inkl. group_uniforms als Subheader).
func _add_shader_uniforms(parent: Node, node_name: String, mat: ShaderMaterial) -> void:
	if mat.shader == null:
		return
	var ulist := mat.shader.get_shader_uniform_list(true)
	var has_real := false
	for u in ulist:
		var usage: int = int(u["usage"])
		if usage & PROPERTY_USAGE_GROUP:
			continue
		if _supported(int(u["type"])):
			has_real = true
			break
	if not has_real:
		return

	_add_section(parent, node_name.to_upper())
	var rid := mat.shader.get_rid()
	for u in ulist:
		var usage: int = int(u["usage"])
		var uname: String = str(u["name"])
		if uname == "":
			continue
		if usage & PROPERTY_USAGE_GROUP:
			_add_section(parent, "  " + uname.to_upper())
			continue
		var utype: int = int(u["type"])
		if not _supported(utype):
			continue
		var key := uname
		var getter := func() -> Variant:
			var v: Variant = mat.get_shader_parameter(key)
			if v == null:
				v = RenderingServer.shader_get_parameter_default(rid, key)
			return v
		var setter := func(v: Variant) -> void:
			mat.set_shader_parameter(key, v)
		_add_control_for(parent, uname, utype, int(u["hint"]), str(u["hint_string"]), getter, setter)


func _supported(t: int) -> bool:
	return (t == TYPE_FLOAT or t == TYPE_INT or t == TYPE_VECTOR2
		or t == TYPE_VECTOR3 or t == TYPE_COLOR or t == TYPE_BOOL)


# Erzeugt das passende Control je nach Typ/Hint und bindet es an getter/setter.
func _add_control_for(parent: Node, label: String, ptype: int, hint: int, hint_string: String, getter: Callable, setter: Callable) -> void:
	match ptype:
		TYPE_FLOAT, TYPE_INT:
			var r := _parse_range(hint_string, ptype, getter)
			_add_bound_slider(parent, label, r[0], r[1], r[2], getter, setter, ptype == TYPE_INT)
		TYPE_VECTOR2:
			var r2 := _parse_range(hint_string, TYPE_FLOAT, getter)
			_add_vec2(parent, label, r2[0], r2[1], r2[2], getter, setter)
		TYPE_VECTOR3:
			if hint == PROPERTY_HINT_COLOR_NO_ALPHA:
				_add_color(parent, label, getter, setter)
			else:
				var r3 := _parse_range(hint_string, TYPE_FLOAT, getter)
				_add_vec3(parent, label, r3[0], r3[1], r3[2], getter, setter)
		TYPE_COLOR:
			_add_color(parent, label, getter, setter)
		TYPE_BOOL:
			_add_check(parent, label, getter, setter)


# hint_string "min,max[,step]" -> [min, max, step]. Sonst Heuristik aus Wert.
func _parse_range(hint_string: String, ptype: int, getter: Callable) -> Array:
	var mn := 0.0
	var mx := 1.0
	var st := 0.0
	var ok := false
	if hint_string != "":
		var parts := hint_string.split(",", false)
		if parts.size() >= 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
			mn = parts[0].to_float()
			mx = parts[1].to_float()
			ok = true
			if parts.size() >= 3 and parts[2].is_valid_float():
				st = parts[2].to_float()
	if not ok:
		var cv: Variant = getter.call()
		if cv is float or cv is int:
			var cur := float(cv)
			mn = minf(0.0, cur)
			mx = maxf(1.0, absf(cur) * 4.0)
		else:
			mn = -1.0
			mx = 1.0
	if st <= 0.0:
		st = 1.0 if ptype == TYPE_INT else (mx - mn) / 200.0
	if st <= 0.0:
		st = 0.01
	return [mn, mx, st]


# ------------------------------------------------------------------ Bausteine

func _add_section(parent: Node, title: String) -> void:
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", COL_MUTED)
	l.custom_minimum_size = Vector2(0, 18)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.clip_text = true
	l.tooltip_text = title
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
	# Feste Spaltenbreite: lange Namen abschneiden (Vollname im Tooltip),
	# damit kein Label die Panelbreite ueber PANEL_WIDTH hinaus aufweitet.
	name_lbl.clip_text = true
	name_lbl.size_flags_horizontal = Control.SIZE_FILL
	name_lbl.tooltip_text = name
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


func _make_value_label(val: float, is_int: bool) -> Label:
	var v := Label.new()
	v.text = ("%d" % int(round(val))) if is_int else ("%.2f" % val)
	v.add_theme_font_size_override("font_size", 11)
	v.add_theme_color_override("font_color", COL_MUTED)
	v.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return v


func _add_bound_slider(parent: Node, label: String, mn: float, mx: float, st: float, getter: Callable, setter: Callable, is_int: bool) -> void:
	var cv: Variant = getter.call()
	var val: float = float(cv) if cv != null else mn
	var row := _make_row(parent, label)
	var s := _make_slider(mn, mx, st, val)
	var v := _make_value_label(val, is_int)
	row.add_child(s)
	row.add_child(v)
	s.value_changed.connect(func(value: float) -> void:
		if is_int:
			setter.call(int(round(value)))
			v.text = "%d" % int(round(value))
		else:
			setter.call(value)
			v.text = "%.2f" % value)


func _add_env_slider(parent: Node, env: Environment, prop: String, mn: float, mx: float, st: float) -> void:
	var val := float(env.get(prop))
	var row := _make_row(parent, prop)
	var s := _make_slider(mn, mx, st, val)
	var v := _make_value_label(val, false)
	row.add_child(s)
	row.add_child(v)
	s.value_changed.connect(func(value: float) -> void:
		env.set(prop, value)
		v.text = "%.2f" % value)


func _add_vec2(parent: Node, label: String, mn: float, mx: float, st: float, getter: Callable, setter: Callable) -> void:
	var cv: Variant = getter.call()
	var base: Vector2 = cv if cv is Vector2 else Vector2.ZERO
	for axis in ["x", "y"]:
		var ax := str(axis)
		var start: float = base.x if ax == "x" else base.y
		var row := _make_row(parent, label + "." + ax)
		var s := _make_slider(mn, mx, st, start)
		var v := _make_value_label(start, false)
		row.add_child(s)
		row.add_child(v)
		s.value_changed.connect(func(value: float) -> void:
			var raw: Variant = getter.call()
			var nd: Vector2 = raw if raw is Vector2 else Vector2.ZERO
			if ax == "x":
				nd.x = value
			else:
				nd.y = value
			setter.call(nd)
			v.text = "%.2f" % value)


func _add_vec3(parent: Node, label: String, mn: float, mx: float, st: float, getter: Callable, setter: Callable) -> void:
	var cv: Variant = getter.call()
	var base: Vector3 = cv if cv is Vector3 else Vector3.ZERO
	for axis in ["x", "y", "z"]:
		var ax := str(axis)
		var start: float = base[ax]
		var row := _make_row(parent, label + "." + ax)
		var s := _make_slider(mn, mx, st, start)
		var v := _make_value_label(start, false)
		row.add_child(s)
		row.add_child(v)
		s.value_changed.connect(func(value: float) -> void:
			var raw: Variant = getter.call()
			var nd: Vector3 = raw if raw is Vector3 else Vector3.ZERO
			nd[ax] = value
			setter.call(nd)
			v.text = "%.2f" % value)


func _add_color(parent: Node, label: String, getter: Callable, setter: Callable) -> void:
	var cv: Variant = getter.call()
	var col := Color.WHITE
	if cv is Color:
		col = cv
	elif cv is Vector3:
		col = Color(cv.x, cv.y, cv.z)
	var row := _make_row(parent, label)
	var btn := ColorPickerButton.new()
	btn.color = col
	btn.edit_alpha = false
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 18)
	row.add_child(btn)
	# source_color-Uniforms akzeptieren Color direkt (Godot castet zu vec3).
	btn.color_changed.connect(func(c: Color) -> void:
		setter.call(c))


func _add_check(parent: Node, label: String, getter: Callable, setter: Callable) -> void:
	var row := _make_row(parent, label)
	var cv: Variant = getter.call()
	var cb := CheckBox.new()
	cb.button_pressed = bool(cv) if cv != null else false
	row.add_child(cb)
	cb.toggled.connect(func(pressed: bool) -> void:
		setter.call(pressed))


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


func _on_transition() -> void:
	var cur := ""
	if get_tree().current_scene != null:
		cur = get_tree().current_scene.scene_file_path
	var idx := SCENES.find(cur)
	var nxt: String = SCENES[(idx + 1) % SCENES.size()] if idx >= 0 else SCENES[0]
	get_tree().change_scene_to_file(nxt)


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
