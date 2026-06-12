extends Node3D
## Lines / Speed-Streaks — ported from studio-v005 createLinesModule().
##
## Die gesamte Animation laeuft im Vertex-Shader (lines.gdshader): jede der
## 40k Instanzen hasht ihre 8 Zufallswerte aus INSTANCE_ID und schreibt ihre
## Position direkt in den Clip-Space (Ortho-Vorlage). CPU-seitig passiert nur:
##  - einmaliger Aufbau von QuadMesh + MultiMesh,
##  - Spiegeln der @exports in die Shader-Uniforms,
##  - Anzahl-Steuerung ueber visible_instance_count (HTML: geo.instanceCount).
##
## Farben kommen NICHT von hier — elem_a/elem_b liest der Shader als globale
## STYLE-Uniforms, der Hintergrund ist der Gradient-Sky (Web: gradientPass).
## @exports werden von ParamStore als scene/*-Eintraege erfasst.

const COUNT: int = 40000

@export_group("Linien")
@export_range(0.0, 6.283, 0.001) var angle: float = 2.007
@export_range(0.0, 2.0, 0.02) var speed: float = 0.4
@export_range(0.0, 1.0, 0.02) var speed_var: float = 1.0
@export_range(0.1, 1.0, 0.02) var density: float = 1.0
@export_range(1.0, 4.0, 0.05) var coverage: float = 1.6

@export_group("Form")
@export_range(0.3, 2.5, 0.05) var len_scale: float = 1.0
@export_range(0.0, 1.5, 0.02) var len_spread: float = 1.0
@export_range(0.3, 3.0, 0.05) var width_scale: float = 1.0
@export_range(0.0, 1.0, 0.02) var sharp: float = 1.0

@export_group("Darstellung")
@export_range(0.3, 2.5, 0.05) var contrast: float = 1.15
@export_range(0.0, 1.5, 0.05) var glow: float = 0.3
@export_range(0.0, 1.5, 0.05) var opacity: float = 0.85

@onready var _field: MultiMeshInstance3D = $LineField


func _ready() -> void:
	# Fullscreen-Basis-Quad: 2x2 (NDC-spannend), der Shader skaliert/positioniert
	# jede Instanz selbst — Transforms des MultiMesh bleiben ungenutzt (Nullen),
	# daher braucht es eine custom_aabb gegen Frustum-Culling.
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = COUNT
	_field.multimesh = mm
	_field.custom_aabb = AABB(Vector3(-1000.0, -1000.0, -1000.0), Vector3(2000.0, 2000.0, 2000.0))


func _process(_delta: float) -> void:
	_sync_params()


## @exports jede Frame in die Shader-Uniforms spiegeln (entspricht update(dt,p)
## im Web-Studio) + Instanzanzahl nachfuehren.
func _sync_params() -> void:
	var mat := _field.material_override as ShaderMaterial
	if mat == null or _field.multimesh == null:
		return
	mat.set_shader_parameter("angle", angle)
	mat.set_shader_parameter("speed", speed)
	mat.set_shader_parameter("speed_var", speed_var)
	mat.set_shader_parameter("coverage", coverage)
	mat.set_shader_parameter("len_scale", len_scale)
	mat.set_shader_parameter("len_spread", len_spread)
	mat.set_shader_parameter("width_scale", width_scale)
	mat.set_shader_parameter("sharp", sharp)
	mat.set_shader_parameter("contrast", contrast)
	mat.set_shader_parameter("glow", glow)
	mat.set_shader_parameter("opacity", opacity)
	# Anzahl skaliert mit Coverage-Flaeche: groessere Abdeckung braucht mehr
	# Striche, sonst wird das Feld duenn (HTML: covFill = min(1, cov^2/16)).
	var cov_fill := minf(1.0, (coverage * coverage) / 16.0)
	var visible := maxi(100, int(float(COUNT) * density * (0.4 + cov_fill * 0.6)))
	if _field.multimesh.visible_instance_count != visible:
		_field.multimesh.visible_instance_count = visible
