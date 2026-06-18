extends RefCounted
class_name SlideLoader

# Laedt Slide-Bilder direkt von der Platte (beliebige absolute Pfade, user://, res://)
# ueber Image.load() statt der Godot-Import-Pipeline. Das ist der bewusst austauschbare
# Teil: im Produkt liefert der Host die Pfadliste, hier macht es die UI.
#
# Persistenz: Pfadliste in user://slides.json. Beim Start neu laden, fehlende Pfade
# ueberspringen. Beim allerersten Start (keine slides.json) werden Testbilder geladen.
#
# store_path ist ueberschreibbar, damit mehrere Slideshow-Instanzen eigene Bildpools
# fuehren koennen (eine JSON pro Slot-ID).

const VALID_EXT := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]

var store_path := "user://slides.json"

# Ein Slide: { path:String, tex:ImageTexture, img_aspect:float, name:String }
var slides: Array = []

# Wird gesetzt, falls Pfade beim Laden fehlschlagen (fuer UI-Hinweis).
var last_skipped: Array = []


func _aspect_from_image(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return 16.0 / 9.0
	return float(w) / float(h)


# Einen einzelnen Pfad laden. Gibt das Slide-Dict zurueck oder null bei Fehler.
func _load_one(path: String):
	var img := Image.new()
	var err := img.load(path)
	if err != OK:
		return null
	var tex := ImageTexture.create_from_image(img)
	if tex == null:
		return null
	return {
		"path": path,
		"tex": tex,
		"img_aspect": _aspect_from_image(img),
		"name": path.get_file(),
	}


func _already_present(path: String) -> bool:
	for s in slides:
		if s.path == path:
			return true
	return false


# Liste von Pfaden anhaengen. Duplikate (gleicher Pfad) werden still uebersprungen.
# Gibt die Anzahl tatsaechlich hinzugefuegter Slides zurueck.
func append_paths(paths: Array) -> int:
	var added := 0
	last_skipped = []
	for p in paths:
		var path := String(p)
		if _already_present(path):
			continue
		var rec = _load_one(path)
		if rec == null:
			last_skipped.append(path)
			continue
		slides.append(rec)
		added += 1
	if added > 0:
		_save()
	return added


# Alle Bilddateien eines Verzeichnisses anhaengen (nicht rekursiv).
func append_directory(dir_path: String) -> int:
	var found: Array = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return 0
	d.list_dir_begin()
	var fname := d.get_next()
	while fname != "":
		if not d.current_is_dir():
			var ext := fname.get_extension().to_lower()
			if VALID_EXT.has(ext):
				found.append(dir_path.path_join(fname))
		fname = d.get_next()
	d.list_dir_end()
	found.sort()
	return append_paths(found)


func clear() -> void:
	slides.clear()
	_save()


# --- Persistenz ---

func _save() -> void:
	var paths: Array = []
	for s in slides:
		paths.append(s.path)
	var f := FileAccess.open(store_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"paths": paths}))
	f.close()


func _read_stored_paths() -> Array:
	if not FileAccess.file_exists(store_path):
		return []
	var f := FileAccess.open(store_path, FileAccess.READ)
	if f == null:
		return []
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("paths"):
		return []
	return parsed["paths"]


# Initialisierung beim Start. Gibt true zurueck, wenn aus gespeicherter Liste geladen
# wurde, false wenn der Erststart-Fall (Testbilder) griff.
# default_test_paths: Liste von Pfaden, die beim allerersten Start geladen werden.
func init_load(default_test_paths: Array) -> bool:
	slides.clear()
	last_skipped = []
	var had_store := FileAccess.file_exists(store_path)
	if had_store:
		var stored := _read_stored_paths()
		for p in stored:
			var rec = _load_one(String(p))
			if rec == null:
				last_skipped.append(String(p))
				continue
			slides.append(rec)
		return true
	else:
		# Erststart: Testbilder laden, danach gleich persistieren.
		for p in default_test_paths:
			var rec = _load_one(String(p))
			if rec == null:
				last_skipped.append(String(p))
				continue
			slides.append(rec)
		_save()
		return false


func count() -> int:
	return slides.size()
