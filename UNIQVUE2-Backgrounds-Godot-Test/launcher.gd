extends CanvasLayer
## Launcher — Autoload (layer 200, above ALL runtime UI). The boot gate for the
## Runtime. Native Godot port of launcher_v10_3.html.
##
## Flow:   PIN gate (2468) -> session pick -> "Playout starten" -> reveal Runtime.
##   - PIN, session picker and Playout-start are REAL.
##   - Sessions are the saved NAMED AGENDAS (Agenda.list_agendas). Starting playout
##     loads the chosen agenda and jumps to its first cue.
##   - Update / License / Remote-QR are VISUAL MOCK (demo via the bottom dev bar).
##
## The launcher is a full-screen opaque overlay. BackgroundStage keeps running behind
## it (hidden). "Playout starten" hides the overlay -> the Runtime is live.
## F12 re-opens the launcher (re-locks). "Sperren" / Esc re-locks to the PIN gate.

const CORRECT_PIN := "2468"

# ---- design tokens (from launcher_v10_3.html :root) ----
const YELLOW     := Color(1.0, 0.804, 0.0)
const YELLOW_DIM := Color(1.0, 0.804, 0.0, 0.12)
const BLACK      := Color(0.055, 0.055, 0.055)
const BG1        := Color(0.090, 0.090, 0.090)
const BG2        := Color(0.122, 0.122, 0.122)
const BG3        := Color(0.149, 0.149, 0.149)
const BG4        := Color(0.180, 0.180, 0.180)
const TEXT       := Color(0.957, 0.957, 0.957)
const TEXT2      := Color(0.604, 0.604, 0.604)
const TEXT3      := Color(0.353, 0.353, 0.353)
const GREEN      := Color(0.353, 0.749, 0.431)
const ORANGE     := Color(1.0, 0.580, 0.090)
const BLUE       := Color(0.290, 0.565, 0.886)
const RED        := Color(1.0, 0.302, 0.302)
const BORDER     := Color(1, 1, 1, 0.09)
const BORDER_HI  := Color(1, 1, 1, 0.20)

const MODES := {
	"remote":  {"title": "Fernsteuerung koppeln",
		"desc": "Mit dem Telefon scannen, um das Playout während der Show fernzusteuern.",
		"url": "https://192.168.1.42:8443/remote"},
	"manager": {"title": "Manager öffnen",
		"desc": "Tablet scannen für erweiterte Konfiguration und Verwaltung.",
		"url": "https://192.168.1.42:8443/manager"},
}

# ---- state ----
var _shown := true
var _pin := ""
var _is_touch := true
var _connected := false
var _mode := "remote"
var _unlocked := false
var _lic_active := true
var _update_warn := false
var _sessions: Array = []      # agenda names
var _sel_session := ""

# ---- node refs ----
var _agenda: Node
var _display: Node
var _root: Control
var _pin_cells: Array = []
var _pin_msg: Label
var _stage_state: Label
var _stage_dot: Panel

var _pin_stage: Control
var _connect_stage: Control
var _conn_title: Label
var _conn_desc: Label
var _qr_url: Label
var _dev_txt: Label
var _seg_remote: Button
var _seg_manager: Button
var _start_btn: Button

var _sess_state: Label
var _sess_state_box: PanelContainer
var _remote_tag: PanelContainer
var _sess_name: Label
var _sess_view: Control
var _sess_picker: Control
var _plist: VBoxContainer
var _mid_label: Label

var _sys_big: Label
var _sys_txt: Label
var _sys_sub: Label
var _st_upd_ic: Label
var _st_upd_d: Label
var _st_lic_ic: Label
var _st_lic_d: Label
var _act_update: PanelContainer
var _act_lic: PanelContainer
var _dev_btn_touch: Button
var _dev_btn_lic: Button


func _ready() -> void:
	layer = 200
	_agenda = get_node_or_null("/root/Agenda")
	_display = get_node_or_null("/root/DisplaySetup")
	_load_sessions()
	_build()
	_apply_touch_mode()
	_render_pin()
	get_window().size_changed.connect(_relayout)


func _load_sessions() -> void:
	_sessions = []
	if _agenda != null and _agenda.has_method("list_agendas"):
		_sessions = _agenda.call("list_agendas")
	if not _sessions.is_empty():
		_sel_session = str(_sessions[0])


# =============================================================== UI construction

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP   # block clicks reaching runtime
	add_child(_root)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = BLACK
	_root.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var shell := VBoxContainer.new()
	shell.custom_minimum_size = Vector2(1180, 0)
	shell.add_theme_constant_override("separation", 26)
	center.add_child(shell)

	shell.add_child(_build_topline())

	var grid := HBoxContainer.new()
	grid.add_theme_constant_override("separation", 18)
	shell.add_child(grid)
	grid.add_child(_build_left())
	grid.add_child(_build_mid())
	grid.add_child(_build_right())

	shell.add_child(_build_devbar())


func _build_topline() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 13)

	var brand := _lbl("UNIQVUE", 22, TEXT, 600)
	row.add_child(brand)
	row.add_child(_vrule(20))
	row.add_child(_lbl("ONE", 19, TEXT, 300))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var sgroup := VBoxContainer.new()
	sgroup.alignment = BoxContainer.ALIGNMENT_CENTER
	sgroup.add_child(_lbl("STAGE", 9, TEXT3, 400))
	sgroup.add_child(_lbl("Lab München", 15, TEXT, 500))
	row.add_child(sgroup)

	_stage_state_box(row)
	return row


func _stage_state_box(row: HBoxContainer) -> void:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _sbox(BG2, BORDER, 8))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	box.add_child(hb)
	_stage_dot = Panel.new()
	_stage_dot.custom_minimum_size = Vector2(8, 8)
	_stage_dot.add_theme_stylebox_override("panel", _dot_style(TEXT2))
	var dotwrap := CenterContainer.new()
	dotwrap.add_child(_stage_dot)
	hb.add_child(dotwrap)
	_stage_state = _lbl("Idle", 12, TEXT2, 600)
	hb.add_child(_stage_state)
	var pad := MarginContainer.new()
	for s in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + s, 14)
	for s in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + s, 7)
	pad.add_child(box)
	row.add_child(pad)


# ----------------------------------------------------------------- LEFT card

func _build_left() -> Control:
	var panel := _card(280)
	var card := panel.get_child(0)        # inner VBox; panel goes to grid
	card.add_child(_axis_label("System"))

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 11)
	_sys_big = _badge("✓", GREEN)
	head.add_child(_sys_big)
	var ht := VBoxContainer.new()
	_sys_txt = _lbl("Betriebsbereit", 15, TEXT, 500)
	_sys_sub = _lbl("Alle Dienste aktiv", 11, TEXT2, 400)
	ht.add_child(_sys_txt)
	ht.add_child(_sys_sub)
	head.add_child(ht)
	card.add_child(head)
	card.add_child(_hsep())

	var lic := _stat_row("Lizenz", "Aktiv", GREEN)
	_st_lic_ic = lic[1]
	_st_lic_d = lic[2]
	card.add_child(lic[0])
	card.add_child(_stat_row("Runtime", "Bereit", GREEN)[0])
	card.add_child(_stat_row("Netzwerk", "Verbunden", GREEN)[0])
	card.add_child(_stat_row("Speicher", "412 GB frei", GREEN)[0])
	var upd := _stat_row("Update-Dienst", "Aktuell", GREEN)
	_st_upd_ic = upd[1]
	_st_upd_d = upd[2]
	card.add_child(upd[0])

	# mock action cards (hidden until toggled from dev bar)
	_act_update = _action_card("Update 1.3.0 verfügbar", "Greift nicht in den laufenden Betrieb ein", "Update", BLUE)
	_act_lic = _action_card("Neue Module freigeschaltet", "Serverseitig aktiviert", "Anwenden", YELLOW)
	_act_update.visible = false
	_act_lic.visible = false
	card.add_child(_act_update)
	card.add_child(_act_lic)

	var grow := Control.new()
	grow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_child(grow)

	card.add_child(_hsep())
	var vf := HBoxContainer.new()
	vf.add_child(_lbl("VERSION", 10, TEXT3, 600))
	var vsp := Control.new()
	vsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vf.add_child(vsp)
	vf.add_child(_lbl("1.2.4", 13, TEXT, 500))
	card.add_child(vf)
	return panel


# ----------------------------------------------------------------- MIDDLE card

func _build_mid() -> Control:
	var panel := _card(0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card := panel.get_child(0)        # inner VBox
	_mid_label = _axis_label("Freigabe")
	card.add_child(_mid_label)

	# --- PIN stage ---
	_pin_stage = VBoxContainer.new()
	_pin_stage.alignment = BoxContainer.ALIGNMENT_CENTER
	_pin_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pin_stage.add_theme_constant_override("separation", 22)
	var hint := _lbl("PIN eingeben, um Playout und Bedienung freizugeben", 13, TEXT2, 400)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pin_stage.add_child(hint)

	var cells := HBoxContainer.new()
	cells.alignment = BoxContainer.ALIGNMENT_CENTER
	cells.add_theme_constant_override("separation", 12)
	_pin_cells = []
	for i in 4:
		var c := PanelContainer.new()
		c.custom_minimum_size = Vector2(60, 68)
		c.add_theme_stylebox_override("panel", _sbox(BG2, BORDER, 10))
		var cl := _lbl("", 26, TEXT, 500)
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		c.add_child(cl)
		_pin_cells.append(c)
		cells.add_child(c)
	_pin_stage.add_child(cells)

	var pad := GridContainer.new()
	pad.columns = 3
	pad.add_theme_constant_override("h_separation", 12)
	pad.add_theme_constant_override("v_separation", 12)
	pad.custom_minimum_size = Vector2(300, 0)
	for n in ["1", "2", "3", "4", "5", "6", "7", "8", "9"]:
		pad.add_child(_pad_btn(n, n))
	pad.add_child(_pad_btn("Leeren", "clear"))
	pad.add_child(_pad_btn("0", "0"))
	pad.add_child(_pad_btn("←", "del"))
	var padwrap := CenterContainer.new()
	padwrap.add_child(pad)
	_pin_stage.add_child(padwrap)

	_pin_msg = _lbl("", 12, RED, 400)
	_pin_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pin_msg.custom_minimum_size = Vector2(0, 17)
	_pin_stage.add_child(_pin_msg)
	card.add_child(_pin_stage)

	# --- connect stage (post-unlock) ---
	_connect_stage = VBoxContainer.new()
	_connect_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_connect_stage.add_theme_constant_override("separation", 18)
	_connect_stage.visible = false

	var seg := HBoxContainer.new()
	seg.add_theme_constant_override("separation", 4)
	_seg_remote = _seg_btn("Remote · Steuerung", "remote")
	_seg_manager = _seg_btn("Manager · Konfig", "manager")
	seg.add_child(_seg_remote)
	seg.add_child(_seg_manager)
	_connect_stage.add_child(seg)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 24)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_qr_box())
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 10)
	_conn_title = _lbl("Fernsteuerung koppeln", 16, TEXT, 500)
	_conn_desc = _lbl(MODES["remote"]["desc"], 12, TEXT2, 400)
	_conn_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_conn_title)
	side.add_child(_conn_desc)
	var urlbox := PanelContainer.new()
	urlbox.add_theme_stylebox_override("panel", _sbox(BG2, BORDER, 8))
	_qr_url = _lbl(str(MODES["remote"]["url"]), 12, YELLOW, 400)
	urlbox.add_child(_qr_url)
	side.add_child(urlbox)
	_dev_txt = _lbl("Kein Gerät verbunden", 13, TEXT2, 400)
	side.add_child(_dev_txt)
	body.add_child(side)
	_connect_stage.add_child(body)

	_start_btn = _primary_btn("Playout starten")
	_start_btn.pressed.connect(_on_start)
	_connect_stage.add_child(_start_btn)
	var lock_btn := _secondary_btn("Sperren")
	lock_btn.pressed.connect(_reset_gate)
	_connect_stage.add_child(lock_btn)
	card.add_child(_connect_stage)
	return panel


# ----------------------------------------------------------------- RIGHT card

func _build_right() -> Control:
	var panel := _card(300)
	var card := panel.get_child(0)        # inner VBox
	card.add_child(_axis_label("Session"))

	var tags := HBoxContainer.new()
	tags.add_theme_constant_override("separation", 8)
	_sess_state_box = PanelContainer.new()
	_sess_state_box.add_theme_stylebox_override("panel", _sbox(BG3, BORDER, 5))
	_sess_state = _lbl("Gesperrt", 11, TEXT2, 600)
	var sm := MarginContainer.new()
	for s in ["left", "right"]:
		sm.add_theme_constant_override("margin_" + s, 11)
	for s in ["top", "bottom"]:
		sm.add_theme_constant_override("margin_" + s, 5)
	sm.add_child(_sess_state)
	_sess_state_box.add_child(sm)
	tags.add_child(_sess_state_box)
	_remote_tag = PanelContainer.new()
	_remote_tag.add_theme_stylebox_override("panel", _sbox(BG3, BORDER, 5))
	var rl := MarginContainer.new()
	for s in ["left", "right"]:
		rl.add_theme_constant_override("margin_" + s, 11)
	for s in ["top", "bottom"]:
		rl.add_theme_constant_override("margin_" + s, 5)
	rl.add_child(_lbl("Remote", 11, TEXT2, 600))
	_remote_tag.add_child(rl)
	_remote_tag.visible = false
	tags.add_child(_remote_tag)
	card.add_child(tags)

	# session view
	_sess_view = VBoxContainer.new()
	_sess_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sess_view.add_theme_constant_override("separation", 12)
	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(0, 150)
	thumb.add_theme_stylebox_override("panel", _sbox(Color(0.07, 0.07, 0.07), BORDER, 10))
	_sess_view.add_child(thumb)
	_sess_name = _lbl(_sel_session if _sel_session != "" else "Standard-Runtime", 20, TEXT, 600)
	_sess_view.add_child(_sess_name)
	_sess_view.add_child(_sfact("Status", "RELEASED", GREEN))
	_sess_view.add_child(_sfact("Sessions", str(_sessions.size()), TEXT))
	_sess_view.add_child(_sfact("Quelle", "Agenda", TEXT))
	var grow := Control.new()
	grow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sess_view.add_child(grow)
	var change := _secondary_btn("Session wechseln")
	change.pressed.connect(_open_picker)
	change.visible = false
	change.name = "ChangeBtn"
	_sess_view.add_child(change)
	card.add_child(_sess_view)

	# session picker
	_sess_picker = VBoxContainer.new()
	_sess_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sess_picker.add_theme_constant_override("separation", 12)
	_sess_picker.visible = false
	_sess_picker.add_child(_lbl("Wähle die Session, die beim Start geladen wird.", 12, TEXT2, 400))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_plist = VBoxContainer.new()
	_plist.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plist.add_theme_constant_override("separation", 7)
	scroll.add_child(_plist)
	_sess_picker.add_child(scroll)
	_rebuild_picker()
	var pa := HBoxContainer.new()
	pa.add_theme_constant_override("separation", 8)
	var cancel := _secondary_btn("Abbrechen")
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(_close_picker)
	var ok := _primary_btn("Übernehmen")
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok.pressed.connect(_confirm_session)
	pa.add_child(cancel)
	pa.add_child(ok)
	_sess_picker.add_child(pa)
	card.add_child(_sess_picker)
	return panel


func _rebuild_picker() -> void:
	for c in _plist.get_children():
		c.queue_free()
	if _sessions.is_empty():
		_plist.add_child(_lbl("Keine gespeicherten Sessions.\nStandard-Runtime wird gestartet.", 12, TEXT3, 400))
		return
	for nm in _sessions:
		var b := Button.new()
		b.text = "   " + str(nm)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 44)
		b.add_theme_font_size_override("font_size", 13)
		var sel := str(nm) == _sel_session
		_style_btn(b, BG1 if not sel else YELLOW_DIM, YELLOW if sel else BORDER, TEXT)
		b.pressed.connect(_pick_session.bind(str(nm)))
		_plist.add_child(b)


# =============================================================== dev bar (mock)

func _build_devbar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 9)
	bar.add_child(_lbl("MOCK", 9, TEXT3, 600))
	_dev_btn_touch = _dev_btn("Touch: an", _toggle_touch)
	_dev_btn_touch.button_pressed = true
	bar.add_child(_dev_btn_touch)
	bar.add_child(_dev_btn("Update-Hinweis", _toggle_update))
	_dev_btn_lic = _dev_btn("Lizenz: aktiv", _toggle_license)
	bar.add_child(_dev_btn_lic)
	bar.add_child(_dev_btn("Gerät verbinden", _mock_device))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(sp)
	bar.add_child(_lbl("Test-PIN 2468  ·  F12 = Launcher", 11, TEXT3, 400))
	return bar


# =============================================================== PIN logic

func _push_digit(d: String) -> void:
	if _pin.length() >= 4:
		return
	_pin_msg.text = ""
	_pin += d
	_render_pin()
	if _pin.length() == 4:
		await get_tree().create_timer(0.15).timeout
		_check_pin()


func _check_pin() -> void:
	if _pin == CORRECT_PIN:
		_pin_msg.text = "Freigegeben"
		_pin_msg.add_theme_color_override("font_color", GREEN)
		await get_tree().create_timer(0.4).timeout
		_unlock()
	else:
		_pin_msg.add_theme_color_override("font_color", RED)
		_pin_msg.text = "Falsche PIN"
		await get_tree().create_timer(0.45).timeout
		_pin = ""
		_render_pin()


func _render_pin() -> void:
	for i in _pin_cells.size():
		var c := _pin_cells[i] as PanelContainer
		var l := c.get_child(0) as Label
		l.text = "•" if i < _pin.length() else ""
		var active := i == _pin.length() and _pin.length() < 4
		var bcol := YELLOW if active else (BORDER_HI if i < _pin.length() else BORDER)
		c.add_theme_stylebox_override("panel", _sbox(BG3 if active else BG2, bcol, 10))


func _unlock() -> void:
	_unlocked = true
	_pin_stage.visible = false
	_connect_stage.visible = true
	_mid_label.text = "Verbinden & Starten"
	_sess_state.text = "Freigegeben"
	_sess_state_box.add_theme_stylebox_override("panel", _sbox(Color(GREEN.r, GREEN.g, GREEN.b, 0.14), Color(GREEN.r, GREEN.g, GREEN.b, 0.3), 5))
	_sess_state.add_theme_color_override("font_color", GREEN)
	_remote_tag.visible = true
	_sess_view.get_node("ChangeBtn").visible = true
	_set_stage_ready(true)
	_set_mode("remote")
	_update_dev()


func _reset_gate() -> void:
	_unlocked = false
	_pin = ""
	_render_pin()
	_pin_msg.text = ""
	_connected = false
	_close_picker()
	_connect_stage.visible = false
	_apply_touch_mode()
	_mid_label.text = "Freigabe"
	_sess_state.text = "Gesperrt"
	_sess_state_box.add_theme_stylebox_override("panel", _sbox(BG3, BORDER, 5))
	_sess_state.add_theme_color_override("font_color", TEXT2)
	_remote_tag.visible = false
	_sess_view.get_node("ChangeBtn").visible = false
	_set_stage_ready(false)
	_update_dev()


func _set_stage_ready(ready: bool) -> void:
	_stage_state.text = "Ready" if ready else "Idle"
	_stage_state.add_theme_color_override("font_color", GREEN if ready else TEXT2)
	_stage_dot.add_theme_stylebox_override("panel", _dot_style(GREEN if ready else TEXT2))


# =============================================================== Playout start

func _on_start() -> void:
	# Apply the chosen session (named agenda) then reveal the runtime.
	if _sel_session != "" and _agenda != null and _agenda.has_method("load_agenda"):
		_agenda.call("load_agenda", _sel_session)
		if _agenda.has_method("entry_count") and int(_agenda.call("entry_count")) > 0:
			_agenda.call("go_to", 0)
	# Switch the live output to its target mode (span / preview / window).
	if _display != null and _display.has_method("start_playout"):
		_display.call("start_playout")
	_hide_launcher()


func _hide_launcher() -> void:
	_shown = false
	_root.visible = false


func show_locked() -> void:
	_shown = true
	_root.visible = true
	# Drop back to a framed window for the launcher (keeps saved playout mode).
	if _display != null and _display.has_method("enter_launcher"):
		_display.call("enter_launcher")
	_load_sessions()
	_rebuild_picker()
	_sess_name.text = _sel_session if _sel_session != "" else "Standard-Runtime"
	_reset_gate()


# =============================================================== connect / modes

func _set_mode(m: String) -> void:
	_mode = m
	var cfg: Dictionary = MODES[m]
	_seg_remote.button_pressed = m == "remote"
	_seg_manager.button_pressed = m == "manager"
	_style_seg(_seg_remote, m == "remote")
	_style_seg(_seg_manager, m == "manager")
	_conn_title.text = str(cfg["title"])
	_conn_desc.text = str(cfg["desc"])
	_qr_url.text = str(cfg["url"])
	_dev_txt.visible = m == "remote"


func _update_dev() -> void:
	var rtt := _remote_tag.get_child(0).get_child(0) as Label
	if not _connected:
		_dev_txt.text = "Kein Gerät verbunden"
		_dev_txt.add_theme_color_override("font_color", TEXT2)
		rtt.text = "Remote"
	else:
		_dev_txt.text = "iPhone 15 Pro · Moderator"
		_dev_txt.add_theme_color_override("font_color", TEXT)
		rtt.text = "Verbunden"


# =============================================================== session picker

func _open_picker() -> void:
	_sess_view.visible = false
	_sess_picker.visible = true


func _close_picker() -> void:
	_sess_picker.visible = false
	_sess_view.visible = true


func _pick_session(nm: String) -> void:
	_sel_session = nm
	_rebuild_picker()


func _confirm_session() -> void:
	_sess_name.text = _sel_session if _sel_session != "" else "Standard-Runtime"
	_close_picker()


# =============================================================== dev-bar mocks

func _toggle_touch() -> void:
	_is_touch = not _is_touch
	_dev_btn_touch.text = "Touch: " + ("an" if _is_touch else "aus")
	_reset_gate()


func _toggle_update() -> void:
	_update_warn = not _update_warn
	_act_update.visible = _update_warn
	_st_upd_ic.text = "!" if _update_warn else "✓"
	_st_upd_ic.add_theme_color_override("font_color", ORANGE if _update_warn else GREEN)
	_st_upd_d.text = "Update 1.3.0" if _update_warn else "Aktuell"
	_st_upd_d.add_theme_color_override("font_color", ORANGE if _update_warn else TEXT2)
	_refresh_sys()


func _toggle_license() -> void:
	_lic_active = not _lic_active
	_act_lic.visible = not _lic_active
	_st_lic_ic.text = "✓" if _lic_active else "✗"
	_st_lic_ic.add_theme_color_override("font_color", GREEN if _lic_active else RED)
	_st_lic_d.text = "Aktiv" if _lic_active else "Abgelaufen"
	_st_lic_d.add_theme_color_override("font_color", TEXT2 if _lic_active else RED)
	_dev_btn_lic.text = "Lizenz: " + ("aktiv" if _lic_active else "inaktiv")
	_refresh_sys()


func _mock_device() -> void:
	if not _unlocked or _mode != "remote":
		return
	_connected = not _connected
	_update_dev()


func _refresh_sys() -> void:
	if not _lic_active:
		_sys_big.text = "✗"
		_sys_big.add_theme_color_override("font_color", RED)
		_sys_txt.text = "Nicht betriebsbereit"
		_sys_sub.text = "Lizenz abgelaufen"
	elif _update_warn:
		_sys_big.text = "!"
		_sys_big.add_theme_color_override("font_color", ORANGE)
		_sys_txt.text = "Betriebsbereit"
		_sys_sub.text = "Update verfügbar"
	else:
		_sys_big.text = "✓"
		_sys_big.add_theme_color_override("font_color", GREEN)
		_sys_txt.text = "Betriebsbereit"
		_sys_sub.text = "Alle Dienste aktiv"


func _apply_touch_mode() -> void:
	_pin_stage.visible = _is_touch
	# non-touch pregate (phone-driven) is folded into the PIN stage hint for v1.
	if not _is_touch:
		_pin = ""
		_render_pin()


# =============================================================== input

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k := event as InputEventKey
	# Re-open the launcher (re-lock) from the running runtime.
	if not _shown:
		if k.keycode == KEY_F12:
			show_locked()
			get_viewport().set_input_as_handled()
		return
	# Launcher visible -> swallow runtime hotkeys so they don't fire behind it.
	if k.keycode in [KEY_TAB, KEY_F1, KEY_F2, KEY_A]:
		get_viewport().set_input_as_handled()
		return
	# PIN keyboard entry (touch mode, PIN stage).
	if _is_touch and not _unlocked:
		if k.keycode >= KEY_0 and k.keycode <= KEY_9:
			_push_digit(char(k.keycode))
			get_viewport().set_input_as_handled()
		elif k.keycode >= KEY_KP_0 and k.keycode <= KEY_KP_9:
			_push_digit(str(k.keycode - KEY_KP_0))
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_BACKSPACE:
			_pin = _pin.substr(0, _pin.length() - 1)
			_render_pin()
			get_viewport().set_input_as_handled()


func _relayout() -> void:
	pass  # full-rect anchors + CenterContainer re-flow automatically


# =============================================================== UI helpers

func _lbl(text: String, size: int, col: Color, _weight: int = 400) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


# Returns a PanelContainer card. Child controls go into its inner VBox at
# get_child(0); the PanelContainer itself is what gets placed in the grid.
func _card(min_w: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _sbox(BG1, BORDER, 14, 24))
	p.custom_minimum_size = Vector2(min_w, 600)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(v)
	return p


func _axis_label(text: String) -> Label:
	var l := _lbl(text.to_upper(), 10, TEXT3, 600)
	return l


func _hsep() -> Control:
	var s := Panel.new()
	s.custom_minimum_size = Vector2(0, 1)
	s.add_theme_stylebox_override("panel", _sbox(Color(1, 1, 1, 0.06), Color(0, 0, 0, 0), 0))
	return s


func _vrule(h: float) -> Control:
	var s := Panel.new()
	s.custom_minimum_size = Vector2(1, h)
	s.add_theme_stylebox_override("panel", _sbox(BORDER_HI, Color(0, 0, 0, 0), 0))
	var cc := CenterContainer.new()
	cc.add_child(s)
	return cc


func _badge(glyph: String, col: Color) -> Label:
	var l := _lbl(glyph, 15, col, 700)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(30, 30)
	return l


func _stat_row(name: String, det: String, col: Color) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 11)
	var ic := _lbl("✓", 10, col, 700)
	ic.custom_minimum_size = Vector2(18, 18)
	ic.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(ic)
	var nm := _lbl(name, 13, TEXT, 400)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(nm)
	var d := _lbl(det, 12, TEXT2, 400)
	row.add_child(d)
	return [row, ic, d]


func _sfact(k: String, v: String, vcol: Color) -> Control:
	var row := HBoxContainer.new()
	var kl := _lbl(k, 12, TEXT2, 400)
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(kl)
	row.add_child(_lbl(v, 12, vcol, 500))
	return row


func _action_card(title: String, desc: String, btn: String, accent: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _sbox(Color(accent.r, accent.g, accent.b, 0.08), Color(accent.r, accent.g, accent.b, 0.3), 8, 10))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	var tv := VBoxContainer.new()
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(_lbl(title, 12, TEXT, 600))
	tv.add_child(_lbl(desc, 10, TEXT2, 400))
	hb.add_child(tv)
	var b := Button.new()
	b.text = btn
	b.add_theme_font_size_override("font_size", 11)
	_style_btn(b, accent, accent, BLACK if accent == YELLOW else TEXT)
	hb.add_child(b)
	p.add_child(hb)
	return p


func _qr_box() -> Control:
	# Visual mock: white rounded panel with a centered placeholder glyph.
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(172, 172)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_theme_stylebox_override("panel", _sbox(Color(1, 1, 1), Color(0, 0, 0, 0), 10))
	var l := _lbl("QR", 22, Color(0.1, 0.1, 0.1), 700)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


func _pad_btn(text: String, act: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(86, 54)
	b.add_theme_font_size_override("font_size", 18 if act.is_valid_int() else 12)
	_style_btn(b, BG2, BORDER, TEXT if act.is_valid_int() else TEXT2)
	b.pressed.connect(_on_pad.bind(act))
	return b


func _on_pad(act: String) -> void:
	if act == "clear":
		_pin = ""
		_pin_msg.text = ""
		_render_pin()
	elif act == "del":
		_pin = _pin.substr(0, _pin.length() - 1)
		_render_pin()
	else:
		_push_digit(act)


func _seg_btn(text: String, m: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 40)
	b.add_theme_font_size_override("font_size", 13)
	b.pressed.connect(_set_mode.bind(m))
	_style_seg(b, m == "remote")
	return b


func _style_seg(b: Button, active: bool) -> void:
	_style_btn(b, BG4 if active else BG2, BORDER, TEXT if active else TEXT2)


func _primary_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.add_theme_font_size_override("font_size", 15)
	_style_btn(b, YELLOW, YELLOW, BLACK)
	return b


func _secondary_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.add_theme_font_size_override("font_size", 12)
	_style_btn(b, Color(0, 0, 0, 0), BORDER, TEXT2)
	return b


func _dev_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.add_theme_font_size_override("font_size", 11)
	_style_btn(b, BG2, BORDER, TEXT2)
	b.pressed.connect(cb)
	return b


func _style_btn(b: Button, bg: Color, border: Color, fg: Color) -> void:
	b.add_theme_stylebox_override("normal", _sbox(bg, border, 8, 8))
	b.add_theme_stylebox_override("hover", _sbox(bg.lightened(0.06), border, 8, 8))
	b.add_theme_stylebox_override("pressed", _sbox(bg.darkened(0.1), border, 8, 8))
	b.add_theme_stylebox_override("focus", _sbox(bg, border, 8, 8))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_focus_color", fg)


func _sbox(bg: Color, border: Color, radius: int, pad: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(1)
	if pad > 0:
		s.content_margin_left = pad
		s.content_margin_right = pad
		s.content_margin_top = pad
		s.content_margin_bottom = pad
	return s


func _dot_style(col: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(4)
	return s
