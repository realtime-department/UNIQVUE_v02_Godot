extends Node3D
## Cubic — instanced cube tunnel, ported from studio-v005 createCubicModule()
## (studio-v005.html:971-1242).
##
## All 6000 cube positions/rotations are computed inside cubic_surf.gdshader and
## cubic_line.gdshader from INSTANCE_ID — no per-frame transform uploads needed.
## CPU-side: only uniform updates + ImmediateMesh for 4200 particles.
##
## Colors come from global STYLE uniforms (fog_color/elem_a/elem_b) — NO @export
## Color.  @exports are captured by ParamStore as scene/* entries.

@export_group("Welt & Flug")
@export_range(0.0, 1.5, 0.02)  var speed: float = 0.16
@export_range(-1.5, 1.5, 0.02) var rotate: float = 0.0
@export_range(8.0, 40.0, 0.5)  var tunnel_size: float = 26.5
@export_range(0.85, 1.6, 0.02) var cube_scale: float = 1.37
@export_range(0.0, 1.5, 0.02)  var cube_jitter: float = 1.50
@export_range(-1.0, 1.0, 0.02) var wall_tilt: float = 0.24

@export_group("Material")
@export var outlines: bool = true
@export_range(0.05, 1.0, 0.02) var face_light: float = 0.17
@export_range(0.0, 1.8, 0.05)  var spec: float = 0.55
@export_range(6.0, 70.0, 1.0)  var shininess: float = 38.0
@export_range(0, 180, 1)        var light_angle: int = 74
@export_range(0.0, 1.5, 0.02)  var edge_glow: float = 0.48
@export_range(0.2, 1.5, 0.05)  var opacity: float = 1.0

@export_group("Partikel")
@export_range(0.0, 3.0, 0.05) var particles: float = 3.0
@export_range(0, 4)            var shape: int = 0

@export_group("Tiefe & Fog")
@export_range(60.0, 1200.0, 20.0) var fog_start: float = 140.0
@export_range(0.0, 2.0, 0.05)     var fog_density: float = 1.10

@export_group("Kamera")
@export_range(35.0, 110.0, 1.0) var cam_fov: float = 62.0
@export_range(-180.0, 180.0, 1.0) var cam_roll: float = 0.0
@export_range(0.0, 8.0, 0.2)   var cam_sway: float = 0.0

const COLS := 10
const ROWS := 150
const TILES := 4 * COLS * ROWS   # 6000
const PMAX  := 4200

var _scroll: float = 0.0
var _tunnel_rot: float = 0.0
var _p_scroll: float = 0.0
var _span_z: float = 795.0
var _t: float = 0.0

var _pbase_x: PackedFloat32Array
var _pbase_y: PackedFloat32Array
var _pbase_z: PackedFloat32Array
var _pseed:   PackedFloat32Array

var _p_mesh: ImmediateMesh
var _surf_mat: ShaderMaterial
var _line_mat: ShaderMaterial
var _part_mat: ShaderMaterial

@onready var _camera: Camera3D          = $Camera3D
@onready var _surf:   MultiMeshInstance3D = $SurfMesh
@onready var _line:   MultiMeshInstance3D = $LineMesh
@onready var _points: MeshInstance3D    = $Points


func _ready() -> void:
	# Surf MultiMesh — BoxMesh, Identity transforms (positions computed in shader)
	var surf_mm := MultiMesh.new()
	surf_mm.transform_format = MultiMesh.TRANSFORM_3D
	surf_mm.instance_count   = TILES
	surf_mm.mesh             = BoxMesh.new()
	_surf.multimesh          = surf_mm

	# Line MultiMesh — unit-cube outline (12 edges)
	var line_mm := MultiMesh.new()
	line_mm.transform_format = MultiMesh.TRANSFORM_3D
	line_mm.instance_count   = TILES
	line_mm.mesh             = _make_outline_mesh()
	_line.multimesh          = line_mm

	var big := AABB(Vector3(-400.0, -400.0, -1800.0), Vector3(800.0, 800.0, 1900.0))
	_surf.custom_aabb = big
	_line.custom_aabb = big

	# Particle base positions (normalized, fixed once)
	_pbase_x = PackedFloat32Array(); _pbase_x.resize(PMAX)
	_pbase_y = PackedFloat32Array(); _pbase_y.resize(PMAX)
	_pbase_z = PackedFloat32Array(); _pbase_z.resize(PMAX)
	_pseed   = PackedFloat32Array(); _pseed.resize(PMAX)
	for i in range(PMAX):
		_pbase_x[i] = (_hsh(float(i) * 1.1 + 0.5) - 0.5) * 2.0
		_pbase_y[i] = (_hsh(float(i) * 2.2 + 0.5) - 0.5) * 2.0
		_pbase_z[i] = _hsh(float(i) * 3.3 + 0.5)
		_pseed[i]   = _hsh(float(i) * 7.7 + 0.5)

	_p_mesh        = ImmediateMesh.new()
	_points.mesh   = _p_mesh
	_points.custom_aabb = big

	_surf_mat = _surf.material_override as ShaderMaterial
	_line_mat = _line.material_override as ShaderMaterial
	_part_mat = _points.material_override as ShaderMaterial


func _hsh(n: float) -> float:
	var s := sin(n * 12.9898) * 43758.5453
	return s - floor(s)


func _make_outline_mesh() -> ArrayMesh:
	var corners := [
		Vector3(-0.5, -0.5, -0.5), Vector3( 0.5, -0.5, -0.5),
		Vector3( 0.5,  0.5, -0.5), Vector3(-0.5,  0.5, -0.5),
		Vector3(-0.5, -0.5,  0.5), Vector3( 0.5, -0.5,  0.5),
		Vector3( 0.5,  0.5,  0.5), Vector3(-0.5,  0.5,  0.5),
	]
	var edges: Array = [
		[0,1],[1,2],[2,3],[3,0],
		[4,5],[5,6],[6,7],[7,4],
		[0,4],[1,5],[2,6],[3,7],
	]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(corners[e[0]])
		verts.append(corners[e[1]])
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = verts
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrs)
	return m


func _process(delta: float) -> void:
	var dt := minf(delta, 0.05)
	_t += dt
	var cube_w := (2.0 * tunnel_size) / float(COLS)
	_span_z = cube_w * float(ROWS)
	var adv := dt * speed * 28.0
	_scroll    -= adv
	if _scroll < -_span_z: _scroll += _span_z
	_tunnel_rot += dt * rotate * 0.2
	_p_scroll = fmod(_p_scroll - adv * 1.1 / maxf(_span_z, 1.0), 1.0)
	_update_particles()
	_update_camera()
	_update_materials()


func _update_particles() -> void:
	_p_mesh.clear_surfaces()
	var n := mini(PMAX, int(float(PMAX) * (particles / 3.0)))
	if n <= 0:
		return
	var half := tunnel_size * 0.92
	_p_mesh.surface_begin(Mesh.PRIMITIVE_POINTS)
	for i in range(n):
		var zf := fmod(_pbase_z[i] + _p_scroll, 1.0)
		if zf < 0.0: zf += 1.0
		_p_mesh.surface_set_color(Color(_pseed[i], 0.0, 0.0, 1.0))
		_p_mesh.surface_add_vertex(Vector3(
			_pbase_x[i] * half,
			_pbase_y[i] * half,
			-zf * _span_z
		))
	_p_mesh.surface_end()


func _update_camera() -> void:
	var rr   := deg_to_rad(cam_roll)
	var up   := Vector3(sin(rr), cos(rr), 0.0)
	var sway := sin(_t * 0.3) * cam_sway
	_camera.position = Vector3(sway, 0.0, 0.0)
	_camera.look_at(Vector3(sway, 0.0, -100.0), up)
	_camera.fov = cam_fov


func _update_materials() -> void:
	if _surf_mat:
		_surf_mat.set_shader_parameter("tunnel_size",  tunnel_size)
		_surf_mat.set_shader_parameter("cube_scale",   cube_scale)
		_surf_mat.set_shader_parameter("cube_jitter",  cube_jitter)
		_surf_mat.set_shader_parameter("wall_tilt",    wall_tilt)
		_surf_mat.set_shader_parameter("tunnel_rot",   _tunnel_rot)
		_surf_mat.set_shader_parameter("scroll",       _scroll)
		_surf_mat.set_shader_parameter("span_z",       _span_z)
		_surf_mat.set_shader_parameter("face_light",   face_light)
		_surf_mat.set_shader_parameter("spec",         spec)
		_surf_mat.set_shader_parameter("shininess",    shininess)
		_surf_mat.set_shader_parameter("light_angle",  float(light_angle))
		_surf_mat.set_shader_parameter("opacity",      opacity)
		_surf_mat.set_shader_parameter("fog_start",    fog_start)
		_surf_mat.set_shader_parameter("fog_density",  fog_density)
	if _line_mat:
		_line_mat.set_shader_parameter("tunnel_size",  tunnel_size)
		_line_mat.set_shader_parameter("cube_scale",   cube_scale)
		_line_mat.set_shader_parameter("cube_jitter",  cube_jitter)
		_line_mat.set_shader_parameter("wall_tilt",    wall_tilt)
		_line_mat.set_shader_parameter("tunnel_rot",   _tunnel_rot)
		_line_mat.set_shader_parameter("scroll",       _scroll)
		_line_mat.set_shader_parameter("span_z",       _span_z)
		_line_mat.set_shader_parameter("glow",         edge_glow)
		_line_mat.set_shader_parameter("opacity",      opacity)
		_line_mat.set_shader_parameter("fog_start",    fog_start)
		_line_mat.set_shader_parameter("fog_density",  fog_density)
		_line.visible = outlines
	if _part_mat:
		_part_mat.set_shader_parameter("opacity",      opacity)
		_part_mat.set_shader_parameter("fog_start",    fog_start)
		_part_mat.set_shader_parameter("fog_density",  fog_density)
		_part_mat.set_shader_parameter("z_far",        _span_z)
		_part_mat.set_shader_parameter("shape",        shape)
