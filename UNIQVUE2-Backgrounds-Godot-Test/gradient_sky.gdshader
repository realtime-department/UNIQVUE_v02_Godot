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
global uniform float sky_dither_enable = 0.0;

// 4×4 Bayer ordered dither — purely spatial, zero temporal variation.
// Uses floor() to be immune to TAA sub-pixel jitter.
float _bayer4(vec2 p) {
	const float M[16] = {
		 0.0,  8.0,  2.0, 10.0,
		12.0,  4.0, 14.0,  6.0,
		 3.0, 11.0,  1.0,  9.0,
		15.0,  7.0, 13.0,  5.0
	};
	int i = int(mod(p.y, 4.0)) * 4 + int(mod(p.x, 4.0));
	return M[i] / 16.0 - 0.5;
}

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
	c += _bayer4(floor(FRAGCOORD.xy)) * (1.0 / 255.0) * sky_dither_enable;
	COLOR = c;
}
