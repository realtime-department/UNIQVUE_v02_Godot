shader_type spatial;
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;

// ---- Globale STYLE-Palette ----
global uniform vec4 fog_color : source_color;
global uniform vec4 elem_a    : source_color;
global uniform vec4 elem_b    : source_color;

// ---- Wellen-Parameter (direkte 1:1-Entsprechung zu studio-v005.html) ----
group_uniforms Wave;
uniform float amp        : hint_range(0.0, 20.0)  = 5.6;
uniform float freq       : hint_range(0.005, 0.3) = 0.038;  // direkt wie HTML uFreq
uniform float wavelength : hint_range(0.5, 8.0)   = 3.0;    // s = freq * wavelength
uniform float speed      : hint_range(0.0, 3.0)   = 0.0;
uniform float flow       : hint_range(0.0, 2.0)   = 0.10;
uniform float warp       : hint_range(0.0, 2.0)   = 1.5;
uniform vec2  dir                                 = vec2(0.0, 1.0);
uniform float y_off      : hint_range(-20.0, 20.0)= -8.0;
uniform float mirror     : hint_range(0.0, 1.0)   = 0.0;
uniform float x_noise    : hint_range(0.0, 1.0)   = 0.10;
group_uniforms;

group_uniforms Appearance;
uniform float point_size    : hint_range(1.0, 8.0)   = 3.0;
uniform float point_opacity : hint_range(0.0, 1.5)   = 0.40;
uniform float glow_boost    : hint_range(0.0, 4.0)   = 0.15;
uniform int   shape         : hint_range(0, 4, 1)    = 0;
uniform float z_near        : hint_range(0.0, 200.0) = 6.0;
uniform float z_far         : hint_range(10.0, 600.0)= 140.0;
group_uniforms;

varying float v_h;
varying float v_fade;

// Identisch zu studio-v005.html field(): s = freq * wavelength, q = rohe Weltposition.
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
	float h = field(pos.xz);   // rohe Weltposition, wie HTML
	pos.y = h * amp + y_off;
	float xt = TIME * speed;
	pos.x += x_noise * (sin(pos.z * 0.7 + xt * 1.3) * 0.6 + sin(pos.z * 2.3 - xt * 0.9) * 0.4);
	VERTEX = pos;

	v_h = clamp(h * 0.5 + 0.5, 0.0, 1.0);

	float vz = -(MODELVIEW_MATRIX * vec4(pos, 1.0)).z;
	float depth_n = clamp((vz - z_near) / max(0.001, z_far - z_near), 0.0, 1.0);
	v_fade = 1.0 - depth_n * 0.85;

	POINT_SIZE = point_size * mix(2.2, 0.6, depth_n);
}

void fragment() {
	vec2 pc = POINT_COORD - vec2(0.5);
	float d = length(pc);
	float a = 0.0;

	if (shape == 0) {
		if (d > 0.5) { discard; }
		a = smoothstep(0.5, 0.32, d) * v_fade;
	} else if (shape == 1) {
		float ring = abs(d - 0.34);
		if (ring > 0.13) { discard; }
		a = smoothstep(0.13, 0.0, ring) * v_fade;
	} else if (shape == 2) {
		float sq = max(abs(pc.x), abs(pc.y));
		if (sq > 0.46) { discard; }
		a = smoothstep(0.46, 0.30, sq) * v_fade;
	} else if (shape == 3) {
		vec2 pa = abs(pc);
		float spike = smoothstep(0.5, 0.0, min(pa.x, pa.y) * 6.0 + d * 0.6);
		float core  = smoothstep(0.32, 0.0, d);
		a = clamp(max(spike, core), 0.0, 1.0) * v_fade;
		if (a <= 0.001) { discard; }
	} else {
		vec2 pa = abs(pc);
		float hb = smoothstep(0.10, 0.04, pa.y) * smoothstep(0.48, 0.40, pa.x);
		float vb = smoothstep(0.10, 0.04, pa.x) * smoothstep(0.48, 0.40, pa.y);
		a = clamp(hb + vb, 0.0, 1.0) * v_fade;
		if (a <= 0.001) { discard; }
	}

	a *= point_opacity;

	vec3 col = mix(fog_color.rgb, elem_a.rgb, smoothstep(0.0, 0.55, v_h));
	col = mix(col, elem_b.rgb, smoothstep(0.55, 0.95, v_h));
	float crest = smoothstep(0.6, 0.95, v_h);
	col += elem_b.rgb * crest * glow_boost;

	ALBEDO = col;
	EMISSION = col;
	ALPHA = a;
}
