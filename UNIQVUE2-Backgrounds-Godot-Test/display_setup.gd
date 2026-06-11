extends Node
## Fenster-Setup fuer Einzel-Monitor-Entwicklung UND das 3-Schirm-Showsetup.
## Als Autoload registriert (siehe project.godot) - MUSS vor BackgroundStage stehen,
## damit dessen SubViewports gleich auf die richtige (gespannte) Groesse initialisiert
## werden. (BackgroundStage folgt aber ohnehin window.size_changed.)
##
## Verhalten:
##   - 1 Bildschirm   -> normales, gerahmtes Fenster (Entwicklung wird nicht gestoert)
##   - 2+ Bildschirme -> randloses Fenster ueber den gesamten erweiterten Desktop
##                       (3x 3840x2160 nebeneinander => 11520x2160)
##   - Erzwingen per Kommandozeile: --span  bzw.  --windowed
##
## Tasten zur Laufzeit (kollidieren nicht mit RuntimeUI: Tab=Panel):
##   F11 = zwischen gespanntem Vollbild und normalem Fenster wechseln
##   F10 = Ultrawide-Vorschau (48:9) auf einem Einzelschirm ein/aus -
##         zeigt die echte Show-Komposition zum Tunen von Kamera/Layout
## (Bewusst KEIN ESC-Beenden, um eine laufende Show nicht versehentlich zu beenden -
##  Fenster ueber Alt+F4 schliessen.)

## Showsetup-Raster fuer die F10-Vorschau auf einem Einzelschirm.
## Das tatsaechliche Spannen passt sich JEDER Schirmzahl/-anordnung automatisch an
## (Vereinigungsrechteck) - diese Werte betreffen NUR die lokale Vorschau-Geometrie.
##   3x1 -> 48:9   |   9x1 -> 144:9 (16:1)   |   3x3 -> 16:9
const SHOW_COLS := 3
const SHOW_ROWS := 1
const SHOW_ASPECT := float(SHOW_COLS * 16) / float(SHOW_ROWS * 9)

var _spanned := false
var _previewing := false
var _windowed_rect := Rect2i(Vector2i(80, 80), Vector2i(1920, 1080))

func _ready() -> void:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	if args.has("--windowed"):
		_restore_window()
	elif args.has("--span") or DisplayServer.get_screen_count() > 1:
		_span_all_screens()
	else:
		_restore_window()
		print("Display-Setup: Einzelschirm -> normales Fenster. F10 = Ultrawide-Vorschau, F11 = Span.")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F11:
				if _spanned: _restore_window() else: _span_all_screens()
			KEY_F10:
				if _previewing: _restore_window() else: _preview_ultrawide()

## Vereinigungs-Rechteck aller Bildschirme bilden und randloses Fenster darueberlegen.
func _span_all_screens() -> void:
	var screen_count := DisplayServer.get_screen_count()
	if screen_count == 0:
		return

	var rect := Rect2i(DisplayServer.screen_get_position(0), DisplayServer.screen_get_size(0))
	for i in range(1, screen_count):
		rect = rect.merge(Rect2i(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i)))

	var win := get_window()
	win.mode = Window.MODE_WINDOWED
	win.borderless = true
	win.position = rect.position
	win.size = rect.size
	_spanned = true
	_previewing = false
	print("Display-Setup: %d Bildschirm(e) -> Fenster %s @ %s" % [screen_count, rect.size, rect.position])

## Vorschau der Show-Komposition (48:9) auf einem Einzelschirm.
func _preview_ultrawide() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var screen_size := DisplayServer.screen_get_size(screen)
	# In den Schirm einpassen (Breite UND Hoehe), damit auch hohe Raster (z.B. 3x3)
	# vollstaendig sichtbar bleiben.
	var w := int(screen_size.x * 0.95)
	var h := int(round(float(w) / SHOW_ASPECT))
	if h > int(screen_size.y * 0.95):
		h = int(screen_size.y * 0.95)
		w = int(round(float(h) * SHOW_ASPECT))
	var win := get_window()
	win.borderless = false
	win.size = Vector2i(w, h)
	win.position = DisplayServer.screen_get_position(screen) + Vector2i((screen_size.x - w) / 2, (screen_size.y - h) / 2)
	_previewing = true
	_spanned = false
	print("Display-Setup: Ultrawide-Vorschau %s (48:9)" % win.size)

func _restore_window() -> void:
	var win := get_window()
	win.borderless = false
	win.size = _windowed_rect.size
	win.position = _windowed_rect.position
	_spanned = false
	_previewing = false
