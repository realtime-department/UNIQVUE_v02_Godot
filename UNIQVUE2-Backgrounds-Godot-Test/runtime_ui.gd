extends CanvasLayer
## ONE global runtime control panel as Autoload (Singleton). It lives OUTSIDE
## the individual scenes and persists across scene changes, therefore:
##   - no UI logic/nodes in the individual .tscn,
##   - panel position and visibility are preserved during TRANSITION switches.
##
## When a scene (re-)loads, only the controls are rebuilt, automatically
## read from:
##   1) @export variables of the scene root script (e.g. tunnel_sim.gd) incl. groups,
##   2) shader uniforms of all ShaderMaterials (name/type/hint_range/source_color),
##   3) fixed POST parameters of the WorldEnvironment (Glow/Contrast/Saturation).
##
## - Tab toggles the panel, title bar drags the panel freely.
## - TRANSITION switches to the next scene (order: SCENES).

const PANEL_WIDTH := 300.0      # fixed total width (independent of scene/labels)
const PANEL_HEIGHT := 780.0     # fixed total height (independent of content)
const LABEL_WIDTH := 116.0
const VALUE_WIDTH := 50.0
const COL_MUTED := Color(0.62, 0.66, 0.72)

# Global post parameters (master environment, Bloom/Glow only): [property, min, max, step].
# Tonemap/Vignette/Grain live in the overlay material (see _add_overlay_slider), not here.
const POST_PARAMS := [
	["glow_intensity", 0.0, 3.0, 0.01],
	["glow_strength", 0.0, 3.0, 0.01],
	["glow_bloom", 0.0, 1.0, 0.01],
	["glow_hdr_threshold", 0.0, 2.0, 0.01],
]

const SHAPE_NAMES := ["Dot", "Ring", "Square", "Star", "Cross"]

# [label, msaa_3d, screen_space_aa, use_taa]
const AA_MODES := [
	["None",   Viewport.MSAA_DISABLED, Viewport.SCREEN_SPACE_AA_DISABLED, false],
	["FXAA",   Viewport.MSAA_DISABLED, Viewport.SCREEN_SPACE_AA_FXAA,     false],
	["2×",     Viewport.MSAA_2X,       Viewport.SCREEN_SPACE_AA_DISABLED, false],
	["4×",     Viewport.MSAA_4X,       Viewport.SCREEN_SPACE_AA_DISABLED, false],
	["8×",     Viewport.MSAA_8X,       Viewport.SCREEN_SPACE_AA_DISABLED, false],
	["TAA",    Viewport.MSAA_DISABLED, Viewport.SCREEN_SPACE_AA_DISABLED, true],
	["TAA+2×", Viewport.MSAA_2X,       Viewport.SCREEN_SPACE_AA_DISABLED, true],
]

var _panel: PanelContainer
var _title: Label
var _rows: VBoxContainer
var _dragging := false
# Collapsed state of sections, per title; survives scene rebuild.
var _collapsed := {}
# STYLE swatches (persistent in outer container) for re-syncing after
# a preset LOAD — otherwise the color fields still show the old values.
var _style_swatches: Array = []
# SEQUENCE section (persistent in outer container): step list + dropdown + status.
var _seq_list: VBoxContainer
var _seq_opt: OptionButton
var _seq_status: Label
# FPS display.
var _fps_label: Label
# FPS update counter.
var _fps_timer: float = 0.0
# Anti-aliasing level (survives scene rebuild).
var _aa_index: int = 0
# Debanding strength (LSB) for the final present pass (survives scene rebuild).
var _dither_strength: float = 1.0


func _ready() -> void:
	layer = 100  # always above the 3D scene
	_build_chrome()
	# Dock to the background stage: it signals the active background.
	_connect_stage.call_deferred()
	# Keep panel visible on window change (PREVIEW/SPAN/WINDOW).
	get_window().size_changed.connect(_on_window_resized)


func _on_window_resized() -> void:
	if _panel == null:
		return
	var vp := get_viewport().get_visible_rect().size
	_panel.position = _panel.position.clamp(Vector2.ZERO, (vp - _panel.size).max(Vector2.ZERO))


# --------------------------------------------------------------- Panel frame

func _build_chrome() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	# Fixed total size for ALL scenes: width AND height are pinned, the
	# scrollable control area (see below) absorbs any content amount -> no jumping
	# of panel size on scene switch (e.g. when the scrollbar appears).
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	_panel.size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	_panel.clip_contents = true
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var vp := get_viewport().get_visible_rect().size
	_panel.position = Vector2(vp.x - PANEL_WIDTH - 16.0, 16.0)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 2)
	_panel.add_child(outer)

	# --- Title bar (drag handle) ---
	_title = Label.new()
	_title.text = "  UNIQVUE2   ·   drag · Tab"
	_title.add_theme_font_size_override("font_size", 11)
	_title.add_theme_color_override("font_color", COL_MUTED)
	_title.mouse_filter = Control.MOUSE_FILTER_STOP
	_title.gui_input.connect(_on_title_input)
	_title.custom_minimum_size = Vector2(0, 22)
	# Long scene names must not inflate the panel width.
	_title.clip_text = true
	outer.add_child(_title)

	# --- STAGE: virtual display configuration (global, persists across scenes) ---
	_build_stage_config(outer)

	# --- STYLE: central color palette (global, shared across backgrounds) ---
	_build_style_config(outer)

	# --- PRESET: named presets save/load (S3, global) ---
	_build_preset_config(outer)

	# --- SEQUENCE: preset playlist + playback (S4, global) ---
	_build_sequencer_config(outer)

	# --- Scrollable control area (content rebuilt per scene) ---
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Always show vertical scrollbar -> its space is permanently reserved.
	# Otherwise content shifts sideways when a scene needs no scrollbar
	# and the control column takes the freed width.
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	# Absorbs all content variation: fills the remaining panel space
	# (EXPAND_FILL) and scrolls internally. Panel size stays fixed,
	# regardless of how many controls the scene generates.
	scroll.custom_minimum_size = Vector2(0, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 3)
	scroll.add_child(_rows)

	# --- Transition duration (number field), persists across all scenes ---
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 6)
	trow.custom_minimum_size = Vector2(0, 24)
	var tlbl := Label.new()
	tlbl.text = "trans time (s)"
	tlbl.add_theme_font_size_override("font_size", 11)
	tlbl.add_theme_color_override("font_color", COL_MUTED)
	tlbl.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	tlbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	trow.add_child(tlbl)
	var spin := SpinBox.new()
	spin.min_value = 0.1
	spin.max_value = 10.0
	spin.step = 0.05
	spin.value = _stage_transition_time()
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	trow.add_child(spin)
	outer.add_child(trow)
	spin.value_changed.connect(func(value: float) -> void:
		var stage := get_node_or_null("/root/BackgroundStage")
		if stage != null:
			stage.set("transition_time", value))

	# --- TRANSITION (scene switch), persists across all scenes ---
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

	# FPS display (bottom).
	_fps_label = Label.new()
	_fps_label.add_theme_font_size_override("font_size", 10)
	_fps_label.add_theme_color_override("font_color", COL_MUTED)
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	outer.add_child(_fps_label)


func _process(delta: float) -> void:
	_fps_timer += delta
	if _fps_timer >= 0.5 and _fps_label != null:
		_fps_timer = 0.0
		_fps_label.text = "%d fps" % Engine.get_frames_per_second()


# Dock to the background stage and populate initially. Deferred so all
# autoloads exist and the first background is already loaded.
func _connect_stage() -> void:
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage == null:
		return
	if not stage.is_connected("active_changed", _on_active_changed):
		stage.connect("active_changed", _on_active_changed)
	var root: Variant = stage.call("active_root")
	if root is Node:
		_on_active_changed(root)


func _on_active_changed(root: Node) -> void:
	if root != null and root.is_inside_tree():
		_populate(root)


# --------------------------------------------------------------- Populate

func _populate(root: Node) -> void:
	_title.text = "  %s   ·   drag · Tab" % str(root.name).to_upper()
	while _rows.get_child_count() > 0:
		var c := _rows.get_child(0)
		_rows.remove_child(c)
		c.queue_free()

	# 1) @export variables of the scene root script (CPU parameters, e.g. Tunnel).
	if root.get_script() != null:
		_add_object_props(_rows, root)

	# 2) Shader uniforms of all ShaderMaterials in the scene.
	# @export variables are already visible under step 1; same-named
	# shader uniforms are skipped (would do nothing — _process()
	# overwrites them every frame with the @export value).
	var exported_names := {}
	if root.get_script() != null:
		for prop in root.get_property_list():
			var _usage := int(prop["usage"])
			if _usage & PROPERTY_USAGE_SCRIPT_VARIABLE and _usage & PROPERTY_USAGE_EDITOR:
				exported_names[str(prop["name"])] = true
	for entry in ParamStore._find_shader_materials(root):
		var node_name: String = str(entry[0])
		var mat: ShaderMaterial = entry[1]
		_add_shader_uniforms(_rows, node_name, mat, exported_names)

	# 3) Global POST parameters. Since S1 post works centrally via the master
	#    composite (BackgroundStage.post_environment); falls back to the scene env
	#    if no master is present (yet).
	var stage := get_node_or_null("/root/BackgroundStage")
	var penv: Environment = null
	if stage != null:
		var pe: Variant = stage.call("post_environment")
		if pe is Environment:
			penv = pe
	if penv == null:
		penv = _find_environment(root)
	if penv != null:
		var post_body := _add_section(_rows, "POST")
		for p in POST_PARAMS:
			_add_env_slider(post_body, penv, p[0], p[1], p[2], p[3])
		# Vignette/Grain live in the master overlay material, not the environment.
		if stage != null:
			var omat: Variant = stage.call("post_overlay")
			if omat is ShaderMaterial:
				_add_overlay_slider(post_body, omat, "vignette", 0.0, 1.0, 0.01)
				_add_overlay_slider(post_body, omat, "grain", 0.0, 0.3, 0.005)
		# Scale render resolution (½ / ¾ / 1×).
		var res_row := HBoxContainer.new()
		res_row.add_theme_constant_override("separation", 4)
		var half_btn := _cfg_button("½")
		var tq_btn   := _cfg_button("¾")
		var full_btn := _cfg_button("1×")
		res_row.add_child(half_btn)
		res_row.add_child(tq_btn)
		res_row.add_child(full_btn)
		post_body.add_child(res_row)
		half_btn.pressed.connect(func() -> void:
			if stage != null:
				var sz := get_viewport().get_visible_rect().size
				stage.call("set_render_size_override",
					Vector2i(int(sz.x * 0.5), int(sz.y * 0.5))))
		tq_btn.pressed.connect(func() -> void:
			if stage != null:
				var sz := get_viewport().get_visible_rect().size
				stage.call("set_render_size_override",
					Vector2i(int(sz.x * 0.75), int(sz.y * 0.75))))
		full_btn.pressed.connect(func() -> void:
			if stage != null:
				stage.call("clear_render_size_override"))
		# Anti-Aliasing (None → 2× → 4× → 8×).
		var aa_row := HBoxContainer.new()
		aa_row.add_theme_constant_override("separation", 4)
		var aa_dec := _cfg_button("◀")
		aa_dec.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		aa_dec.custom_minimum_size = Vector2(28, 26)
		var aa_lbl := Label.new()
		aa_lbl.text = AA_MODES[_aa_index][0]
		aa_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		aa_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		aa_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		aa_lbl.add_theme_font_size_override("font_size", 11)
		aa_lbl.add_theme_color_override("font_color", Color.WHITE)
		var aa_inc := _cfg_button("▶")
		aa_inc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		aa_inc.custom_minimum_size = Vector2(28, 26)
		aa_row.add_child(aa_dec)
		aa_row.add_child(aa_lbl)
		aa_row.add_child(aa_inc)
		post_body.add_child(aa_row)
		aa_dec.pressed.connect(func() -> void:
			if _aa_index > 0:
				_aa_index -= 1
				aa_lbl.text = AA_MODES[_aa_index][0]
				_apply_aa(get_viewport()))
		aa_inc.pressed.connect(func() -> void:
			if _aa_index < AA_MODES.size() - 1:
				_aa_index += 1
				aa_lbl.text = AA_MODES[_aa_index][0]
				_apply_aa(get_viewport()))
		# Dither slider (blue-noise strength for style gradient).
		var dither_row := _make_row(post_body, "Dither")
		var dither_s := _make_slider(0.0, 4.0, 0.1, _dither_strength)
		var dither_v := _make_value_label(_dither_strength, false)
		dither_row.add_child(dither_s)
		dither_row.add_child(dither_v)
		dither_s.value_changed.connect(func(value: float) -> void:
			_dither_strength = value
			dither_v.text = "%.2f" % value
			var st := get_node_or_null("/root/BackgroundStage")
			if st != null:
				st.call("set_deband", value))

	# Remove empty sections (e.g. material header whose uniforms are all grouped
	# -> the header body stays empty).
	for child in _rows.get_children():
		if child.has_meta("section_body"):
			var b: Node = child.get_meta("section_body")
			if b.get_child_count() == 0:
				child.queue_free()


func _find_environment(root: Node) -> Environment:
	var we := ParamStore._find_world_env(root)
	if we != null:
		return we.environment
	return null


# Build @export variables + @export_group headers of the script on 'obj'.
func _add_object_props(parent: Node, obj: Object) -> void:
	var header_done := false
	var body: Node = parent   # populated once the first section exists
	for prop in obj.get_property_list():
		var usage: int = int(prop["usage"])
		var pname: String = str(prop["name"])
		if usage & PROPERTY_USAGE_GROUP:
			if pname != "":
				body = _add_section(parent, pname.to_upper())
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
			body = _add_section(parent, str(obj.name).to_upper())
			header_done = true
		var key := pname
		var getter := func() -> Variant: return obj.get(key)
		var setter := func(v: Variant) -> void: obj.set(key, v)
		_add_control_for(body, pname, ptype, int(prop["hint"]), str(prop["hint_string"]), getter, setter)


# Build shader uniforms of a material (incl. group_uniforms as sub-headers).
func _add_shader_uniforms(parent: Node, node_name: String, mat: ShaderMaterial, exclude: Dictionary = {}) -> void:
	if mat.shader == null:
		return
	var ulist := mat.shader.get_shader_uniform_list(true)
	var has_real := false
	for u in ulist:
		var usage: int = int(u["usage"])
		if usage & PROPERTY_USAGE_GROUP:
			continue
		if str(u["name"]) in exclude:
			continue
		if _supported(int(u["type"])):
			has_real = true
			break
	if not has_real:
		return

	var body: Node = _add_section(parent, node_name.to_upper())
	var rid := mat.shader.get_rid()
	var skip_group := false
	for u in ulist:
		var usage: int = int(u["usage"])
		var uname: String = str(u["name"])
		if uname == "":
			continue
		if usage & PROPERTY_USAGE_GROUP:
			# Groups with leading '_' (e.g. _Sync) hidden from UI.
			if uname.begins_with("_"):
				skip_group = true
			else:
				skip_group = false
				body = _add_section(parent, "  " + uname.to_upper())
			continue
		if skip_group:
			continue
		if uname in exclude:
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
		_add_control_for(body, uname, utype, int(u["hint"]), str(u["hint_string"]), getter, setter)


func _supported(t: int) -> bool:
	return (t == TYPE_FLOAT or t == TYPE_INT or t == TYPE_VECTOR2
		or t == TYPE_VECTOR3 or t == TYPE_COLOR or t == TYPE_BOOL)


# Create the matching control per type/hint and bind to getter/setter.
func _add_control_for(parent: Node, label: String, ptype: int, hint: int, hint_string: String, getter: Callable, setter: Callable) -> void:
	match ptype:
		TYPE_FLOAT, TYPE_INT:
			# 'shape' parameter: 5-button picker instead of slider.
			if label == "shape" and ptype == TYPE_INT:
				_add_shape_picker(parent, label, getter, setter)
			else:
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


# hint_string "min,max[,step]" -> [min, max, step]. Otherwise heuristic from value.
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


# ------------------------------------------------------------------ Building blocks

# Collapsible section: clickable header (chevron + title) + body container.
# Returns the BODY — all controls of this section belong there.
# The open/closed state is stored per title in _collapsed and survives
# rebuild on scene switch.
func _add_section(parent: Node, title: String) -> VBoxContainer:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 2)
	parent.add_child(group)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 3)

	var collapsed := bool(_collapsed.get(title, false))

	var header := Button.new()
	header.flat = true
	header.focus_mode = Control.FOCUS_NONE
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_theme_font_size_override("font_size", 10)
	header.add_theme_color_override("font_color", COL_MUTED)
	header.add_theme_color_override("font_hover_color", Color.WHITE)
	header.add_theme_color_override("font_pressed_color", Color.WHITE)
	var empty := StyleBoxEmpty.new()
	header.add_theme_stylebox_override("normal", empty)
	header.add_theme_stylebox_override("hover", empty)
	header.add_theme_stylebox_override("pressed", empty)
	header.add_theme_stylebox_override("focus", empty)
	header.custom_minimum_size = Vector2(0, 18)
	header.clip_text = true
	header.tooltip_text = title
	header.text = _section_text(title, collapsed)

	group.add_child(header)
	group.add_child(body)
	body.visible = not collapsed
	group.set_meta("section_body", body)

	header.pressed.connect(func() -> void:
		var now := body.visible          # visible -> collapse now
		body.visible = not now
		_collapsed[title] = now
		header.text = _section_text(title, now))

	return body


func _section_text(title: String, collapsed: bool) -> String:
	return ("▸  " if collapsed else "▾  ") + title


func _make_row(parent: Node, name: String, on_reset: Callable = Callable()) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var name_lbl := Label.new()
	name_lbl.text = name
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	name_lbl.clip_text = true
	name_lbl.size_flags_horizontal = Control.SIZE_FILL
	name_lbl.tooltip_text = name + (("  (dbl-click: reset)") if on_reset.is_valid() else "")
	if on_reset.is_valid():
		name_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
		name_lbl.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.double_click and event.pressed \
					and event.button_index == MOUSE_BUTTON_LEFT:
				on_reset.call())
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
	var default_val := val
	var s := _make_slider(mn, mx, st, val)
	var v := _make_value_label(val, is_int)
	var reset := func() -> void:
		setter.call(int(round(default_val)) if is_int else default_val)
		s.value = default_val
		v.text = ("%d" % int(round(default_val))) if is_int else ("%.2f" % default_val)
	var row := _make_row(parent, label, reset)
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


# Slider for a shader parameter of the master overlay material (Vignette/Grain).
func _add_overlay_slider(parent: Node, mat: ShaderMaterial, prop: String, mn: float, mx: float, st: float) -> void:
	var cur: Variant = mat.get_shader_parameter(prop)
	var val: float = float(cur) if cur != null else mn
	var row := _make_row(parent, prop)
	var s := _make_slider(mn, mx, st, val)
	var v := _make_value_label(val, false)
	row.add_child(s)
	row.add_child(v)
	s.value_changed.connect(func(value: float) -> void:
		mat.set_shader_parameter(prop, value)
		v.text = "%.2f" % value)


func _add_shape_picker(parent: Node, label: String, getter: Callable, setter: Callable) -> void:
	var cur: int = int(getter.call())
	var row := _make_row(parent, label)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 2)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hbox)
	var btns: Array[Button] = []
	for i in range(SHAPE_NAMES.size()):
		var btn := Button.new()
		btn.text = SHAPE_NAMES[i]
		btn.toggle_mode = true
		btn.button_pressed = i == cur
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", 10)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 20)
		btn.add_theme_stylebox_override("pressed", _button_style(0.3))
		btn.add_theme_stylebox_override("normal", _button_style(0.0))
		btn.add_theme_stylebox_override("hover", _button_style(0.12))
		btn.add_theme_stylebox_override("focus", _button_style(0.0))
		var idx := i
		btn.pressed.connect(func() -> void:
			setter.call(idx)
			for j in range(btns.size()):
				btns[j].button_pressed = j == idx)
		btns.append(btn)
		hbox.add_child(btn)


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
		var start: float = base.x if ax == "x" else (base.y if ax == "y" else base.z)
		var row := _make_row(parent, label + "." + ax)
		var s := _make_slider(mn, mx, st, start)
		var v := _make_value_label(start, false)
		row.add_child(s)
		row.add_child(v)
		s.value_changed.connect(func(value: float) -> void:
			var raw: Variant = getter.call()
			var nd: Vector3 = raw if raw is Vector3 else Vector3.ZERO
			if ax == "x":   nd.x = value
			elif ax == "y": nd.y = value
			else:           nd.z = value
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
	# source_color uniforms accept Color directly (Godot casts to vec3).
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


# ------------------------------------------------------------------ Interaction

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


func _stage_transition_time() -> float:
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage != null:
		var v: Variant = stage.get("transition_time")
		if v is float or v is int:
			return float(v)
	return 1.2


func _on_transition() -> void:
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage != null:
		stage.call("transition")


# ------------------------------------------------------- STAGE / Display config

## Global section for configuring the virtual screen layout.
## Controls the DisplaySetup autoload (grid, preview, span). Persists across all
## scenes (lives in the 'outer' container, not the per-scene _rows).
func _build_stage_config(parent: Node) -> void:
	var ds := get_node_or_null("/root/DisplaySetup")
	if ds == null:
		return

	var body := _add_section(parent, "STAGE")

	# Grid: cols x rows
	var grid_row := HBoxContainer.new()
	grid_row.add_theme_constant_override("separation", 6)
	grid_row.add_child(_cfg_label("cols"))
	var cols_spin := _cfg_spin(1, 32, 1, ds.get("cols"))
	grid_row.add_child(cols_spin)
	grid_row.add_child(_cfg_label("rows"))
	var rows_spin := _cfg_spin(1, 32, 1, ds.get("rows"))
	grid_row.add_child(rows_spin)
	body.add_child(grid_row)

	# Pixels per individual screen
	var px_row := HBoxContainer.new()
	px_row.add_theme_constant_override("separation", 6)
	px_row.add_child(_cfg_label("scr w"))
	var w_spin := _cfg_spin(320, 16384, 1, ds.get("screen_w"))
	px_row.add_child(w_spin)
	px_row.add_child(_cfg_label("h"))
	var h_spin := _cfg_spin(240, 16384, 1, ds.get("screen_h"))
	px_row.add_child(h_spin)
	body.add_child(px_row)

	# Info: grid, aspect ratio, total resolution
	var info := Label.new()
	info.add_theme_font_size_override("font_size", 10)
	info.add_theme_color_override("font_color", COL_MUTED)
	info.clip_text = true
	body.add_child(info)

	var apply := func() -> void:
		ds.call("configure", int(cols_spin.value), int(rows_spin.value),
			int(w_spin.value), int(h_spin.value))
		var total: Vector2i = ds.call("total_resolution")
		var asp: float = ds.call("grid_aspect")
		info.text = "%dx%d  ·  %.2f:1  ·  %dx%d" % [
			int(cols_spin.value), int(rows_spin.value), asp, total.x, total.y]
		info.tooltip_text = info.text
	apply.call()
	for sp in [cols_spin, rows_spin, w_spin, h_spin]:
		sp.value_changed.connect(func(_v: float) -> void: apply.call())

	# Mode buttons: Preview / Span / Window
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	var prev_btn := _cfg_button("PREVIEW")
	var span_btn := _cfg_button("SPAN")
	var win_btn := _cfg_button("WINDOW")
	btn_row.add_child(prev_btn)
	btn_row.add_child(span_btn)
	btn_row.add_child(win_btn)
	body.add_child(btn_row)
	prev_btn.pressed.connect(func() -> void: ds.call("open_preview"))
	span_btn.pressed.connect(func() -> void: ds.call("span_screens"))
	win_btn.pressed.connect(func() -> void: ds.call("restore_window"))

	# Close preview window without changing the main window.
	var close_btn := _cfg_button("CLOSE PREVIEW WINDOWS")
	body.add_child(close_btn)
	close_btn.pressed.connect(func() -> void: ds.call("close_preview"))

	# --- Scene selector: one button per scene ---
	var scene_label := Label.new()
	scene_label.text = "scene"
	scene_label.add_theme_font_size_override("font_size", 10)
	scene_label.add_theme_color_override("font_color", COL_MUTED)
	body.add_child(scene_label)
	# Labels directly from the registry (BackgroundStage.SCENE_LABELS) -> stays
	# automatically in sync when scenes are added there. Rows of 4.
	var scene_labels_arr: Array = preload("res://background_stage.gd").SCENE_LABELS
	var per_row := 4
	var cur_row: HBoxContainer = null
	for si in range(scene_labels_arr.size()):
		if si % per_row == 0:
			cur_row = HBoxContainer.new()
			cur_row.add_theme_constant_override("separation", 4)
			body.add_child(cur_row)
		var sb := _cfg_button(str(scene_labels_arr[si]))
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var target_idx := si
		sb.pressed.connect(func() -> void:
			var stage := get_node_or_null("/root/BackgroundStage")
			if stage != null:
				stage.call("transition_to", target_idx))
		cur_row.add_child(sb)

	# --- Master blackout ---
	var black_row := HBoxContainer.new()
	black_row.add_theme_constant_override("separation", 6)
	var blbl := _cfg_label("blackout")
	black_row.add_child(blbl)
	var bslider := HSlider.new()
	bslider.min_value = 0.0
	bslider.max_value = 1.0
	bslider.step = 0.01
	bslider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bslider.custom_minimum_size = Vector2(0, 20)
	var bstage := get_node_or_null("/root/BackgroundStage")
	if bstage != null:
		bslider.value = bstage.call("get_blackout")
	bslider.value_changed.connect(func(v: float) -> void:
		var st := get_node_or_null("/root/BackgroundStage")
		if st != null:
			st.call("set_blackout", v))
	black_row.add_child(bslider)
	var black_btn := _cfg_button("BLACK")
	black_btn.pressed.connect(func() -> void:
		bslider.value = 1.0
		var st := get_node_or_null("/root/BackgroundStage")
		if st != null:
			st.call("set_blackout", 1.0))
	black_row.add_child(black_btn)
	body.add_child(black_row)

	# --- HDR / Rec.709 toggle ---
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 6)
	hdr_row.add_child(_cfg_label("tonemap"))
	var hdr_stage := get_node_or_null("/root/BackgroundStage")
	var hdr_on: bool = hdr_stage.call("get_hdr_mode") if hdr_stage != null else false
	var hdr_btn := Button.new()
	hdr_btn.text = "HDR" if hdr_on else "SDR"
	hdr_btn.toggle_mode = true
	hdr_btn.button_pressed = hdr_on
	hdr_btn.flat = true
	hdr_btn.add_theme_font_size_override("font_size", 11)
	hdr_btn.add_theme_color_override("font_color", Color.WHITE)
	hdr_btn.add_theme_stylebox_override("normal", _button_style(0.0))
	hdr_btn.add_theme_stylebox_override("hover", _button_style(0.12))
	hdr_btn.add_theme_stylebox_override("pressed", _button_style(0.3))
	hdr_btn.add_theme_stylebox_override("focus", _button_style(0.0))
	hdr_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_btn.custom_minimum_size = Vector2(0, 26)
	hdr_row.add_child(hdr_btn)
	body.add_child(hdr_row)
	hdr_btn.toggled.connect(func(pressed: bool) -> void:
		var st := get_node_or_null("/root/BackgroundStage")
		if st != null:
			st.call("set_hdr_mode", pressed)
		hdr_btn.text = "HDR" if pressed else "SDR")


## Global STYLE section: the 8 palette colors as stacked swatch rows
## (name left, wide color bar right), split into two labeled groups.
## Gradient stop order from top (zenith) to bottom (ground) — mirrors
## the actual sky gradient. Controls the Style autoload which mirrors values into
## global shader uniforms. Persists across all scenes.
func _build_style_config(parent: Node) -> void:
	var st := get_node_or_null("/root/Style")
	if st == null:
		return

	var body := _add_section(parent, "BACKGROUND STYLE")

	for pair in [
		["sky_zenith", "zenith"], ["sky_mid", "sky"], ["sky_horizon", "horizon"],
		["sky_ground_mid", "grnd-mid"], ["sky_ground", "ground"],
		["fog_color", "fog"], ["elem_a", "elem A"], ["elem_b", "elem B"],
	]:
		_add_style_swatch(body, st, str(pair[0]), str(pair[1]))

	# Style preset UI (own presets, independent of scene presets).
	var core := get_node_or_null("/root/BgCore")
	if core == null:
		return

	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 11)
	opt.custom_minimum_size = Vector2(0, 24)
	body.add_child(opt)

	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "style name"
	name_edit.add_theme_font_size_override("font_size", 11)
	name_edit.custom_minimum_size = Vector2(0, 24)
	body.add_child(name_edit)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 4)
	var save_btn := _cfg_button("SAVE")
	var load_btn := _cfg_button("LOAD")
	var del_btn  := _cfg_button("DEL")
	brow.add_child(save_btn)
	brow.add_child(load_btn)
	brow.add_child(del_btn)
	body.add_child(brow)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 10)
	status.add_theme_color_override("font_color", COL_MUTED)
	status.clip_text = true
	body.add_child(status)

	var refresh := func() -> void:
		opt.clear()
		for n in core.call("list_style_presets"):
			opt.add_item(str(n))
		var want := name_edit.text.strip_edges()
		for i in range(opt.item_count):
			if opt.get_item_text(i) == want:
				opt.select(i)
				break
	refresh.call()

	opt.item_selected.connect(func(idx: int) -> void:
		name_edit.text = opt.get_item_text(idx))

	save_btn.pressed.connect(func() -> void:
		var nm := name_edit.text.strip_edges()
		if nm == "":
			status.text = "name?"
			return
		if core.call("save_style", nm):
			status.text = "saved '%s'" % nm
		else:
			status.text = "save failed")

	load_btn.pressed.connect(func() -> void:
		var nm := name_edit.text.strip_edges()
		if nm == "" and opt.selected >= 0:
			nm = opt.get_item_text(opt.selected)
			name_edit.text = nm
		if nm == "":
			status.text = "pick a style"
			return
		var snap: Dictionary = core.call("load_style", nm)
		if snap.is_empty():
			status.text = "not found"
		else:
			status.text = "loaded '%s'" % nm
			_sync_style_swatches())

	del_btn.pressed.connect(func() -> void:
		var nm := name_edit.text.strip_edges()
		if nm == "":
			status.text = "name?"
			return
		core.call("delete_style_preset", nm)
		status.text = "deleted '%s'" % nm)

	if not core.is_connected("style_presets_changed", refresh):
		core.connect("style_presets_changed", refresh)


# One palette row: name (fixed column) + full-width ColorPickerButton.
func _add_style_swatch(parent: Node, st: Node, key: String, label: String) -> void:
	var row := _make_row(parent, label)
	var btn := ColorPickerButton.new()
	btn.color = st.call("get_color", key)
	btn.edit_alpha = false
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 18)
	btn.color_changed.connect(func(c: Color) -> void:
		st.call("set_color", key, c))
	row.add_child(btn)
	# Track for re-sync after preset LOAD (pull field to loaded value).
	_style_swatches.append({"btn": btn, "key": key, "st": st})


## Global PRESET section (S3): named presets via BgCore save/load/delete.
## Dropdown lists user://presets/*; the name field determines the target of SAVE/LOAD/DEL.
## Lives in the persistent outer container, built once (no scene rebuild).
func _build_preset_config(parent: Node) -> void:
	var core := get_node_or_null("/root/BgCore")
	if core == null:
		return

	var body := _add_section(parent, "PRESET")

	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 11)
	opt.custom_minimum_size = Vector2(0, 24)
	body.add_child(opt)

	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "preset name"
	name_edit.add_theme_font_size_override("font_size", 11)
	name_edit.custom_minimum_size = Vector2(0, 24)
	body.add_child(name_edit)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 4)
	var save_btn := _cfg_button("SAVE")
	var load_btn := _cfg_button("LOAD")
	var del_btn := _cfg_button("DEL")
	brow.add_child(save_btn)
	brow.add_child(load_btn)
	brow.add_child(del_btn)
	body.add_child(brow)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 10)
	status.add_theme_color_override("font_color", COL_MUTED)
	status.clip_text = true
	body.add_child(status)

	# Populate dropdown from existing presets; align selection to the name field
	# if there is a match there.
	var refresh := func() -> void:
		opt.clear()
		for n in core.call("list_presets"):
			opt.add_item(str(n))
		var want := name_edit.text.strip_edges()
		for i in range(opt.item_count):
			if opt.get_item_text(i) == want:
				opt.select(i)
				break
	refresh.call()

	opt.item_selected.connect(func(idx: int) -> void:
		name_edit.text = opt.get_item_text(idx))

	save_btn.pressed.connect(func() -> void:
		var nm := name_edit.text.strip_edges()
		if nm == "":
			status.text = "name?"
			return
		if core.call("save_current", nm):
			status.text = "saved '%s'" % nm   # presets_changed -> refresh
		else:
			status.text = "save failed")

	load_btn.pressed.connect(func() -> void:
		var nm := name_edit.text.strip_edges()
		if nm == "" and opt.selected >= 0:
			nm = opt.get_item_text(opt.selected)
			name_edit.text = nm
		if nm == "":
			status.text = "pick a preset"
			return
		var snap: Dictionary = core.call("load_preset", nm)
		if snap.is_empty():
			status.text = "not found"
		else:
			status.text = "loaded '%s' (%d)" % [nm, snap.size()]
			_after_preset_loaded())

	del_btn.pressed.connect(func() -> void:
		var nm := name_edit.text.strip_edges()
		if nm == "":
			status.text = "name?"
			return
		core.call("delete_preset", nm)
		status.text = "deleted '%s'" % nm)   # presets_changed -> refresh

	# Refresh list on any change (SAVE/DEL, also external).
	if not core.is_connected("presets_changed", refresh):
		core.connect("presets_changed", refresh)


## After a preset LOAD, sync the visible controls/swatches to the now-changed
## values (apply() only changes parameters, not UI positions).
func _after_preset_loaded() -> void:
	_sync_style_swatches()
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage != null:
		var r: Variant = stage.call("active_root")
		if r is Node and r.is_inside_tree():
			_populate(r)   # rebuilds scene/mat/post/overlay controls from current values


## Pull STYLE swatches (in the persistent outer container) from Style. Block signals
## so programmatic setting does not fire set_color back.
func _sync_style_swatches() -> void:
	for sw in _style_swatches:
		var b: ColorPickerButton = sw.btn
		b.set_block_signals(true)
		b.color = sw.st.call("get_color", sw.key)
		b.set_block_signals(false)


## Global SEQUENCE section (S4): build + play preset playlist via Sequencer.
## Top: preset picker + ADD, below: height-limited scrollable step list,
## below that: PLAY/STOP/NEXT. Lives in the persistent outer container. Starts collapsed
## so the section does not overflow the pinned panel.
func _build_sequencer_config(parent: Node) -> void:
	var seq := get_node_or_null("/root/Sequencer")
	var core := get_node_or_null("/root/BgCore")
	if seq == null or core == null:
		return
	if not _collapsed.has("SEQUENCE"):
		_collapsed["SEQUENCE"] = true

	var body := _add_section(parent, "SEQUENCE")

	# Preset picker + ADD.
	var addrow := HBoxContainer.new()
	addrow.add_theme_constant_override("separation", 4)
	_seq_opt = OptionButton.new()
	_seq_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seq_opt.add_theme_font_size_override("font_size", 11)
	_seq_opt.custom_minimum_size = Vector2(0, 24)
	addrow.add_child(_seq_opt)
	var add_btn := _cfg_button("ADD")
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	add_btn.custom_minimum_size = Vector2(54, 26)
	addrow.add_child(add_btn)
	body.add_child(addrow)

	# Step list — fixed height, scrolls internally (otherwise a long playlist
	# overflows the pinned panel).
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(0, 150)
	body.add_child(sc)
	_seq_list = VBoxContainer.new()
	_seq_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seq_list.add_theme_constant_override("separation", 4)
	sc.add_child(_seq_list)

	# Transport: ‹ PREV / PLAY / STOP / NEXT ›
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 4)
	var prev_btn := _cfg_button("‹")
	var play_btn := _cfg_button("PLAY")
	var stop_btn := _cfg_button("STOP")
	var next_btn := _cfg_button("›")
	trow.add_child(prev_btn)
	trow.add_child(play_btn)
	trow.add_child(stop_btn)
	trow.add_child(next_btn)
	body.add_child(trow)

	_seq_status = Label.new()
	_seq_status.add_theme_font_size_override("font_size", 10)
	_seq_status.add_theme_color_override("font_color", COL_MUTED)
	_seq_status.clip_text = true
	body.add_child(_seq_status)

	# JSON Export / Import.
	var json_toggle := _cfg_button("JSON ▸")
	body.add_child(json_toggle)
	var json_edit := TextEdit.new()
	json_edit.visible = false
	json_edit.custom_minimum_size = Vector2(0, 110)
	json_edit.add_theme_font_size_override("font_size", 10)
	body.add_child(json_edit)
	var json_row2 := HBoxContainer.new()
	json_row2.add_theme_constant_override("separation", 4)
	json_row2.visible = false
	var export_btn := _cfg_button("EXPORT")
	var import_btn := _cfg_button("IMPORT")
	json_row2.add_child(export_btn)
	json_row2.add_child(import_btn)
	body.add_child(json_row2)
	var json_open := false
	json_toggle.pressed.connect(func() -> void:
		json_open = !json_open
		json_edit.visible = json_open
		json_row2.visible = json_open
		json_toggle.text = "JSON ▾" if json_open else "JSON ▸")

	var refresh_opt := func() -> void:
		_seq_opt.clear()
		for n in core.call("list_presets"):
			_seq_opt.add_item(str(n))
	refresh_opt.call()

	add_btn.pressed.connect(func() -> void:
		if _seq_opt.selected < 0:
			if _seq_status != null:
				_seq_status.text = "save a preset first"
			return
		var nm := _seq_opt.get_item_text(_seq_opt.selected)
		seq.call("add_step", nm, 3.0, _stage_transition_time()))

	prev_btn.pressed.connect(func() -> void: seq.call("prev"))
	play_btn.pressed.connect(func() -> void: seq.call("play"))
	stop_btn.pressed.connect(func() -> void: seq.call("stop"))
	next_btn.pressed.connect(func() -> void: seq.call("next"))

	export_btn.pressed.connect(func() -> void:
		var arr: Array = []
		for i in range(seq.call("step_count")):
			arr.append(seq.call("get_step", i))
		json_edit.text = JSON.stringify({"steps": arr}, "\t"))

	import_btn.pressed.connect(func() -> void:
		var txt := json_edit.text.strip_edges()
		if txt.is_empty():
			return
		var parsed: Variant = JSON.parse_string(txt)
		if not (parsed is Dictionary):
			return
		var steps_arr: Variant = parsed.get("steps", null)
		if not (steps_arr is Array):
			return
		seq.call("clear")
		for s in steps_arr:
			if s is Dictionary:
				seq.call("add_step",
					str(s.get("preset", "")),
					float(s.get("hold", 3.0)),
					float(s.get("trans", 1.2)),
					str(s.get("mode", "zoom"))))

	# Refresh dropdown on preset change, list on playback/list change.
	if not core.is_connected("presets_changed", refresh_opt):
		core.connect("presets_changed", refresh_opt)
	if not seq.is_connected("state_changed", _refresh_seq_list):
		seq.connect("state_changed", _refresh_seq_list)

	_refresh_seq_list()


## Rebuild step list from the sequencer (bound to state_changed).
func _refresh_seq_list() -> void:
	if _seq_list == null:
		return
	var seq := get_node_or_null("/root/Sequencer")
	if seq == null:
		return
	while _seq_list.get_child_count() > 0:
		var c := _seq_list.get_child(0)
		_seq_list.remove_child(c)
		c.queue_free()
	var count: int = seq.call("step_count")
	var cur: int = seq.call("current_index")
	var playing: bool = seq.call("is_playing")
	for i in range(count):
		_build_seq_step(_seq_list, seq, i, cur, playing)
	if _seq_status != null:
		if playing and count > 0:
			_seq_status.text = "playing  %d/%d" % [cur + 1, count]
		else:
			_seq_status.text = "%d steps" % count


## One step row: top marker+name+up/down/del, below hold/trans spinboxes.
func _build_seq_step(parent: Node, seq: Node, i: int, cur: int, playing: bool) -> void:
	var step: Dictionary = seq.call("get_step", i)
	var active := playing and i == cur

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	parent.add_child(box)

	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 4)
	var marker := Label.new()
	marker.text = "▶" if active else ("%d" % (i + 1))
	marker.add_theme_font_size_override("font_size", 11)
	marker.add_theme_color_override("font_color", Color.WHITE if active else COL_MUTED)
	marker.custom_minimum_size = Vector2(16, 0)
	r1.add_child(marker)
	var nm := Label.new()
	nm.text = str(step.get("preset", ""))
	nm.add_theme_font_size_override("font_size", 11)
	nm.clip_text = true
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.tooltip_text = nm.text
	r1.add_child(nm)
	var up := _mini_button("↑")
	var dn := _mini_button("↓")
	var dl := _mini_button("✕")
	r1.add_child(up)
	r1.add_child(dn)
	r1.add_child(dl)
	box.add_child(r1)

	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 4)
	r2.add_child(_cfg_label("hold"))
	var hold_spin := _cfg_spin(0.0, 600.0, 0.1, float(step.get("hold", 3.0)))
	r2.add_child(hold_spin)
	r2.add_child(_cfg_label("trans"))
	var trans_spin := _cfg_spin(0.0, 30.0, 0.05, float(step.get("trans", 1.2)))
	r2.add_child(trans_spin)
	box.add_child(r2)

	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 4)
	r3.add_child(_cfg_label("mode"))
	var mode_opt := OptionButton.new()
	mode_opt.add_item("Zoom")
	mode_opt.add_item("Cross")
	mode_opt.selected = 1 if str(step.get("mode", "zoom")) == "cross" else 0
	mode_opt.add_theme_font_size_override("font_size", 11)
	mode_opt.focus_mode = Control.FOCUS_NONE
	mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r3.add_child(mode_opt)
	box.add_child(r3)

	hold_spin.value_changed.connect(func(v: float) -> void:
		seq.call("set_step_value", i, "hold", v))
	trans_spin.value_changed.connect(func(v: float) -> void:
		seq.call("set_step_value", i, "trans", v))
	mode_opt.item_selected.connect(func(idx: int) -> void:
		seq.call("set_step_value", i, "mode", "cross" if idx == 1 else "zoom"))
	up.pressed.connect(func() -> void: seq.call("move_step", i, -1))
	dn.pressed.connect(func() -> void: seq.call("move_step", i, 1))
	dl.pressed.connect(func() -> void: seq.call("remove_step", i))


func _mini_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 11)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _button_style(0.0))
	b.add_theme_stylebox_override("hover", _button_style(0.12))
	b.add_theme_stylebox_override("pressed", _button_style(0.22))
	b.add_theme_stylebox_override("focus", _button_style(0.0))
	b.custom_minimum_size = Vector2(22, 22)
	return b


func _cfg_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", COL_MUTED)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _cfg_spin(mn: float, mx: float, st: float, val: Variant) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = mn
	s.max_value = mx
	s.step = st
	s.value = float(val) if (val is float or val is int) else mn
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(56, 0)
	return s


func _apply_aa(_vp: Viewport) -> void:
	var m: Array = AA_MODES[_aa_index]
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage != null:
		stage.call("set_antialiasing", m[1], m[2], m[3])


func _cfg_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.add_theme_font_size_override("font_size", 11)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _button_style(0.0))
	b.add_theme_stylebox_override("hover", _button_style(0.12))
	b.add_theme_stylebox_override("pressed", _button_style(0.22))
	b.add_theme_stylebox_override("focus", _button_style(0.0))
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 26)
	return b


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
