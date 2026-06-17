extends MeshInstance3D
## Erzeugt einmalig ein grid_w x grid_h Punkt-Gitter (XZ-Ebene) plus ein Linien-
## Gitter (Wire) als Geschwisterknoten. Die gesamte Wellenbewegung geschieht im
## Vertex-Shader — CPU baut die Geometrie nur einmal (oder bei Dichte-Aenderung).
##
## Dichte-Aenderung: particle_wave_root.gd ruft set_density() auf, wenn das
## 'density'-Export aendert.

const _WIRE_SHADER := preload("res://wave_wire.gdshader")

var grid_w: int = 220
var grid_h: int = 220
const SPAN_X_BASE: float = 320.0
var span_x: float = SPAN_X_BASE
var span_z: float = 420.0

# Breiten-Faktor (aspect/16:9): streckt die X-Spannweite des Gitters (breitere
# Spaltenabstaende bei gleicher Punktzahl -> stabiler Polycount), damit das Gitter
# bei breiten/Wand-Aufloesungen die Breite fuellt. Z/Y bleiben unveraendert.
var _wfac: float = 1.0

var _verts: PackedVector3Array   # geteilt zwischen Punkt- und Linien-Gitter


func _ready() -> void:
	var stage := get_node_or_null("/root/BackgroundStage")
	_wfac = stage.width_factor() if stage else 1.0
	span_x = SPAN_X_BASE * _wfac
	if stage:
		stage.aspect_changed.connect(_on_aspect_changed)
	_build_points()
	_build_wire.call_deferred()


# Aspekt-Aenderung: X-Spannweite neu setzen und Gitter neu aufbauen. Die Wellen-
# bewegung lebt komplett im Vertex-Shader, daher genuegt ein einmaliger Rebuild der
# Basis-Geometrie (kein Per-Frame-Reset). Z/Y bleiben unveraendert.
func _on_aspect_changed(aspect: float) -> void:
	var nf := aspect / (16.0 / 9.0)
	if absf(nf - _wfac) < 0.0001:
		return
	_wfac = nf
	span_x = SPAN_X_BASE * _wfac
	_build()


## Von particle_wave_root.density-Setter aufgerufen. Rebuild des Punkt- und
## Linien-Gitters mit neuer Dichte.
func set_density(n: int) -> void:
	grid_w = clampi(n, 5, 340)
	grid_h = grid_w
	_build()


func _build() -> void:
	_build_points()
	_build_wire()


func _build_points() -> void:
	_verts = PackedVector3Array()
	_verts.resize(grid_w * grid_h)
	var col_spacing := span_x / float(grid_w - 1)
	var row_spacing := span_z / float(grid_h - 1)
	# Per-point jitter breaks the perfectly regular lattice. A regular point grid
	# beats against the pixel grid and produces screen-locked moire stripes that
	# move with the camera and survive every camera/post fix. Seeded = reproducible.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var i := 0
	for zz in range(grid_h):
		# Progressive X-drift: 3 column-widths over full depth.
		# Prevents identical q.x sampling along screen-columns (wave-phase lock),
		# which caused systematic dark vertical stripes when dir=(0,1).
		var x_drift := (float(zz) / float(grid_h - 1)) * col_spacing * 3.0
		for xx in range(grid_w):
			var jx := rng.randf_range(-0.5, 0.5) * col_spacing
			var jz := rng.randf_range(-0.4, 0.4) * row_spacing
			var fx := (float(xx) / float(grid_w - 1) - 0.5) * span_x + x_drift + jx
			var fz := (float(zz) / float(grid_h - 1) - 0.5) * span_z + jz
			_verts[i] = Vector3(fx, 0.0, fz)
			i += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh = am
	custom_aabb = AABB(Vector3(-span_x * 0.6, -40.0, -span_z * 0.6), Vector3(span_x * 1.2, 80.0, span_z * 1.2))


func _build_wire() -> void:
	if _verts.is_empty():
		return
	var parent := get_parent()
	if parent == null:
		return

	# Wire-Knoten suchen oder anlegen.
	var wire_name := name + "Wire"
	var wire := parent.get_node_or_null(wire_name) as MeshInstance3D
	if wire == null:
		wire = MeshInstance3D.new()
		wire.name = wire_name
		wire.transform = transform  # inherit Y-flip (or identity) from this grid node
		var wmat := ShaderMaterial.new()
		wmat.shader = _WIRE_SHADER
		wmat.set_shader_parameter("wire_opacity", 0.35)
		wire.material_override = wmat
		parent.add_child(wire)

	# Linien-Index-Puffer aufbauen (horizontale + vertikale Verbindungen).
	var w := grid_w
	var h := grid_h
	var indices := PackedInt32Array()
	indices.resize(2 * ((w - 1) * h + w * (h - 1)))
	var out := 0
	for z in range(h):
		for x in range(w - 1):
			indices[out] = z * w + x;       out += 1
			indices[out] = z * w + x + 1;   out += 1
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
	wire.custom_aabb = custom_aabb
	print("Particle Wave: %d Punkte, %d Liniensegmente" % [grid_w * grid_h, indices.size() / 2])
