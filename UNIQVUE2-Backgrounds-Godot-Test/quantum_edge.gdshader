shader_type spatial;
// Quantum — EDGES / Wireframe (port from studio-v026.html edgeVert/edgeFrag).
// Same radial fBm deformation as quantum.gdshader; v_centU = u (from VERTEX.x),
// no per-face UV. Additive.
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;

global uniform vec4 fog_color : source_color;
global uniform vec4 elem_a : source_color;
global uniform vec4 elem_b : source_color;

group_uniforms _Live;
uniform float u_speed = 0.08;
uniform float u_flow = 1.18;
uniform float u_warp = 1.35;
uniform float u_amp = 1.10;
uniform float u_detail = 2.0;
uniform float u_wavelength = 0.90;
uniform float u_diameter = 0.85;
uniform float u_spin = 0.02;
uniform float u_depth_fog = 1.60;
uniform float u_light_u = 0.5;
uniform float u_light_width = 0.53;
uniform float u_edge_opacity = 0.50;
group_uniforms;

const float TUBE_LEN = 460.0;
const float BASE_R = 26.0;
const float RAD_AMP = 23.4;

varying float v_rad;
varying float v_fog;
varying float v_centU;
varying float v_clone_fade;

float hash3(vec3 p) { return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }
float smoother(float t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = p - i;
	float u = smoother(f.x);
	float v = smoother(f.y);
	float w = smoother(f.z);
	float c000 = hash3(i + vec3(0.0, 0.0, 0.0));
	float c100 = hash3(i + vec3(1.0, 0.0, 0.0));
	float c010 = hash3(i + vec3(0.0, 1.0, 0.0));
	float c110 = hash3(i + vec3(1.0, 1.0, 0.0));
	float c001 = hash3(i + vec3(0.0, 0.0, 1.0));
	float c101 = hash3(i + vec3(1.0, 0.0, 1.0));
	float c011 = hash3(i + vec3(0.0, 1.0, 1.0));
	float c111 = hash3(i + vec3(1.0, 1.0, 1.0));
	float x00 = mix(c000, c100, u);
	float x10 = mix(c010, c110, u);
	float x01 = mix(c001, c101, u);
	float x11 = mix(c011, c111, u);
	return mix(mix(x00, x10, v), mix(x01, x11, v), w) * 2.0 - 1.0;
}
float fbm(vec3 p) {
	float a = 0.0;
	float amp = 0.5;
	float fr = 1.0;
	for (int o = 0; o < 3; o++) {
		a += vnoise(p * fr) * amp;
		amp *= 0.5;
		fr *= 2.0;
	}
	return a;
}
// Stage builtins (VERTEX/INSTANCE_CUSTOM) are NOT available in helper functions
// and are passed as parameters (phase = INSTANCE_CUSTOM.x). TIME is globally ok.
float radialN(float u, float ang, float t, float phase) {
	float ns = 0.018 / max(0.2, u_wavelength) * TUBE_LEN;
	vec3 dir = vec3(0.0, cos(ang), sin(ang));
	float wx = fbm(vec3(u * ns + t + phase, dir.y * 0.8, dir.z * 0.8)) * 6.0;
	float base = fbm(vec3(u * ns + t + wx * 0.05 * u_warp + phase, dir.y * 1.2 + 5.0, dir.z * 1.2 + 5.0));
	float fine = fbm(vec3(u * ns * 3.1 + t * 1.3 + phase, dir.y * 2.4, dir.z * 2.4)) * 0.4 * u_detail;
	return base + fine;
}
vec3 deform(vec3 vert, float phase, out float vrad, out float vu) {
	float u = vert.x / TUBE_LEN + 0.5;
	float ang = atan(vert.z, vert.y) + u_spin * 0.3 * TIME;
	vu = u;
	float x = (u - 0.5) * TUBE_LEN;
	vec3 dir = vec3(0.0, cos(ang), sin(ang));
	float t = TIME * u_speed * u_flow;
	float r = radialN(u, ang, t, phase);
	vrad = clamp(r * 0.5 + 0.5, 0.0, 1.0);
	float eff_r = (BASE_R + r * (RAD_AMP * u_amp)) * u_diameter;
	eff_r = max(eff_r, BASE_R * u_diameter * 0.12);
	return vec3(x, dir.y * eff_r, dir.z * eff_r);
}

float light_at(float u) {
	float d = abs(u - u_light_u);
	return exp(-(d * d) / max(0.0005, u_light_width * u_light_width * 0.5));
}
float fog_mix(float vz) {
	float n = clamp((vz - 70.0) / 360.0, 0.0, 1.0);
	return clamp(n * u_depth_fog, 0.0, 0.9);
}

void vertex() {
	float vr;
	float vu;
	vec3 p = deform(VERTEX, INSTANCE_CUSTOM.x, vr, vu);
	v_rad = vr;
	v_centU = vu;
	v_clone_fade = INSTANCE_CUSTOM.y;
	vec4 mv = MODELVIEW_MATRIX * vec4(p, 1.0);
	v_fog = -mv.z;
	VERTEX = p;
}

void fragment() {
	float lit = light_at(v_centU);
	vec3 col = mix(elem_a.rgb, elem_b.rgb, 0.5 + v_rad * 0.3 + lit * 0.4);
	float fm = fog_mix(v_fog);
	col = mix(col, fog_color.rgb, fm);
	float a = u_edge_opacity * (0.7 + lit * 0.6) * (1.0 - fm * 0.85) * v_clone_fade;
	if (a <= 0.0009) {
		discard;
	}
	ALBEDO = col;
	EMISSION = col;
	ALPHA = a;
}
