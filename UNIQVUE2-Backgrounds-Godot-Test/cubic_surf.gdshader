shader_type spatial;
// Cube-tunnel surface — Half-Lambert + specular, depth fog, alpha blend.
// Faithful port of studio-v005 surfMat: all per-instance positioning comes from
// the MultiMesh instance transform (MODELVIEW_MATRIX); the shader only lights.
// Per-instance brightness varies via the seed stored in INSTANCE_CUSTOM.x.
render_mode unshaded, blend_mix, depth_draw_always, cull_back;

global uniform vec4 fog_color : source_color;
global uniform vec4 elem_a    : source_color;
global uniform vec4 elem_b    : source_color;

uniform float face_light   : hint_range(0.05, 1.0)   = 0.17;
uniform float spec         : hint_range(0.0, 1.8)    = 0.55;
uniform float shininess    : hint_range(6.0, 70.0)   = 38.0;
uniform float light_angle  : hint_range(0.0, 180.0)  = 74.0;
uniform float opacity      : hint_range(0.2, 1.5)    = 1.0;
uniform float fog_start    : hint_range(60.0, 1200.0) = 140.0;
uniform float fog_density  : hint_range(0.0, 2.0)    = 1.1;
uniform float z_far        = 795.0;

varying vec3  v_n;
varying vec3  v_view;
varying float v_dist;
varying float v_seed;

void vertex() {
	v_seed = INSTANCE_CUSTOM.x;
	vec4 mv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	v_n     = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_view  = normalize(-mv.xyz);
	v_dist  = -mv.z;
	POSITION = PROJECTION_MATRIX * mv;
}

void fragment() {
	vec3 N = normalize(v_n);
	vec3 V = normalize(v_view);
	float la = light_angle * PI / 180.0;
	vec3 L  = normalize(vec3(cos(la) * 0.5, sin(la) * 0.6, 0.84));
	float diff = max(0.0, dot(N, L));
	float hl   = diff * 0.5 + 0.5;              // Half-Lambert
	vec3 H  = normalize(L + V);
	float sp   = pow(max(0.0, dot(N, H)), shininess) * spec;
	vec3 face  = elem_a.rgb * (face_light * hl) * (0.85 + 0.3 * v_seed);
	vec3 col   = face + elem_b.rgb * sp;
	float fog_mix = clamp(1.0 - exp(-max(0.0, v_dist - fog_start) * 0.003 * fog_density), 0.0, 1.0);
	col = mix(col, fog_color.rgb, fog_mix * 0.9);
	float near_f = smoothstep(0.5, 10.0, v_dist);
	float far_f  = 1.0 - smoothstep(fog_start, z_far * 0.98, v_dist);
	float a = opacity * near_f * far_f;
	if (a < 0.003) { discard; }
	ALBEDO = col;
	ALPHA  = a;
}
