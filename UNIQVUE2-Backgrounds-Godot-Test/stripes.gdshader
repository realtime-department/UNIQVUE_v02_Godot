shader_type canvas_item;
render_mode blend_add;

// Stripes — 1:1 port of the fullscreen fragment shader from studio-v005
// createStripesModule() (studio-v005.html:894-945).
// Seamless slat tiling, three layers with cross-drift.
// Runs on a fullscreen ColorRect (CanvasLayer) ADDITIVELY over the
// Gradient-Sky — matches the web flow gradientPass -> Stripes-Quad.
//
// Differences from HTML:
//   - uTime  -> TIME (no uniform needed)
//   - uAspect-> derived from SCREEN_PIXEL_SIZE (canvas_item has no VIEWPORT_SIZE)
//   - uC1/uC2/uC3 -> global STYLE uniforms fog_color/elem_a/elem_b
//   - UV.y points down in Godot -> p.y flipped so the
//     stripe direction (angle) matches the web original.

global uniform vec4 fog_color : source_color;
global uniform vec4 elem_a    : source_color;
global uniform vec4 elem_b    : source_color;

group_uniforms Stripes;
uniform float angle        : hint_range(0.0, 6.283)  = 2.007;
uniform float speed        : hint_range(0.0, 2.0)    = 0.4;
uniform float stripe_scale : hint_range(6.0, 80.0)   = 26.0;
uniform float cross_drift  : hint_range(0.0, 2.0)    = 0.4;
uniform float layer_mix    : hint_range(0.0, 1.0)    = 0.6;
group_uniforms;

group_uniforms Variation;
uniform float width_var    : hint_range(0.0, 1.0)    = 0.6;
uniform float tone_var     : hint_range(0.0, 1.0)    = 1.0;
uniform float sharp        : hint_range(0.0, 1.0)    = 0.4;
group_uniforms;

group_uniforms Appearance;
uniform float contrast     : hint_range(0.3, 2.5)    = 1.1;
uniform float glow         : hint_range(0.0, 1.5)    = 0.4;
uniform float opacity      : hint_range(0.0, 1.5)    = 0.9;
group_uniforms;

float hash(float n) {
	uint x = floatBitsToUint(n);
	x ^= x >> 16u; x *= 0x7feb352du; x ^= x >> 15u; x *= 0x846ca68bu; x ^= x >> 16u;
	return float(x) * (1.0 / 4294967296.0);
}

// One slat layer: returns brightness (m) at position x.
float layer_m(float x, float scl, float seed_off) {
	float xx = x * scl;
	float fl = floor(xx);
	float fr = fract(xx);
	float w0 = mix(0.5, mix(0.5, 0.92, hash((fl + seed_off) * 1.7)), width_var);
	float bi;
	float fb;
	if (fr < w0) {
		bi = fl * 2.0;
		fb = fr / w0;
	} else {
		bi = fl * 2.0 + 1.0;
		fb = (fr - w0) / max(0.05, 1.0 - w0);
	}
	float tone_r = hash((bi + seed_off) * 0.917);
	float tone = mix(0.55, tone_r, tone_var);
	tone = pow(tone, 0.7);
	float edge = mix(0.45, 0.015, sharp);
	float band = smoothstep(0.0, edge, fb) * smoothstep(1.0, 1.0 - edge, fb);
	float shade = 0.72 + 0.28 * sin(fb * 3.14159);
	return clamp(tone * shade * mix(0.55, 1.0, band), 0.0, 1.0);
}

void fragment() {
	// uAspect = W/H; SCREEN_PIXEL_SIZE = 1/resolution -> aspect = sps.y/sps.x.
	float aspect = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 1e-6);
	// vUv-0.5 with y upward (Godot UV.y points down -> flip).
	vec2 p = vec2(UV.x - 0.5, 0.5 - UV.y);
	p.x *= aspect;
	float ca = cos(angle);
	float sa = sin(angle);
	float u = p.x * ca - p.y * sa;
	float base_scroll = TIME * speed * 0.6;
	// Three layers with slightly different cross-speed -> interleaving.
	float dr = cross_drift;
	float m0 = layer_m(u + base_scroll, stripe_scale, 0.0);
	float m1 = layer_m(u + base_scroll + TIME * dr * 0.12, stripe_scale * 0.83, 11.0);
	float m2 = layer_m(u + base_scroll - TIME * dr * 0.18, stripe_scale * 1.27, 23.0);
	// Combine layers: base layer + overlaid variance.
	float m = m0;
	m = mix(m, max(m, m1), layer_mix);
	m = mix(m, max(m, m2 * 0.85), layer_mix * 0.7);
	m = clamp(m * contrast, 0.0, 1.0);
	vec3 col = mix(fog_color.rgb, elem_a.rgb, smoothstep(0.04, 0.6, m));
	col = mix(col, elem_b.rgb, smoothstep(0.55, 1.0, m));
	col += elem_b.rgb * pow(m, 3.0) * glow * 1.5;
	COLOR = vec4(col, opacity);
}
