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

# Klick-Ziele fuer Grid/Gallery: [{idx:int, rect:Rect2}] in Viewport-Pixeln. Pro Frame
# aus der Kamera-Projektion neu berechnet; vom Overlay fuer Picking gelesen.
var pick_targets: Array = []

# Slot-Aspect. Im Standalone aus der SubViewport-Groesse. Default 16:9.
var _aspect := 16.0 / 9.0

# Idle-render throttle: a static slide does not need its SubViewport re-rendered every
# frame. While nothing is animating, the viewport is set to UPDATE_DISABLED (the last
# rendered frame stays on screen). _wake() re-arms it on any change (navigation, mode,
# pool rebuild, slot resize). This is the main per-frame GPU saving with several
# slideshow slots on screen at once.
var _idle_frames := 0
var _last_size := Vector2i.ZERO

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
	_wake()


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
	if state.t < 1.0 and not is_persp():
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
	_wake()
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
	_wake()
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
	_wake()


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


# Re-arm the SubViewport so the next frames render again (after any visible change).
func _wake() -> void:
	_idle_frames = 0
	render_target_update_mode = SubViewport.UPDATE_ALWAYS


# True while any visible motion is in progress (slide transition, grid/coverflow zoom,
# or the perspective spring). Auto-run is intentionally NOT included: the hold between
# slides is static, and the auto_timer (advanced in _process regardless of render mode)
# calls next() -> _wake() when it fires.
func _is_animating() -> bool:
	if state.t < 1.0:
		return true
	if state.grid_zoom or absf(state.grid_zoom_t) > 0.001:
		return true
	if state.cf_zoom or absf(state.cf_zoom_t) > 0.001:
		return true
	if is_persp():
		if absf(anim_center - float(state.index)) > 0.004 or absf(ac_vel) > 0.05:
			return true
	return false


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

	# Slot was resized (reflow / aspect change) -> content must re-fit, so render again.
	if size != _last_size:
		_last_size = size
		_wake()

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
	var _spring_done := not is_persp() or (absf(anim_center - float(state.index)) < 0.1 and absf(ac_vel) < 0.1)
	if state.auto_run and state.t >= 1.0 and not state.grid_zoom and not state.cf_zoom and _spring_done:
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

	# Throttle: only render this slot's viewport while something is animating. When
	# static, render two settle frames (so the final image is in the texture) then stop
	# updating until _wake() re-arms it. Main per-frame saving with multiple slots.
	if _is_animating():
		_idle_frames = 0
		render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_layout()
	elif _idle_frames < 2:
		_idle_frames += 1
		render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_layout()
	elif render_target_update_mode != SubViewport.UPDATE_DISABLED:
		render_target_update_mode = SubViewport.UPDATE_DISABLED


func _layout() -> void:
	_apply_aspect_from_viewport()
	pick_targets.clear()
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


# --- Helpers fuer die uebrigen Modi ---
# Karte mit StandardMaterial3D (bildgenaues Seitenverhaeltnis), Hoehe in Welt-Einheiten,
# Breite aus dem Bildaspekt. Opacity ueber albedo-Alpha (Material ist ALPHA-transparent).
func _place_card(idx: int, pos: Vector3, rot: Vector3, height: float, opacity: float) -> void:
	if idx < 0 or idx >= slide_meshes.size():
		return
	var m: MeshInstance3D = slide_meshes[idx]
	m.visible = true
	var ia: float = loader.slides[idx].img_aspect
	m.position = pos
	m.rotation = rot
	m.scale = Vector3(height * ia, height, 1.0)
	var mat: StandardMaterial3D = slide_std_mats[idx]
	m.material_override = mat
	mat.albedo_color = Color(1, 1, 1, clampf(opacity, 0.0, 1.0))


# Klick-Ziel (Viewport-Pixel-Rect) eines achsenparallelen Quads ueber die Kamera-Projektion.
func _push_pick(idx: int, pos: Vector3, w: float, h: float) -> void:
	var hw := w * 0.5
	var hh := h * 0.5
	var a := camera.unproject_position(Vector3(pos.x - hw, pos.y + hh, pos.z))
	var b := camera.unproject_position(Vector3(pos.x + hw, pos.y - hh, pos.z))
	pick_targets.append({"idx": idx, "rect": Rect2(a, b - a).abs()})


# --- Interaktion (vom Overlay aufgerufen) ---
# Grid: MB1 halten -> ausgewaehltes Bild in den Slot zoomen; loslassen -> zurueck.
func grid_press(idx: int) -> void:
	if idx < 0 or idx >= nv():
		return
	state.index = idx
	state.from_index = idx
	state.t = 1.0
	state.grid_zoom = true
	_wake()


func grid_release() -> void:
	state.grid_zoom = false
	_wake()


# Grosses Hauptbild der Gallery ueber eines der beiden MainPair-Quads (Crossfade).
func _place_main(slot: int, tex_idx: int, pos: Vector3, height: float, opacity: float) -> void:
	if slot < 0 or slot >= main_meshes.size() or tex_idx < 0 or tex_idx >= loader.count():
		return
	var m: MeshInstance3D = main_meshes[slot]
	m.visible = true
	var ia: float = loader.slides[tex_idx].img_aspect
	m.position = pos
	m.rotation = Vector3.ZERO
	m.scale = Vector3(height * ia, height, 1.0)
	var mat: ShaderMaterial = main_shader_mats[slot]
	m.material_override = mat
	mat.set_shader_parameter("u_tex", loader.slides[tex_idx].tex)
	mat.set_shader_parameter("u_img_aspect", ia)
	mat.set_shader_parameter("u_quad_aspect", ia)
	mat.set_shader_parameter("u_fit", float(state.fit))
	mat.set_shader_parameter("u_opacity", clampf(opacity, 0.0, 1.0))
	mat.set_shader_parameter("u_blur", 0.0)


# --- Gallery (ortho): grosses Hauptbild + Thumbnail-Streifen unten ---
func _layout_gallery() -> void:
	_hide_all()
	var n := nv()
	if loader.count() == 0 or n <= 0:
		return
	var tt := _ease_io(state.t)
	var cur: int = state.index
	var prv: int = state.from_index
	var moving: bool = state.t < 1.0 and cur != prv

	var main_h := 1.42
	var main_y := 0.26
	if moving:
		_place_main(0, prv, Vector3(0, main_y, 0.0), main_h, 1.0 - tt)
		_place_main(1, cur, Vector3(0, main_y, 0.1), main_h, tt)
	else:
		_place_main(0, cur, Vector3(0, main_y, 0.1), main_h, 1.0)

	# Thumbnail-Streifen unten, bildgenau, aktuelles groesser + heller.
	var th := 0.34
	var gap := 0.07
	var y := -0.82
	var total := 0.0
	var ws: Array = []
	for i in range(n):
		var w: float = th * float(loader.slides[i].img_aspect)
		ws.append(w)
		total += w
	total += gap * float(maxi(0, n - 1))
	var x := -total / 2.0
	for i in range(n):
		var w: float = ws[i]
		var sel: bool = i == cur
		var h := th * (1.18 if sel else 1.0)
		var cx := x + w / 2.0
		_place_card(i, Vector3(cx, y, 0.2 if sel else 0.05), Vector3.ZERO, h, 1.0 if sel else 0.66)
		_push_pick(i, Vector3(cx, y, 0.0), h * float(loader.slides[i].img_aspect), h)
		x += w + gap


# --- Grid (ortho): gleichmaessiges Raster, aktuelles hervorgehoben ---
func _layout_grid() -> void:
	_hide_all()
	var n := nv()
	if loader.count() == 0 or n <= 0:
		return
	var cols := int(ceil(sqrt(float(n))))
	cols = maxi(1, cols)
	var rows := int(ceil(float(n) / float(cols)))
	var vw := 2.0 * _aspect
	var vh := 2.0
	var pad := 0.05
	var cellw := (vw - pad * float(cols + 1)) / float(cols)
	var cellh := (vh - pad * float(rows + 1)) / float(rows)
	var z: float = state.grid_zoom_t  # 0..1 Fokus-Zoom (optional)
	for i in range(n):
		var c := i % cols
		var r := i / cols
		var cx := -vw / 2.0 + pad + cellw * (float(c) + 0.5) + pad * float(c)
		var cy := vh / 2.0 - pad - cellh * (float(r) + 0.5) - pad * float(r)
		var ia: float = loader.slides[i].img_aspect
		var ch := minf(cellh, cellw / ia)
		var op := 1.0
		var sel: bool = i == state.index
		if z > 0.001:
			if sel:
				# Fit the whole image into the slot (keep aspect).
				var fit_h := minf(vh, vw / ia)
				cx = lerpf(cx, 0.0, z)
				cy = lerpf(cy, 0.0, z)
				ch = lerpf(ch, fit_h, z)
			else:
				op = 1.0 - z
		elif sel:
			ch *= 1.06
		_place_card(i, Vector3(cx, cy, 0.1 if sel else 0.0), Vector3.ZERO, ch, op)
		_push_pick(i, Vector3(cx, cy, 0.0), ch * ia, ch)


# --- Coverflow (persp): zentrales Slide + bis zu 2 Nachbarn je Seite ---
# Portiert 1:1 aus slideshow-overlay-poc_19.html (layoutCoverflow). Sichtbare Nachbarn
# (SIDE_MAX) und Spread sind adaptiv zum Slot-Aspekt; das ganze Arrangement wird so
# geschrumpft, dass der breiteste projizierte Slide-Rand in die halbe Slot-Breite passt.
func _layout_coverflow() -> void:
	_hide_all()
	var n := nv()
	if loader.count() == 0 or n <= 0:
		return
	var aspect := _aspect
	var side_max := (1.0 if aspect < 0.8 else (1.5 if aspect < 1.2 else 2.0))
	var spread_f := (0.42 if aspect < 0.8 else (0.50 if aspect < 1.2 else 0.60))
	var base_h := 2.0 * 0.78
	var base_w := base_h * SLIDE_ASPECT
	if base_h > 2.0 * 0.82:
		base_h = 2.0 * 0.82
		base_w = base_h * SLIDE_ASPECT
	# Finaler Fit: ueber die sichtbaren a-Werte den breitesten projizierten Rand finden
	# und das GANZE Arrangement passend schrumpfen.
	var worst := 0.0
	var a := 1.0
	while a <= side_max + 0.5 + 0.001:
		worst = maxf(worst, _cf_ndc_right(a, base_w, spread_f, aspect))
		a += 0.5
	var limit := 0.98
	if worst > limit:
		var k := limit / worst
		base_w *= k
		base_h *= k
	var spread := base_w * spread_f
	for i in range(n):
		var off := float(i) - anim_center
		if state.loop:
			while off > float(n) / 2.0: off -= float(n)
			while off < -float(n) / 2.0: off += float(n)
		var aa := absf(off)
		if aa > side_max + 0.6:
			continue
		var sgn := (-1.0 if off < 0.0 else 1.0)
		var x := sgn * (minf(aa, 1.0) * spread + (((aa - 1.0) * spread * 0.6) if aa > 1.0 else 0.0))
		var z := -minf(aa, 3.0) * 0.5
		var ry := -sgn * minf(aa, 1.0) * 0.85
		var sc := maxf(0.6, 1.0 - 0.16 * aa)
		# Tiefenstaffelung + weiches Ausblenden des aeussersten Slides.
		var dim := 1.0 - minf(1.0, aa) * 0.32 - maxf(0.0, aa - 1.0) * 0.14
		var fade_start := maxf(0.6, side_max - 0.4)
		var fade_out := maxf(0.0, 1.0 - maxf(0.0, aa - fade_start) / 0.8)
		var op := maxf(0.0, dim * fade_out)
		_place_card(i, Vector3(x, 0, z), Vector3(0, ry, 0), base_h * sc, op)


# Projizierter (perspektivischer) Bildrand der aeussersten Ecke eines Slides bei "abstand" a,
# normalisiert auf die halbe Slot-Breite (NDC). Genau wie ndcRight() im HTML.
func _cf_ndc_right(a: float, base_w: float, spread_f: float, aspect: float) -> float:
	var pos_x := minf(a, 1.0) * base_w * spread_f + (((a - 1.0) * base_w * spread_f * 0.6) if a > 1.0 else 0.0)
	var scl := maxf(0.6, 1.0 - 0.16 * a)
	var cz := -minf(a, 3.0) * 0.5
	var ry := -minf(a, 1.0) * 0.85
	var hw := base_w * scl / 2.0
	var tanh := tan(deg_to_rad(FOV) / 2.0)
	var worst := 0.0
	for s in [-1.0, 1.0]:
		var wx: float = pos_x + s * hw * cos(ry)
		var wz: float = cz - s * hw * sin(ry)
		var half_w: float = (PERSP_DIST - wz) * tanh * aspect
		worst = maxf(worst, absf(wx) / half_w)
	return worst


# --- Carousel (persp): Ring aus Karten, vorderste frontal ---
# Portiert 1:1 aus slideshow-overlay-poc_19.html (layoutCarousel). Feste Winkel-Luecke
# zwischen Slide-Kanten; Radius wird geloest, sodass alle Segmente + Luecken den Vollkreis
# fuellen, dann auf Slot-Breite geschrumpft.
func _layout_carousel() -> void:
	_hide_all()
	var n := nv()
	if loader.count() == 0 or n <= 0:
		return
	var aspect := _aspect
	# Einzelner Slide: kein Ring, zentral darstellen (echtes Seitenverhaeltnis).
	if n == 1:
		var iw0: float = loader.slides[0].img_aspect
		var bh1 := 2.0 * 0.82
		var bw1 := bh1 * iw0
		var maxw1 := 2.0 * aspect * 0.92
		if bw1 > maxw1:
			bw1 = maxw1
			bh1 = bw1 / iw0
		_place_card(0, Vector3.ZERO, Vector3.ZERO, bh1, 1.0)
		return
	var base_h := 2.0 * 0.82
	var max_w := 2.0 * aspect * 0.56
	var widest := 0.0
	for i in range(n):
		widest = maxf(widest, float(loader.slides[i].img_aspect))
	if base_h * widest > max_w:
		base_h = max_w / widest
	var gap_ang := 0.13
	# Mindestradius (Slides nicht groesser als der Ring) -> bei 2-3 Slides kein Kollaps.
	var R := maxf(base_h * 1.3, _carousel_solve_r(n, base_h, gap_ang))
	var ad := _carousel_build_angles(n, base_h, R, gap_ang)
	var ang: Array = ad.ang
	var span: float = ad.span
	# centerAng EINMAL aus dem Start-Layout (wie const im HTML) — Fit-Schleife aktualisiert
	# ang/span, aber nicht centerAng.
	var center_ang := _carousel_ang_at(ang, span, anim_center, n)
	for _it in range(60):
		var worst := 0.0
		for i in range(n):
			var w: float = ang[i] - center_ang
			worst = maxf(worst, _carousel_ndc_right_at(w, float(loader.slides[i].img_aspect), R, base_h, aspect))
		if worst <= 0.98:
			break
		var k := 0.98 / worst
		base_h *= k
		R = maxf(base_h * 1.3, _carousel_solve_r(n, base_h, gap_ang))
		ad = _carousel_build_angles(n, base_h, R, gap_ang)
		ang = ad.ang
		span = ad.span
	var rot := _carousel_ang_at(ang, span, anim_center, n)
	for i in range(n):
		var w: float = ang[i] - rot
		while w > PI: w -= TAU
		while w < -PI: w += TAU
		var iw: float = loader.slides[i].img_aspect
		var x := sin(w) * R
		var z := cos(w) * R - R
		var facing := cos(w)
		var op := (1.0 if facing >= 0.0 else 0.32)
		_place_card(i, Vector3(x, 0, z), Vector3(0, w, 0), base_h, op)


# Summe aller Slide-Winkelsegmente + Luecken bei Radius R.
func _carousel_total_angle(n: int, base_h: float, R: float, gap_ang: float) -> float:
	var s := 0.0
	for i in range(n):
		s += 2.0 * asin(minf(0.999, (base_h * float(loader.slides[i].img_aspect) / 2.0) / R)) + gap_ang
	return s


# Radius so loesen, dass alle Segmente + Luecken exakt 2π fuellen (Bisektion).
func _carousel_solve_r(n: int, base_h: float, gap_ang: float) -> float:
	var lo := base_h * 0.5
	var hi := base_h * 300.0
	for _it in range(80):
		var mid := (lo + hi) / 2.0
		if _carousel_total_angle(n, base_h, mid, gap_ang) > TAU:
			lo = mid
		else:
			hi = mid
	return (lo + hi) / 2.0


# Absolute Winkelposition (Mitte) jedes Slides auf dem Ring + Gesamtspanne.
func _carousel_build_angles(n: int, base_h: float, R: float, gap_ang: float) -> Dictionary:
	var half_a: Array = []
	for i in range(n):
		half_a.append(asin(minf(0.999, (base_h * float(loader.slides[i].img_aspect) / 2.0) / R)))
	var ang: Array = []
	var acc := 0.0
	for i in range(n):
		ang.append(acc + half_a[i])
		acc += 2.0 * half_a[i] + gap_ang
	return {"ang": ang, "span": acc}


# Winkelposition fuer (fraktionalen) anim_center: linear zwischen den Slide-Winkeln.
func _carousel_ang_at(ang: Array, span: float, ac: float, n: int) -> float:
	var i0 := int(floor(ac))
	var f := ac - float(i0)
	var a0: float = ang[((i0 % n) + n) % n]
	var a1: float = ang[(((i0 + 1) % n) + n) % n]
	var d := a1 - a0
	if d < 0.0:
		d += span
	return a0 + d * f


# Projizierter Bildrand eines Slides bei Ringwinkel w (Perspektive), NDC.
func _carousel_ndc_right_at(w: float, iw: float, R: float, base_h: float, aspect: float) -> float:
	var tanh := tan(deg_to_rad(FOV) / 2.0)
	var cx := sin(w) * R
	var cz := cos(w) * R - R
	var dx := cos(w) * base_h * iw / 2.0
	var dz := -sin(w) * base_h * iw / 2.0
	var x1 := absf((cx - dx) / ((PERSP_DIST - (cz - dz)) * tanh * aspect))
	var x2 := absf((cx + dx) / ((PERSP_DIST - (cz + dz)) * tanh * aspect))
	return maxf(x1, x2)
