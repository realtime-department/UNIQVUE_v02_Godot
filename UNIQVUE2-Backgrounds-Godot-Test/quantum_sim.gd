extends Node3D
## Quantum — irregular, meshed tube (port from studio-v026.html
## createQuantumModule). Three layers over ONE vertex set on the tube surface:
##   - Polygons (triangles, PRIMITIVE_TRIANGLES)
##   - Edges    (wireframe, PRIMITIVE_LINES, indexed)
##   - Points   (PRIMITIVE_POINTS)
## The mesh (K-nearest-neighbor triangulation in (u,ang)-space) is generated
## once deterministically in _ready(). Radial fBm deformation + self-rotation
## happens entirely in the shaders (quantum*.gdshader). Up to MAX_CLONES tube
## clones are duplicated via MultiMesh (Y offset + shape variation per clone).
##
## Note: The web reference uses mulberry32(777); here a fixed-seeded
## RandomNumberGenerator produces the same KIND of irregular distribution (stable
## across runs, functionally equivalent — the exact point cloud is not bit-identical).

@export_group("Motion")
@export_range(0.0, 1.0, 0.01) var speed: float = 0.08
@export_range(0.0, 2.0, 0.02) var flow: float = 1.18
@export_range(-0.5, 0.5, 0.01) var spin: float = 0.02

@export_group("Form")
@export_range(0.0, 2.5, 0.05) var warp: float = 1.35
@export_range(0.2, 2.0, 0.02) var wavelength: float = 0.90
@export_range(0.0, 2.0, 0.05) var amp: float = 1.10
@export_range(0.0, 2.5, 0.05) var detail: float = 2.0
@export_range(0.2, 2.0, 0.05) var diameter: float = 0.85
@export_range(0.0, 360.0, 1.0) var orient_deg: float = 85.0

@export_group("Clones (Tubes)")
@export_range(1.0, 5.0, 0.25) var clones: float = 3.0
@export_range(20.0, 160.0, 1.0) var clone_gap: float = 74.0
@export_range(0.0, 1.0, 0.05) var clone_vary: float = 0.55

@export_group("Visible Layers")
@export var show_poly: bool = true
@export var show_edges: bool = true
@export var show_points: bool = true

@export_group("Polygons & Highlights")
@export_range(0.0, 1.0, 0.02) var poly_coverage: float = 0.26
@export_range(0.0, 0.6, 0.01) var poly_opacity: float = 0.16
@export var light_auto: bool = true
@export_range(0.0, 1.0, 0.02) var light_pos: float = 0.42
@export_range(0.1, 1.0, 0.02) var light_width: float = 0.53
@export_range(0.0, 2.0, 0.05) var glow: float = 1.45

@export_group("Edges & Points")
@export_range(0.0, 1.0, 0.02) var edge_opacity: float = 0.50
@export_range(0.0, 1.5, 0.02) var point_opacity: float = 1.18
@export_range(1.0, 8.0, 0.2) var point_size: float = 5.0
@export_range(0, 4, 1) var shape: int = 2

@export_group("Depth")
@export_range(0.0, 2.0, 0.05) var depth_fog: float = 1.60

@export_group("Camera")
@export_range(-60.0, 60.0, 1.0) var cam_height: float = 0.0
@export_range(60.0, 340.0, 2.0) var cam_dist: float = 150.0
@export_range(-40.0, 40.0, 1.0) var cam_pitch: float = 0.0
@export_range(25.0, 80.0, 1.0) var cam_fov: float = 46.0

const TUBE_LEN := 460.0
const RAD := 26.0
const MAX_CLONES := 5
const NVERT := 1100
const ASPECT := 3.0
const KNN := 7

@onready var _camera: Camera3D = $Camera3D
@onready var _tube: Node3D = $Tube
@onready var _poly: MultiMeshInstance3D = $Tube/Poly
@onready var _edges: MultiMeshInstance3D = $Tube/Edges
@onready var _points: MultiMeshInstance3D = $Tube/Points

var _su: PackedFloat32Array
var _sa: PackedFloat32Array
var _t: float = 0.0

# Width factor (aspect/16:9): stretches the tube along its longitudinal axis (local
# X of _tube, ~horizontal since orient_deg ~90), so it fills the width on wide/wall
# resolutions. Applied as _tube.scale.x; Y/Z stay unchanged.
var _wfac: float = 1.0

var _poly_mat: ShaderMaterial
var _edge_mat: ShaderMaterial
var _point_mat: ShaderMaterial


func _ready() -> void:
	var stage := get_node_or_null("/root/BackgroundStage")
	_wfac = stage.width_factor() if stage else 1.0
	if stage:
		stage.aspect_changed.connect(_on_aspect_changed)
	_build_geometry()
	_tube.scale.x = _wfac
	_poly_mat = _poly.material_override as ShaderMaterial
	_edge_mat = _edges.material_override as ShaderMaterial
	_point_mat = _points.material_override as ShaderMaterial
	_update_camera()
	_update_all()


# Aspect change: only set the width factor as X scale of the tube.
# _tube.rotation.z is set per frame separately -> scale is preserved.
# Y/Z stay unchanged.
func _on_aspect_changed(aspect: float) -> void:
	_wfac = aspect / (16.0 / 9.0)
	_tube.scale.x = _wfac


func _process(delta: float) -> void:
	_t += minf(delta, 0.05)
	_update_camera()
	_update_all()


# --------------------------------------------------------------- Geometry Setup

func _build_geometry() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var vu := PackedFloat32Array()
	var va := PackedFloat32Array()
	vu.resize(NVERT)
	va.resize(NVERT)
	for i in NVERT:
		vu[i] = rng.randf()
		va[i] = rng.randf() * TAU

	# Sort by u -> neighborhood along the tube becomes local.
	var order := range(NVERT)
	order.sort_custom(func(a, b): return vu[a] < vu[b])
	_su = PackedFloat32Array()
	_sa = PackedFloat32Array()
	_su.resize(NVERT)
	_sa.resize(NVERT)
	for k in NVERT:
		_su[k] = vu[order[k]]
		_sa[k] = va[order[k]]

	# K-nearest neighbors -> triangles (with face/edge filters against artifacts).
	var tris := PackedInt32Array()
	var tset := {}
	for i in NVERT:
		var lo: int = maxi(0, i - 50)
		var hi: int = mini(NVERT, i + 50)
		var cand := []
		for j in range(lo, hi):
			if j != i:
				cand.append([j, _d2(i, j)])
		cand.sort_custom(func(a, b): return a[1] < b[1])
		var k_count: int = mini(KNN, cand.size())
		for n in range(k_count - 1):
			var a: int = i
			var b: int = cand[n][0]
			var c: int = cand[n + 1][0]
			var key := _tri_key(a, b, c)
			if tset.has(key):
				continue
			if _tri_area(a, b, c) < 0.00005:
				continue
			if _max_edge(a, b, c) > 0.05:
				continue
			tset[key] = true
			tris.append(a)
			tris.append(b)
			tris.append(c)

	# Unique edges from the triangles.
	var edge_idx := PackedInt32Array()
	var eset := {}
	var tcount := tris.size()
	var ti := 0
	while ti < tcount:
		var t0: int = tris[ti]
		var t1: int = tris[ti + 1]
		var t2: int = tris[ti + 2]
		_add_edge(t0, t1, eset, edge_idx)
		_add_edge(t1, t2, eset, edge_idx)
		_add_edge(t2, t0, eset, edge_idx)
		ti += 3

	# Base surface positions (undeformed) — deformation happens in the shader.
	var pos := PackedVector3Array()
	pos.resize(NVERT)
	for i in NVERT:
		pos[i] = _vertex_pos(i)

	# --- Points mesh (PRIMITIVE_POINTS) ---
	var point_mesh := ArrayMesh.new()
	var parr := []
	parr.resize(Mesh.ARRAY_MAX)
	parr[Mesh.ARRAY_VERTEX] = pos
	point_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, parr)

	# --- Edges mesh (PRIMITIVE_LINES, indexed) ---
	var edge_mesh := ArrayMesh.new()
	var earr := []
	earr.resize(Mesh.ARRAY_MAX)
	earr[Mesh.ARRAY_VERTEX] = pos
	earr[Mesh.ARRAY_INDEX] = edge_idx
	edge_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)

	# --- Polygon mesh (non-indexed, UV = (aFace, aCentU)) ---
	var face_count := tris.size() / 3
	var ppos := PackedVector3Array()
	var puv := PackedVector2Array()
	ppos.resize(face_count * 3)
	puv.resize(face_count * 3)
	for f in face_count:
		var ia: int = tris[f * 3]
		var ib: int = tris[f * 3 + 1]
		var ic: int = tris[f * 3 + 2]
		var cu: float = (_su[ia] + _su[ib] + _su[ic]) / 3.0
		var hv: float = sin(float(f) * 12.9898 + 1.23) * 43758.5453
		hv = hv - floor(hv)   # fract -> per-face hash for coverage
		ppos[f * 3] = pos[ia]
		ppos[f * 3 + 1] = pos[ib]
		ppos[f * 3 + 2] = pos[ic]
		puv[f * 3] = Vector2(hv, cu)
		puv[f * 3 + 1] = Vector2(hv, cu)
		puv[f * 3 + 2] = Vector2(hv, cu)
	var poly_mesh := ArrayMesh.new()
	var pa := []
	pa.resize(Mesh.ARRAY_MAX)
	pa[Mesh.ARRAY_VERTEX] = ppos
	pa[Mesh.ARRAY_TEX_UV] = puv
	poly_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, pa)

	_setup_multimesh(_poly, poly_mesh)
	_setup_multimesh(_edges, edge_mesh)
	_setup_multimesh(_points, point_mesh)


func _setup_multimesh(mmi: MultiMeshInstance3D, mesh: Mesh) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = MAX_CLONES
	mmi.multimesh = mm
	# Generous AABB: vertex deformation + clone offset exceed the base box.
	mmi.custom_aabb = AABB(Vector3(-400.0, -560.0, -400.0), Vector3(800.0, 1120.0, 800.0))


func _d2(i: int, j: int) -> float:
	var da := (_su[i] - _su[j]) * ASPECT
	var dd: float = abs(_sa[i] - _sa[j])
	if dd > PI:
		dd = TAU - dd
	dd /= TAU
	return da * da + dd * dd


func _tri_area(a: int, b: int, c: int) -> float:
	var ax := _su[a] * ASPECT
	var ay := _sa[a] / TAU
	var bx := _su[b] * ASPECT
	var by := _sa[b] / TAU
	var cx := _su[c] * ASPECT
	var cy := _sa[c] / TAU
	return abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) * 0.5


func _max_edge(a: int, b: int, c: int) -> float:
	return maxf(maxf(_d2(a, b), _d2(b, c)), _d2(a, c))


func _tri_key(a: int, b: int, c: int) -> int:
	var s := [a, b, c]
	s.sort()
	return s[0] * NVERT * NVERT + s[1] * NVERT + s[2]


func _add_edge(a: int, b: int, eset: Dictionary, out: PackedInt32Array) -> void:
	var lo: int = mini(a, b)
	var hi: int = maxi(a, b)
	var key := lo * NVERT + hi
	if eset.has(key):
		return
	eset[key] = true
	out.append(lo)
	out.append(hi)


func _vertex_pos(i: int) -> Vector3:
	var u := _su[i]
	var ang := _sa[i]
	return Vector3((u - 0.5) * TUBE_LEN, cos(ang) * RAD, sin(ang) * RAD)


# --------------------------------------------------------------- Runtime Update

func _update_camera() -> void:
	if _camera == null:
		return
	_camera.fov = cam_fov
	_camera.position = Vector3(0.0, cam_height, cam_dist)
	_camera.look_at(Vector3(0.0, cam_pitch, 0.0), Vector3.UP)


func _update_all() -> void:
	if _poly_mat == null:
		return

	var light_u := light_pos
	if light_auto:
		light_u = 0.5 + 0.5 * sin(_t * 0.15)

	# Shared deformation/light/fog uniforms applied to all three materials.
	for m in [_poly_mat, _edge_mat, _point_mat]:
		m.set_shader_parameter("u_speed", speed)
		m.set_shader_parameter("u_flow", flow)
		m.set_shader_parameter("u_warp", warp)
		m.set_shader_parameter("u_amp", amp)
		m.set_shader_parameter("u_detail", detail)
		m.set_shader_parameter("u_wavelength", wavelength)
		m.set_shader_parameter("u_diameter", diameter)
		m.set_shader_parameter("u_spin", spin)
		m.set_shader_parameter("u_depth_fog", depth_fog)
		m.set_shader_parameter("u_light_u", light_u)
		m.set_shader_parameter("u_light_width", light_width)

	_poly_mat.set_shader_parameter("u_glow", glow)
	_poly_mat.set_shader_parameter("u_poly_opacity", poly_opacity)
	_poly_mat.set_shader_parameter("u_coverage", poly_coverage)
	_edge_mat.set_shader_parameter("u_edge_opacity", edge_opacity)
	_point_mat.set_shader_parameter("u_point_opacity", point_opacity)
	_point_mat.set_shader_parameter("u_point_size", point_size)
	_point_mat.set_shader_parameter("u_shape", shape)

	_tube.rotation.z = PI * 0.5 - deg_to_rad(orient_deg)
	_poly.visible = show_poly
	_edges.visible = show_edges
	_points.visible = show_points and speed > 0.0

	var count := clampf(clones, 0.0001, float(MAX_CLONES))
	var mid := (count - 1.0) * 0.5
	for ci in MAX_CLONES:
		var fade := clampf(count - float(ci), 0.0, 1.0)
		var tr := Transform3D.IDENTITY
		tr.origin = Vector3(0.0, (float(ci) - mid) * clone_gap, 0.0)
		var cd := Color(float(ci + 1) * 5.37 * clone_vary, fade, 0.0, 0.0)
		for mmi in [_poly, _edges, _points]:
			var mm: MultiMesh = mmi.multimesh
			mm.set_instance_transform(ci, tr)
			mm.set_instance_custom_data(ci, cd)
