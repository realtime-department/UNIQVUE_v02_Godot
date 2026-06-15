extends MeshInstance3D
## Erzeugt einmalig ein grid_w x grid_h Punkt-Gitter auf einer Kugeloberflaeche
## plus ein Linien-Gitter (Wire) als Geschwisterknoten. Die Wellenbewegung
## geschieht als radiale Verschiebung im Vertex-Shader.
##
## Dichte-/Radius-Aenderung: particle_wave_root.gd ruft set_density() bzw.
## set_sphere_radius() auf.

var grid_w: int = 220
var grid_h: int = 220
var sphere_radius: float = 100.0

var _verts: PackedVector3Array   # geteilt zwischen Punkt- und Linien-Gitter


func _ready() -> void:
	_build()


func set_density(n: int) -> void:
	grid_w = clampi(n, 5, 340)
	grid_h = grid_w
	_build()


func set_sphere_radius(r: float) -> void:
	sphere_radius = r
	_build()


func _build() -> void:
	_build_points()
	_build_wire()


func _build_points() -> void:
	_verts = PackedVector3Array()
	_verts.resize(grid_w * grid_h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var dtheta := PI / float(grid_h - 1)
	var dphi   := TAU / float(grid_w - 1)
	var i := 0
	for zz in range(grid_h):
		var theta := float(zz) * dtheta
		for xx in range(grid_w):
			var phi := float(xx) * dphi
			var jt := rng.randf_range(-0.5, 0.5) * dtheta
			var jp := rng.randf_range(-0.4, 0.4) * dphi
			var t := clampf(theta + jt, 0.001, PI - 0.001)
			var p := phi + jp
			_verts[i] = Vector3(sin(t) * cos(p), cos(t), sin(t) * sin(p)) * sphere_radius
			i += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh = am
	var r := sphere_radius * 1.3
	custom_aabb = AABB(Vector3(-r, -r, -r), Vector3(r * 2.0, r * 2.0, r * 2.0))


func _build_wire() -> void:
	if _verts.is_empty():
		return
	var parent := get_parent()
	if parent == null:
		return

	# Wire-Knoten suchen oder anlegen.
	var wire := parent.get_node_or_null("Wire") as MeshInstance3D
	if wire == null:
		wire = MeshInstance3D.new()
		wire.name = "Wire"
		var wshader: Shader = load("res://wave_wire.gdshader")
		if wshader == null:
			return
		var wmat := ShaderMaterial.new()
		wmat.shader = wshader
		wmat.set_shader_parameter("wire_opacity", 0.35)
		wire.material_override = wmat
		parent.add_child(wire)

	# Linien-Index-Puffer: Breitenkreise (phi-Ringe, geschlossen) + Meridiane.
	var w := grid_w
	var h := grid_h
	var indices := PackedInt32Array()
	indices.resize(2 * (w * h + w * (h - 1)))
	var out := 0
	for z in range(h):
		for x in range(w):
			indices[out] = z * w + x;           out += 1
			indices[out] = z * w + (x + 1) % w; out += 1
	for z in range(h - 1):
		for x in range(w):
			indices[out] = z * w + x;       out += 1
			indices[out] = (z + 1) * w + x; out += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var wm := ArrayMesh.new()
	wm.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	wire.mesh = wm
	var r := sphere_radius * 1.3
	wire.custom_aabb = AABB(Vector3(-r, -r, -r), Vector3(r * 2.0, r * 2.0, r * 2.0))
	print("Particle Wave sphere: %d Punkte, %d Liniensegmente" % [grid_w * grid_h, indices.size() / 2])
