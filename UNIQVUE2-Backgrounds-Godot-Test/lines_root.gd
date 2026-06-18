extends Node3D
## Lines / Speed-Streaks — ported from studio-v005 createLinesModule().
##
## The entire animation runs in the vertex shader (lines.gdshader): each of
## the 40k instances hashes its 8 random values from INSTANCE_ID and writes
## its position directly to clip-space (ortho reference). On the CPU side only:
##  - one-time setup of QuadMesh + MultiMesh,
##  - mirroring @exports to the shader uniforms,
##  - instance count control via visible_instance_count (HTML: geo.instanceCount).
##
## Colors do NOT come from here — elem_a/elem_b is read by the shader as global
## STYLE uniforms, the background is the Gradient-Sky (web: gradientPass).
## @exports are captured by ParamStore as scene/* entries.

const COUNT: int = 40000

@export_group("Lines")
@export_range(0.0, 6.283, 0.001) var angle: float = 2.007
@export_range(0.0, 2.0, 0.02) var speed: float = 0.4
@export_range(0.0, 1.0, 0.02) var speed_var: float = 1.0
@export_range(0.1, 1.0, 0.02) var density: float = 1.0
@export_range(1.0, 4.0, 0.05) var coverage: float = 1.6

@export_group("Shape")
@export_range(0.3, 2.5, 0.05) var len_scale: float = 1.0
@export_range(0.0, 1.5, 0.02) var len_spread: float = 1.0
@export_range(0.3, 3.0, 0.05) var width_scale: float = 1.0
@export_range(0.0, 1.0, 0.02) var sharp: float = 1.0

@export_group("Appearance")
@export_range(0.3, 2.5, 0.05) var contrast: float = 1.15
@export_range(0.0, 1.5, 0.05) var glow: float = 0.3
@export_range(0.0, 1.5, 0.05) var opacity: float = 0.85

@onready var _field: MultiMeshInstance3D = $LineField


func _ready() -> void:
	# Fullscreen base quad: 2x2 (NDC-spanning), the shader scales/positions
	# each instance itself — MultiMesh transforms stay unused (zeros),
	# so a custom_aabb is needed to prevent frustum culling.
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


## Mirror @exports to shader uniforms each frame (equivalent to update(dt,p)
## in the web studio) + update instance count.
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
	var vp := get_viewport().get_visible_rect().size
	if vp.y > 0.0:
		mat.set_shader_parameter("aspect_ratio", vp.x / vp.y)
	# Count scales with coverage area: larger coverage needs more
	# strokes, otherwise the field thins out (HTML: covFill = min(1, cov^2/16)).
	var cov_fill := minf(1.0, (coverage * coverage) / 16.0)
	var visible := maxi(100, int(float(COUNT) * density * (0.4 + cov_fill * 0.6)))
	if _field.multimesh.visible_instance_count != visible:
		_field.multimesh.visible_instance_count = visible
