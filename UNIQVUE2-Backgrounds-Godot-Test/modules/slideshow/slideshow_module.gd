extends SubViewport
# ============================================================
#  Slideshow Module — Godot Port
#
#  Das Modul IST der SubViewport (Skript am SubViewport-Knoten). Ein SubViewportContainer
#  rendert nur einen DIREKTEN SubViewport-Kind; zwischen Container und SubViewport darf
#  kein weiterer Node liegen.
#  Eine Camera3D mit umschaltbarer Projektion, Hoehe-2-Welt (y in -1..1, x in -aspect..aspect).
#  Alle Modi rechnen in dieser Welt; ortho und persp teilen exakt den Massstab.
# ============================================================

const SLIDE_ASPECT := 16.0 / 9.0
const PERSP_DIST := 2.414213562373095  # = 1/tan(22.5deg), sichtbare Hoehe bei z=0 == 2
const FOV := 45.0

# --- Node-Referenzen (Skript sitzt am SubViewport, Kinder also direkt) ---
@onready var sub_viewport: SubViewport = self
@onready var camera: Camera3D = $Camera3D
@onready var slides_root: Node3D = $Slides
@onready var main_pair_root: Node3D = $MainPair

# --- Slide-Pool ---
# SlideLoader per preload, nicht ueber die globale class_name-Registrierung. Das ist
# reihenfolge-unabhaengig (kein Henne-Ei beim Erstimport) und robust beim spaeteren
# Zusammenfuehren mit dem Background-Projekt.
const SlideLoaderClass := preload("res://modules/slideshow/slide_loader.gd")
var loader  # Instanz von SlideLoaderClass
# Quad-Meshes pro Slide (MeshInstance3D), dynamisch passend zum Pool aufgebaut.
var slide_meshes: Array = []
# Pro Slide zwei vorbereitete Materialien: Standard (format-genaue Modi) und Shader
# (Slidedeck/Gallery-Main: Fit/Crop-Remap + Blur). Layout waehlt, kein Erzeugen pro Frame.
var slide_std_mats: Array = []
var slide_shader_mats: Array = []
# Zwei dedizierte Quads fuer die Gallery-Hauptanzeige (Crossfade). Stufe 5.
var main_meshes: Array = []
var main_shader_mats: Array = []
var quad_mesh: QuadMesh
var slide_shader: Shader

# Optionale Instanz-ID: wenn gesetzt, fuehrt jede Slideshow einen eigenen Bildpool
# (user://slides_<id>.json) statt des gemeinsamen user://slides.json.
var instance_id := ""

# --- Zustand (Modulvertrag) ---
var state := {
	"mode": "slidedeck",
	"fit": 0,                  # 0 = Crop, 1 = Fit
	"transition": "swipeH",
	"transition_time": 0.6,
	"auto_run": false,
	"auto_run_seconds": 4.0,
	"loop": true,
	"show_nav": true,
	"show_pagination": true,
	"index": 0,
	"from_index": 0,
	"t": 1.0,                  # 0..1 Transitionsfortschritt; >=1 == statisch
	"dir": 1,
	"auto_timer": 0.0,
	"grid_zoom": false,
	"grid_zoom_t": 0.0,
	"cf_zoom": false,
	"cf_zoom_t": 0.0,
	"slide_count": 1,          # aktive Anzahl (1..N), per UI steuerbar; nach Laden gesetzt
	"slot_edit": false,        # Slot-Rahmen/Handles (Funktionalitaet folgt in Slot-Stufe)
	"slot_bg": true,           # Slot-Hintergrund deckend (Funktionalitaet folgt)
}

# Feder (smoothDamp) fuer Coverflow/Carousel — Stufe 6/7, hier schon vorhanden.
var anim_center := 0.0
var ac_vel := 0.0

# Slot-Aspect. Im Standalone aus der SubViewport-Groesse. Default 16:9.
var _aspect := 16.0 / 9.0

signal slides_changed(n: int)


func _ready() -> void:
	quad_mesh = QuadMesh.new()
	quad_mesh.size = Vector2(1, 1)  # Einheitsquad, pro Slide skaliert
	slide_shader = load("res://modules/slideshow/slide.gdshader")

	loader = SlideLoaderClass.new()
	if instance_id != "":
		loader.store_path = "user://slides_%s.json" % instance_id
	var defaults := _default_test_paths()
	loader.init_load(defaults)
	_rebuild_pool()
	_apply_aspect_from_viewport()
	_update_camera()


# Testbilder fuer den Erststart. Liegen als lose Dateien im Projekt und werden ueber
# ihren absoluten Pfad geladen (nicht als importierte Ressource), genau wie alle
# spaeter per UI geladenen Bilder. So ist der Ladepfad einheitlich.
func _default_test_paths() -> Array:
	var base := ProjectSettings.globalize_path("res://modules/slideshow/slides/")
	return [
		base + "test_16x9.png",
		base + "test_portrait.png",
		base + "test_square.png",
		base + "test_wide.png",
		base + "test_4x3.png",
	]


# --- Slide-Pool dynamisch aufbauen ---
# Anders als der Prototyp (fester Pool) wird hier bei jedem Laden neu gebaut, weil N
# sich zur Laufzeit aendert. slide_count und index werden in den gueltigen Bereich geklemmt.
func _rebuild_pool() -> void:
	for m in slide_meshes:
		if is_instance_valid(m):
			m.queue_free()
	slide_meshes.clear()
	slide_std_mats.clear()
	slide_shader_mats.clear()

	var n: int = loader.count()
	for i in range(n):
		var rec = loader.slides[i]
		var mi := MeshInstance3D.new()
		mi.mesh = quad_mesh
		var std := _make_slide_material(rec.tex)
		var shm := _make_shader_material(rec.tex, rec.img_aspect)
		slide_std_mats.append(std)
		slide_shader_mats.append(shm)
		mi.material_override = std
		mi.visible = false
		slides_root.add_child(mi)
		slide_meshes.append(mi)

	# MainPair einmalig anlegen (zwei Quads mit Shader-Material, Textur pro Frame gesetzt).
	if main_meshes.is_empty() and n > 0:
		for j in range(2):
			var mi := MeshInstance3D.new()
			mi.mesh = quad_mesh
			var shm := _make_shader_material(loader.slides[0].tex, loader.slides[0].img_aspect)
			main_shader_mats.append(shm)
			mi.material_override = shm
			mi.visible = false
			main_pair_root.add_child(mi)
			main_meshes.append(mi)

	# Zustand an neue Poolgroesse anpassen.
	state.slide_count = max(1, n)
	if state.index > nv() - 1:
		state.index = max(0, nv() - 1)
		state.from_index = state.index
		state.t = 1.0
	if anim_center > nv() - 1:
		anim_center = state.index
	emit_signal("slides_changed", n)


# Unshaded StandardMaterial3D. Transparenz-Default ist weiche Alpha, weil Slidedeck-
# Transitions (fade, zoomblur) die Opacity kontinuierlich von 0..1 fahren — Alpha-Scissor
# wuerde sie unter Schwelle 0.5 hart verschwinden lassen statt weich einzublenden.
# Die Scissor-vs-Prepass-Entscheidung der Spec (§4.2) betrifft nur die Perspektiv-Modi
# (rotierte, ueberlappende Quads). Dort wird das Material pro Modus umgestellt (Stufe 6/7).
func _make_slide_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return mat


# ShaderMaterial fuer Slidedeck/Gallery-Main: kann Fit/Crop-Remap und Zoomblur.
# Crop ohne Blur ist der billige Zweig (ein sample_fit), daher kostet der Modus nichts extra.
func _make_shader_material(tex: Texture2D, img_aspect: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = slide_shader
	mat.set_shader_parameter("u_tex", tex)
	mat.set_shader_parameter("u_opacity", 1.0)
	mat.set_shader_parameter("u_img_aspect", img_aspect)
	mat.set_shader_parameter("u_quad_aspect", img_aspect)
	mat.set_shader_parameter("u_fit", 0.0)
	mat.set_shader_parameter("u_blur", 0.0)
	return mat


# --- Aspect / Kamera ---
func _apply_aspect_from_viewport() -> void:
	var sz := sub_viewport.size
	if sz.y > 0:
		_aspect = float(sz.x) / float(sz.y)


func aspect() -> float:
	return _aspect


func is_persp() -> bool:
	return state.mode == "coverflow" or state.mode == "carousel"


func _update_camera() -> void:
	if is_persp():
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		camera.fov = FOV
		camera.keep_aspect = Camera3D.KEEP_HEIGHT
		camera.position = Vector3(0, 0, PERSP_DIST)
	else:
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 2.0
		camera.position = Vector3(0, 0, 10)
	camera.look_at(Vector3.ZERO, Vector3.UP)


# --- Modulvertrag: Index/Transition ---
func nv() -> int:
	return clampi(int(round(state.slide_count)), 1, max(1, loader.count()))


# Eigene cubic-in-out-Ease. Bewusst NICHT "ease" genannt, das ist ein globaler
# GDScript-Name (@GlobalScope.ease(value, curve)) und wuerde kollidieren.
func _ease_io(x: float) -> float:
	if x < 0.5:
		return 4.0 * x * x * x
	return 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0


func start_transition(target: int) -> bool:
	if state.t < 1.0:
		return false
	var n := nv()
	var tgt := target
	if tgt < 0:
		tgt = (n - 1) if state.loop else 0
	if tgt > n - 1:
		tgt = 0 if state.loop else (n - 1)
	if tgt == state.index:
		return false
	state.dir = 1 if target > state.index else -1
	if state.loop and target < 0:
		state.dir = -1
	if state.loop and target > n - 1:
		state.dir = 1
	state.from_index = state.index
	state.index = tgt
	state.t = 0.0
	return true


func go_to(target: int) -> bool:
	if target < 0 or target > nv() - 1:
		return false
	if target == state.index and state.t >= 1.0:
		return false
	state.from_index = state.index
	state.index = target
	state.dir = 1 if target > state.from_index else -1
	state.t = 0.0
	return true


func next() -> void:
	start_transition(state.index + 1)


func prev() -> void:
	start_transition(state.index - 1)


func set_mode(m: String) -> void:
	state.mode = m
	state.grid_zoom = false
	state.grid_zoom_t = 0.0
	state.t = 1.0
	anim_center = state.index
	ac_vel = 0.0
	_update_camera()


# --- Laden (von UI aufgerufen) ---
func load_image_paths(paths: Array) -> void:
	loader.append_paths(paths)
	_rebuild_pool()


func load_directory(dir_path: String) -> void:
	loader.append_directory(dir_path)
	_rebuild_pool()


func clear_slides() -> void:
	loader.clear()
	_rebuild_pool()


# --- Hilfen ---
func _hide_all() -> void:
	for m in slide_meshes:
		m.visible = false
	for m in main_meshes:
		m.visible = false


# --- Render-Loop ---
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_RIGHT, KEY_DOWN:
				next()
			KEY_LEFT, KEY_UP:
				prev()


func _process(delta: float) -> void:
	var dt := minf(0.05, delta)

	if state.t < 1.0:
		state.t = minf(1.0, state.t + dt / maxf(0.05, state.transition_time))

	# Grid-Zoom (exponentieller Approach, nicht die kubische Ease).
	var z_target := 1.0 if state.grid_zoom else 0.0
	state.grid_zoom_t += (z_target - state.grid_zoom_t) * minf(1.0, dt / maxf(0.05, state.transition_time))
	if absf(state.grid_zoom_t - z_target) < 0.001:
		state.grid_zoom_t = z_target

	# Coverflow/Carousel-Fullscreen.
	var cf_target := 1.0 if state.cf_zoom else 0.0
	state.cf_zoom_t += (cf_target - state.cf_zoom_t) * minf(1.0, dt / maxf(0.05, state.transition_time))
	if absf(state.cf_zoom_t - cf_target) < 0.001:
		state.cf_zoom_t = cf_target

	# Auto-Run.
	if state.auto_run and state.t >= 1.0 and not state.grid_zoom and not state.cf_zoom:
		state.auto_timer += dt
		if state.auto_timer >= state.auto_run_seconds:
			state.auto_timer = 0.0
			next()
	elif state.t < 1.0:
		state.auto_timer = 0.0

	# Kritisch gedaempfte Feder fuer anim_center (nur Perspektiv-Modi).
	if is_persp():
		var n := nv()
		var target := float(state.index)
		if state.loop:
			var d := target - anim_center
			while d > n / 2.0:
				target -= n
				d = target - anim_center
			while d < -n / 2.0:
				target += n
				d = target - anim_center
		var smooth_time := maxf(0.07, state.transition_time * 0.38)
		var om := 2.0 / smooth_time
		var x := om * dt
		var expo := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
		var chg := anim_center - target
		var tmp := (ac_vel + om * chg) * dt
		ac_vel = (ac_vel - om * tmp) * expo
		anim_center = target + (chg + tmp) * expo
		if absf(anim_center - target) < 0.004 and absf(ac_vel) < 0.05:
			anim_center = state.index
			ac_vel = 0.0
		if state.loop:
			if anim_center < 0:
				anim_center += n
			if anim_center >= n:
				anim_center -= n

	_layout()


func _layout() -> void:
	_apply_aspect_from_viewport()
	match state.mode:
		"gallery":
			_layout_gallery()
		"grid":
			_layout_grid()
		"coverflow":
			_layout_coverflow()
		"carousel":
			_layout_carousel()
		_:
			_layout_slidedeck()


# --- Slidedeck (ortho) ---
# Nutzt das Shader-Material (Fit/Crop-Remap + Blur). Quad-Aspekt ist der Slot-Aspekt,
# das Bild wird per uFit ein- oder beschnitten.
func _place_deck(idx: int, x: float, y: float, opacity: float, scl: float, z: float, blur: float) -> void:
	if idx < 0 or idx >= slide_meshes.size():
		return
	var m: MeshInstance3D = slide_meshes[idx]
	m.visible = true
	var full_w := 2.0 * _aspect
	m.position = Vector3(x, y, z)
	m.rotation = Vector3.ZERO
	m.scale = Vector3(full_w * scl, 2.0 * scl, 1.0)
	var mat: ShaderMaterial = slide_shader_mats[idx]
	m.material_override = mat
	mat.set_shader_parameter("u_quad_aspect", _aspect)
	mat.set_shader_parameter("u_img_aspect", loader.slides[idx].img_aspect)
	mat.set_shader_parameter("u_fit", float(state.fit))
	mat.set_shader_parameter("u_opacity", opacity)
	mat.set_shader_parameter("u_blur", blur)


func _layout_slidedeck() -> void:
	_hide_all()
	if loader.count() == 0:
		return
	var full_w := 2.0 * _aspect
	var tt := _ease_io(state.t)
	var cur: int = state.index
	var prv: int = state.from_index
	var moving: bool = float(state.t) < 1.0 and cur != prv

	if not moving:
		_place_deck(cur, 0, 0, 1, 1, 0.1, 0)
		return

	var d := float(state.dir)
	var tri := 1.0 - absf(2.0 * tt - 1.0)
	match state.transition:
		"swipeH":
			_place_deck(prv, -d * full_w * tt, 0, 1, 1, 0, 0)
			_place_deck(cur, d * full_w * (1.0 - tt), 0, 1, 1, 0.1, 0)
		"swipeV":
			_place_deck(prv, 0, d * 2.0 * tt, 1, 1, 0, 0)
			_place_deck(cur, 0, -d * 2.0 * (1.0 - tt), 1, 1, 0.1, 0)
		"push":
			_place_deck(prv, -d * full_w * tt, 0, 1, 1, 0, tri * 1.4)
			_place_deck(cur, d * full_w * (1.0 - tt), 0, 1, 1, 0.1, tri * 1.4)
		"fade":
			_place_deck(prv, 0, 0, 1, 1, 0.0, 0)
			_place_deck(cur, 0, 0, tt, 1, 0.1, 0)
		"zoomblur":
			_place_deck(prv, 0, 0, 1, 1.0 + 0.10 * tt, 0.0, tt * 2.2)
			_place_deck(cur, 0, 0, tt, 1.12 - 0.12 * tt, 0.1, (1.0 - tt) * 2.2)
		"fx":
			_place_deck(prv, 0, 0, 1, 1, 0.0, 0)
			_place_deck(cur, 0, 0, tt, 1.28 - 0.28 * tt, 0.1, 0)
		_:
			_place_deck(prv, 0, 0, 1, 1, 0.0, 0)
			_place_deck(cur, 0, 0, tt, 1, 0.1, 0)


# --- Stubs fuer Folgestufen ---
func _layout_gallery() -> void:
	_layout_slidedeck()  # Stufe 5

func _layout_grid() -> void:
	_layout_slidedeck()  # Stufe 4

func _layout_coverflow() -> void:
	_layout_slidedeck()  # Stufe 6

func _layout_carousel() -> void:
	_layout_slidedeck()  # Stufe 7
