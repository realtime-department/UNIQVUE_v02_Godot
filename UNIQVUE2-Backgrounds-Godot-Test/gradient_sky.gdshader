shader_type sky;
// 5-stop vertical gradient as background, fed from the global STYLE palette
// (see style.gd / project.godot [shader_globals]). Corresponds to gradientPass in
// the web studio (studio-v005.html:245-260) — purely screen-vertical like the original.
//
// sky_viewport_h is set by background_stage.gd on every viewport resize and
// corresponds to the height of the rendering SubViewport. This keeps the gradient
// uniformly scaled on multi-display setups — independent of the horizontal FOV.

global uniform vec4  sky_zenith     : source_color;
global uniform vec4  sky_mid        : source_color;
global uniform vec4  sky_horizon    : source_color;
global uniform vec4  sky_ground_mid : source_color;
global uniform vec4  sky_ground     : source_color;
global uniform float sky_viewport_h = 1080.0;

// No dithering here: this pass runs INSIDE the TAA viewport (_vps). Static
// screen-space noise is interpreted by TAA-resolve as detail and
// "crawls" -> flickering. Debanding happens flicker-free in the overlay-present
// pass (background_stage.gd OVERLAY_SHADER), behind the TAA-resolve. The
// gradient stays in HDR until then (_vps.use_hdr_2d), so no
// 8-bit quantization occurs here that would need dithering.
void sky() {
	// Screen-space vertical: t = 1 at top (zenith), t = 0 at bottom (ground).
	// FRAGCOORD.y = 0 is at top (Vulkan/Forward+ convention).
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
