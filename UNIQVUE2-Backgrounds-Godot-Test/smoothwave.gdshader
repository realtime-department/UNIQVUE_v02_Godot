shader_type spatial;
// Smooth Wave — layered transparent "sheets" (port from studio-v026.html
// createSmoothWaveModule). Procedurally deformed plane meshes with vertex
// displacement along X and over depth (fold), semi-transparent
// (alpha-over, NormalBlending in web -> blend_mix here) with filled
// translucent interior and soft edge brightening (Fresnel + rim).
//
// Unlike the other modules: ALPHA-OVER instead of additive. The sheets
// lie translucent over the gradient_sky background. depth_draw_never +
// fixed instance order (MultiMesh index = g*MAX_LAYERS+l) reproduces
// the renderOrder of the web original.
//
// Colors centrally from the global palette: elem_a = sheet base, elem_b =
// edge/highlight. Per-instance data (shape seed + fade-in) come via
// INSTANCE_CUSTOM, layer/group offset + orientation via the instance
// or node transform (smoothwave_root.gd).
render_mode unshaded, depth_draw_never, blend_mix, cull_disabled;

global uniform vec4 elem_a : source_color;
global uniform vec4 elem_b : source_color;

// Script-driven uniforms: hidden under '_Live' so ParamStore only captures the
// clean scene/* exports of the root (groups with '_' are ignored).
group_uniforms _Live;
uniform float u_speed = 0.28;
uniform float u_wavelength = 1.5;
uniform float u_stretch = -1.0;
uniform float u_fold = 0.45;
uniform float u_twist = 1.9;
uniform float u_opacity = 0.20;
uniform float u_edge = 0.75;
uniform float u_glanz = -0.30;
uniform float u_contrast = 1.30;
group_uniforms;

varying float v_edge_x;
varying vec3 v_n;
varying vec3 v_view;
varying float v_end_fade;
varying float v_clone_fade;

void vertex() {
	vec3 pos = VERTEX;
	float t = TIME * u_speed;
	float seed = INSTANCE_CUSTOM.x;      // uPhase (shape variation per layer/group)
	v_clone_fade = INSTANCE_CUSTOM.y;    // uCloneFade (soft fade-in/out)
	float invwl = 1.0 / max(0.15, u_wavelength);
	float fx = pos.x;
	float fz = pos.z;
	float w = sin(fx * 0.16 * invwl + t + seed * 6.28) * 1.9
			+ sin(fx * 0.34 * invwl - t * 0.8 + seed * 3.1) * 0.9
			+ sin(fx * 0.08 * invwl + t * 0.5 + seed) * 2.4
			+ sin(fx * 0.22 * invwl + fz * 0.25 + t * 0.6 + seed * 2.0) * 1.1 * u_fold;
	float amp = mix(0.7, 1.7, clamp(u_stretch * 0.5 + 0.5, 0.0, 1.0));
	pos.y += w * amp;
	pos.y += sin(fz * 0.4 + fx * 0.05 * invwl + t * 0.4 + seed) * 1.3 * amp * u_twist;

	v_edge_x = UV.y;
	v_end_fade = smoothstep(0.0, 0.12, UV.x) * smoothstep(1.0, 0.88, UV.x);

	float dwdx = ( cos(fx * 0.16 * invwl + t + seed * 6.28) * 0.16 * invwl * 1.9
				 + cos(fx * 0.34 * invwl - t * 0.8 + seed * 3.1) * 0.34 * invwl * 0.9
				 + cos(fx * 0.08 * invwl + t * 0.5 + seed) * 0.08 * invwl * 2.4 ) * amp;
	vec3 nrm = normalize(vec3(-dwdx, 1.0, 0.0));

	vec4 wp = MODELVIEW_MATRIX * vec4(pos, 1.0);
	v_n = normalize((MODELVIEW_MATRIX * vec4(nrm, 0.0)).xyz);
	v_view = normalize(-wp.xyz);
	VERTEX = pos;
}

void fragment() {
	float ndv = abs(dot(normalize(v_n), normalize(v_view)));
	float graz = 1.0 - ndv;
	float fres = pow(clamp(graz + u_glanz * 0.35, 0.0, 1.0), max(0.4, u_edge * 1.6));
	float di = 1.0 - abs(v_edge_x - 0.5) * 2.0;
	float interior = smoothstep(0.0, 0.35, di);
	float edge_band = smoothstep(0.18, 0.0, abs(v_edge_x - 0.5) * 2.0);
	float edge_hi = edge_band * 0.5 + fres * 0.45;
	edge_hi *= clamp(u_edge * 0.5, 0.2, 1.6);
	float body = interior * 0.7 + 0.12;
	float lum = clamp(body + edge_hi, 0.0, 1.3);
	lum = pow(lum, mix(1.25, 0.75, clamp(u_contrast * 0.5, 0.0, 1.0)));
	vec3 col = mix(elem_a.rgb, elem_b.rgb, clamp(edge_hi * 1.4 + (1.0 - interior) * 0.2, 0.0, 1.0));
	float a = clamp((body * 0.6 + edge_hi * 0.5) * u_opacity * 1.4, 0.0, 0.9) * v_end_fade * v_clone_fade;
	if (a <= 0.0009) {
		discard;
	}
	ALBEDO = col * lum;
	ALPHA = a;
}
