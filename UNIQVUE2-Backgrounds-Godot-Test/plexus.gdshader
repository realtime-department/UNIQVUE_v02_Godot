shader_type spatial;
// Plexus point sprites - ported from the plexus point ShaderMaterial in
// studio-v005.html:607-622. 5 selectable shapes (Dot/Ring/Square/Star/Cross),
// additive blend. Per-vertex hub strength arrives in COLOR.r (set by
// plexus_sim.gd); colours come from the global STYLE palette.
render_mode unshaded, depth_draw_never, blend_add, cull_disabled, use_point_size;

global uniform vec4 fog_color : source_color;
global uniform vec4 elem_a    : source_color;
global uniform vec4 elem_b    : source_color;

uniform float point_size    : hint_range(2.0, 16.0)   = 2.5;
uniform float point_opacity : hint_range(0.0, 1.5)    = 1.05;
uniform float depth_fade    : hint_range(0.0, 1.0)    = 1.0;
uniform int   shape         : hint_range(0, 4, 1)     = 0;
group_uniforms _Sync;
uniform float z_near        : hint_range(0.0, 100.0)  = 6.0;
uniform float z_far         : hint_range(1.0, 200.0)  = 46.0;
group_uniforms;

varying float v_fade;
varying float v_depth_n;
varying float v_hub;

void vertex() {
	float vz = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	v_depth_n = clamp((vz - z_near) / max(0.001, z_far - z_near), 0.0, 1.0);
	v_fade = mix(1.0, 1.0 - depth_fade, v_depth_n);
	v_hub = COLOR.r;
	float hub_scale = 1.0 + v_hub * 2.2;
	POINT_SIZE = point_size * hub_scale * (14.0 / max(0.1, vz));
}

void fragment() {
	vec2 pc = POINT_COORD - vec2(0.5);
	float d = length(pc);
	float m = 0.0;

	if (shape == 0) {
		if (d > 0.5) { discard; }
		m = smoothstep(0.5, 0.0, d);
	} else if (shape == 1) {
		float ring = abs(d - 0.34);
		if (ring > 0.13) { discard; }
		m = smoothstep(0.13, 0.0, ring);
	} else if (shape == 2) {
		float sq = max(abs(pc.x), abs(pc.y));
		if (sq > 0.46) { discard; }
		m = smoothstep(0.46, 0.30, sq);
	} else if (shape == 3) {
		vec2 pa = abs(pc);
		float spike = smoothstep(0.5, 0.0, min(pa.x, pa.y) * 6.0 + d * 0.6);
		float core  = smoothstep(0.32, 0.0, d);
		m = clamp(max(spike, core), 0.0, 1.0);
		if (m <= 0.001) { discard; }
	} else {
		vec2 pa = abs(pc);
		float hb = smoothstep(0.10, 0.04, pa.y) * smoothstep(0.48, 0.40, pa.x);
		float vb = smoothstep(0.10, 0.04, pa.x) * smoothstep(0.48, 0.40, pa.y);
		m = clamp(hb + vb, 0.0, 1.0);
		if (m <= 0.001) { discard; }
	}

	// HTML: col = mix(uC2,uC3,glow) + hot core; distant points sink into fog.
	float glow = pow(m, 2.5);
	vec3 col = mix(elem_a.rgb, elem_b.rgb, glow);
	col = mix(col, fog_color.rgb, v_depth_n * depth_fade * 0.5);
	col += elem_b.rgb * pow(m, 8.0) * (2.4 + v_hub * 4.0);
	float a = m * point_opacity * v_fade * (0.7 + v_hub * 0.6);

	ALBEDO = col;
	EMISSION = col;
	ALPHA = a;
}
