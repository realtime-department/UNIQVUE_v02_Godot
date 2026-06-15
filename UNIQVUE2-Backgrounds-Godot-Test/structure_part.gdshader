shader_type spatial;
// Structure ambient particles — simple depth-based alpha, point sprites.
// Color from elem_b global (HTML: pMat.uniforms.uColor = _SC.elemB).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, use_point_size;

global uniform vec4 elem_b : source_color;

uniform float part_size : hint_range(1.0, 8.0) = 2.8;
uniform float near_dist = 300.0;
uniform float far_dist  = 5500.0;

varying float v_a;

void vertex() {
	vec4 vp    = VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0);
	float depth = max(-vp.z, 1.0);
	v_a        = mix(0.55, 0.12, smoothstep(near_dist, far_dist, depth));
	POINT_SIZE = part_size * (900.0 / depth);
	POSITION   = PROJECTION_MATRIX * vp;
}

void fragment() {
	if (v_a <= 0.001) { discard; }
	float r = smoothstep(0.5, 0.0, length(POINT_COORD - vec2(0.5)));
	if (r <= 0.001) { discard; }
	ALBEDO = elem_b.rgb;
	ALPHA  = v_a * r;
}
