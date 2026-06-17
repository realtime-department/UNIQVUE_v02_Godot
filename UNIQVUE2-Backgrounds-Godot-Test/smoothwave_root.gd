extends Node3D
## Smooth Wave — Wurzelskript (Port aus studio-v026.html createSmoothWaveModule).
##
## MAX_GROUPS (4) x MAX_LAYERS (6) "Tuecher" als EIN MultiMesh ueber einem
## PlaneMesh. Pro Frame:
##   - Kamera setzen (Position/Blickziel/FOV) wie applyCamera() im Web.
##   - Globale Form-/Darstellungs-Uniforms ans Material schieben.
##   - Pro Instanz: Transform (Layer-Stack + Gruppen-Versatz) und INSTANCE_CUSTOM
##     (Form-Seed + weicher Einblend-Fade) setzen.
##   - Knoten-Rotation z = PI/2 - Ausrichtung (cloth.rotation.z im Web).
##
## Fraktionale "layers"/"group_clones" blenden den jeweils letzten Layer/Klon
## weich ein (Fade -> Alpha im Shader). @export-Werte sind die einzige
## Parameterquelle; ParamStore erfasst sie als scene/*.

@export_group("Form & Bewegung")
@export_range(0.0, 2.0, 0.02) var speed: float = 0.28
@export_range(0.15, 3.0, 0.05) var wavelength: float = 1.5
@export_range(-1.0, 1.0, 0.05) var stretch: float = -1.0
@export_range(0.0, 2.0, 0.05) var fold: float = 0.45
@export_range(0.0, 3.0, 0.05) var twist: float = 1.9

@export_group("Tuecher (pro Gruppe)")
@export_range(1.0, 6.0, 0.5) var layers: float = 5.0
@export_range(0.0, 8.0, 0.1) var y_spread: float = 0.0
@export_range(-1.0, 1.0, 0.02) var y_off: float = 0.62
@export_range(0.0, 360.0, 1.0) var orient_deg: float = 88.0

@export_group("Gruppen-Klone")
@export_range(1.0, 4.0, 0.25) var group_clones: float = 1.0
@export_range(4.0, 40.0, 0.5) var group_gap: float = 12.0
@export_range(0.0, 1.0, 0.05) var group_vary: float = 0.5

@export_group("Darstellung")
@export_range(0.0, 1.0, 0.02) var opacity: float = 0.20
@export_range(0.2, 3.0, 0.05) var edge: float = 0.75
@export_range(-1.0, 1.0, 0.02) var glanz: float = -0.30
@export_range(0.0, 2.0, 0.05) var contrast: float = 1.30

@export_group("Kamera")
@export_range(-10.0, 30.0, 0.5) var cam_height: float = 6.0
@export_range(20.0, 120.0, 1.0) var cam_dist: float = 44.0
@export_range(-10.0, 20.0, 0.2) var cam_pitch: float = 1.0
@export_range(25.0, 80.0, 1.0) var cam_fov: float = 40.0

const RIB_W := 130.0
const RIB_D := 16.0
const SEG_X := 420
const SEG_Z := 28
const MAX_LAYERS := 6
const MAX_GROUPS := 4

@onready var _camera: Camera3D = $Camera3D
@onready var _cloth: MultiMeshInstance3D = $Cloth
var _mat: ShaderMaterial
var _mm: MultiMesh


func _ready() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(RIB_W, RIB_D)
	plane.subdivide_width = SEG_X
	plane.subdivide_depth = SEG_Z

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = plane
	_mm.instance_count = MAX_GROUPS * MAX_LAYERS
	_cloth.multimesh = _mm
	# Grosszuegige AABB: verhindert Frustum-Culling durch Vertex-Displacement +
	# Gruppen-Versatz (Geometrie verlaesst die ungebeugte Plane-Box deutlich).
	_cloth.custom_aabb = AABB(Vector3(-140.0, -120.0, -140.0), Vector3(280.0, 240.0, 280.0))

	_mat = _cloth.material_override as ShaderMaterial
	_update_camera()
	_update_cloth()


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
	_mat.set_shader_parameter("u_glanz", glanz)
	_mat.set_shader_parameter("u_contrast", contrast)

	var l_count := clampf(layers, 0.0001, float(MAX_LAYERS))       # Tuecher pro Gruppe
	var g_count := clampf(group_clones, 0.0001, float(MAX_GROUPS)) # Gruppen-Klone
	var l_mid := (l_count - 1.0) * 0.5
	var g_mid := (g_count - 1.0) * 0.5

	for g in MAX_GROUPS:
		var g_fade := clampf(g_count - float(g), 0.0, 1.0)
		var group_y := (float(g) - g_mid) * group_gap
		var group_phase := float(g + 1) * 3.91 * group_vary
		for l in MAX_LAYERS:
			var idx := g * MAX_LAYERS + l   # = renderOrder im Web (hinten -> vorne)
			var l_fade := clampf(l_count - float(l), 0.0, 1.0)
			var fade := g_fade * l_fade
			var stack := float(l) - l_mid
			var phase := (float(l) * 1.7 + 0.5) + group_phase
			var tr := Transform3D.IDENTITY
			# Layer-Stack + Gruppen-Versatz + globaler Hoehen-Offset (uYOff*6 im Web).
			tr.origin = Vector3(0.0, stack * y_spread + y_off * 6.0 + group_y, stack * 1.1)
			_mm.set_instance_transform(idx, tr)
			_mm.set_instance_custom_data(idx, Color(phase, fade, 0.0, 0.0))
