extends Node3D
## ParticleWave scene root — Kamera-Parameter, Gitter-Dichte und Wire-Sync.
## @exports werden von ParamStore als scene/*-Eintraege erfasst.

@export_group("Grid")
## Gitterpunkte pro Achse. Aenderung loest einen Rebuild aus.
@export_range(25, 340, 1) var density: int = 220:
	set(v):
		density = v
		if is_inside_tree():
			var gb := get_node_or_null("Grid")
			if gb != null:
				gb.call("set_density", v)

## Kugelradius. Aenderung loest Rebuild + Shader-Sync aus.
@export_range(50.0, 300.0, 1.0) var sphere_radius: float = 100.0:
	set(v):
		sphere_radius = v
		if is_inside_tree():
			_apply_sphere_radius()

@export_group("Camera")
@export_range(0.5, 40.0, 0.5) var cam_height: float = 0.0
@export_range(20.0, 400.0, 1.0) var cam_dist: float = 220.0
@export_range(-20.0, 20.0, 0.5) var cam_pitch: float = 0.0  # Y-coord of look target (not angle)
@export_range(-40.0, 40.0, 0.5) var cam_yaw: float = 0.0
@export_range(25.0, 90.0, 1.0) var cam_fov: float = 60.0

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_apply_sphere_radius()
	_update_camera()


func _process(_delta: float) -> void:
	_update_camera()
	_sync_wire()


func _apply_sphere_radius() -> void:
	var gb := get_node_or_null("Grid")
	if gb != null:
		gb.sphere_radius = sphere_radius
		gb.call("_build")
	var grid := get_node_or_null("Grid") as MeshInstance3D
	if grid != null:
		var gm := grid.material_override as ShaderMaterial
		if gm != null:
			gm.set_shader_parameter("sphere_radius", sphere_radius)


func _update_camera() -> void:
	if _camera == null:
		return
	_camera.fov = cam_fov
	_camera.position = Vector3(cam_yaw, cam_height, -cam_dist)
	_camera.look_at(Vector3(cam_yaw * 0.3, cam_pitch, 0.0), Vector3.UP)


## Geteilte Wellen-Parameter vom Grid-Material auf das Wire-Material uebertragen,
## damit beide Netze dieselbe Wellenform zeigen. Wire-Parameter beginnen mit '_'
## und werden von UI/ParamStore nicht erfasst — nur wire_opacity ist tunable.
func _sync_wire() -> void:
	var grid := get_node_or_null("Grid") as MeshInstance3D
	var wire := get_node_or_null("Wire") as MeshInstance3D
	if grid == null or wire == null:
		return
	var gm := grid.material_override as ShaderMaterial
	var wm := wire.material_override as ShaderMaterial
	if gm == null or wm == null:
		return
	for p in ["amp", "freq", "wavelength", "speed", "flow", "warp",
			"dir", "y_off", "mirror", "z_near", "z_far", "sphere_radius"]:
		wm.set_shader_parameter(p, gm.get_shader_parameter(p))
