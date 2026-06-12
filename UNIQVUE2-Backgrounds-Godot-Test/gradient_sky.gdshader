shader_type sky;
// 5-Stop-Vertikal-Gradient als Hintergrund, gespeist aus der globalen STYLE-Palette
// (siehe style.gd / project.godot [shader_globals]). Entspricht gradientPass im
// Web-Studio (studio-v005.html:245-260), hier ueber die Blickrichtungs-Hoehe
// (EYEDIR.y) horizont-referenziert statt rein bildschirm-vertikal.

global uniform vec4 sky_zenith : source_color;
global uniform vec4 sky_mid : source_color;
global uniform vec4 sky_horizon : source_color;
global uniform vec4 sky_ground_mid : source_color;
global uniform vec4 sky_ground : source_color;

void sky() {
	// EYEDIR.y in [-1..1] -> t in [0..1]: 1 = Zenit (oben), 0 = Boden (unten),
	// 0.5 = Horizont. Stops identisch zum Web-Verlauf.
	float t = clamp(EYEDIR.y * 0.5 + 0.5, 0.0, 1.0);
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
