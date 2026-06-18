extends Node3D
## Cubic — instanced cube tunnel, faithful port of studio-v005 createCubicModule()
## (studio-v005.html:971-1242).
##
## Like the reference, every cube's transform is computed on the CPU in
## _write_matrices() (the port of writeMatrices()) and uploaded to the MultiMesh
## via set_instance_transform(); the shaders only light the instance. Particles
## are CPU-positioned points (ImmediateMesh).
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
@export_range(-180.0, 180.0, 1.0) var cam_roll: float = 0.0
@export_range(0.0, 8.0, 0.2)   var cam_sway: float = 0.0
@export_range(35.0, 110.0, 1.0) var cam_fov: float = 62.0

const COLS := 10
const ROWS := 150
const PER_WALL := COLS * ROWS    # 1500
const TILES := 4 * COLS * ROWS   # 6000
const PMAX  := 4200

var _scroll: float = 0.0
var _tunnel_rot: float = 0.0
var _p_scroll: float = 0.0
var _span_z: float = 795.0
var _t: float = 0.0

# Per-instance brightness seed, indexed by instance idx (s,c,r order).
var _seed: PackedFloat32Array

var _pbase_x: PackedFloat32Array
var _pbase_y: PackedFloat32Array
var _pbase_z: PackedFloat32Array
var _pseed:   PackedFloat32Array

var _surf_mm: MultiMesh
var _line_mm: MultiMesh

# Persistent MultiMesh buffers (16 floats/instance: 3 transform rows = 12,
# then 4 custom-data floats). Filled per frame and uploaded in ONE
# multimesh_set_buffer call per mesh instead of 6000 set_instance_transform.
var _surf_buf: PackedFloat32Array
var _line_buf: PackedFloat32Array

# Persistent particle buffers, filled by index each frame then uploaded once
# via a single add_surface_from_arrays (replaces per-vertex ImmediateMesh).
var _p_pos: PackedVector3Array
var _p_col: PackedColorArray

var _p_mesh: ArrayMesh
var _surf_mat: ShaderMaterial
var _line_mat: ShaderMaterial
var _part_mat: ShaderMaterial

@onready var _camera: Camera3D          = $Camera3D
@onready var _surf:   MultiMeshInstance3D = $SurfMesh
@onready var _line:   MultiMeshInstance3D = $LineMesh
@onready var _points: MeshInstance3D    = $Points


func _ready() -> void:
	# Surf MultiMesh — unit BoxMesh, per-instance transforms written each frame.
	_surf_mm = MultiMesh.new()
	_surf_mm.transform_format = MultiMesh.TRANSFORM_3D
	_surf_mm.use_custom_data  = true   # exposes INSTANCE_CUSTOM (seed) in shader
	_surf_mm.instance_count   = TILES
	var box := BoxMesh.new()
	box.size = Vector3.ONE             # corners at +/-0.5 (matches outline)
	_surf_mm.mesh             = box
	_surf.multimesh           = _surf_mm

	# Line MultiMesh — unit-cube outline (12 edges)
	_line_mm = MultiMesh.new()
	_line_mm.transform_format = MultiMesh.TRANSFORM_3D
	_line_mm.use_custom_data  = true
	_line_mm.instance_count   = TILES
	_line_mm.mesh             = _make_outline_mesh()
	_line.multimesh           = _line_mm

	# Persistent buffers: 16 floats/instance (12 transform + 4 custom data).
	_surf_buf = PackedFloat32Array(); _surf_buf.resize(TILES * 16)
	_line_buf = PackedFloat32Array(); _line_buf.resize(TILES * 16)

	# Per-instance seed: cellSeed[ci] with ci = s*PER_WALL + r*COLS + c
	# (the reference aSeed mapping), set once — it never changes.
	# The custom-data slots (o+12..o+15 = Color(sd,0,0,1)) are also written
	# here ONCE, since the seed never changes after setup. idx runs in
	# s->c->r order, identical to _write_matrices() below.
	_seed = PackedFloat32Array(); _seed.resize(TILES)
	var idx := 0
	for s in range(4):
		for c in range(COLS):
			for r in range(ROWS):
				var ci := s * PER_WALL + r * COLS + c
				var sd := _hsh(float(ci) * 0.7)
				_seed[idx] = sd
				# Pre-fill custom data (r,g,b,a) = (sd,0,0,1) for both buffers.
				var o := idx * 16
				_surf_buf[o + 12] = sd; _surf_buf[o + 13] = 0.0
				_surf_buf[o + 14] = 0.0; _surf_buf[o + 15] = 1.0
				_line_buf[o + 12] = sd; _line_buf[o + 13] = 0.0
				_line_buf[o + 14] = 0.0; _line_buf[o + 15] = 1.0
				idx += 1

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

	# Persistent particle ArrayMesh + buffers (filled by index, uploaded once).
	_p_pos = PackedVector3Array(); _p_pos.resize(PMAX)
	_p_col = PackedColorArray();   _p_col.resize(PMAX)
	_p_mesh        = ArrayMesh.new()
	_points.mesh   = _p_mesh
	_points.custom_aabb = big

	_surf_mat = _surf.material_override as ShaderMaterial
	_line_mat = _line.material_override as ShaderMaterial
	_part_mat = _points.material_override as ShaderMaterial

	_write_matrices()


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
	var adv := dt * speed * 28.0
	_tunnel_rot += dt * rotate * 0.2
	_scroll -= adv
	if _scroll < -_span_z: _scroll += _span_z
	if _scroll >  _span_z: _scroll -= _span_z
	_p_scroll = _p_scroll - adv * 1.1 / maxf(_span_z, 1.0)
	_p_scroll -= floor(_p_scroll)
	_write_matrices()
	_update_particles()
	_update_camera()
	_update_materials()


## Port of writeMatrices(): rebuild every cube transform on the CPU.
func _write_matrices() -> void:
	var rr := tunnel_size
	var cube_w := (2.0 * rr) / float(COLS)
	var sc := cube_w * cube_scale
	var cell_d := cube_w
	_span_z = cell_d * float(ROWS)
	var tilt := wall_tilt * 0.6
	var ct := cos(tilt)
	var st := sin(tilt)
	var z_axis := Vector3(0.0, 0.0, 1.0)
	var idx := 0
	for s in range(4):
		var ang := float(s) * PI * 0.5 + _tunnel_rot
		var ca := cos(ang)
		var sa := sin(ang)
		var rot_z := ang + tilt
		var basis := Basis(z_axis, rot_z).scaled(Vector3(sc, sc, sc))
		for c in range(COLS):
			var u := (float(c) + 0.5) / float(COLS) * 2.0 - 1.0
			var lx0 := u * rr
			for r in range(ROWS):
				var zc := fmod(float(r) * cell_d + _scroll, _span_z)
				if zc < 0.0: zc += _span_z
				var jit := (_seed[idx] - 0.5) * cube_jitter * cube_w
				var ly0 := -rr + sc * 0.5 + jit
				var dx := lx0
				var dy := ly0 - (-rr)
				var lx := ct * dx - st * dy
				var ly := (-rr) + (st * dx + ct * dy)
				var wx := lx * ca - ly * sa
				var wy := lx * sa + ly * ca
				var t := Transform3D(basis, Vector3(wx, wy, -zc))
				# Write the 12 transform floats into the buffer (3 rows of
				# [basis.x.k, basis.y.k, basis.z.k, origin.k]). Custom-data
				# floats at o+12..o+15 are pre-filled once in _ready().
				var o := idx * 16
				var bx := t.basis.x; var by := t.basis.y; var bz := t.basis.z
				var og := t.origin
				_surf_buf[o + 0] = bx.x; _surf_buf[o + 1] = by.x
				_surf_buf[o + 2] = bz.x; _surf_buf[o + 3] = og.x
				_surf_buf[o + 4] = bx.y; _surf_buf[o + 5] = by.y
				_surf_buf[o + 6] = bz.y; _surf_buf[o + 7] = og.y
				_surf_buf[o + 8] = bx.z; _surf_buf[o + 9] = by.z
				_surf_buf[o + 10] = bz.z; _surf_buf[o + 11] = og.z
				if outlines:
					# Line MultiMesh shares the same transforms.
					_line_buf[o + 0] = bx.x; _line_buf[o + 1] = by.x
					_line_buf[o + 2] = bz.x; _line_buf[o + 3] = og.x
					_line_buf[o + 4] = bx.y; _line_buf[o + 5] = by.y
					_line_buf[o + 6] = bz.y; _line_buf[o + 7] = og.y
					_line_buf[o + 8] = bx.z; _line_buf[o + 9] = by.z
					_line_buf[o + 10] = bz.z; _line_buf[o + 11] = og.z
				idx += 1
	# ONE upload per mesh per frame instead of 6000 RS round-trips each.
	RenderingServer.multimesh_set_buffer(_surf_mm.get_rid(), _surf_buf)
	if outlines:
		RenderingServer.multimesh_set_buffer(_line_mm.get_rid(), _line_buf)
	_surf_mm.visible_instance_count = idx
	_line_mm.visible_instance_count = idx if outlines else 0


func _update_particles() -> void:
	_p_mesh.clear_surfaces()
	if speed <= 0.0:
		return
	var n := mini(PMAX, int(float(PMAX) * (particles / 3.0)))
	if n <= 0:
		return
	var half := tunnel_size * 0.92
	# Fill the first n entries of the persistent buffers, then upload once.
	for i in range(n):
		var zf := fmod(_pbase_z[i] + _p_scroll, 1.0)
		if zf < 0.0: zf += 1.0
		_p_pos[i] = Vector3(
			_pbase_x[i] * half,
			_pbase_y[i] * half,
			-zf * _span_z
		)
		_p_col[i] = Color(_pseed[i], 0.0, 0.0, 1.0)
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = _p_pos.slice(0, n)
	arrs[Mesh.ARRAY_COLOR]  = _p_col.slice(0, n)
	_p_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrs)


func _update_camera() -> void:
	var rr   := deg_to_rad(cam_roll)
	var up   := Vector3(sin(rr), cos(rr), 0.0)
	var sway := sin(_t * 0.3) * cam_sway
	_camera.position = Vector3(sway, 0.0, 0.0)
	_camera.look_at(Vector3(0.0, 0.0, -100.0), up)
	_camera.fov = cam_fov


func _update_materials() -> void:
	if _surf_mat:
		_surf_mat.set_shader_parameter("face_light",   face_light)
		_surf_mat.set_shader_parameter("spec",         spec)
		_surf_mat.set_shader_parameter("shininess",    shininess)
		_surf_mat.set_shader_parameter("light_angle",  float(light_angle))
		_surf_mat.set_shader_parameter("opacity",      opacity)
		_surf_mat.set_shader_parameter("fog_start",    fog_start)
		_surf_mat.set_shader_parameter("fog_density",  fog_density)
		_surf_mat.set_shader_parameter("z_far",        _span_z)
	if _line_mat:
		_line_mat.set_shader_parameter("glow",         edge_glow)
		_line_mat.set_shader_parameter("opacity",      opacity)
		_line_mat.set_shader_parameter("fog_start",    fog_start)
		_line_mat.set_shader_parameter("fog_density",  fog_density)
		_line_mat.set_shader_parameter("z_far",        _span_z)
		_line.visible = outlines
	if _part_mat:
		_part_mat.set_shader_parameter("opacity",      opacity)
		_part_mat.set_shader_parameter("fog_start",    fog_start)
		_part_mat.set_shader_parameter("fog_density",  fog_density)
		_part_mat.set_shader_parameter("z_far",        _span_z)
		_part_mat.set_shader_parameter("shape",        shape)
