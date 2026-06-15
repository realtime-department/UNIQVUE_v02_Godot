shader_type spatial;
// Cubic particle point-sprites — depth-based size + fog alpha. seed in COLOR.r.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, use_point_size;

global uniform vec4 elem_b : source_color;

uniform float opacity     : hint_range(0.0, 1.5)    = 1.0;
uniform float fog_start   : hint_range(60.0, 1200.0) = 140.0;
uniform float fog_density : hint_range(0.0, 2.0)    = 1.1;
uniform float z_far       = 795.0;
uniform int   shape       : hint_range(0, 4, 1)     = 0;

varying float v_a;

void vertex() {
	float seed = COLOR.r;
	vec4 mv    = VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0);
	float vz   = max(-mv.z, 0.1);
	float fog  = 1.0 - exp(-max(0.0, vz - fog_start) * 0.003 * fog_density);
	float nf   = smoothstep(1.0, 12.0, vz);
	float ff   = 1.0 - smoothstep(z_far * 0.7, z_far, vz);
	v_a        = nf * ff * (1.0 - fog) * (0.45 + 0.55 * seed);
	POINT_SIZE = (2.5 + seed * 4.5) * (120.0 / vz);
	POSITION   = PROJECTION_MATRIX * mv;
}

void fragment() {
	if (v_a <= 0.001) { discard; }
	vec2 pc = POINT_COORD - vec2(0.5);
	float r = length(pc);
	float m = 0.0;
	if (shape == 0) {
		m = smoothstep(0.5, 0.0, r);
	} else if (shape == 1) {
		m = smoothstep(0.13, 0.0, abs(r - 0.34));
	} else if (shape == 2) {
		m = smoothstep(0.46, 0.30, max(abs(pc.x), abs(pc.y)));
	} else if (shape == 3) {
		vec2 pa = abs(pc);
		float spike = smoothstep(0.5, 0.0, min(pa.x, pa.y) * 6.0 + r * 0.6);
		float core  = smoothstep(0.32, 0.0, r);
		m = clamp(max(spike, core), 0.0, 1.0);
	} else {
		vec2 pa = abs(pc);
		float cr = min(pa.x, pa.y);
		m = smoothstep(0.12, 0.0, cr) * smoothstep(0.5, 0.2, r);
	}
	if (m <= 0.001) { discard; }
	ALBEDO = elem_b.rgb;
	ALPHA  = m * v_a * opacity;
}
