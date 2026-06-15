extends Node
## Virtuelle Buehnen-/Display-Konfiguration. Als Autoload registriert (siehe
## project.godot) - MUSS vor BackgroundStage stehen, damit dessen SubViewports
## gleich auf die richtige Groesse initialisiert werden.
##
## Beim Start:
##   - 1 Bildschirm   -> normales, gerahmtes Fenster
##   - 2+ Bildschirme -> randloses Fenster ueber den gesamten erweiterten Desktop
##   - Erzwingen per Kommandozeile: --span  bzw.  --windowed
##
## Zur Laufzeit ueber das RuntimeUI-Panel ("STAGE") steuerbar:
##   - virtuelles Raster (Spalten x Zeilen, Schirm-Pixel) frei einstellen
##   - PREVIEW: pro virtuellem Schirm EIN eigenes Fenster, das genau seinen
##              Ausschnitt des durchgehenden Bildes zeigt -> Wand inkl. Naht
##              (Spalt zwischen den Fenstern = Bezel) auf dem Dev-Rechner simulieren
##   - SPAN:    randlos ueber die real angeschlossenen Schirme
##   - WINDOW:  normales Fenster (schliesst die Vorschaufenster)

enum Mode { WINDOWED, PREVIEW, SPAN }

# Virtuelles Showraster (vom RuntimeUI gesetzt). screen_w/h = Pixel je Einzelschirm.
var cols := 3
var rows := 1
var screen_w := 3840
var screen_h := 2160

# Canvas-Shader: zeigt je Fenster genau eine Rasterzelle des Gesamtbildes.
const SLICE_SHADER := "shader_type canvas_item;
uniform vec2 cell = vec2(1.0);
uniform vec2 offset = vec2(0.0);
void fragment() {
	COLOR = texture(TEXTURE, UV * cell + offset);
}"

var _mode := Mode.WINDOWED
var _windowed_rect := Rect2i(Vector2i(80, 80), Vector2i(1920, 1080))
var _preview_windows: Array[Window] = []
var _prev_embed := true

const CONFIG_PATH := "user://display_config.cfg"


func _ready() -> void:
	_load_config()
	var cli := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	if cli.has("--windowed"):
		restore_window()
	elif cli.has("--span") or DisplayServer.get_screen_count() > 1:
		span_screens()
	else:
		restore_window()
		print("Display-Setup: Einzelschirm -> Fenster. Steuerung im Panel unter STAGE.")


# --------------------------------------------------------------- Oeffentliche API
# (vom RuntimeUI-Panel genutzt)

## Raster/Schirm-Pixel uebernehmen. (Wirkt sich beim naechsten PREVIEW/SPAN aus -
## eine laufende Vorschau wird NICHT bei jedem Tastendruck neu gebaut.)
func configure(c: int, r: int, sw: int, sh: int) -> void:
	cols = maxi(1, c)
	rows = maxi(1, r)
	screen_w = maxi(1, sw)
	screen_h = maxi(1, sh)
	_save_config()


func grid_aspect() -> float:
	return float(cols * screen_w) / float(rows * screen_h)


func total_resolution() -> Vector2i:
	return Vector2i(cols * screen_w, rows * screen_h)


func mode() -> int:
	return _mode


## Randloses Fenster ueber das Vereinigungsrechteck ALLER real angeschlossenen
## Schirme - passt sich jeder Zahl/Anordnung automatisch an.
func span_screens() -> void:
	close_preview()
	var n := DisplayServer.get_screen_count()
	if n == 0:
		return
	var rect := Rect2i(DisplayServer.screen_get_position(0), DisplayServer.screen_get_size(0))
	for i in range(1, n):
		rect = rect.merge(Rect2i(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i)))
	var win := get_window()
	win.mode = Window.MODE_WINDOWED
	win.borderless = true
	win.position = rect.position
	win.size = rect.size
	_mode = Mode.SPAN
	print("Display-Setup: %d Schirm(e) -> Span %s @ %s" % [n, rect.size, rect.position])
	_save_config()


func restore_window() -> void:
	close_preview()
	var win := get_window()
	win.borderless = false
	win.size = _windowed_rect.size
	win.position = _windowed_rect.position
	_mode = Mode.WINDOWED
	_save_config()


# ------------------------------------------------------- Multi-Window-Vorschau

## Oeffnet pro virtuellem Schirm ein eigenes Fenster, das genau seinen Ausschnitt
## des durchgehenden Bildes zeigt. Die Buehne wird dazu in Wand-Aufloesung
## gerendert; der Spalt zwischen den Fenstern simuliert die Bezel-Naht.
func open_preview() -> void:
	close_preview()
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage == null:
		return

	# Anzeigegroesse je Schirmfenster: in die aktuelle Schirmbreite einpassen.
	var scr := DisplayServer.window_get_current_screen()
	var ss := DisplayServer.screen_get_size(scr)
	var gap := 10
	var slice_w := int(min(640.0, (float(ss.x) * 0.92 - float(cols - 1) * gap) / float(cols)))
	slice_w = maxi(160, slice_w)
	var slice_h := maxi(90, int(round(float(slice_w) * float(screen_h) / float(screen_w))))

	# Buehne in der Gesamt-(Wand-)Aufloesung rendern lassen -> korrektes
	# Gesamt-Seitenverhaeltnis; jede Zelle ist genau slice_w x slice_h gross.
	stage.call("set_render_size_override", Vector2i(cols * slice_w, rows * slice_h))

	# Native OS-Fenster erlauben (statt im Hauptfenster eingebettet).
	_prev_embed = get_tree().root.gui_embed_subwindows
	get_tree().root.gui_embed_subwindows = false

	var tex: Texture2D = stage.call("active_texture")
	var shader := Shader.new()
	shader.code = SLICE_SHADER
	var base := DisplayServer.screen_get_position(scr) + Vector2i(60, 60)

	for r in range(rows):
		for c in range(cols):
			var w := Window.new()
			w.title = "S %d,%d" % [c + 1, r + 1]
			w.size = Vector2i(slice_w, slice_h)
			w.position = base + Vector2i(c * (slice_w + gap), r * (slice_h + gap))
			w.min_size = Vector2i(120, 68)

			var tr := TextureRect.new()
			tr.texture = tex
			tr.set_anchors_preset(Control.PRESET_FULL_RECT)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED

			var mat := ShaderMaterial.new()
			mat.shader = shader
			mat.set_shader_parameter("cell", Vector2(1.0 / float(cols), 1.0 / float(rows)))
			mat.set_shader_parameter("offset", Vector2(float(c) / float(cols), float(r) / float(rows)))
			tr.material = mat

			w.add_child(tr)
			add_child(w)
			w.visible = true
			_preview_windows.append(w)

	# Bei Szenenwechsel zeigt die aktive Ebene eine neue Textur -> nachziehen.
	if not stage.is_connected("active_changed", _on_preview_active):
		stage.connect("active_changed", _on_preview_active)

	_mode = Mode.PREVIEW
	print("Display-Setup: Vorschau %dx%d Fenster, Zelle %dx%d" % [cols, rows, slice_w, slice_h])
	_save_config()


func close_preview() -> void:
	if _preview_windows.is_empty():
		return
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage != null:
		stage.call("clear_render_size_override")
		if stage.is_connected("active_changed", _on_preview_active):
			stage.disconnect("active_changed", _on_preview_active)
	for w in _preview_windows:
		if is_instance_valid(w):
			w.queue_free()
	_preview_windows.clear()
	if is_inside_tree():
		get_tree().root.gui_embed_subwindows = _prev_embed


func _on_preview_active(_root: Node) -> void:
	var stage := get_node_or_null("/root/BackgroundStage")
	if stage == null:
		return
	var tex: Texture2D = stage.call("active_texture")
	for w in _preview_windows:
		if is_instance_valid(w) and w.get_child_count() > 0 and w.get_child(0) is TextureRect:
			(w.get_child(0) as TextureRect).texture = tex


func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "cols", cols)
	cfg.set_value("display", "rows", rows)
	cfg.set_value("display", "screen_w", screen_w)
	cfg.set_value("display", "screen_h", screen_h)
	cfg.set_value("display", "mode", _mode)
	cfg.save(CONFIG_PATH)

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	cols = cfg.get_value("display", "cols", cols)
	rows = cfg.get_value("display", "rows", rows)
	screen_w = cfg.get_value("display", "screen_w", screen_w)
	screen_h = cfg.get_value("display", "screen_h", screen_h)
	var saved_mode: int = cfg.get_value("display", "mode", Mode.WINDOWED)
	# Re-apply the saved mode on next frame (after all autoloads are ready)
	call_deferred("_apply_saved_mode", saved_mode)

func _apply_saved_mode(saved_mode: int) -> void:
	match saved_mode:
		Mode.SPAN:
			span_screens()
		Mode.PREVIEW:
			open_preview()
		_:
			pass  # WINDOWED is already default
