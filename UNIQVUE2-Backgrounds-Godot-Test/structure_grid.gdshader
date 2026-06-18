shader_type spatial;
// Structure ceiling-grid panels — luminance→alpha, additive.
// Per-panel brightness via INSTANCE_CUSTOM.x (set from MultiMesh custom data).
// Tint from elem_b global; shared fade & opacity from uniforms.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

global uniform vec4 elem_b : source_color;

uniform sampler2D tex_grid : source_color, filter_linear_mipmap_anisotropic, hint_default_white;
group_uniforms _Sync;
uniform float opacity    : hint_range(0.0, 1.5) = 0.85;
group_uniforms;
uniform float fade_start = 3200.0;
uniform float fade_end   = 6600.0;
uniform float tint_mix   : hint_range(0.0, 1.0) = 0.5;

varying vec2  v_uv;
varying float v_depth;
varying float v_bright;

void vertex() {
	v_uv    = UV;
	v_bright = INSTANCE_CUSTOM.x;
	vec4 vp  = VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_depth  = -vp.z;
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	float l  = texture(tex_grid, v_uv).r;
	float a  = smoothstep(0.06, 0.5, l) * opacity;
	a       *= 1.0 - smoothstep(fade_start, fade_end, v_depth);
	if (a < 0.01) { discard; }
	// Blend between elem_b and white by tint_mix (same formula as HTML)
	vec3 col = mix(elem_b.rgb, vec3(1.0), 1.0 - tint_mix);
	ALBEDO = col * v_bright * l;
	ALPHA  = a;
}
