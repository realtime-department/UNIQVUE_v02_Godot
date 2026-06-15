shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled;

// Lines / Speed-Streaks — 1:1-Port von studio-v005.html createLinesModule()
// (Zeilen 786-852, vertexShader + fragmentShader).
//
// Die HTML-Version nutzt InstancedBufferGeometry mit 8 Zufalls-Attributen pro
// Instanz (aTrack..aCross), die einmalig per Math.random() gesetzt werden und
// sich nie aendern. Hier werden dieselben 8 Werte deterministisch aus
// INSTANCE_ID gehasht — kein CPU-Buffer noetig, MultiMesh-Transforms bleiben
// ungenutzt (POSITION wird direkt im Clip-Space geschrieben, wie das
// gl_Position der Ortho-Vorlage).
//
// Farben kommen global aus STYLE: uC2 = elem_a, uC3 = elem_b
// (Fog ist im Web nur der Hintergrund -> hier uebernimmt das der Gradient-Sky).

global uniform vec4 elem_a : source_color;
global uniform vec4 elem_b : source_color;

group_uniforms Linien;
uniform float angle     : hint_range(0.0, 6.283, 0.001) = 2.007; // Winkel (Richtung), Dial 0..2PI
uniform float speed     : hint_range(0.0, 2.0, 0.02)    = 0.4;   // Tempo
uniform float speed_var : hint_range(0.0, 1.0, 0.02)    = 1.0;   // Tempo-Varianz
uniform float coverage  : hint_range(1.0, 4.0, 0.05)    = 1.6;   // Flaechenabdeckung
group_uniforms;

group_uniforms Form;
uniform float len_scale   : hint_range(0.3, 2.5, 0.05) = 1.0;  // Laengen-Faktor
uniform float len_spread  : hint_range(0.0, 1.5, 0.02) = 1.0;  // Laengen-Streuung
uniform float width_scale : hint_range(0.3, 3.0, 0.05) = 1.0;  // Breiten-Faktor
uniform float sharp       : hint_range(0.0, 1.0, 0.02) = 1.0;  // Kantenschaerfe (hart<->weich)
group_uniforms;

group_uniforms Darstellung;
uniform float contrast : hint_range(0.3, 2.5, 0.05) = 1.15; // Kontrast
uniform float glow     : hint_range(0.0, 1.5, 0.05) = 0.3;  // Gluehen
uniform float opacity  : hint_range(0.0, 1.5, 0.05) = 0.85; // Deckkraft
group_uniforms;

varying vec2 v_local;
varying float v_tone;
varying float v_alpha_mul;

// Integer-Hash (lowbias32) — praezisionssicher fuer alle 40k Instanz-IDs,
// im Gegensatz zu fract(sin(...))-Hashes, die bei grossen IDs degenerieren.
float hash_inst(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return float(x) * (1.0 / 4294967296.0);
}

void vertex() {
	// 8 Zufallswerte pro Instanz, identische Verteilungen wie die JS-Befuellung
	// (studio-v005.html:773-777). aSeed/aCross werden im HTML-Shader deklariert,
	// aber nie benutzt (crossT = aTrack) — der Vollstaendigkeit halber trotzdem da.
	uint id = uint(INSTANCE_ID) * 8u;
	float a_track = hash_inst(id + 0u);
	float a_phase = hash_inst(id + 1u);
	float a_speed = 0.5 + hash_inst(id + 2u) * 1.5;
	float a_len   = hash_inst(id + 3u);
	float a_width = hash_inst(id + 4u);
	float a_tone  = 0.35 + hash_inst(id + 5u) * 0.65;
	float a_seed  = hash_inst(id + 6u);                 // im HTML ungenutzt
	float a_cross = (hash_inst(id + 7u) - 0.5) * 2.0;   // im HTML ungenutzt

	float aspect = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;   // entspricht uAspect = W/H

	// Laengenspreizung: lenSpread streut die Laengen weiter (kurz..lang).
	float lbase = mix(0.06, 0.40, a_len);
	float len_s = mix(0.23, lbase, clamp(len_spread, 0.0, 1.5)) * len_scale;
	if (len_spread > 1.0) {
		len_s = lbase * pow(a_len + 0.15, (len_spread - 1.0) * 2.0) * len_scale;
	}
	float wid_s = mix(0.003, 0.014, a_width) * width_scale;
	float diag = sqrt(aspect * aspect + 1.0) * 1.15;
	float span = diag * coverage;
	// Geschwindigkeitsvarianz: bei 0 alle gleich schnell, bei 1 volle Spreizung.
	float spd = mix(1.0, a_speed, speed_var);
	// TIME statt CPU-uTime (HTML wrappt bei 600 s, Godot-Default bei 3600 s —
	// fract() bleibt in beiden Faellen praezise genug).
	float run = fract(a_phase + TIME * speed * 1.4 * spd * 0.15);
	float run_y = (run - 0.5) * 2.0 * span;
	float track_x = (a_track - 0.5) * 2.0 * span;

	// QuadMesh ist 2x2 -> halbieren auf [-0.5..0.5], wie THREE.PlaneGeometry(1,1).
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

	// Direkter Clip-Space-Output (Godot-NDC ist y-up wie WebGL); z=0.5 liegt
	// sicher zwischen Near/Far — Tiefe ist egal (kein Depth-Test/-Write).
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
