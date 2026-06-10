shader_type spatial;
// Punkte haben keine Flaeche -> kein Lighting, nur Emission. unshaded.
// depth_draw_opaque sorgt dafuer, dass DOF (im WorldEnvironment) korrekte Tiefe bekommt.
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;

// ---- Wellen-Parameter (entsprechen den Three.js-Uniforms) ----
group_uniforms Wave;
uniform float amp        : hint_range(0.0, 20.0)  = 5.0;    // uAmp
uniform float freq       : hint_range(0.05, 3.0)  = 1.0;    // uFreq
uniform float wavelength : hint_range(0.2, 6.0)   = 1.0;    // uWavelength
uniform float speed      : hint_range(0.0, 3.0)   = 0.5;    // uSpeed
uniform float flow       : hint_range(0.0, 2.0)   = 0.3;    // uFlow
uniform float warp       : hint_range(0.0, 2.0)   = 0.4;    // uWarp
uniform vec2  dir        = vec2(0.0, 1.0);                  // uDir (Fliessrichtung, xz-Ebene)
uniform float y_off      : hint_range(-20.0, 20.0)= 0.0;    // uYOff
uniform float mirror     : hint_range(0.0, 1.0)   = 0.0;    // uMirror (0/1)
uniform float x_noise    : hint_range(0.0, 1.0)   = 0.15;   // subtiles horizontales Rauschen (X-Sway)
group_uniforms;

// ---- Darstellung ----
group_uniforms Appearance;
uniform float point_size : hint_range(1.0, 8.0)   = 2.0;
uniform float glow_boost : hint_range(0.0, 4.0)   = 1.5;    // uGlow, Kamm-Ueberstrahlung
uniform vec3  col_valley : source_color = vec3(0.05, 0.10, 0.22);  // uC1 fern/Tal
uniform vec3  col_mid    : source_color = vec3(0.15, 0.45, 0.75);  // uC2
uniform vec3  col_crest  : source_color = vec3(0.65, 0.90, 1.00);  // uC3 Kamm
uniform float z_near     = 4.0;     // uZNear  Tiefen-Fade Start
uniform float z_far      = 90.0;    // uZFar   Tiefen-Fade Ende
group_uniforms;

varying float v_h;       // normierte Hoehe 0..1
varying float v_fade;    // Tiefen-Fade

// Billiges 2D-Hoehenfeld: mehrere Sinus-Oktaven + dezenter Domain-Warp.
// 1:1 portiert aus dem Three.js field(), uWavelength skaliert die dominante Welle.
float field(vec2 q) {
	float t = TIME * speed;
	float s = 1.0 / max(0.2, wavelength);   // groessere Wellenlaenge -> niedrigere Frequenz
	// gerichtete Fliessbewegung entlang dir (xz-Ebene)
	q += dir * (t * flow * 8.0);
	// Domain-Warp fuer Unregelmaessigkeit
	vec2 w = vec2(sin(q.y * 0.6 + t) * 0.5, cos(q.x * 0.5 - t) * 0.5) * warp;
	q += w;
	float h = 0.0;
	h += sin((q.x * 1.0 + q.y * 0.6) * s) * 0.55;        // dominante Welle
	h += sin((q.x * 0.5 - q.y * 1.3) * s + t * 0.7) * 0.30;
	h += sin(q.x * 2.1 + q.y * 1.7 - t * 0.5) * 0.16;    // Detail-Oktaven
	h += sin(q.x * 3.7 - q.y * 2.9) * 0.08;
	return h;
}

void vertex() {
	vec3 pos = VERTEX;
	// horizontale Spiegelung an x=0
	pos.x = mix(pos.x, -pos.x, step(0.5, mirror));
	vec2 q = pos.xz * freq * 6.0;
	float h = field(q);
	pos.y = h * amp + y_off;
	// subtiles horizontales Rauschen (verformt field() nicht; rein visueller Sway)
	float xt = TIME * speed;
	pos.x += x_noise * (sin(pos.z * 0.7 + xt * 1.3) * 0.6 + sin(pos.z * 2.3 - xt * 0.9) * 0.4);
	VERTEX = pos;

	v_h = clamp(h * 0.5 + 0.5, 0.0, 1.0);

	// Tiefen-Fade aus View-space Z (entspricht vDepthN/vFade im Three.js-Shader)
	float vz = -(MODELVIEW_MATRIX * vec4(pos, 1.0)).z;
	float depth_n = clamp((vz - z_near) / max(0.001, z_far - z_near), 0.0, 1.0);
	v_fade = 1.0 - depth_n * 0.85;

	// perspektivische Punktgroesse: nahe Punkte groesser
	POINT_SIZE = point_size * mix(2.2, 0.6, depth_n);
}

void fragment() {
	// runde Punkte: gl_PointCoord-Aequivalent ist POINT_COORD
	vec2 pc = POINT_COORD - vec2(0.5);
	float d = length(pc);
	if (d > 0.5) {
		discard;
	}
	// weiche Kante
	float a = smoothstep(0.5, 0.32, d) * v_fade;

	// hoehenabhaengige Faerbung: Tal -> Mid -> Kamm
	vec3 col = mix(col_valley, col_mid, smoothstep(0.0, 0.55, v_h));
	col = mix(col, col_crest, smoothstep(0.55, 0.95, v_h));
	// Kaemme ueberstrahlen als Bloom-Futter (HDR > 1.0 fuer Glow)
	float crest = smoothstep(0.6, 0.95, v_h);
	col += col_crest * crest * glow_boost;

	ALBEDO = col;
	EMISSION = col;            // unshaded: Emission traegt die Farbe in den Glow
	ALPHA = a;
}
