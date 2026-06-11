extends Node
## Virtuelle Buehnen-/Display-Konfiguration. Als Autoload registriert (siehe
## project.godot) - MUSS vor BackgroundStage stehen, damit dessen SubViewports
## gleich auf die richtige Groesse initialisiert werden.
##
## Beim Start:
##   - 1 Bildschirm   -> normales, gerahmtes Fenster (Entwicklung wird nicht gestoert)
##   - 2+ Bildschirme -> randloses Fenster ueber den gesamten erweiterten Desktop
##   - Erzwingen per Kommandozeile: --span  bzw.  --windowed
##
## Zur Laufzeit komplett ueber das RuntimeUI-Panel ("STAGE") steuerbar - KEINE
## Tastenkuerzel mehr (F9/F10/F11 sind teils von Godot/Windows belegt):
##   - virtuelles Raster (Spalten x Zeilen, Schirm-Pixel) frei einstellen
##   - PREVIEW: dieses Raster als korrekt proportioniertes Fenster (Einzelschirm)
##   - SPAN:    randlos ueber die real angeschlossenen Schirme
##   - WINDOW:  normales Fenster

enum Mode { WINDOWED, PREVIEW, SPAN }

# Virtuelles Showraster (vom RuntimeUI gesetzt). screen_w/h = Pixel je Einzelschirm.
var cols := 3
var rows := 1
var screen_w := 3840
var screen_h := 2160

var _mode := Mode.WINDOWED
var _windowed_rect := Rect2i(Vector2i(80, 80), Vector2i(1920, 1080))


func _ready() -> void:
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

## Raster/Schirm-Pixel uebernehmen. Laeuft gerade eine Vorschau, wird sie sofort
## auf das neue Seitenverhaeltnis nachgezogen.
func configure(c: int, r: int, sw: int, sh: int) -> void:
	cols = maxi(1, c)
	rows = maxi(1, r)
	screen_w = maxi(1, sw)
	screen_h = maxi(1, sh)
	if _mode == Mode.PREVIEW:
		preview_grid()


func grid_aspect() -> float:
	return float(cols * screen_w) / float(rows * screen_h)


func total_resolution() -> Vector2i:
	return Vector2i(cols * screen_w, rows * screen_h)


func mode() -> int:
	return _mode


## Randloses Fenster ueber das Vereinigungsrechteck ALLER real angeschlossenen
## Schirme - passt sich jeder Zahl/Anordnung automatisch an.
func span_screens() -> void:
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


## Vorschau des virtuellen Rasters auf dem aktuellen Einzelschirm: gerahmtes Fenster
## mit korrektem Show-Seitenverhaeltnis, eingepasst in Breite UND Hoehe.
func preview_grid() -> void:
	var scr := DisplayServer.window_get_current_screen()
	var ss := DisplayServer.screen_get_size(scr)
	var aspect := grid_aspect()
	var w := int(ss.x * 0.95)
	var h := int(round(float(w) / aspect))
	if h > int(ss.y * 0.95):
		h = int(ss.y * 0.95)
		w = int(round(float(h) * aspect))
	var win := get_window()
	win.borderless = false
	win.size = Vector2i(maxi(64, w), maxi(64, h))
	win.position = DisplayServer.screen_get_position(scr) \
		+ Vector2i((ss.x - win.size.x) / 2, (ss.y - win.size.y) / 2)
	_mode = Mode.PREVIEW
	print("Display-Setup: Vorschau %s (%dx%d, %.3f:1)" % [win.size, cols, rows, aspect])


func restore_window() -> void:
	var win := get_window()
	win.borderless = false
	win.size = _windowed_rect.size
	win.position = _windowed_rect.position
	_mode = Mode.WINDOWED
