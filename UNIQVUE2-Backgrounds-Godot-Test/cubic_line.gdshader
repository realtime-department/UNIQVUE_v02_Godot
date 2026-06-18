shader_type spatial;
// Cube-tunnel wireframe outlines — additive edges, depth fog.
// Faithful port of studio-v005 lineMat: position from the MultiMesh instance
// transform (MODELVIEW_MATRIX). uEdgeCol and uCenter are both elem_b in the
// reference update(), so the depth colour-mix collapses to elem_b * glow.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

global uniform vec4 elem_b : source_color;

group_uniforms _Sync;
uniform float glow         : hint_range(0.0, 1.5)    = 0.48;
uniform float z_far        = 795.0;
group_uniforms;
uniform float opacity      : hint_range(0.0, 1.5)    = 1.0;
uniform float fog_start    : hint_range(60.0, 1200.0) = 140.0;
uniform float fog_density  : hint_range(0.0, 2.0)    = 1.1;

varying float v_dist;

void vertex() {
	vec4 mv  = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	v_dist   = -mv.z;
	POSITION = PROJECTION_MATRIX * mv;
}

void fragment() {
	vec3 col = elem_b.rgb * glow;
	float fog_mix = clamp(1.0 - exp(-max(0.0, v_dist - fog_start) * 0.003 * fog_density), 0.0, 1.0);
	float near_f  = smoothstep(0.5, 10.0, v_dist);
	float far_f   = 1.0 - smoothstep(fog_start, z_far * 0.98, v_dist);
	float a = opacity * near_f * far_f * (1.0 - fog_mix * 0.9);
	if (a < 0.003) { discard; }
	ALBEDO = col;
	ALPHA  = a;
}
