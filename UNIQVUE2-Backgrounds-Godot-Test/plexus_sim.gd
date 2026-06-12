extends Node3D
## Plexus - 3D-Punktnetz, ported from studio-v005 createPlexusModule()
## (studio-v005.html:563-748).
##
## CPU-Sim nach dem Muster von tunnel_sim.gd: N Punkte (max 900) treiben
## velocity-gesteuert in einer 22 x 13 x (8+depth*34) Box. Der Chaos-Regler
## blendet zwischen laminarer Stroemung und turbulentem Feld. Hub-Punkte
## (deterministisch via rngHash + hubs-Anteil) sind groesser/heller und
## verstaerken ihre Links. Pro Frame ein O(N^2)-Paar-Pass, der gleichzeitig
## Separationskraefte (SEP_R) und Links (< link_dist, smoothstep-Fade ueber
## link_soft) liefert; daraus werden zwei ImmediateMesh gebaut
## (PRIMITIVE_LINES + PRIMITIVE_POINTS).
##
## Farben kommen NICHT aus @exports: die Shader (plexus.gdshader /
## plexus_line.gdshader) lesen die globalen STYLE-Uniforms
## fog_color/elem_a/elem_b direkt (uC1/uC2/uC3 im Web, studio-v005.html:697).
## Pro-Punkt-Daten laufen ueber die Vertex-Color: Punkte COLOR.r = hub,
## Linien COLOR.a = Link-Alpha.

@export_group("Netz & Bewegung")
@export_range(0.0, 1.5, 0.02) var speed: float = 0.10
@export_range(0.0, 1.5, 0.02) var drift: float = 0.66
@export_range(0.0, 1.0, 0.02) var chaos: float = 0.88
@export_range(1.5, 8.0, 0.1) var link_dist: float = 5.1
@export_range(0.0, 0.95, 0.02) var link_soft: float = 0.64

@export_group("Komposition")
@export_range(60, 900, 10) var count: int = 420
@export_range(0.0, 1.0, 0.02) var depth: float = 0.88
@export_range(0.0, 0.6, 0.02) var hubs: float = 0.28

@export_group("Darstellung")
@export_range(2.0, 16.0, 0.5) var point_size: float = 2.5
@export_range(0.0, 1.5, 0.05) var point_opacity: float = 1.05
@export_range(0.0, 1.5, 0.05) var line_opacity: float = 0.45
@export_range(0.0, 1.0, 0.05) var depth_fade: float = 1.0

@export_group("Kamera")
@export_range(6.0, 60.0, 0.5) var cam_dist: float = 16.0
@export_range(-20.0, 20.0, 0.5) var cam_height: float = 0.0
@export_range(-20.0, 20.0, 0.5) var cam_yaw: float = 0.0
@export_range(-180.0, 180.0, 1.0) var cam_roll: float = 0.0
@export_range(25.0, 90.0, 1.0) var cam_fov: float = 50.0

const NMAX: int = 900
const LMAX: int = 24000          # max Liniensegmente pro Frame
const BOX_X: float = 22.0
const BOX_Y: float = 13.0
const SEP_R: float = 2.6         # Separations-Radius (HTML SEP_R)

var _pos: PackedFloat32Array
var _vel: PackedFloat32Array
var _hub: PackedFloat32Array
var _phase: PackedFloat32Array
var _sep: PackedFloat32Array

var _t: float = 0.0
var _box_z: float = 14.0
var _depth_cache: float = -1.0
var _hubs_cache: float = -1.0

var _point_mesh: ImmediateMesh
var _line_mesh: ImmediateMesh
var _point_mat: ShaderMaterial
var _line_mat: ShaderMaterial

@onready var _camera: Camera3D = $Camera3D
@onready var _streaks: MeshInstance3D = $Streaks
@onready var _points: MeshInstance3D = $Points


func _ready() -> void:
	_pos = PackedFloat32Array(); _pos.resize(NMAX * 3)
	_vel = PackedFloat32Array(); _vel.resize(NMAX * 3)
	_hub = PackedFloat32Array(); _hub.resize(NMAX)
	_phase = PackedFloat32Array(); _phase.resize(NMAX)
	_sep = PackedFloat32Array(); _sep.resize(NMAX * 3)
	_box_z = 8.0 + depth * 34.0
	_depth_cache = depth
	_hubs_cache = hubs
	_seed()
	_point_mesh = ImmediateMesh.new()
	_line_mesh = ImmediateMesh.new()
	_points.mesh = _point_mesh
	_streaks.mesh = _line_mesh
	_point_mat = _points.material_override as ShaderMaterial
	_line_mat = _streaks.material_override as ShaderMaterial
	# Grosszuegige AABB (Box max 22 x 13 x 42), damit nichts geculled wird.
	var big_aabb := AABB(Vector3(-20.0, -20.0, -25.0), Vector3(40.0, 40.0, 50.0))
	_points.custom_aabb = big_aabb
	_streaks.custom_aabb = big_aabb


# Deterministischer Hash wie im HTML rngHash(): frac(sin(i*127.1+0.5)*43758.5453).
func _rng_hash(i: int) -> float:
	var x := sin(float(i) * 127.1 + 0.5) * 43758.5453
	return x - floor(x)


func _seed() -> void:
	for i in range(NMAX):
		_pos[i * 3] = (randf() - 0.5) * BOX_X
		_pos[i * 3 + 1] = (randf() - 0.5) * BOX_Y
		_pos[i * 3 + 2] = (randf() - 0.5) * _box_z
		_vel[i * 3] = randf() - 0.5
		_vel[i * 3 + 1] = randf() - 0.5
		_vel[i * 3 + 2] = randf() - 0.5
		_phase[i] = _rng_hash(i + 9999) * TAU
	_re_hub()


# Hub-Staerke je Punkt aus deterministischem Hash; hubs = Anteil der Punkte > 0.
func _re_hub() -> void:
	var thr := 1.0 - hubs
	for i in range(NMAX):
		var r := _rng_hash(i)
		_hub[i] = (r - thr) / maxf(0.0001, hubs) if r > thr else 0.0


# Tiefen-Aenderung: Z-Positionen proportional auf die neue Box-Tiefe skalieren.
func _apply_depth() -> void:
	var old_z := _box_z
	_box_z = 8.0 + depth * 34.0
	if old_z > 0.0 and absf(old_z - _box_z) > 0.001:
		var k := _box_z / old_z
		for i in range(NMAX):
			_pos[i * 3 + 2] *= k


func _process(delta: float) -> void:
	var dt := minf(delta, 0.05)
	if absf(depth - _depth_cache) > 0.001:
		_depth_cache = depth
		_apply_depth()
	if absf(hubs - _hubs_cache) > 0.001:
		_hubs_cache = hubs
		_re_hub()
	_t += dt
	_simulate(dt)
	_update_camera()
	_update_materials()


func _update_camera() -> void:
	# HTML applyCamera(): position.set(camYaw, camHeight, camDist), lookAt(0,0,0),
	# Roll ueber den Up-Vektor.
	_camera.position = Vector3(cam_yaw, cam_height, cam_dist)
	var rr := deg_to_rad(cam_roll)
	_camera.look_at(Vector3.ZERO, Vector3(sin(rr), cos(rr), 0.0))
	_camera.fov = cam_fov


func _update_materials() -> void:
	# uZNear/uZFar wie im HTML render(): Kamera-Z +/- halbe Box-Tiefe.
	var z_near := maxf(0.5, cam_dist - _box_z * 0.5)
	var z_far := cam_dist + _box_z * 0.5
	if _point_mat != null:
		_point_mat.set_shader_parameter("point_size", point_size)
		_point_mat.set_shader_parameter("point_opacity", point_opacity)
		_point_mat.set_shader_parameter("depth_fade", depth_fade)
		_point_mat.set_shader_parameter("z_near", z_near)
		_point_mat.set_shader_parameter("z_far", z_far)
	if _line_mat != null:
		_line_mat.set_shader_parameter("line_opacity", line_opacity)
		_line_mat.set_shader_parameter("depth_fade", depth_fade)
		_line_mat.set_shader_parameter("z_near", z_near)
		_line_mat.set_shader_parameter("z_far", z_far)


# Stroemungsfeld (HTML flow()): laminarer + turbulenter Anteil, chaos blendet.
func _flow(x: float, y: float, z: float, ph: float) -> Vector3:
	var ch := chaos
	var lx := 0.5 + 0.25 * sin(_t * 0.2 + y * 0.08 + ph)
	var ly := 0.18 * sin(_t * 0.25 + z * 0.10 + ph * 1.3)
	var lz := 0.18 * cos(_t * 0.18 + x * 0.08 + ph * 0.7)
	var tx := (sin(y * 0.25 + _t * 0.4 + ph) - cos(z * 0.22 - _t * 0.3 + ph * 0.5)) * 2.0
	var ty := (sin(z * 0.25 - _t * 0.35 + ph * 1.1) - cos(x * 0.22 + _t * 0.25 + ph * 0.6)) * 2.0
	var tz := (sin(x * 0.25 + _t * 0.3 + ph * 0.9) - cos(y * 0.22 - _t * 0.4 + ph * 0.4)) * 2.0
	var lw := (1.0 - ch) * (1.0 - ch * 0.5)
	return Vector3(lx * lw + tx * ch, ly * lw + ty * ch, lz * lw + tz * ch)


func _simulate(dt: float) -> void:
	var n := clampi(count, 40, NMAX)
	var sr2 := SEP_R * SEP_R
	var max_d := link_dist
	var max_d2 := max_d * max_d
	var inner := max_d * (1.0 - link_soft)
	var inner_rng := maxf(0.0001, max_d - inner)

	_line_mesh.clear_surfaces()
	_point_mesh.clear_surfaces()
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_point_mesh.surface_begin(Mesh.PRIMITIVE_POINTS)

	# Ein O(N^2)-Halb-Pass (j > i) liefert Separation UND Links aus denselben
	# (aktuellen) Positionen; Punkte werden aus denselben Positionen emittiert,
	# damit Linien-Enden exakt auf den Punkten liegen. Integration folgt danach.
	_sep.fill(0.0)
	var li := 0
	for i in range(n):
		var i3 := i * 3
		var xi := _pos[i3]
		var yi := _pos[i3 + 1]
		var zi := _pos[i3 + 2]
		var hub_i := _hub[i]
		for j in range(i + 1, n):
			var j3 := j * 3
			var dx := xi - _pos[j3]
			var dy := yi - _pos[j3 + 1]
			var dz := zi - _pos[j3 + 2]
			var d2 := dx * dx + dy * dy + dz * dz
			if d2 < sr2 and d2 > 1e-4:
				var dist_s := sqrt(d2)
				var inv := (1.0 - dist_s / SEP_R) / dist_s
				_sep[i3] += dx * inv
				_sep[i3 + 1] += dy * inv
				_sep[i3 + 2] += dz * inv
				_sep[j3] -= dx * inv
				_sep[j3 + 1] -= dy * inv
				_sep[j3 + 2] -= dz * inv
			if d2 < max_d2 and li < LMAX:
				var dist := sqrt(d2)
				var a: float
				if dist <= inner:
					a = 1.0
				else:
					var tt := (dist - inner) / inner_rng
					a = 1.0 - tt * tt * (3.0 - 2.0 * tt)
				a *= 1.0 + (hub_i + _hub[j]) * 0.5
				var lc := Color(1.0, 1.0, 1.0, a)
				_line_mesh.surface_set_color(lc)
				_line_mesh.surface_add_vertex(Vector3(xi, yi, zi))
				_line_mesh.surface_set_color(lc)
				_line_mesh.surface_add_vertex(Vector3(_pos[j3], _pos[j3 + 1], _pos[j3 + 2]))
				li += 1
		# Punkt-Vertex: hub in COLOR.r (Shader skaliert Groesse/Helligkeit damit).
		_point_mesh.surface_set_color(Color(hub_i, 0.0, 0.0, 1.0))
		_point_mesh.surface_add_vertex(Vector3(xi, yi, zi))
	if li == 0:
		# surface_end() braucht mindestens einen Vertex -> unsichtbares Dummy-Segment.
		_line_mesh.surface_set_color(Color(0.0, 0.0, 0.0, 0.0))
		_line_mesh.surface_add_vertex(Vector3.ZERO)
		_line_mesh.surface_set_color(Color(0.0, 0.0, 0.0, 0.0))
		_line_mesh.surface_add_vertex(Vector3.ZERO)
	_line_mesh.surface_end()
	_point_mesh.surface_end()

	# Integration (HTML step()): Flow + Separation + Jitter, Daempfung,
	# Positions-Update, weiche Box-Grenzen (Feder zurueck ab 96 % Halbmass).
	var sp := speed
	var dr := drift
	var damp := pow(0.985, dt * 60.0)   # frameraten-unabhaengig (HTML: 0.985 @60fps)
	var mx := BOX_X * 0.5 * 0.96
	var my := BOX_Y * 0.5 * 0.96
	var mz := _box_z * 0.5 * 0.96
	for i in range(n):
		var i3 := i * 3
		var ph := _phase[i]
		var f := _flow(_pos[i3], _pos[i3 + 1], _pos[i3 + 2], ph)
		var vx := _vel[i3] + f.x * dr * dt + _sep[i3] * 2.2 * dt
		var vy := _vel[i3 + 1] + f.y * dr * dt + _sep[i3 + 1] * 2.2 * dt
		var vz := _vel[i3 + 2] + f.z * dr * dt + _sep[i3 + 2] * 2.2 * dt
		vx += sin(_t * 0.7 + ph) * 0.25 * dt
		vy += cos(_t * 0.6 + ph * 1.3) * 0.25 * dt
		vz += sin(_t * 0.5 + ph * 0.7) * 0.25 * dt
		vx *= damp
		vy *= damp
		vz *= damp
		var px := _pos[i3] + vx * sp * dt
		var py := _pos[i3 + 1] + vy * sp * dt
		var pz := _pos[i3 + 2] + vz * sp * dt
		if px > mx:
			vx -= (px - mx) * 0.5
		elif px < -mx:
			vx += (-mx - px) * 0.5
		if py > my:
			vy -= (py - my) * 0.5
		elif py < -my:
			vy += (-my - py) * 0.5
		if pz > mz:
			vz -= (pz - mz) * 0.5
		elif pz < -mz:
			vz += (-mz - pz) * 0.5
		_vel[i3] = vx
		_vel[i3 + 1] = vy
		_vel[i3 + 2] = vz
		_pos[i3] = px
		_pos[i3 + 1] = py
		_pos[i3 + 2] = pz
