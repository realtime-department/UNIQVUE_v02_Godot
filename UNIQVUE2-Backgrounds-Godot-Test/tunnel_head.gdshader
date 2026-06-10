shader_type spatial;
// Point-sprite heads at streak tips. 5 selectable shapes. Additive blend.
render_mode unshaded, depth_draw_never, blend_add, cull_disabled, use_point_size;

uniform int shape : hint_range(0, 4, 1) = 0;

void vertex() {
	float vz = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	POINT_SIZE = clamp(900.0 / max(vz, 0.1), 1.0, 26.0);
}

void fragment() {
	vec2 pc = POINT_COORD - vec2(0.5);
	float r = length(pc);
	float m = 0.0;
	if (shape == 0) {
		m = smoothstep(0.5, 0.0, r);
	} else if (shape == 1) {
		float d = abs(r - 0.34);
		m = smoothstep(0.13, 0.0, d);
	} else if (shape == 2) {
		float sq = max(abs(pc.x), abs(pc.y));
		m = smoothstep(0.46, 0.30, sq);
	} else if (shape == 3) {
		vec2 a = abs(pc);
		float spike = smoothstep(0.5, 0.0, min(a.x, a.y) * 6.0 + r * 0.6);
		float core = smoothstep(0.32, 0.0, r);
		m = clamp(max(spike, core), 0.0, 1.0);
	} else {
		vec2 a = abs(pc);
		float h = smoothstep(0.10, 0.04, a.y) * smoothstep(0.48, 0.40, a.x);
		float v = smoothstep(0.10, 0.04, a.x) * smoothstep(0.48, 0.40, a.y);
		m = clamp(h + v, 0.0, 1.0);
	}
	if (m <= 0.001) {
		discard;
	}
	vec3 c = COLOR.rgb + vec3(1.0) * pow(m, 6.0) * 1.5;
	ALBEDO = c;
	EMISSION = c;
	ALPHA = m * COLOR.a;
}
