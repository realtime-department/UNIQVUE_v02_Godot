extends Node3D
## Plexus - 3D-Punktnetz, ported from studio-v005 createPlexusModule()
## (studio-v005.html:563-748).
##
## CPU-Sim nach dem Muster von tunnel_sim.gd: N Punkte (max 900) treiben
## velocity-gesteuert in einer 22 x 13 x (8+depth*34) Box. Der Chaos-Regler
## blendet zwischen laminarer Stroemung und turbulentem Feld. Hub-Punkte
## (deterministisch via rngHash + hubs-Anteil) sind groesser/heller und
## verstaerken ihre Links. Pro Frame EIN Grid-Nachbarpass (HTML buildGrid)
## liefert gleichzeitig Separationskraefte (SEP_R) und Links (< link_dist,
## smoothstep-Fade ueber link_soft); Geometrie wird in persistente Buffer
## geschrieben und je Mesh in EINEM add_surface_from_arrays hochgeladen
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

# Spatial grid (HTML buildGrid): head-of-linked-list per cell + per-point next.
var _grid_buf: PackedInt32Array
var _next_idx: PackedInt32Array
var _gx: int = 1
var _gy: int = 1
var _gz: int = 1
var _cell_size: float = 3.6

# Persistent geometry buffers, filled by index each frame then uploaded once.
var _lp: PackedVector3Array      # line vertex positions (2 per link)
var _lc: PackedColorArray        # line vertex colours (alpha in .a)
var _pp: PackedVector3Array      # point positions
var _pc: PackedColorArray        # point colours (hub in .r)

var _t: float = 0.0
var _box_z: float = 14.0
var _depth_cache: float = -1.0
var _hubs_cache: float = -1.0

# --- Profiling: prints the CPU cost of each sim phase every 60 frames so we can
# tell whether we are CPU- or GPU-bound. Set to false to silence.
@export var profile: bool = false
var _pf_nbr: int = 0
var _pf_int: int = 0
var _pf_up: int = 0
var _pf_frames: int = 0
var _pf_links: int = 0

var _point_mesh: ArrayMesh
var _line_mesh: ArrayMesh
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
	_next_idx = PackedInt32Array(); _next_idx.resize(NMAX)
	_lp = PackedVector3Array(); _lp.resize(LMAX * 2)
	_lc = PackedColorArray();  _lc.resize(LMAX * 2)
	_pp = PackedVector3Array(); _pp.resize(NMAX)
	_pc = PackedColorArray();  _pc.resize(NMAX)
	_box_z = 8.0 + depth * 34.0
	_depth_cache = depth
	_hubs_cache = hubs
	_seed()
	_point_mesh = ArrayMesh.new()
	_line_mesh = ArrayMesh.new()
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


## Spatial grid (port of HTML buildGrid): bucket the first n points into cells
## of side cell_size; _grid_buf[ci] is the head of a per-cell linked list, with
## _next_idx[i] chaining to the next point in the same cell.
func _build_grid(cs: float, n: int) -> void:
	_cell_size = maxf(0.5, cs)
	_gx = int(ceil(BOX_X / _cell_size)) + 2
	_gy = int(ceil(BOX_Y / _cell_size)) + 2
	_gz = int(ceil(_box_z / _cell_size)) + 2
	var total := _gx * _gy * _gz
	if _grid_buf.size() != total:
		_grid_buf.resize(total)
	_grid_buf.fill(-1)
	var ox := BOX_X * 0.5
	var oy := BOX_Y * 0.5
	var oz := _box_z * 0.5
	for i in range(n):
		var i3 := i * 3
		var cx := clampi(int(floor((_pos[i3]     + ox) / _cell_size)) + 1, 0, _gx - 1)
		var cy := clampi(int(floor((_pos[i3 + 1] + oy) / _cell_size)) + 1, 0, _gy - 1)
		var cz := clampi(int(floor((_pos[i3 + 2] + oz) / _cell_size)) + 1, 0, _gz - 1)
		var ci := (cz * _gy + cy) * _gx + cx
		_next_idx[i] = _grid_buf[ci]
		_grid_buf[ci] = i


func _simulate(dt: float) -> void:
	var n := clampi(count, 40, NMAX)
	var t0 := Time.get_ticks_usec()

	# --- One spatial grid at link_dist serves BOTH separation (radius SEP_R) and
	# links (radius link_dist): since link_dist >= SEP_R, a single 3x3x3 scan
	# finds every neighbour either pass needs. Separation forces, link segments
	# and the point cloud are all produced from the current positions in this one
	# pass; integration follows, so points and link endpoints stay aligned.
	_build_grid(link_dist, n)
	_sep.fill(0.0)
	var posr := _pos          # read-only alias -> faster inner reads (CoW safe)
	var grid := _grid_buf
	var nxt := _next_idx
	var hub := _hub
	var sr2 := SEP_R * SEP_R
	var max_d := link_dist
	var max_d2 := max_d * max_d
	var inner := max_d * (1.0 - link_soft)
	var inner_rng := maxf(0.0001, max_d - inner)
	var ox := BOX_X * 0.5
	var oy := BOX_Y * 0.5
	var oz := _box_z * 0.5
	var gx := _gx
	var gy := _gy
	var gz := _gz
	var cs := _cell_size
	var li := 0
	for i in range(n):
		var i3 := i * 3
		var xi := posr[i3]
		var yi := posr[i3 + 1]
		var zi := posr[i3 + 2]
		var hub_i := hub[i]
		var cx := clampi(int(floor((xi + ox) / cs)) + 1, 0, gx - 1)
		var cy := clampi(int(floor((yi + oy) / cs)) + 1, 0, gy - 1)
		var cz := clampi(int(floor((zi + oz) / cs)) + 1, 0, gz - 1)
		for dz in range(-1, 2):
			var nz := cz + dz
			if nz < 0 or nz >= gz: continue
			for dy in range(-1, 2):
				var ny := cy + dy
				if ny < 0 or ny >= gy: continue
				for dx in range(-1, 2):
					var nx := cx + dx
					if nx < 0 or nx >= gx: continue
					var j := grid[(nz * gy + ny) * gx + nx]
					while j != -1:
						if j != i:
							var j3 := j * 3
							var ddx := xi - posr[j3]
							var ddy := yi - posr[j3 + 1]
							var ddz := zi - posr[j3 + 2]
							var d2 := ddx * ddx + ddy * ddy + ddz * ddz
							# Beyond link_dist contributes to neither pass; one
							# sqrt then serves separation and the link alpha.
							if d2 < max_d2 and d2 > 1e-4:
								var dsq := sqrt(d2)
								if d2 < sr2:
									var inv := (1.0 - dsq / SEP_R) / dsq
									_sep[i3] += ddx * inv
									_sep[i3 + 1] += ddy * inv
									_sep[i3 + 2] += ddz * inv
								if j > i and li < LMAX:
									var a: float
									if dsq <= inner:
										a = 1.0
									else:
										var tt := (dsq - inner) / inner_rng
										a = 1.0 - tt * tt * (3.0 - 2.0 * tt)
									a *= 1.0 + (hub_i + hub[j]) * 0.5
									var lc := Color(1.0, 1.0, 1.0, a)
									var b := li * 2
									_lp[b] = Vector3(xi, yi, zi)
									_lc[b] = lc
									_lp[b + 1] = Vector3(posr[j3], posr[j3 + 1], posr[j3 + 2])
									_lc[b + 1] = lc
									li += 1
						j = nxt[j]
		# Point i (current position); hub in COLOR.r.
		_pp[i] = Vector3(xi, yi, zi)
		_pc[i] = Color(hub_i, 0.0, 0.0, 1.0)

	var t1 := Time.get_ticks_usec()

	# --- Integration (HTML step()): Flow + Separation + Jitter, Daempfung,
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

	var t2 := Time.get_ticks_usec()
	_upload_meshes(n, li)

	if profile:
		var t3 := Time.get_ticks_usec()
		_pf_nbr += t1 - t0
		_pf_int += t2 - t1
		_pf_up += t3 - t2
		_pf_links += li
		_pf_frames += 1
		if _pf_frames >= 60:
			var f := float(_pf_frames)
			print("plexus n=%d links=%d | sim cpu/frame: neighbours+emit %.2fms  integrate %.2fms  upload %.2fms  TOTAL %.2fms | fps=%.0f (frame budget %.2fms)" % [
				n, _pf_links / _pf_frames,
				_pf_nbr / f / 1000.0, _pf_int / f / 1000.0, _pf_up / f / 1000.0,
				(_pf_nbr + _pf_int + _pf_up) / f / 1000.0,
				Engine.get_frames_per_second(), 1000.0 / maxf(1.0, Engine.get_frames_per_second())])
			_pf_nbr = 0; _pf_int = 0; _pf_up = 0; _pf_links = 0; _pf_frames = 0


## Single batched upload per mesh (replaces per-vertex ImmediateMesh calls).
func _upload_meshes(n: int, li: int) -> void:
	_line_mesh.clear_surfaces()
	if li > 0:
		var arrs: Array = []
		arrs.resize(Mesh.ARRAY_MAX)
		arrs[Mesh.ARRAY_VERTEX] = _lp.slice(0, li * 2)
		arrs[Mesh.ARRAY_COLOR]  = _lc.slice(0, li * 2)
		_line_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrs)
	_point_mesh.clear_surfaces()
	if n > 0:
		var parrs: Array = []
		parrs.resize(Mesh.ARRAY_MAX)
		parrs[Mesh.ARRAY_VERTEX] = _pp.slice(0, n)
		parrs[Mesh.ARRAY_COLOR]  = _pc.slice(0, n)
		_point_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, parrs)
