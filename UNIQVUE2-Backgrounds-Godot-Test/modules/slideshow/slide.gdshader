shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, depth_test_disabled;

// Portiert aus dem Prototyp (sampleFit + 8-Tap Zoom-Blur). Nur fuer Slidedeck und
// Gallery-Hauptbild, wo der Quad-Aspekt vom Bild-Aspekt abweichen kann und der globale
// Fit/Crop-Toggle plus der Transition-Blur greifen. Andere Modi nutzen StandardMaterial3D.

uniform sampler2D u_tex : source_color;
uniform float u_opacity = 1.0;
uniform float u_img_aspect = 1.7777778;   // echtes Bild w/h
uniform float u_quad_aspect = 1.7777778;  // Aspekt des Quads, auf den gemappt wird
uniform float u_fit = 0.0;                 // 0 = Crop, 1 = Fit
uniform float u_blur = 0.0;                // radialer Zoom-Blur (nur Transition)

// UV so umrechnen, dass das Bild den Quad fuellt (Crop) oder hineinpasst (Fit).
// Mathematik identisch zum Prototyp; symmetrisch um 0.5, daher V-Flip-invariant.
vec4 sample_fit(vec2 uv) {
	float qa = u_quad_aspect;
	float ia = u_img_aspect;
	if (u_fit < 0.5) {
		// CROP: kleinere Dimension fuellt, groessere wird beschnitten
		if (qa > ia) {
			float k = ia / qa;
			uv.y = (uv.y - 0.5) * k + 0.5;
		} else {
			float k = qa / ia;
			uv.x = (uv.x - 0.5) * k + 0.5;
		}
	} else {
		// FIT: ganzes Bild sichtbar, Raender (letterbox)
		if (qa > ia) {
			float k = qa / ia;
			uv.x = (uv.x - 0.5) * k + 0.5;
		} else {
			float k = ia / qa;
			uv.y = (uv.y - 0.5) * k + 0.5;
		}
	}
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return vec4(0.0);
	}
	return texture(u_tex, uv);
}

void fragment() {
	vec4 col;
	if (u_blur < 0.001) {
		col = sample_fit(UV);
	} else {
		// 8 radiale Samples vom Zentrum, gleichgewichtet (wie Prototyp)
		col = vec4(0.0);
		float wsum = 0.0;
		vec2 c = vec2(0.5);
		for (int i = 0; i < 8; i++) {
			float f = 1.0 + (float(i) / 7.0 - 0.5) * u_blur * 0.18;
			vec2 uv = (UV - c) * f + c;
			col += sample_fit(uv);
			wsum += 1.0;
		}
		col /= wsum;
	}
	col.a *= u_opacity;
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
