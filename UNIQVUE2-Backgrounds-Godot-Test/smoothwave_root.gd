extends Node3D
## Smooth Wave — root script (port from studio-v026.html createSmoothWaveModule).
##
## MAX_GROUPS (4) x MAX_LAYERS (6) "sheets" as ONE MultiMesh over a
## PlaneMesh. Per frame:
##   - Set camera (position/look target/FOV) as in applyCamera() in the web version.
##   - Push global shape/appearance uniforms to the material.
##   - Per instance: Transform (layer stack + group offset) and INSTANCE_CUSTOM
##     (shape seed + soft fade-in) set.
##   - Node rotation z = PI/2 - orientation (cloth.rotation.z in the web version).
##
## Fractional "layers"/"group_clones" fade in the last layer/clone
## softly (fade -> alpha in shader). @export values are the only
## parameter source; ParamStore captures them as scene/*.

@export_group("Shape & Motion")
@export_range(0.0, 2.0, 0.02) var speed: float = 0.28
@export_range(0.15, 3.0, 0.05) var wavelength: float = 1.5
@export_range(-1.0, 1.0, 0.05) var stretch: float = -1.0
@export_range(0.0, 2.0, 0.05) var fold: float = 0.45
@export_range(0.0, 3.0, 0.05) var twist: float = 1.9

@export_group("Sheets (per group)")
@export_range(1.0, 6.0, 0.5) var layers: float = 5.0
@export_range(0.0, 8.0, 0.1) var y_spread: float = 0.0
@export_range(-1.0, 1.0, 0.02) var y_off: float = 0.62
@export_range(0.0, 360.0, 1.0) var orient_deg: float = 88.0

@export_group("Group Clones")
@export_range(1.0, 4.0, 0.25) var group_clones: float = 1.0
@export_range(4.0, 40.0, 0.5) var group_gap: float = 12.0
@export_range(0.0, 1.0, 0.05) var group_vary: float = 0.5

@export_group("Appearance")
@export_range(0.0, 1.0, 0.02) var opacity: float = 0.20
@export_range(0.2, 3.0, 0.05) var edge: float = 0.75
@export_range(-1.0, 1.0, 0.02) var sheen: float = -0.30
@export_range(0.0, 2.0, 0.05) var contrast: float = 1.30

@export_group("Camera")
@export_range(-10.0, 30.0, 0.5) var cam_height: float = 6.0
@export_range(20.0, 120.0, 1.0) var cam_dist: float = 44.0
@export_range(-10.0, 20.0, 0.2) var cam_pitch: float = 1.0
@export_range(25.0, 80.0, 1.0) var cam_fov: float = 40.0

const RIB_W := 130.0
const RIB_D := 16.0
# Subdivision: slightly reduced vs. 420x28 (=564k prims at 24 instances).
# 300x24 -> 14,400 tris/instance; at default visibility (~5 instances) ~72k.
const SEG_X := 300
const SEG_Z := 24
const MAX_LAYERS := 6
const MAX_GROUPS := 4

@onready var _camera: Camera3D = $Camera3D
@onready var _cloth: MultiMeshInstance3D = $Cloth
var _mat: ShaderMaterial
var _mm: MultiMesh
var _plane: PlaneMesh

# Width factor (aspect/16:9): stretches the X width of the cloth plane (RIB_W) so
# the sheets fill the width on wide/wall resolutions. The cloth is rotated around Z
# (orient_deg ~90 -> plane-X ~ world-X). Z/Y stay unchanged.
var _wfac: float = 1.0


func _ready() -> void:
	var stage := get_node_or_null("/root/BackgroundStage")
	_wfac = stage.width_factor() if stage else 1.0
	if stage:
		stage.aspect_changed.connect(_on_aspect_changed)

	_plane = PlaneMesh.new()
	_plane.size = Vector2(RIB_W * _wfac, RIB_D)
	_plane.subdivide_width = SEG_X
	_plane.subdivide_depth = SEG_Z

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _plane
	_mm.instance_count = MAX_GROUPS * MAX_LAYERS
	_cloth.multimesh = _mm
	_apply_aabb()

	_mat = _cloth.material_override as ShaderMaterial
	_update_camera()
	_update_cloth()


# Generous AABB (X half-extent widened by _wfac): prevents frustum culling by
# vertex displacement + group offset and the stretched plane width.
func _apply_aabb() -> void:
	var hx := 140.0 * maxf(1.0, _wfac)
	_cloth.custom_aabb = AABB(Vector3(-hx, -120.0, -140.0), Vector3(hx * 2.0, 240.0, 280.0))


# Aspect change: reset X width of the plane (MultiMesh shares ONE plane for
# all instances -> one mesh update is enough). Z/Y stay unchanged.
func _on_aspect_changed(aspect: float) -> void:
	var nf := aspect / (16.0 / 9.0)
	if absf(nf - _wfac) < 0.0001:
		return
	_wfac = nf
	if _plane != null:
		_plane.size = Vector2(RIB_W * _wfac, RIB_D)
	_apply_aabb()


func _process(_delta: float) -> void:
	_update_camera()
	_update_cloth()


func _update_camera() -> void:
	if _camera == null:
		return
	_camera.fov = cam_fov
	_camera.position = Vector3(0.0, cam_height, cam_dist)
	_camera.look_at(Vector3(0.0, cam_pitch + y_off * 4.0, 0.0), Vector3.UP)


func _update_cloth() -> void:
	if _mat == null or _mm == null:
		return

	_cloth.rotation.z = PI * 0.5 - deg_to_rad(orient_deg)

	_mat.set_shader_parameter("u_speed", speed)
	_mat.set_shader_parameter("u_wavelength", wavelength)
	_mat.set_shader_parameter("u_stretch", stretch)
	_mat.set_shader_parameter("u_fold", fold)
	_mat.set_shader_parameter("u_twist", twist)
	_mat.set_shader_parameter("u_opacity", opacity)
	_mat.set_shader_parameter("u_edge", edge)
	_mat.set_shader_parameter("u_glanz", sheen)
	_mat.set_shader_parameter("u_contrast", contrast)

	var l_count := clampf(layers, 0.0001, float(MAX_LAYERS))       # sheets per group
	var g_count := clampf(group_clones, 0.0001, float(MAX_GROUPS)) # group clones
	var l_mid := (l_count - 1.0) * 0.5
	var g_mid := (g_count - 1.0) * 0.5

	# Only render active layers/groups. Inactive instances had fade=0 (alpha 0)
	# and were invisible but still fully rasterized -> pure waste.
	# ceil() captures the fractional last layer/group (soft fade-in).
	var active_g := int(ceil(g_count))
	var active_l := int(ceil(l_count))
	var write := 0  # compact buffer index; order stays back -> front
	for g in active_g:
		var g_fade := clampf(g_count - float(g), 0.0, 1.0)
		var group_y := (float(g) - g_mid) * group_gap
		var group_phase := float(g + 1) * 3.91 * group_vary
		for l in active_l:
			var l_fade := clampf(l_count - float(l), 0.0, 1.0)
			var fade := g_fade * l_fade
			var stack := float(l) - l_mid
			var phase := (float(l) * 1.7 + 0.5) + group_phase
			var tr := Transform3D.IDENTITY
			# Layer stack + group offset + global height offset (uYOff*6 in the web version).
			tr.origin = Vector3(0.0, stack * y_spread + y_off * 6.0 + group_y, stack * 1.1)
			_mm.set_instance_transform(write, tr)
			_mm.set_instance_custom_data(write, Color(phase, fade, 0.0, 0.0))
			write += 1
	_mm.visible_instance_count = write
