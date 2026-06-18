extends Node3D
## Tunnel / Light-Streaks - ported from studio-v002 createTunnelModule().
## CPU updates Z positions + builds ImmediateMesh geometry each frame.

@export_group("Flight")
@export_range(0.0, 300.0, 1.0) var speed: float = 90.0
@export_range(0.0, 5.0, 0.05) var streak_length: float = 1.0
@export_range(-3.0, 3.0, 0.05) var swirl: float = 0.0
@export_range(0.0, 6.283, 0.01) var drift_angle: float = 0.0
@export_range(0.0, 50.0, 0.1) var drift_amount: float = 0.0

@export_group("Distribution")
@export_range(0, 6000, 1) var particle_count: int = 2200
@export_range(5.0, 150.0, 1.0) var radius: float = 70.0

# Colors now come globally from STYLE (fog_color/elem_a/elem_b) instead of
# per-scene @exports. Convention as in the web studio: c1=Fog, c2=elemA, c3=elemB
# (studio-v005.html:356). Read per frame in _simulate() from the Style autoload
# (cheap) and mixed into vertex colors on the CPU side.

@export_group("Appearance")
@export_range(0.0, 1.5, 0.01) var opacity: float = 0.9
@export_range(0.0, 3.0, 0.01) var head_glow: float = 1.0

@export_group("Camera")
@export_range(-180.0, 180.0, 1.0) var cam_roll: float = 0.0
@export_range(-60.0, 60.0, 0.5) var cam_pitch: float = 0.0
@export_range(-60.0, 60.0, 0.5) var cam_yaw: float = 0.0
@export_range(30.0, 110.0, 1.0) var cam_fov: float = 70.0

const NMAX: int = 6000
const Z_NEAR: float = 2.0
const Z_FAR: float = 400.0

var _pz: PackedFloat32Array
var _pang: PackedFloat32Array
var _prad: PackedFloat32Array
var _pseed: PackedFloat32Array

# Width factor (aspect/16:9): stretches the horizontal (X) extent of the radial
# streak distribution so the tube fills the width on wide/wall resolutions
# instead of clustering in the center. Only X is scaled (Y/Z stay), distribution is
# computed per frame from _pang/_prad -> no re-seed needed.
var _wfac: float = 1.0

# Batched geometry buffers. Instead of per-vertex surface_* calls (up to ~12000
# scripting boundary calls/frame) we fill persistent packed arrays and
# upload them once per mesh via ArrayMesh.add_surface_from_arrays — exactly
# the pattern from plexus_sim.gd _upload_meshes().
var _streak_mesh: ArrayMesh
var _head_mesh: ArrayMesh
var _sp: PackedVector3Array       # streak vertex positions (2 per particle)
var _sc: PackedColorArray         # streak vertex colours
var _hp: PackedVector3Array       # head positions (1 per particle)
var _hc: PackedColorArray         # head colours

@onready var _camera: Camera3D = $Camera3D
@onready var _streaks: MeshInstance3D = $Streaks
@onready var _heads: MeshInstance3D = $Heads

func _ready() -> void:
	_pz = PackedFloat32Array(); _pz.resize(NMAX)
	_pang = PackedFloat32Array(); _pang.resize(NMAX)
	_prad = PackedFloat32Array(); _prad.resize(NMAX)
	_pseed = PackedFloat32Array(); _pseed.resize(NMAX)
	var stage := get_node_or_null("/root/BackgroundStage")
	_wfac = stage.width_factor() if stage else 1.0
	if stage:
		stage.aspect_changed.connect(_on_aspect_changed)
	for i in range(NMAX):
		_spawn(i, true)
	# Size persistent buffers once to NMAX (streaks: 2 vertices/
	# particle). Upload sliced later to the actually filled length.
	_sp = PackedVector3Array(); _sp.resize(NMAX * 2)
	_sc = PackedColorArray();   _sc.resize(NMAX * 2)
	_hp = PackedVector3Array(); _hp.resize(NMAX)
	_hc = PackedColorArray();   _hc.resize(NMAX)
	_streak_mesh = ArrayMesh.new()
	_head_mesh = ArrayMesh.new()
	_streaks.mesh = _streak_mesh
	_heads.mesh = _head_mesh
	# X half-extent widened by _wfac so the horizontally stretched distribution is
	# not culled on wide resolutions.
	var hx := 200.0 * maxf(1.0, _wfac)
	var big_aabb := AABB(Vector3(-hx, -200.0, -410.0), Vector3(hx * 2.0, 400.0, 820.0))
	_streaks.custom_aabb = big_aabb
	_heads.custom_aabb = big_aabb

func _spawn(i: int, spread: bool) -> void:
	if spread:
		_pz[i] = Z_NEAR + randf() * (Z_FAR - Z_NEAR)
	else:
		_pz[i] = Z_FAR * 0.5 + randf() * Z_FAR * 0.5
	_pang[i] = randf() * TAU
	_prad[i] = (0.15 + randf() * 0.85) * radius
	_pseed[i] = randf()

# Aspect change: only store the width factor. X positions are recomputed in the
# next _simulate() from _pang/_prad * _wfac -> smooth transition, no re-seed.
func _on_aspect_changed(aspect: float) -> void:
	_wfac = aspect / (16.0 / 9.0)


func _process(delta: float) -> void:
	_simulate(minf(delta, 0.05))
	_update_camera()


func _update_camera() -> void:
	var target_x := tan(deg_to_rad(cam_yaw)) * 100.0
	var target_y := tan(deg_to_rad(cam_pitch)) * -100.0
	if drift_amount > 0.0:
		target_x += sin(drift_angle) * drift_amount
		target_y -= cos(drift_angle) * drift_amount
	var roll_rad := deg_to_rad(cam_roll)
	_camera.look_at(
		Vector3(target_x, target_y, -100.0),
		Vector3(sin(roll_rad), cos(roll_rad), 0.0))
	_camera.fov = cam_fov

func _simulate(dt: float) -> void:
	if speed <= 0.0:
		_upload_meshes(0)
		return
	# Colors centrally from STYLE (far/valley -> near/highlight).
	var color_far: Color = Style.get_color("fog_color")
	var color_mid: Color = Style.get_color("elem_a")
	var color_near: Color = Style.get_color("elem_b")
	var n := mini(NMAX, particle_count)
	# Running write index: respawned particles (continue) emit no
	# vertices, so the filled length is variable (<= n). si counts the
	# actually written streak/head particles — like plexus's li.
	var si := 0
	for i in range(n):
		_pz[i] -= speed * dt
		if swirl != 0.0:
			_pang[i] += swirl * dt * (1.0 - _pz[i] / Z_FAR) * 0.5
		if _pz[i] <= Z_NEAR:
			_spawn(i, false)
			continue
		var z: float = _pz[i]
		# Only stretch X with the width factor -> radial distribution is pulled wide
		# on wide resolutions, Y stays unchanged.
		var x: float = cos(_pang[i]) * _prad[i] * _wfac
		var y: float = sin(_pang[i]) * _prad[i]
		var near_t: float = 1.0 - z / Z_FAR
		var streak_len: float = minf(z - Z_NEAR,
			speed * dt * streak_length * (1.0 + near_t * 6.0))
		var col: Color
		if near_t < 0.5:
			col = color_far.lerp(color_mid, near_t * 2.0)
		else:
			col = color_mid.lerp(color_near, (near_t - 0.5) * 2.0)
		var br: float = 0.35 + _pseed[i] * 0.4 + near_t * 0.6
		var a_front: float = minf(1.0, 0.3 + near_t) * opacity
		var fc := Color(col.r * br, col.g * br, col.b * br, a_front)
		var bc := Color(col.r * br * 0.2, col.g * br * 0.2, col.b * br * 0.2, 0.0)
		# Streak: write front vertex (fc) + back vertex (bc) into the buffers.
		var b := si * 2
		_sp[b] = Vector3(x, y, -z)
		_sc[b] = fc
		_sp[b + 1] = Vector3(x, y, -(z + streak_len))
		_sc[b + 1] = bc
		var ha: float = minf(1.0, near_t * 1.2) * head_glow * opacity
		_hp[si] = Vector3(x, y, -z)
		_hc[si] = Color(fc.r, fc.g, fc.b, ha)
		si += 1
	_upload_meshes(si)

func _upload_meshes(si: int) -> void:
	# Single upload per mesh instead of per-vertex calls (mirrors plexus_sim.gd
	# _upload_meshes). Upload only the filled slice; skip the zero-vertex case
	# after clear_surfaces.
	_streak_mesh.clear_surfaces()
	if si > 0:
		var arrs: Array = []
		arrs.resize(Mesh.ARRAY_MAX)
		arrs[Mesh.ARRAY_VERTEX] = _sp.slice(0, si * 2)
		arrs[Mesh.ARRAY_COLOR]  = _sc.slice(0, si * 2)
		_streak_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrs)
	_head_mesh.clear_surfaces()
	if si > 0:
		var harrs: Array = []
		harrs.resize(Mesh.ARRAY_MAX)
		harrs[Mesh.ARRAY_VERTEX] = _hp.slice(0, si)
		harrs[Mesh.ARRAY_COLOR]  = _hc.slice(0, si)
		_head_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, harrs)
