extends Node3D
## Tunnel / Light-Streaks - ported from studio-v002 createTunnelModule().
## CPU updates Z positions + builds ImmediateMesh geometry each frame.

@export_group("Flight")
@export var speed: float = 90.0
@export var streak_length: float = 1.0
@export var swirl: float = 0.0
@export var drift_angle: float = 0.0
@export var drift_amount: float = 0.0

@export_group("Distribution")
@export var particle_count: int = 2200
@export var radius: float = 70.0

@export_group("Colors")
@export var color_far: Color = Color(0.039, 0.102, 0.227, 1)
@export var color_mid: Color = Color(0.227, 0.627, 1.0, 1)
@export var color_near: Color = Color(1.0, 1.0, 1.0, 1)

@export_group("Appearance")
@export var opacity: float = 0.9
@export var head_glow: float = 1.0

const NMAX: int = 6000
const Z_NEAR: float = 2.0
const Z_FAR: float = 400.0

var _pz: PackedFloat32Array
var _pang: PackedFloat32Array
var _prad: PackedFloat32Array
var _pseed: PackedFloat32Array

var _streak_mesh: ImmediateMesh
var _head_mesh: ImmediateMesh

@onready var _camera: Camera3D = $Camera3D
@onready var _streaks: MeshInstance3D = $Streaks
@onready var _heads: MeshInstance3D = $Heads

func _ready() -> void:
	_pz = PackedFloat32Array(); _pz.resize(NMAX)
	_pang = PackedFloat32Array(); _pang.resize(NMAX)
	_prad = PackedFloat32Array(); _prad.resize(NMAX)
	_pseed = PackedFloat32Array(); _pseed.resize(NMAX)
	for i in range(NMAX):
		_spawn(i, true)
	_streak_mesh = ImmediateMesh.new()
	_head_mesh = ImmediateMesh.new()
	_streaks.mesh = _streak_mesh
	_heads.mesh = _head_mesh
	var big_aabb := AABB(Vector3(-200.0, -200.0, -410.0), Vector3(400.0, 400.0, 820.0))
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

func _process(delta: float) -> void:
	_simulate(minf(delta, 0.05))
	if drift_amount > 0.0:
		_camera.look_at(
			Vector3(sin(drift_angle) * drift_amount,
				-cos(drift_angle) * drift_amount,
				-100.0),
			Vector3.UP)

func _simulate(dt: float) -> void:
	_streak_mesh.clear_surfaces()
	_head_mesh.clear_surfaces()
	_streak_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_head_mesh.surface_begin(Mesh.PRIMITIVE_POINTS)
	var n := mini(NMAX, particle_count)
	for i in range(n):
		_pz[i] -= speed * dt
		if swirl != 0.0:
			_pang[i] += swirl * dt * (1.0 - _pz[i] / Z_FAR) * 0.5
		if _pz[i] <= Z_NEAR:
			_spawn(i, false)
			continue
		var z: float = _pz[i]
		var x: float = cos(_pang[i]) * _prad[i]
		var y: float = sin(_pang[i]) * _prad[i]
		var near_t: float = 1.0 - z / Z_FAR
		var len: float = minf(z - Z_NEAR,
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
		_streak_mesh.surface_set_color(fc)
		_streak_mesh.surface_add_vertex(Vector3(x, y, -z))
		_streak_mesh.surface_set_color(bc)
		_streak_mesh.surface_add_vertex(Vector3(x, y, -(z + len)))
		var ha: float = minf(1.0, near_t * 1.2) * head_glow * opacity
		_head_mesh.surface_set_color(Color(fc.r, fc.g, fc.b, ha))
		_head_mesh.surface_add_vertex(Vector3(x, y, -z))
	_streak_mesh.surface_end()
	_head_mesh.surface_end()
