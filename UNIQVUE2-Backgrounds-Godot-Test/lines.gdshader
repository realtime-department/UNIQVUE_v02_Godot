shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled;

// Lines / Speed-Streaks — 1:1 port from studio-v005.html createLinesModule()
// (lines 786-852, vertexShader + fragmentShader).
//
// The HTML version uses InstancedBufferGeometry with 8 random attributes per
// instance (aTrack..aCross), set once via Math.random() and never changed.
// Here the same 8 values are derived deterministically from INSTANCE_ID via
// hash — no CPU buffer needed, MultiMesh transforms stay unused
// (POSITION is written directly to clip-space, like the
// gl_Position of the ortho reference).
//
// Colors come globally from STYLE: uC2 = elem_a, uC3 = elem_b
// (Fog in the web is just the background -> here the Gradient-Sky takes over).

global uniform vec4 elem_a : source_color;
global uniform vec4 elem_b : source_color;

group_uniforms Lines;
uniform float angle     : hint_range(0.0, 6.283, 0.001) = 2.007; // Angle (direction), dial 0..2PI
uniform float speed     : hint_range(0.0, 2.0, 0.02)    = 0.4;   // Tempo
uniform float speed_var : hint_range(0.0, 1.0, 0.02)    = 1.0;   // Tempo-Varianz
uniform float coverage  : hint_range(1.0, 4.0, 0.05)    = 1.6;   // Area coverage
group_uniforms;

group_uniforms Shape;
uniform float len_scale   : hint_range(0.3, 2.5, 0.05) = 1.0;  // Length factor
uniform float len_spread  : hint_range(0.0, 1.5, 0.02) = 1.0;  // Length spread
uniform float width_scale : hint_range(0.3, 3.0, 0.05) = 1.0;  // Width factor
uniform float sharp       : hint_range(0.0, 1.0, 0.02) = 1.0;  // Edge sharpness (hard<->soft)
group_uniforms;

group_uniforms Appearance;
uniform float contrast : hint_range(0.3, 2.5, 0.05) = 1.15; // Contrast
uniform float glow     : hint_range(0.0, 1.5, 0.05) = 0.3;  // Glow
uniform float opacity  : hint_range(0.0, 1.5, 0.05) = 0.85; // Opacity
group_uniforms;

group_uniforms _Sync;
uniform float aspect_ratio : hint_range(0.1, 5.0) = 1.777; // set by lines_root.gd each frame
group_uniforms;

varying vec2 v_local;
varying float v_tone;
varying float v_alpha_mul;

// Integer hash (lowbias32) — precision-safe for all 40k instance IDs,
// unlike fract(sin(...))-hashes which degenerate at large IDs.
float hash_inst(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return float(x) * (1.0 / 4294967296.0);
}

void vertex() {
	// 8 random values per instance, identical distributions to the JS seeding
	// (studio-v005.html:773-777). aSeed/aCross are declared in the HTML shader
	// but never used (crossT = aTrack) — kept here for completeness.
	uint id = uint(INSTANCE_ID) * 8u;
	float a_track = hash_inst(id + 0u);
	float a_phase = hash_inst(id + 1u);
	float a_speed = 0.5 + hash_inst(id + 2u) * 1.5;
	float a_len   = hash_inst(id + 3u);
	float a_width = hash_inst(id + 4u);
	float a_tone  = 0.35 + hash_inst(id + 5u) * 0.65;
	float a_seed  = hash_inst(id + 6u);                 // im HTML ungenutzt
	float a_cross = (hash_inst(id + 7u) - 0.5) * 2.0;   // im HTML ungenutzt

	float aspect = aspect_ratio;   // set by lines_root.gd; VIEWPORT_SIZE invalid in spatial vertex()

	// Length spread: lenSpread distributes lengths further (short..long).
	float lbase = mix(0.06, 0.40, a_len);
	float len_s = mix(0.23, lbase, clamp(len_spread, 0.0, 1.5)) * len_scale;
	if (len_spread > 1.0) {
		len_s = lbase * pow(a_len + 0.15, (len_spread - 1.0) * 2.0) * len_scale;
	}
	float wid_s = mix(0.003, 0.014, a_width) * width_scale;
	float diag = sqrt(aspect * aspect + 1.0) * 1.15;
	float span = diag * coverage;
	// Speed variance: at 0 all same speed, at 1 full spread.
	float spd = mix(1.0, a_speed, speed_var);
	// TIME instead of CPU-uTime (HTML wraps at 600 s, Godot default at 3600 s —
	// fract() stays precise enough in both cases).
	float run = fract(a_phase + TIME * speed * 1.4 * spd * 0.15);
	float run_y = (run - 0.5) * 2.0 * span;
	float track_x = (a_track - 0.5) * 2.0 * span;

	// QuadMesh is 2x2 -> halve to [-0.5..0.5], like THREE.PlaneGeometry(1,1).
	vec2 q = VERTEX.xy * 0.5;
	v_local = q;
	vec2 local = vec2(q.x * wid_s, q.y * len_s);
	vec2 pos2 = vec2(track_x, run_y) + local;
	float ca = cos(angle);
	float sa = -sin(angle);
	vec2 rot = vec2(pos2.x * ca - pos2.y * sa, pos2.x * sa + pos2.y * ca);
	rot.x /= aspect;

	v_tone = a_tone;
	float end_fade = smoothstep(0.0, 0.16, run) * smoothstep(1.0, 0.84, run);
	v_alpha_mul = end_fade;

	// Direct clip-space output (Godot NDC is y-up like WebGL); z=0.5 lies
	// safely between Near/Far — depth doesn't matter (no depth test/write).
	POSITION = vec4(rot, 0.5, 1.0);
}

void fragment() {
	float edge = mix(0.5, 0.001, sharp);
	float across = 1.0 - smoothstep(0.5 - edge, 0.5, abs(v_local.x));
	float along  = 1.0 - smoothstep(0.5 - edge, 0.5, abs(v_local.y));
	float m = clamp(across * along * v_tone * contrast, 0.0, 1.0);
	vec3 col = mix(elem_a.rgb, elem_b.rgb, smoothstep(0.2, 0.95, m * v_tone));
	col += elem_b.rgb * pow(m, 2.5) * glow * 1.5;
	ALBEDO = col;
	EMISSION = col;
	ALPHA = m * v_alpha_mul * opacity;
}
