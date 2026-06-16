shader_type sky;
// 5-Stop-Vertikal-Gradient als Hintergrund, gespeist aus der globalen STYLE-Palette
// (siehe style.gd / project.godot [shader_globals]). Entspricht gradientPass im
// Web-Studio (studio-v005.html:245-260) — rein bildschirm-vertikal wie das Original.
//
// sky_viewport_h wird von background_stage.gd bei jedem Viewport-Resize gesetzt und
// entspricht der Hoehe des rendernden SubViewports. Dadurch bleibt der Gradient auf
// Multi-Display-Setups gleichmaessig breit — unabhaengig vom horizontalen FOV.

global uniform vec4  sky_zenith     : source_color;
global uniform vec4  sky_mid        : source_color;
global uniform vec4  sky_horizon    : source_color;
global uniform vec4  sky_ground_mid : source_color;
global uniform vec4  sky_ground     : source_color;
global uniform float sky_viewport_h = 1080.0;

// Kein Dithering hier: dieser Pass laeuft IM TAA-Viewport (_vps). Statisches
// Screen-Space-Rauschen wird vom TAA-Resolve als Detail interpretiert und
// "kriecht" -> Flackern. Debanding passiert flicker-frei im Overlay-Present-
// Pass (background_stage.gd OVERLAY_SHADER), hinter dem TAA-Resolve. Der
// Gradient bleibt bis dahin in HDR (_vps.use_hdr_2d), also entsteht hier
// keine 8-Bit-Quantisierung, die gedithert werden muesste.
void sky() {
	// Screen-space vertical: t = 1 oben (Zenit), t = 0 unten (Boden).
	// FRAGCOORD.y = 0 ist oben (Vulkan/Forward+-Konvention).
	float t = clamp(1.0 - FRAGCOORD.y / sky_viewport_h, 0.0, 1.0);
	vec3 c;
	if (t > 0.75) {
		c = mix(sky_mid.rgb, sky_zenith.rgb, smoothstep(0.75, 1.0, t));
	} else if (t > 0.5) {
		c = mix(sky_horizon.rgb, sky_mid.rgb, smoothstep(0.5, 0.75, t));
	} else if (t > 0.25) {
		c = mix(sky_ground_mid.rgb, sky_horizon.rgb, smoothstep(0.25, 0.5, t));
	} else {
		c = mix(sky_ground.rgb, sky_ground_mid.rgb, smoothstep(0.0, 0.25, t));
	}
	COLOR = c;
}
