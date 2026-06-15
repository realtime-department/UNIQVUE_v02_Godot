extends CanvasLayer
## Echtzeit-Performance-Monitor. F1 zum Ein-/Ausblenden.
##
## Misst auf einem Rolling-Window von 120 Frames:
##   - FPS, Frame-Zeit (cur / hi / avg / σ)
##   - Render: Draw Calls, Primitives, Objekte, VRAM / TMEM / BMEM
##   - System: Static Memory, Nodes, Objekte, Ressourcen, Orphans
##   - Timing: Process-Zeit, Physik-Zeit, Audio-Latenz
##   - Frame-Zeit-Graph (Unicode-Blöcke, 0–33 ms Skala)

const HISTORY := 120
const GRAPH_W := 36
const BAR     := ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

var _panel: PanelContainer
var _label:  Label

var _ft:    PackedFloat32Array   # Frame-Zeiten in ms
var _head  := 0
var _count := 0


func _ready() -> void:
	layer = 102   # ueber RuntimeUI (layer 100)
	_ft.resize(HISTORY)
	_ft.fill(16.67)
	_build()
	get_window().size_changed.connect(func() -> void:
		if _panel != null:
			_panel.position = Vector2(8.0, 8.0))


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.position    = Vector2(8.0, 8.0)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.72)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	_panel.add_theme_stylebox_override("panel", sb)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 10)
	_label.add_theme_color_override("font_color", Color(0.82, 0.90, 0.97))
	var mf := SystemFont.new()
	mf.font_names = PackedStringArray([
		"Courier New", "Consolas", "Lucida Console", "DejaVu Sans Mono", "monospace"])
	_label.add_theme_font_override("font", mf)
	_panel.add_child(_label)

	_panel.visible = false   # F1 oeffnet
	add_child(_panel)


func _process(delta: float) -> void:
	_ft[_head] = delta * 1000.0
	_head  = (_head + 1) % HISTORY
	_count = mini(_count + 1, HISTORY)

	if _panel != null and _panel.visible:
		_update()


# ------------------------------------------------------------------ Anzeige

func _update() -> void:
	# --- Frame-Zeit-Statistik (Rolling Window) ---
	var cur    := _ft[(_head - 1 + HISTORY) % HISTORY]
	var ft_min := INF
	var ft_max := 0.0
	var ft_sum := 0.0
	for i in range(_count):
		var v := _ft[(_head - 1 - i + HISTORY * 2) % HISTORY]
		if v < ft_min: ft_min = v
		if v > ft_max: ft_max = v
		ft_sum += v
	var ft_avg := ft_sum / float(_count)
	var sq_sum := 0.0
	for i in range(_count):
		var d := _ft[(_head - 1 - i + HISTORY * 2) % HISTORY] - ft_avg
		sq_sum += d * d
	var sigma := sqrt(sq_sum / float(_count))

	# --- Performance-Singleton ---
	var fps   := Performance.get_monitor(Performance.TIME_FPS)
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var r_obj := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var vmem  := int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var tmem  := int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var bmem  := int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED))
	var smem  := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var obj_c := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var res_c := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var orp_c := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var proc  := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys  := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var aud   := Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY) * 1000.0

	var vp   := get_viewport().get_visible_rect().size
	var fps_lo  := 1000.0 / maxf(ft_max, 0.001)
	var fps_avg := 1000.0 / maxf(ft_avg, 0.001)

	# --- Frame-Zeit-Graph ---
	var graph := ""
	for i in range(GRAPH_W):
		var gi := (_head - 1 - (GRAPH_W - 1 - i) + HISTORY * 100) % HISTORY
		var t  := clampf(_ft[gi] / 33.33, 0.0, 1.0)
		graph += BAR[int(t * 7.0)]

	# --- Text zusammensetzen ---
	var s := ""
	s += "─ PERF  [F1] ─────────────────────────\n"
	s += "fps  %6.1f  │  cur   %7.2f ms\n" % [fps,    cur   ]
	s += "lo   %6.1f  │  hi    %7.2f ms\n" % [fps_lo, ft_max]
	s += "avg  %6.1f  │  sigma %7.2f ms  n=%d\n" % [fps_avg, sigma, _count]
	s += "─ RENDER ──────────────────────────────\n"
	s += "draws  %s  │  prim  %s\n" % [_fc(draws),  _fc(prims)]
	s += "objs   %s  │  vmem  %s\n" % [_fc(r_obj),  _fb(vmem) ]
	s += "tmem   %s  │  bmem  %s\n" % [_fb(tmem),   _fb(bmem) ]
	s += "─ SYSTEM ──────────────────────────────\n"
	s += "smem   %s  │  nodes %s\n" % [_fb(smem),   _fc(nodes)]
	s += "obj    %s  │  res   %s\n" % [_fc(obj_c),  _fc(res_c)]
	s += "orphan %s  │  audio %6.2f ms\n" % [_fc(orp_c), aud]
	s += "─ TIMING ──────────────────────────────\n"
	s += "proc  %7.3f ms  │  phys  %7.3f ms\n" % [proc, phys]
	s += "vp    %dx%d\n" % [int(vp.x), int(vp.y)]
	s += "─ FRAME  %d smp  [0 ── 16.7 ── 33ms] ─\n" % _count
	s += graph

	_label.text = s


# ------------------------------------------------------------------ Formatter

# Bytes -> lesbarer String, rechtsbündig auf 7 Zeichen.
func _fb(b: int) -> String:
	var raw: String
	if   b >= 1073741824: raw = "%.2fGB" % (b / 1073741824.0)
	elif b >= 1048576:    raw = "%.1fMB" % (b / 1048576.0)
	elif b >= 1024:       raw = "%.1fKB" % (b / 1024.0)
	else:                 raw = "%dB"    %  b
	return raw.lpad(7)


# Anzahl -> lesbarer String, rechtsbündig auf 7 Zeichen.
func _fc(n: int) -> String:
	var raw: String
	if   n >= 1000000: raw = "%.2fM" % (n / 1000000.0)
	elif n >= 1000:    raw = "%.1fk" % (n / 1000.0)
	else:              raw = "%d"    %  n
	return raw.lpad(7)


# ------------------------------------------------------------------ Input

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F1:
		if _panel != null:
			_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()
