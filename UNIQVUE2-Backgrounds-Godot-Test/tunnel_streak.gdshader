shader_type spatial;
// Line-segment streaks, per-vertex colour+alpha, additive blend.
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;

void vertex() {
}

void fragment() {
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb;
	ALPHA = COLOR.a;
}
