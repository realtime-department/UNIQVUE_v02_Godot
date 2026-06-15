shader_type spatial;
// Cube-tunnel wireframe outlines — per-instance position from INSTANCE_ID,
// additive blend. Uses elem_b tinted by glow factor.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

global uniform vec4 elem_b : source_color;

uniform float tunnel_size  : hint_range(8.0, 40.0)   = 26.5;
uniform float cube_scale   : hint_range(0.85, 1.6)   = 1.37;
uniform float cube_jitter  : hint_range(0.0, 1.5)    = 1.50;
uniform float wall_tilt    : hint_range(-1.0, 1.0)   = 0.24;
uniform float tunnel_rot   = 0.0;
uniform float scroll       = 0.0;
uniform float span_z       = 795.0;

uniform float glow         : hint_range(0.0, 1.5)    = 0.48;
uniform float opacity      : hint_range(0.0, 1.5)    = 1.0;
uniform float fog_start    : hint_range(60.0, 1200.0) = 140.0;
uniform float fog_density  : hint_range(0.0, 2.0)    = 1.1;

varying float v_dist;

float h(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

void vertex() {
	const int COLS = 10;
	const int ROWS = 150;
	const float PI = 3.14159265;

	int id  = INSTANCE_ID;
	int pw  = COLS * ROWS;
	int s   = id / pw;
	int rem = id % pw;
	int r   = rem / COLS;
	int c   = rem % COLS;

	float cube_w = (2.0 * tunnel_size) / float(COLS);
	float sc     = cube_w * cube_scale;
	float cell_d = cube_w;

	float ang = float(s) * PI * 0.5 + tunnel_rot;
	float ca = cos(ang); float sa = sin(ang);
	float tilt = wall_tilt * 0.6;
	float ct = cos(tilt); float st = sin(tilt);

	float u   = (float(c) + 0.5) / float(COLS) * 2.0 - 1.0;
	float lx0 = u * tunnel_size;

	float seed = h(float(INSTANCE_ID) * 0.7);
	float jit  = (seed - 0.5) * cube_jitter * cube_w;
	float ly0  = -tunnel_size + sc * 0.5 + jit;

	float dx = lx0; float dy = ly0 - (-tunnel_size);
	float lx = ct * dx - st * dy;
	float ly = (-tunnel_size) + (st * dx + ct * dy);

	float wx = lx * ca - ly * sa;
	float wy = lx * sa + ly * ca;

	float zc = mod(float(r) * cell_d + scroll, span_z);
	if (zc < 0.0) zc += span_z;

	float rot_z = ang + tilt;
	float cz = cos(rot_z); float sz = sin(rot_z);

	vec3 sv = VERTEX * sc;
	vec3 wpos = vec3(
		sv.x * cz - sv.y * sz + wx,
		sv.x * sz + sv.y * cz + wy,
		sv.z - zc
	);

	vec4 vp = VIEW_MATRIX * vec4(wpos, 1.0);
	v_dist   = -vp.z;
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	vec3 col = elem_b.rgb * glow;
	float fog_mix = clamp(1.0 - exp(-max(0.0, v_dist - fog_start) * 0.003 * fog_density), 0.0, 1.0);
	float near_f  = smoothstep(0.5, 10.0, v_dist);
	float far_f   = 1.0 - smoothstep(fog_start, span_z * 0.98, v_dist);
	float a = opacity * near_f * far_f * (1.0 - fog_mix * 0.9);
	if (a < 0.003) { discard; }
	ALBEDO = col;
	ALPHA  = a;
}
