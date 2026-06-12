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

@export_group("Camera")
@export_range(0.5, 40.0, 0.5) var cam_height: float = 3.5
@export_range(20.0, 160.0, 1.0) var cam_dist: float = 70.0
@export_range(-20.0, 20.0, 0.5) var cam_pitch: float = 5.0  # Y-coord of look target (not angle)
@export_range(-40.0, 40.0, 0.5) var cam_yaw: float = 0.0
@export_range(25.0, 90.0, 1.0) var cam_fov: float = 60.0

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_update_camera()


func _process(_delta: float) -> void:
	_update_camera()
	_sync_wire()


func _update_camera() -> void:
	if _camera == null:
		return
	_camera.fov = cam_fov
	_camera.position = Vector3(cam_yaw, cam_height, -cam_dist)
	# cam_pitch ist die Y-Koordinate des Blickziels (wie HTML: CAM_LOOK.set(camYaw*0.3, camPitch, -60)).
	_camera.look_at(Vector3(cam_yaw * 0.3, cam_pitch, 60.0), Vector3.UP)


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
			"dir", "y_off", "mirror", "z_near", "z_far"]:
		wm.set_shader_parameter(p, gm.get_shader_parameter(p))
