shader_type spatial;
// Cube-tunnel surface — Phong lighting, depth fog, alpha blend.
// All per-instance positioning is computed from INSTANCE_ID in the vertex
// shader so the MultiMesh needs no per-frame transform uploads.
render_mode unshaded, blend_mix, depth_draw_always, cull_back;

global uniform vec4 fog_color : source_color;
global uniform vec4 elem_a    : source_color;
global uniform vec4 elem_b    : source_color;

uniform float tunnel_size  : hint_range(8.0, 40.0)   = 26.5;
uniform float cube_scale   : hint_range(0.85, 1.6)   = 1.37;
uniform float cube_jitter  : hint_range(0.0, 1.5)    = 1.50;
uniform float wall_tilt    : hint_range(-1.0, 1.0)   = 0.24;
uniform float tunnel_rot   = 0.0;
uniform float scroll       = 0.0;   // advances each frame (negative, wraps)
uniform float span_z       = 795.0; // = cube_w * ROWS, updated each frame

uniform float face_light   : hint_range(0.05, 1.0)   = 0.17;
uniform float spec         : hint_range(0.0, 1.8)    = 0.55;
uniform float shininess    : hint_range(6.0, 70.0)   = 38.0;
uniform float light_angle  : hint_range(0.0, 180.0)  = 74.0;
uniform float opacity      : hint_range(0.2, 1.5)    = 1.0;
uniform float fog_start    : hint_range(60.0, 1200.0) = 140.0;
uniform float fog_density  : hint_range(0.0, 2.0)    = 1.1;

varying vec3  v_n;
varying vec3  v_view;
varying float v_dist;
varying float v_seed;

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

	v_seed = h(float(INSTANCE_ID) * 0.7);
	float jit = (v_seed - 0.5) * cube_jitter * cube_w;
	float ly0 = -tunnel_size + sc * 0.5 + jit;

	float dx = lx0; float dy = ly0 - (-tunnel_size);
	float lx = ct * dx - st * dy;
	float ly = (-tunnel_size) + (st * dx + ct * dy);

	float wx = lx * ca - ly * sa;
	float wy = lx * sa + ly * ca;

	float zc = mod(float(r) * cell_d + scroll, span_z);
	if (zc < 0.0) zc += span_z;

	float rot_z = ang + tilt;
	float cz = cos(rot_z); float sz = sin(rot_z);

	// Scale, then rotate Z, then translate
	vec3 sv = VERTEX * sc;
	vec3 wpos = vec3(
		sv.x * cz - sv.y * sz + wx,
		sv.x * sz + sv.y * cz + wy,
		sv.z - zc
	);

	// Normal: rotate only (no scale — normals must stay unit-length after normalise)
	vec3 nr = normalize(vec3(
		NORMAL.x * cz - NORMAL.y * sz,
		NORMAL.x * sz + NORMAL.y * cz,
		NORMAL.z
	));

	vec4 vp = VIEW_MATRIX * vec4(wpos, 1.0);
	v_n    = normalize((VIEW_MATRIX * vec4(nr, 0.0)).xyz);
	v_view = normalize(-vp.xyz);
	v_dist = -vp.z;
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	vec3 N = normalize(v_n);
	vec3 V = normalize(v_view);
	float la = light_angle * 3.14159265 / 180.0;
	vec3 L  = normalize(vec3(cos(la) * 0.5, sin(la) * 0.6, 0.84));
	float diff = max(0.0, dot(N, L));
	float hl   = diff * 0.5 + 0.5;
	vec3 H  = normalize(L + V);
	float sp   = pow(max(0.0, dot(N, H)), shininess) * spec;
	vec3 face  = elem_a.rgb * (face_light * hl) * (0.85 + 0.3 * v_seed);
	vec3 col   = face + elem_b.rgb * sp;
	float fog_mix = clamp(1.0 - exp(-max(0.0, v_dist - fog_start) * 0.003 * fog_density), 0.0, 1.0);
	col = mix(col, fog_color.rgb, fog_mix * 0.9);
	float near_f = smoothstep(0.5, 10.0, v_dist);
	float far_f  = 1.0 - smoothstep(fog_start, span_z * 0.98, v_dist);
	float a = opacity * near_f * far_f;
	if (a < 0.003) { discard; }
	ALBEDO = col;
	ALPHA  = a;
}
