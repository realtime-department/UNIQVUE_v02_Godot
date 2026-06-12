shader_type spatial;
// Plexus link lines - ported from the plexus line ShaderMaterial in
// studio-v005.html:629-635. Per-vertex link alpha arrives in COLOR.a (set by
// plexus_sim.gd); colour is a fixed STYLE mix, faded by view depth.
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;

global uniform vec4 elem_a : source_color;
global uniform vec4 elem_b : source_color;

uniform float line_opacity : hint_range(0.0, 1.5)   = 0.45;
uniform float depth_fade   : hint_range(0.0, 1.0)   = 1.0;
uniform float z_near       : hint_range(0.0, 100.0) = 6.0;
uniform float z_far        : hint_range(1.0, 200.0) = 46.0;

varying float v_a;

void vertex() {
	float vz = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	float depth_n = clamp((vz - z_near) / max(0.001, z_far - z_near), 0.0, 1.0);
	float fade = mix(1.0, 1.0 - depth_fade, depth_n);
	v_a = COLOR.a * fade;
}

void fragment() {
	vec3 col = mix(elem_a.rgb, elem_b.rgb, 0.4);
	ALBEDO = col;
	EMISSION = col;
	ALPHA = v_a * line_opacity;
}
