extends VBoxContainer
## Embeddable slideshow controls widget. Lives inside the F2 editor's SELECTED SLOT
## section and is retargeted to the selected slot's module via bind(). Mirrors the
## reference ui_panel controls (mode, fit, slide count, transition, auto-run, loop, nav,
## image loading). Edits apply live and persist per slot.

const ACCENT := Color(1.0, 0.804, 0.0)
const TEXT := Color(0.90, 0.93, 0.96)
const MUTED := Color(0.58, 0.64, 0.72)

const MODE_IDS := ["slidedeck", "gallery", "grid", "coverflow", "carousel"]
const TR_IDS := ["swipeH", "swipeV", "push", "fade", "zoomblur", "fx"]

var slot_id := -1
var mod = null
var _refreshing := false

var _file_dialog: FileDialog
var _dir_dialog: FileDialog
var _mode_opt: OptionButton
var _fit_opt: OptionButton
var _count_slider: HSlider
var _count_val: Label
var _tr_opt: OptionButton
var _dur_slider: HSlider
var _dur_val: Label
var _auto_chk: CheckButton
var _int_slider: HSlider
var _int_val: Label
var _loop_chk: CheckButton
var _nav_chk: CheckButton
var _pag_chk: CheckButton
var _slides_label: Label


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_build_dialogs()
	_build_ui()


func _build_dialogs() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp,*.bmp,*.tga ; Images"])
	_file_dialog.files_selected.connect(func(paths):
		if mod: mod.load_image_paths(Array(paths)))
	add_child(_file_dialog)
	_dir_dialog = FileDialog.new()
	_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dir_dialog.dir_selected.connect(func(p):
		if mod: mod.load_directory(p))
	add_child(_dir_dialog)


func _build_ui() -> void:
	_header(self, "DISPLAY")
	_label(self, "Mode")
	_mode_opt = _dropdown(self, ["Slidedeck", "Gallery", "Grid", "Coverflow", "Carousel"])
	_mode_opt.item_selected.connect(func(i):
		if _refreshing or not mod: return
		mod.set_mode(MODE_IDS[i]); _persist())
	_label(self, "Fit to slot")
	_fit_opt = _dropdown(self, ["Crop (fills slot)", "Fit (whole image)"])
	_fit_opt.item_selected.connect(func(i):
		if _refreshing or not mod: return
		mod.state.fit = i; _persist())
	_label(self, "Active slides")
	var cs := _slider_row(self, 1, 8, 1)
	_count_slider = cs[0]; _count_val = cs[1]
	_count_slider.value_changed.connect(func(x):
		_count_val.text = str(int(x))
		if _refreshing or not mod: return
		mod.state.slide_count = int(x); _persist())

	_header(self, "TRANSITION")
	_label(self, "Type")
	_tr_opt = _dropdown(self, ["Swipe H", "Swipe V", "Push", "Crossfade", "Zoom Blur", "FX Zoom"])
	_tr_opt.item_selected.connect(func(i):
		if _refreshing or not mod: return
		mod.state.transition = TR_IDS[i]; _persist())
	_label(self, "Duration")
	var ds := _slider_row(self, 0.15, 2.0, 0.05, "s")
	_dur_slider = ds[0]; _dur_val = ds[1]
	_dur_slider.value_changed.connect(func(x):
		_dur_val.text = "%.2fs" % x
		if _refreshing or not mod: return
		mod.state.transition_time = x; _persist())
	_auto_chk = _check(self, "Auto-run", func(p):
		if _refreshing or not mod: return
		mod.state.auto_run = p; _persist())
	_label(self, "Interval")
	var ins := _slider_row(self, 1.0, 12.0, 0.5, "s")
	_int_slider = ins[0]; _int_val = ins[1]
	_int_slider.value_changed.connect(func(x):
		_int_val.text = "%.1fs" % x
		if _refreshing or not mod: return
		mod.state.auto_run_seconds = x; _persist())
	_loop_chk = _check(self, "Loop", func(p):
		if _refreshing or not mod: return
		mod.state.loop = p; _persist())

	_header(self, "NAVIGATION")
	_nav_chk = _check(self, "Arrows", func(p):
		if _refreshing or not mod: return
		mod.state.show_nav = p; _persist())
	_pag_chk = _check(self, "Pagination", func(p):
		if _refreshing or not mod: return
		mod.state.show_pagination = p; _persist())
	var navrow := HBoxContainer.new()
	navrow.add_theme_constant_override("separation", 6)
	var bp := Button.new(); bp.text = "‹ Prev"; bp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bp.pressed.connect(func(): if mod: mod.prev())
	var bn := Button.new(); bn.text = "Next ›"; bn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bn.pressed.connect(func(): if mod: mod.next())
	navrow.add_child(bp); navrow.add_child(bn)
	add_child(navrow)

	_header(self, "IMAGES")
	var bf := Button.new(); bf.text = "Add images…"
	bf.pressed.connect(func(): _file_dialog.popup_centered_ratio(0.7))
	add_child(bf)
	var bd := Button.new(); bd.text = "Add folder…"
	bd.pressed.connect(func(): _dir_dialog.popup_centered_ratio(0.7))
	add_child(bd)
	var bc := Button.new(); bc.text = "Clear list"
	bc.pressed.connect(func(): if mod: mod.clear_slides())
	add_child(bc)
	_slides_label = Label.new()
	_slides_label.add_theme_color_override("font_color", ACCENT)
	_slides_label.add_theme_font_size_override("font_size", 11)
	add_child(_slides_label)


# Point the widget at a slot's module and refresh all controls. module==null hides it.
func bind(id: int, module) -> void:
	slot_id = id
	if mod and mod.is_connected("slides_changed", _on_slides_changed):
		mod.disconnect("slides_changed", _on_slides_changed)
	mod = module
	visible = module != null
	if mod and not mod.is_connected("slides_changed", _on_slides_changed):
		mod.slides_changed.connect(_on_slides_changed)
	if mod:
		_refresh_from_module()


func _refresh_from_module() -> void:
	if mod == null:
		return
	_refreshing = true
	var st = mod.state
	_mode_opt.select(maxi(0, MODE_IDS.find(st.mode)))
	_fit_opt.select(int(st.fit))
	var cnt: int = mod.loader.count()
	_count_slider.max_value = maxi(1, cnt)
	_count_slider.value = clampi(int(st.slide_count), 1, maxi(1, cnt))
	_count_val.text = str(int(_count_slider.value))
	_tr_opt.select(maxi(0, TR_IDS.find(st.transition)))
	_dur_slider.value = st.transition_time
	_dur_val.text = "%.2fs" % st.transition_time
	_auto_chk.button_pressed = st.auto_run
	_int_slider.value = st.auto_run_seconds
	_int_val.text = "%.1fs" % st.auto_run_seconds
	_loop_chk.button_pressed = st.loop
	_nav_chk.button_pressed = st.show_nav
	_pag_chk.button_pressed = st.show_pagination
	_slides_label.text = "%d images" % cnt
	_refreshing = false


func _on_slides_changed(n: int) -> void:
	if _slides_label:
		_slides_label.text = "%d images" % n
	if _count_slider:
		_count_slider.max_value = maxi(1, n)


func _persist() -> void:
	if mod:
		SlotManager.persist_slot_state(slot_id, mod.state)


# ---- tiny builders ----

func _header(parent: Node, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.5, 0.57, 0.68))
	parent.add_child(l)


func _label(parent: Node, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", MUTED)
	parent.add_child(l)


func _dropdown(parent: Node, items: Array) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(o)
	return o


func _slider_row(parent: Node, mn: float, mx: float, step: float, suffix := "") -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var s := HSlider.new()
	s.min_value = mn; s.max_value = mx; s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var v := Label.new()
	v.custom_minimum_size = Vector2(44, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_theme_color_override("font_color", ACCENT)
	v.add_theme_font_size_override("font_size", 12)
	row.add_child(s); row.add_child(v)
	parent.add_child(row)
	return [s, v]


func _check(parent: Node, text: String, cb: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.add_theme_color_override("font_color", TEXT)
	c.toggled.connect(cb)
	parent.add_child(c)
	return c
