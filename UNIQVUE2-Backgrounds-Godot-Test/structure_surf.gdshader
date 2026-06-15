shader_type spatial;
// Structure base-geometry — albedo × AO-lightmap, depth-alpha fade.
// Horizon glow from elem_b (global STYLE uniform).
render_mode unshaded, blend_mix, depth_draw_always, cull_back;

global uniform vec4 elem_b : source_color;

uniform sampler2D tex_color : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D tex_ao    : filter_linear_mipmap, hint_default_white;
uniform float exposure   : hint_range(0.4, 3.0) = 1.4;
uniform float light_gain : hint_range(0.3, 2.0) = 1.0;
uniform float fade_start = 3200.0;
uniform float fade_end   = 6600.0;

varying vec2  v_uv;
varying float v_depth;
varying float v_wx;

void vertex() {
	v_uv = UV;
	vec4 wp = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_wx = wp.x;
	vec4 vp = VIEW_MATRIX * wp;
	v_depth  = -vp.z;
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	vec3 albedo = texture(tex_color, v_uv).rgb;
	float light = texture(tex_ao, v_uv).r;
	vec3 col    = albedo * light * light_gain;
	col = pow(max(col, vec3(0.0)), vec3(0.55));
	col *= 0.30 * exposure;
	col += 0.012;
	float lateral = 1.0 - clamp(abs(v_wx) / 1100.0, 0.0, 1.0);
	float far_haze = smoothstep(3000.0, 600.0, v_depth);
	col += elem_b.rgb * pow(lateral, 1.5) * far_haze * 0.05;
	float a = 1.0 - smoothstep(fade_start, fade_end, v_depth);
	a *= smoothstep(40.0, 320.0, v_depth);
	if (a <= 0.001) { discard; }
	ALBEDO = col;
	ALPHA  = a;
}
