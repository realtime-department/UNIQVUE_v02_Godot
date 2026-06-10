extends MeshInstance3D
## Erzeugt ein statisches GRID_W x GRID_H Punkt-Gitter in der XZ-Ebene.
## Das Gitter aendert sich nie - die gesamte Wellenbewegung passiert im Vertex-Shader.
## Das ist der zentrale Effizienzpunkt: CPU baut das Gitter einmal, danach laeuft alles auf der GPU.

@export var grid_w: int = 220          ## Punkte in X
@export var grid_h: int = 220          ## Punkte in Z (Tiefe)
@export var span_x: float = 60.0       ## Breite der Flaeche in Weltkoordinaten
@export var span_z: float = 120.0      ## Tiefe der Flaeche (laeuft in die Ferne)

func _ready() -> void:
	_build_grid()

func _build_grid() -> void:
	var verts := PackedVector3Array()
	verts.resize(grid_w * grid_h)
	var i := 0
	for zz in range(grid_h):
		for xx in range(grid_w):
			var fx := (float(xx) / float(grid_w - 1) - 0.5) * span_x
			# Z von 0 (nah) nach span_z (fern), damit das Gitter in die Tiefe zieht
			var fz := (float(zz) / float(grid_h - 1)) * span_z
			verts[i] = Vector3(fx, 0.0, fz)
			i += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh = am

	# grosszuegige AABB, damit das Gitter nicht faelschlich weggecullt wird,
	# wenn der Vertex-Shader die Punkte nach oben/unten verschiebt
	custom_aabb = AABB(Vector3(-span_x, -40.0, -5.0), Vector3(span_x * 2.0, 80.0, span_z + 10.0))

	print("Particle Wave: %d Punkte erzeugt" % (grid_w * grid_h))
