shader_type spatial;
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;

global uniform vec4 fog_color : source_color;
global uniform vec4 elem_a    : source_color;
global uniform vec4 elem_b    : source_color;

group_uniforms _Sync;
uniform float amp        = 5.6;
uniform float freq       = 0.038;
uniform float wavelength = 3.0;
uniform float speed      = 0.0;
uniform float flow       = 0.10;
uniform float warp       = 1.5;
uniform vec2  dir        = vec2(0.0, 1.0);
uniform float y_off      = -8.0;
uniform float mirror     = 0.0;
uniform float z_near     = 6.0;
uniform float z_far      = 140.0;
group_uniforms;

group_uniforms Appearance;
uniform float wire_opacity : hint_range(0.0, 1.5) = 0.35;
group_uniforms;

varying float v_h;
varying float v_fade;

float field(vec2 q) {
	float t = TIME * speed;
	float s = freq * wavelength;
	q += dir * (t * flow);
	vec2 w = vec2(sin(q.y * 0.6 + t) * 0.5, cos(q.x * 0.5 - t) * 0.5) * warp;
	q += w;
	float h = 0.0;
	h += sin((q.x * 1.0 + q.y * 0.6) * s) * 0.55;
	h += sin((q.x * 0.5 - q.y * 1.3) * s + t * 0.7) * 0.30;
	h += sin(q.x * 2.1 + q.y * 1.7 - t * 0.5) * 0.16;
	h += sin(q.x * 3.7 - q.y * 2.9) * 0.08;
	return h;
}

void vertex() {
	vec3 pos = VERTEX;
	pos.x = mix(pos.x, -pos.x, step(0.5, mirror));
	float h = field(pos.xz);
	pos.y = h * amp + y_off;
	VERTEX = pos;
	v_h = clamp(h * 0.5 + 0.5, 0.0, 1.0);
	float vz = -(MODELVIEW_MATRIX * vec4(pos, 1.0)).z;
	float depth_n = clamp((vz - z_near) / max(0.001, z_far - z_near), 0.0, 1.0);
	v_fade = 1.0 - depth_n * 0.85;
}

void fragment() {
	vec3 col = mix(fog_color.rgb, elem_a.rgb, smoothstep(0.0, 0.55, v_h));
	col = mix(col, elem_b.rgb, smoothstep(0.55, 0.95, v_h));
	ALBEDO = col;
	EMISSION = col;
	ALPHA = v_fade * wire_opacity;
}
