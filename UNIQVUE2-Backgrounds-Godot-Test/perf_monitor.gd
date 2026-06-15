extends CanvasLayer
## Echtzeit-Performance-Monitor mit Hardware-Metriken.
## F1: ein-/ausblenden. Titelzeile: ziehen. Mausrad: Schrift skalieren.
##
## Godot-Metriken: FPS/Frame-Zeit (Rolling-Window 120), Render-Stats, Speicher.
## HW-Metriken (Background-Thread, alle 2 s): GPU (nvidia-smi), CPU + RAM
## (PowerShell/WMI), CPU-Temperatur (WMI Thermal Zone, best-effort).

const HISTORY       := 120
const GRAPH_W       := 38
const BAR           := ["▁","▂","▃","▄","▅","▆","▇","█"]
const POLL_INTERVAL := 2.0

# --- UI ---
var _panel:    PanelContainer
var _label:    Label
var _font_size := 10
var _dragging  := false
var _drag_off  := Vector2.ZERO

# --- Frame-Zeit-Ringpuffer ---
var _ft:   PackedFloat32Array
var _head  := 0
var _count := 0

# --- HW-Daten (Thread) ---
var _mutex  := Mutex.new()
var _thread: Thread = null
var _hw     := {}
var _ptimer := POLL_INTERVAL   # sofort beim Start abfragen


func _ready() -> void:
	layer = 102
	_ft.resize(HISTORY)
	_ft.fill(16.67)
	_hw = _blank_hw()
	_build()


func _blank_hw() -> Dictionary:
	return {
		"cpu_name": "", "cpu_load": -1.0, "cpu_clk": -1.0, "cpu_temp": -1.0,
		"ram_used": -1, "ram_total": -1,
		"gpu_name": "", "gpu_load": -1.0, "gpu_mload": -1.0,
		"gpu_temp": -1.0, "gpu_clk": -1.0, "gpu_mclk": -1.0,
		"gpu_pwr":  -1.0, "gpu_vused": -1, "gpu_vtot": -1,
	}


# ------------------------------------------------------------------ Build

func _build() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.position     = Vector2(8.0, 8.0)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.02, 0.04, 0.80)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(9)
	_panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	_panel.add_child(vbox)

	var mf := SystemFont.new()
	mf.font_names = PackedStringArray([
		"Courier New", "Consolas", "Lucida Console", "DejaVu Sans Mono", "monospace"])

	var title := Label.new()
	title.text = "  PERF  [F1]  drag │ scroll: scale  "
	title.add_theme_font_size_override("font_size", _font_size)
	title.add_theme_font_override("font", mf)
	title.add_theme_color_override("font_color", Color(0.42, 0.50, 0.60))
	title.mouse_filter = Control.MOUSE_FILTER_STOP
	title.gui_input.connect(_on_title_input)
	vbox.add_child(title)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", _font_size)
	_label.add_theme_font_override("font", mf)
	_label.add_theme_color_override("font_color", Color(0.83, 0.91, 0.98))
	_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_label.gui_input.connect(_on_label_input)
	vbox.add_child(_label)

	_panel.visible = false
	add_child(_panel)


# ------------------------------------------------------------------ Loop

func _process(delta: float) -> void:
	_ft[_head] = delta * 1000.0
	_head  = (_head + 1) % HISTORY
	_count = mini(_count + 1, HISTORY)

	_ptimer += delta
	if _ptimer >= POLL_INTERVAL:
		_ptimer = 0.0
		_start_hw_poll()

	if _panel != null and _panel.visible:
		_draw()


# ------------------------------------------------------------------ HW polling (background thread)

func _start_hw_poll() -> void:
	if _thread != null:
		if _thread.is_alive():
			return
		_thread.wait_to_finish()
		_thread = null
	_thread = Thread.new()
	_thread.start(_hw_poll_thread)


func _hw_poll_thread() -> void:
	var r := _blank_hw()
	_do_gpu(r)
	_do_cpu_ram(r)
	_mutex.lock()
	_hw = r
	_mutex.unlock()


func _do_gpu(r: Dictionary) -> void:
	var out: Array = []
	var ret := OS.execute("nvidia-smi", [
		"--query-gpu=name,utilization.gpu,utilization.memory,temperature.gpu,"
			+ "clocks.current.graphics,clocks.current.memory,power.draw,"
			+ "memory.used,memory.total",
		"--format=csv,noheader,nounits"
	], out, false, false)

	if ret == 0 and not out.is_empty():
		var p := _csv(out[0])
		if p.size() >= 9:
			r["gpu_name"]  = p[0].replace("NVIDIA GeForce ", "").replace("NVIDIA ", "")
			r["gpu_load"]  = p[1].to_float()
			r["gpu_mload"] = p[2].to_float()
			r["gpu_temp"]  = p[3].to_float()
			r["gpu_clk"]   = p[4].to_float()
			r["gpu_mclk"]  = p[5].to_float()
			r["gpu_pwr"]   = p[6].to_float()
			r["gpu_vused"] = int(p[7].to_float() * 1048576.0)   # MiB → bytes
			r["gpu_vtot"]  = int(p[8].to_float() * 1048576.0)
			return

	# Fallback: WMI-Basisinfo fuer AMD/Intel (kein Auslastungs-/Temperatur-Zugriff)
	var fb: Array = []
	var cmd := ("$g=Get-CimInstance Win32_VideoController|Select -First 1;"
		+ "\"$($g.Name)|$($g.AdapterRAM)\"")
	if OS.execute("powershell.exe",
			["-NonInteractive", "-NoProfile", "-ExecutionPolicy", "Bypass",
			 "-Command", cmd], fb, false, false) == 0 and not fb.is_empty():
		var p2 := fb[0].strip_edges().split("|")
		if p2.size() >= 2:
			r["gpu_name"]  = p2[0].strip_edges()
			r["gpu_vtot"]  = p2[1].strip_edges().to_int()


func _do_cpu_ram(r: Dictionary) -> void:
	var cmd := (
		"$c=Get-CimInstance Win32_Processor|Select -First 1;"
		+ "$o=Get-CimInstance Win32_OperatingSystem;"
		+ "$t='N/A';"
		+ "try{"
		+   "$tz=Get-CimInstance -NS root/wmi MSAcpi_ThermalZoneTemperature -EA Stop;"
		+   "$t=[math]::Round($tz.CurrentTemperature/10-273.15,1)"
		+ "}catch{};"
		+ "\"$($c.LoadPercentage)|$($c.CurrentClockSpeed)|$($c.Name)"
		+ "|$($o.FreePhysicalMemory)|$($o.TotalVisibleMemorySize)|$t\""
	)
	var out: Array = []
	if OS.execute("powershell.exe",
			["-NonInteractive", "-NoProfile", "-ExecutionPolicy", "Bypass",
			 "-Command", cmd], out, false, false) != 0 or out.is_empty():
		return

	var p := out[0].strip_edges().split("|")
	if p.size() < 6:
		return

	r["cpu_load"]  = p[0].strip_edges().to_float()
	r["cpu_clk"]   = p[1].strip_edges().to_float()
	var cname      := p[2].strip_edges()
	if "@" in cname:
		cname = cname.split("@")[0].strip_edges()
	r["cpu_name"]  = cname
	var free_kb    := p[3].strip_edges().to_int()
	var tot_kb     := p[4].strip_edges().to_int()
	r["ram_total"] = tot_kb  * 1024
	r["ram_used"]  = (tot_kb - free_kb) * 1024
	var tmp_s      := p[5].strip_edges()
	r["cpu_temp"]  = tmp_s.to_float() if tmp_s != "N/A" and tmp_s != "" else -1.0


func _csv(raw: String) -> PackedStringArray:
	var parts := raw.strip_edges().split(",")
	var r := PackedStringArray()
	for x in parts:
		r.append(x.strip_edges())
	return r


# ------------------------------------------------------------------ Render

func _draw() -> void:
	_mutex.lock()
	var hw := _hw.duplicate()
	_mutex.unlock()

	# Frame-Zeit-Statistik
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
	var sq := 0.0
	for i in range(_count):
		var d := _ft[(_head - 1 - i + HISTORY * 2) % HISTORY] - ft_avg
		sq += d * d
	var sigma := sqrt(sq / float(_count))

	# Godot Performance-Singleton
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
	var vp    := get_viewport().get_visible_rect().size

	# Frame-Zeit-Graph
	var graph := ""
	for i in range(GRAPH_W):
		var gi := (_head - 1 - (GRAPH_W - 1 - i) + HISTORY * 100) % HISTORY
		graph  += BAR[int(clampf(_ft[gi] / 33.33, 0.0, 1.0) * 7.0)]

	# Abgeleitete Werte
	var fps_lo  := 1000.0 / maxf(ft_max, 0.001)
	var fps_avg := 1000.0 / maxf(ft_avg, 0.001)
	var gn      : String = hw.get("gpu_name", "")
	var cn      : String = hw.get("cpu_name", "")
	if cn.length() > 24: cn = cn.substr(0, 24)

	var s := ""

	# FPS / Frame-Zeit
	s += "─ FPS / FRAME TIME ─────────────────────────\n"
	s += "fps  %7.1f  │  cur    %7.2f ms\n" % [fps,    cur   ]
	s += "lo   %7.1f  │  hi     %7.2f ms\n" % [fps_lo, ft_max]
	s += "avg  %7.1f  │  sigma  %7.2f ms  n=%d\n" % [fps_avg, sigma, _count]

	# GPU
	s += "─ GPU%s─\n" % _head_pad(gn, 39)
	s += "util  %s  │  mem   %s\n" % [_p(hw.get("gpu_load",-1.0)),  _p(hw.get("gpu_mload",-1.0))]
	s += "temp  %s  │  power %s\n" % [_c(hw.get("gpu_temp",-1.0)),  _w(hw.get("gpu_pwr",  -1.0))]
	s += "clk   %s  │  mclk  %s\n" % [_m(hw.get("gpu_clk", -1.0)),  _m(hw.get("gpu_mclk", -1.0))]
	s += "vram  %s / %s\n"          % [_b(hw.get("gpu_vused",-1)),   _b(hw.get("gpu_vtot", -1))]

	# CPU
	s += "─ CPU%s─\n" % _head_pad(cn, 39)
	s += "util  %s  │  clk   %s\n" % [_p(hw.get("cpu_load",-1.0)),  _m(hw.get("cpu_clk",-1.0))]
	s += "temp  %s\n"               %  _c(hw.get("cpu_temp",-1.0))

	# RAM
	s += "─ RAM ──────────────────────────────────────\n"
	s += "used  %s / %s\n" % [_b(hw.get("ram_used",-1)), _b(hw.get("ram_total",-1))]

	# Godot
	s += "─ GODOT ────────────────────────────────────\n"
	s += "draws %s  │  prim  %s\n" % [_n(draws), _n(prims)]
	s += "objs  %s  │  vmem  %s\n" % [_n(r_obj), _b(vmem) ]
	s += "tmem  %s  │  bmem  %s\n" % [_b(tmem),  _b(bmem) ]
	s += "smem  %s  │  nodes %s\n" % [_b(smem),  _n(nodes)]
	s += "orp   %s  │  res   %s\n" % [_n(orp_c), _n(res_c)]
	s += "proc %7.3f ms  │  phys %7.3f ms\n" % [proc, phys]
	s += "aud  %7.2f ms  │  vp  %dx%d\n"      % [aud,  int(vp.x), int(vp.y)]

	# Frame-Graph
	s += "─ FRAME  %d smp  [0 ─── 16.7 ─── 33 ms] ─\n" % _count
	s += graph

	_label.text = s


# ------------------------------------------------------------------ Format helpers  (8-char right-justified)

func _b(v: int) -> String:
	if v < 0: return "    N/A "
	var r: String
	if   v >= 1073741824: r = "%.2f GB" % (v / 1073741824.0)
	elif v >= 1048576:    r = "%.1f MB" % (v / 1048576.0)
	elif v >= 1024:       r = "%.1f KB" % (v / 1024.0)
	else:                 r = "%d B"    %  v
	return r.lpad(8)

func _n(v: int) -> String:
	if v < 0: return "    N/A "
	var r: String
	if   v >= 1000000: r = "%.2fM" % (v / 1000000.0)
	elif v >= 1000:    r = "%.1fk" % (v / 1000.0)
	else:              r = "%d"    %  v
	return r.lpad(8)

func _p(v: float) -> String:   # percent
	return ("   N/A " if v < 0.0 else ("%5.1f %%" % v).lpad(8))

func _c(v: float) -> String:   # celsius
	return ("   N/A " if v < 0.0 else ("%5.1f°C"  % v).lpad(8))

func _m(v: float) -> String:   # MHz / GHz
	if v < 0.0: return "   N/A "
	return (("%.2fGHz" % (v/1000.0)) if v >= 1000.0 else ("%dMHz" % int(v))).lpad(8)

func _w(v: float) -> String:   # watts
	return ("   N/A " if v < 0.0 else ("%.1f W"  % v).lpad(8))

func _head_pad(name: String, total: int) -> String:
	if name == "": return " " + "─".repeat(total)
	var inner := " " + name + " "
	var rem   := maxi(0, total - inner.length())
	return inner + "─".repeat(rem)


# ------------------------------------------------------------------ Input

func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if _dragging:
			_drag_off = _panel.position - event.global_position
	elif event is InputEventMouseMotion and _dragging:
		var vp := get_viewport().get_visible_rect().size
		_panel.position = (event.global_position + _drag_off).clamp(
			Vector2.ZERO, (vp - _panel.size).max(Vector2.ZERO))
		get_viewport().set_input_as_handled()


func _on_label_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton): return
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			_font_size = mini(_font_size + 1, 24)
			_label.add_theme_font_size_override("font_size", _font_size)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_WHEEL_DOWN:
			_font_size = maxi(_font_size - 1, 7)
			_label.add_theme_font_size_override("font_size", _font_size)
			get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F1:
		if _panel != null:
			_panel.visible = not _panel.visible
			if _panel.visible:
				_ptimer = POLL_INTERVAL   # sofort refreshen
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ Cleanup

func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
