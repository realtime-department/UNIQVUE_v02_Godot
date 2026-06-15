extends Node3D
## Structure — lightmapped architecture, ported from studio-v005 createStructureModule()
## (studio-v005.html:1244-1558).
##
## Geometry loaded from textures/structure_geo.json (extracted pre-step).
## 8 blocks × 9-column layout (floor + ceiling mirror) = 144 MultiMesh instances.
## Ceiling-grid panels use a second MultiMesh (7 cols × 18 rows = 126 instances)
## with per-instance brightness via INSTANCE_CUSTOM.
## ImmediateMesh for 800 ambient particles moving toward camera.
##
## Colors: horizon glow reads elem_b, ground tint reads fog_color/elem_a — all
## global STYLE uniforms, NO @export Color.

@export_group("Welt & Flug")
@export_range(0.0, 2.0, 0.02) var speed: float = 0.7
@export_range(24.0, 70.0, 1.0) var cam_fov: float = 38.0

@export_group("Material")
@export_range(0.4, 3.0, 0.05) var exposure: float = 1.4
@export_range(0.3, 2.0, 0.05) var light_gain: float = 1.0
@export_range(0.0, 1.0, 0.02) var tint_mix: float = 0.5

@export_group("Elemente")
@export_range(0.0, 1.5, 0.02) var ground: float = 0.78
@export_range(0.0, 1.5, 0.02) var grid: float = 0.85
@export_range(0.0, 1.0, 0.02) var particles: float = 1.0
@export_range(1.0, 8.0, 0.1)  var particle_size: float = 2.8

@export_group("Tiefe & Fog")
@export_range(1.0, 5.0, 0.1) var fade_start: float = 3.2
@export_range(3.0, 9.0, 0.1) var fade_end: float = 6.6

const NBLOCKS  := 8
const COLS     := 9
const MESHES   := NBLOCKS * COLS * 2   # 144 (floor + ceiling per column per block)
const SKY_COLS := 7
const SKY_ROWS := 18
const SKY_PANELS := SKY_COLS * SKY_ROWS  # 126
const SKY_ROW_GAP := 430.0
const PANEL_Y  := 262.0
const CAM_Z    := 560.0
const CAM_Y    := 150.0
const PCOUNT   := 800

var _travel: float = 0.0

# Geometry bounds (computed from JSON)
var _tile_d: float = 1243.0
var _seg_len: float = 1044.0
var _cx: float = 12.0
var _cz: float = 86.5
var _step_x: float = 742.0

# Block base transforms (per mesh within one block, shared by all 8 blocks)
var _block_base: Array = []   # Array[Transform3D], 18 entries

# Sky panel base Z and XYZ (excluding Z which cycles)
var _sky_base_z: PackedFloat32Array
var _sky_base_xf: Array = []  # Array[Transform3D] for XY pos + scale, Z=0

var _struct_mm: MultiMesh
var _grid_mm: MultiMesh

var _struct_mat: ShaderMaterial
var _ground_mat: ShaderMaterial
var _grid_mat:   ShaderMaterial
var _part_mat:   ShaderMaterial

# Particles
var _px: PackedFloat32Array
var _py: PackedFloat32Array
var _pz: PackedFloat32Array
var _pspd: PackedFloat32Array
var _p_mesh: ImmediateMesh

@onready var _camera: Camera3D             = $Camera3D
@onready var _struct:  MultiMeshInstance3D = $StructMesh
@onready var _ground_node: MeshInstance3D  = $Ground
@onready var _grid_node:   MultiMeshInstance3D = $GridPanels
@onready var _part_node:   MeshInstance3D  = $Points


func _ready() -> void:
	_load_geometry()
	_build_block_transforms()
	_build_sky_panels()
	_init_particles()

	# Large AABB to prevent frustum culling
	var big := AABB(Vector3(-2000.0, -50.0, -8000.0), Vector3(4000.0, 400.0, 9000.0))
	_struct.custom_aabb = big
	_grid_node.custom_aabb = big
	_part_node.custom_aabb = big

	_struct_mat = _struct.material_override as ShaderMaterial
	_ground_mat = _ground_node.material_override as ShaderMaterial
	_grid_mat   = _grid_node.material_override as ShaderMaterial
	_part_mat   = _part_node.material_override as ShaderMaterial


func _rand(n: float) -> float:
	var s := sin(n) * 43758.5453
	return s - floor(s)


func _load_geometry() -> void:
	var file := FileAccess.open("res://textures/structure_geo.json", FileAccess.READ)
	if file == null:
		push_error("structure_sim: cannot open structure_geo.json")
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if data == null:
		push_error("structure_sim: JSON parse failed")
		return

	var pos_raw: Array = data["positions"]
	var nrm_raw: Array = data["normals"]
	var uv_raw:  Array = data["uvs"]
	var idx_raw: Array = data["indices"]

	# Compute bounding box
	var min_x: float = pos_raw[0]; var max_x: float = pos_raw[0]
	var min_z: float = pos_raw[2]; var max_z: float = pos_raw[2]
	var i := 0
	while i < pos_raw.size():
		min_x = minf(min_x, float(pos_raw[i]))
		max_x = maxf(max_x, float(pos_raw[i]))
		min_z = minf(min_z, float(pos_raw[i + 2]))
		max_z = maxf(max_z, float(pos_raw[i + 2]))
		i += 3
	_step_x = max_x - min_x
	_cx     = (max_x + min_x) * 0.5
	_tile_d = max_z - min_z
	_cz     = (max_z + min_z) * 0.5
	_seg_len = _tile_d * 0.84

	# Build ArrayMesh
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs   := PackedVector2Array()
	i = 0
	while i < pos_raw.size():
		verts.append(Vector3(float(pos_raw[i]), float(pos_raw[i+1]), float(pos_raw[i+2])))
		i += 3
	i = 0
	while i < nrm_raw.size():
		norms.append(Vector3(float(nrm_raw[i]), float(nrm_raw[i+1]), float(nrm_raw[i+2])))
		i += 3
	i = 0
	while i < uv_raw.size():
		uvs.append(Vector2(float(uv_raw[i]), float(uv_raw[i+1])))
		i += 2

	var inds := PackedInt32Array()
	for v in idx_raw:
		inds.append(int(v))

	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX]   = verts
	arrs[Mesh.ARRAY_NORMAL]   = norms
	arrs[Mesh.ARRAY_TEX_UV]   = uvs
	arrs[Mesh.ARRAY_INDEX]    = inds
	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)

	# Structure MultiMesh with this ArrayMesh
	_struct_mm = MultiMesh.new()
	_struct_mm.transform_format = MultiMesh.TRANSFORM_3D
	_struct_mm.instance_count   = MESHES
	_struct_mm.mesh             = amesh
	_struct.multimesh           = _struct_mm


func _build_block_transforms() -> void:
	# 18 base transforms per block (floor + ceiling for each of 9 columns)
	_block_base.resize(COLS * 2)
	for c in range(COLS):
		var ox := (float(c) - float(COLS - 1) * 0.5) * _step_x - _cx

		# Floor mesh: small Y jitter, small Y rotation
		var ry_f := (_rand(float(c) * 13.1) * 2.0 - 1.0) * 0.04
		var dy_f := (_rand(float(c) * 5.7)  * 2.0 - 1.0) * 5.0
		var bf   := Basis(Vector3.UP, ry_f)
		_block_base[c] = Transform3D(bf, Vector3(ox, dy_f, -_cz))

		# Ceiling mesh: PI rotation around Z (flipped), small Y rotation, small X offset
		var ox2  := ox + (_rand(float(c)) * 2.0 - 1.0) * 30.0
		var ry_c := (_rand(float(c) * 3.3) * 2.0 - 1.0) * 0.06
		# Rotate PI around Z → flip upside-down, then apply small Y rotation
		var bc   := Basis(Vector3.FORWARD, PI) * Basis(Vector3.UP, ry_c)
		_block_base[COLS + c] = Transform3D(bc, Vector3(ox2, 300.0, -_cz))


func _build_sky_panels() -> void:
	_sky_base_z = PackedFloat32Array(); _sky_base_z.resize(SKY_PANELS)
	_sky_base_xf.resize(SKY_PANELS)

	_grid_mm = MultiMesh.new()
	_grid_mm.transform_format = MultiMesh.TRANSFORM_3D
	_grid_mm.use_custom_data  = true
	_grid_mm.instance_count   = SKY_PANELS
	# PlaneMesh size 1×1 in XZ plane (will be scaled per instance)
	var pm := PlaneMesh.new()
	pm.size = Vector2(1.0, 1.0)
	_grid_mm.mesh      = pm
	_grid_node.multimesh = _grid_mm

	var sky_front := CAM_Z + 600.0
	for row in range(SKY_ROWS):
		for col in range(SKY_COLS):
			var idx := row * SKY_COLS + col
			var bz  := sky_front - 200.0 - float(row) * SKY_ROW_GAP \
			           - _rand(float(idx) * 1.3) * 120.0
			_sky_base_z[idx] = bz
			var bright := 0.28 + pow(_rand(float(idx) * 2.7), 1.5) * 0.5
			var w := 150.0 + _rand(float(idx) * 1.9) * 190.0
			var d := 150.0 + _rand(float(idx) * 2.3) * 200.0
			var px := (float(col) - float(SKY_COLS - 1) * 0.5) * 340.0 \
			          + (_rand(float(idx)) * 2.0 - 1.0) * 110.0
			var py := PANEL_Y - _rand(float(idx) * 1.7) * 40.0
			# Scale in XZ (PlaneMesh lies in XZ)
			var bas := Basis.IDENTITY.scaled(Vector3(w, 1.0, d))
			_sky_base_xf[idx] = Transform3D(bas, Vector3(px, py, 0.0))
			# Brightness via custom data channel
			_grid_mm.set_instance_custom_data(idx, Color(bright, 0.0, 0.0, 1.0))


func _init_particles() -> void:
	_px   = PackedFloat32Array(); _px.resize(PCOUNT)
	_py   = PackedFloat32Array(); _py.resize(PCOUNT)
	_pz   = PackedFloat32Array(); _pz.resize(PCOUNT)
	_pspd = PackedFloat32Array(); _pspd.resize(PCOUNT)
	for i in range(PCOUNT):
		_px[i]   = (_rand(float(i) * 1.1) * 2.0 - 1.0) * 1800.0
		_py[i]   = 10.0 + _rand(float(i) * 2.2) * 420.0
		_pz[i]   = 400.0 - _rand(float(i) * 3.3) * 6500.0
		_pspd[i] = 60.0 + _rand(float(i) * 4.4) * 120.0
	_p_mesh       = ImmediateMesh.new()
	_part_node.mesh = _p_mesh


func _process(delta: float) -> void:
	var dt := minf(delta, 0.05)
	_travel += speed * 100.0 * dt
	_update_blocks()
	_update_sky_panels()
	_update_particles(dt)
	_update_camera()
	_update_materials()


func _update_blocks() -> void:
	var span  := float(NBLOCKS) * _seg_len
	var halfd := _tile_d * 0.5
	var front := CAM_Z + halfd + 150.0
	for b in range(NBLOCKS):
		var z := (front - float(b) * _seg_len) + fmod(_travel, span)
		while z > front:
			z -= span
		for m in range(COLS * 2):
			var base: Transform3D = _block_base[m]
			_struct_mm.set_instance_transform(
				b * COLS * 2 + m,
				Transform3D(base.basis, base.origin + Vector3(0.0, 0.0, z))
			)


func _update_sky_panels() -> void:
	var sky_span  := float(SKY_ROWS) * SKY_ROW_GAP
	var sky_front := CAM_Z + 600.0
	for idx in range(SKY_PANELS):
		var z := _sky_base_z[idx] + fmod(_travel, sky_span)
		while z > sky_front:
			z -= sky_span
		var base: Transform3D = _sky_base_xf[idx]
		var pos := base.origin
		pos.z = z
		_grid_mm.set_instance_transform(idx, Transform3D(base.basis, pos))


func _update_particles(dt: float) -> void:
	_p_mesh.clear_surfaces()
	var n := mini(PCOUNT, int(float(PCOUNT) * particles))
	if n <= 0:
		return
	_p_mesh.surface_begin(Mesh.PRIMITIVE_POINTS)
	for i in range(n):
		_pz[i] += _pspd[i] * dt
		if _pz[i] > CAM_Z + 200.0:
			_px[i] = (_rand(float(i) * 1.1 + _travel * 0.013) * 2.0 - 1.0) * 1800.0
			_py[i] = 10.0 + _rand(float(i) * 2.2 + _travel * 0.011) * 420.0
			_pz[i] = -6500.0
		_p_mesh.surface_set_color(Color(0.0, 0.0, 0.0, 1.0))
		_p_mesh.surface_add_vertex(Vector3(_px[i], _py[i], _pz[i]))
	_p_mesh.surface_end()


func _update_camera() -> void:
	_camera.position = Vector3(0.0, CAM_Y, CAM_Z)
	_camera.look_at(Vector3(0.0, CAM_Y, -1600.0), Vector3.UP)
	_camera.fov = cam_fov


func _update_materials() -> void:
	var fs := fade_start * 1000.0
	var fe := maxf(fs + 200.0, fade_end * 1000.0)
	if _struct_mat:
		_struct_mat.set_shader_parameter("exposure",    exposure)
		_struct_mat.set_shader_parameter("light_gain",  light_gain)
		_struct_mat.set_shader_parameter("fade_start",  fs)
		_struct_mat.set_shader_parameter("fade_end",    fe)
	if _ground_mat:
		# Tint = mix(fog_color, elem_a, tint_mix) — let shader do it via the tint uniform
		# We pass the CPU-mixed tint (reading from Style autoload)
		var fog_c: Color = Style.get_color("fog_color")
		var elem_a_c: Color = Style.get_color("elem_a")
		var t := fog_c.lerp(elem_a_c, tint_mix)
		_ground_mat.set_shader_parameter("tint",        Vector3(t.r, t.g, t.b))
		_ground_mat.set_shader_parameter("opacity",     ground)
		_ground_mat.set_shader_parameter("fade_start",  fs)
		_ground_mat.set_shader_parameter("fade_end",    fe)
		# Ground scroll: travel * 0.82 / (6650/8.53) wrapped to [0,1)
		var ground_tile_world := 6650.0 / 8.53
		_ground_mat.set_shader_parameter("scroll", fmod(_travel * 0.82 / ground_tile_world, 1.0))
	if _grid_mat:
		_grid_mat.set_shader_parameter("opacity",    grid)
		_grid_mat.set_shader_parameter("fade_start", fs)
		_grid_mat.set_shader_parameter("fade_end",   fe)
		_grid_mat.set_shader_parameter("tint_mix",   tint_mix)
	if _part_mat:
		_part_mat.set_shader_parameter("part_size",  particle_size)
