shader_type spatial;
// Structure ground-glow strip — scrolling hexagon-weave texture, additive.
// Tint = mix(fog_color, elem_a, tint_mix), updated each frame via uniform.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform sampler2D tex_ground : source_color, filter_linear_mipmap, hint_default_white;
uniform float opacity    : hint_range(0.0, 1.5) = 0.78;
uniform float scroll     = 0.0;
uniform float repeat_y   : hint_range(1.0, 20.0) = 8.53;
uniform float fade_start = 3200.0;
uniform float fade_end   = 6600.0;
uniform vec3  tint       : source_color = vec3(0.66, 0.66, 0.66);

varying vec2  v_uv;
varying float v_depth;

void vertex() {
	v_uv = vec2(UV.x, 1.0 - UV.y);  // Godot PlaneMesh UV.y=0→far vs THREE.js UV.y=0→near; also compensates for texGround flipY=true
	vec4 vp  = VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_depth  = -vp.z;
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	vec2 uv2 = vec2(v_uv.x, v_uv.y * repeat_y + scroll);
	vec3 c   = texture(tex_ground, uv2).rgb * tint;
	float a  = 1.0 - smoothstep(fade_start, fade_end, v_depth);
	a       *= smoothstep(20.0, 260.0, v_depth);
	float oa = a * opacity;
	if (oa <= 0.001) { discard; }
	ALBEDO = c;
	ALPHA  = oa;
}
