uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
// Keep snowy white below full reflectance so the rounded native mesh remains
// readable in workshop sunlight. The sky and lights supply the highlights.
uniform vec4 snow_tint : source_color = vec4(0.82, 0.875, 0.93, 1.0);
uniform float crystal_density = 125.0;
uniform float sparkle_strength : hint_range(0.0, 1.0) = 0.65;
// Expression belongs to the mesh instance; every helper shares the same skin.
instance uniform float eye_openness : hint_range(0.0, 1.0) = 1.0;
instance uniform vec2 gaze_uv_offset = vec2(0.0);
instance uniform float eye_reactivity : hint_range(0.0, 1.0) = 0.0;
// A raised lower lid forms a happy crescent inside the existing iris islands.
instance uniform float eye_smile : hint_range(0.0, 1.0) = 0.0;
// The same live danger request affects only the original face atlas.
instance uniform float face_alarm : hint_range(0.0, 1.0) = 0.0;
instance uniform float face_startle : hint_range(0.0, 1.0) = 0.0;
varying vec3 skin_position;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	skin_position = VERTEX;
}

void fragment() {
#ifdef EYE_TEMPORAL_PASS
	// The per-instance branch is uniform for each fragment quad. Stable
	// eyes retain their opaque history without doing another texture/light pass.
	if (eye_reactivity < 0.5) { discard; }
#endif
	vec3 source = texture(albedo_texture, UV).rgb;
	// Preserve the original painted iris islands. Their atlas U axis runs up
	// the face and V runs left; lids close vertically in that actual UV frame.
	vec2 eye_a = UV - vec2(0.409, 0.715);
	vec2 eye_b = UV - vec2(0.409, 0.914);
	bool first_eye = length(eye_a) < length(eye_b);
	vec2 eye_uv = first_eye ? eye_a : eye_b;
	// This finite patch contains the painted mouth, clear of both irises.
	vec2 mouth_uv = UV - vec2(0.323, 0.815);
	float mouth_region = (1.0 - smoothstep(0.035, 0.041, abs(mouth_uv.x)))
		* (1.0 - smoothstep(0.050, 0.058, abs(mouth_uv.y)));
	float eye_region = max(smoothstep(0.025, 0.09, source.b - source.r), 1.0 - smoothstep(0.051, 0.057, length(eye_uv)));
#ifdef EYE_TEMPORAL_PASS
	// The additive pass adds zero RGB and one reactive alpha. Original opaque
	// colour, gloss, SSR, snowy grains, depth and skinned motion stay untouched.
	// Mouth changes share the same bounded reactive clock and native skin.
	if (max(eye_region, mouth_region) <= 0.001) { discard; }
	ALBEDO = vec3(0.0);
	ALPHA = 1.0;
#else
	float openness = clamp(eye_openness, 0.0, 1.0);
	vec2 gaze = gaze_uv_offset * min(1.0, 0.008 / max(length(gaze_uv_offset), 0.00001));
	float lid_curve = pow(clamp(abs(eye_uv.y) / 0.055, 0.0, 1.0), 2.0);
	float opening = 0.061 * openness - 0.010 * lid_curve * (1.0 - openness);
	float lid_aa = max(fwidth(eye_uv.x), 0.0009);
	float eye_open = 1.0 - smoothstep(opening - lid_aa, opening + lid_aa, abs(eye_uv.x));
	if (openness < 0.35) {
		// Near closure, resolve the finite opening as two curved edges. A broad
		// footprint must not leave an opaque iris streak outside the opening.
		float upper = eye_uv.x - opening;
		float lower = eye_uv.x + opening;
		float upper_aa = max(fwidth(upper) * 0.5, 0.00045);
		float lower_aa = max(fwidth(lower) * 0.5, 0.00045);
		float finite_open = clamp(smoothstep(-lower_aa, lower_aa, lower)
			- smoothstep(-upper_aa, upper_aa, upper), 0.0, 1.0);
		eye_open = mix(eye_open, finite_open, 1.0 - smoothstep(0.20, 0.35, openness));
	}
	float alarm = clamp(face_alarm, 0.0, 1.0);
	float startle = clamp(face_startle, 0.0, 1.0);
	if (alarm > 0.0) {
		// The inside corner stays high while the outside lid gathers: a
		// concerned wide iris, using U-up and mirrored V-left atlas islands.
		float inward = clamp((first_eye ? eye_uv.y : -eye_uv.y) / 0.055, -1.0, 1.0);
		float upper = opening - 0.014 * (1.0 - inward) * openness;
		float lower = -opening + 0.003 * lid_curve * openness;
		float upper_delta = eye_uv.x - upper;
		float lower_delta = eye_uv.x - lower;
		float upper_aa = max(fwidth(upper_delta) * 0.5, 0.00045);
		float lower_aa = max(fwidth(lower_delta) * 0.5, 0.00045);
		float alarm_open = clamp(smoothstep(-lower_aa, lower_aa, lower_delta)
			- smoothstep(-upper_aa, upper_aa, upper_delta), 0.0, 1.0);
		eye_open = mix(eye_open, alarm_open, alarm);
	}
	float smile = clamp(eye_smile, 0.0, 1.0) * (1.0 - alarm);
	float happy_lower = -opening;
	if (smile > 0.0) {
		// U is physically up: the lower lid lifts most beneath the pupil and
		// tapers to the original corners. Keep the corneal iris visible above it.
		float happy_seam = 0.017 * (1.0 - lid_curve) - 0.004 * lid_curve;
		float happy_upper = happy_seam + openness * (0.044 * (1.0 - lid_curve) + 0.051 * lid_curve);
		happy_lower = happy_seam + openness * (0.007 * (1.0 - lid_curve) - 0.004 * lid_curve);
		float upper_delta = eye_uv.x - happy_upper;
		float lower_delta = eye_uv.x - happy_lower;
		float upper_aa = max(fwidth(upper_delta) * 0.5, 0.00045);
		float lower_aa = max(fwidth(lower_delta) * 0.5, 0.00045);
		float happy_open = clamp(smoothstep(-lower_aa, lower_aa, lower_delta)
			- smoothstep(-upper_aa, upper_aa, upper_delta), 0.0, 1.0);
		eye_open = mix(eye_open, happy_open, smoothstep(0.0, 1.0, smile));
	}
	eye_open *= smoothstep(0.0, 0.08, openness);
	if (eye_region > 0.001) {
		source = mix(source, texture(albedo_texture, UV - gaze).rgb, eye_region);
	}
	float lid = eye_region * (1.0 - eye_open);
	source = mix(source, vec3(1.0), lid);
	// A soft curved seam makes a fully closed blink readable rather than
	// exposing a thin strip of blue pupil or changing the eye geometry.
	float seam_height = 0.004 * lid_curve;
	if (smile > 0.0) {
		// A blink keeps its finite width but meets in the same happy arch.
		float happy_seam = 0.017 * (1.0 - lid_curve) - 0.004 * lid_curve;
		seam_height = mix(seam_height, happy_seam, smoothstep(0.0, 1.0, smile));
	}
	float seam_delta = eye_uv.x - seam_height;
	// Resolve the two edges of a finite ink line together. Widening an opaque
	// line by its footprint made grazing closed eyes turn into dark spikes.
	float seam_aa = max(fwidth(seam_delta) * 0.5, 0.00045);
	float seam = (smoothstep(-seam_aa, seam_aa, seam_delta + 0.001)
		- smoothstep(-seam_aa, seam_aa, seam_delta - 0.001))
		* (1.0 - smoothstep(0.034, 0.047, abs(eye_uv.y)));
	float closed_lid = seam * eye_region * (1.0 - smoothstep(0.06, 0.24, openness));
	source = mix(source, vec3(0.06, 0.10, 0.16), closed_lid * 0.92);
	float happy_lid = 0.0;
	if (smile > 0.0) {
		// Resolve both edges together, as for the qualified blink seam. This
		// restrained lower-lid line must not widen into a grazing black spike.
		float happy_delta = eye_uv.x - happy_lower;
		float happy_aa = max(fwidth(happy_delta) * 0.5, 0.00045);
		float happy_line = clamp(smoothstep(-happy_aa, happy_aa, happy_delta + 0.0008)
			- smoothstep(-happy_aa, happy_aa, happy_delta - 0.0008), 0.0, 1.0);
		happy_lid = happy_line * eye_region * smoothstep(0.0, 1.0, smile)
			* smoothstep(0.24, 0.45, openness)
			* (1.0 - smoothstep(0.034, 0.047, abs(eye_uv.y)));
		source = mix(source, vec3(0.10, 0.16, 0.22), happy_lid * 0.65);
	}
	float expression_ink = 0.0;
	if (alarm > 0.0) {
		// Replace the original happy arc only inside its white atlas patch.
		// Warning briefly opens an O, then settles into a downturned seam.
		float mouth_side = mouth_uv.y / 0.038;
		float curve = 0.003 - 0.008 * mouth_side * mouth_side;
		float worry_delta = mouth_uv.x - curve;
		float worry_aa = max(fwidth(worry_delta) * 0.5, 0.00045);
		float worry = clamp(smoothstep(-worry_aa, worry_aa, worry_delta + 0.0032)
			- smoothstep(-worry_aa, worry_aa, worry_delta - 0.0032), 0.0, 1.0)
			* (1.0 - smoothstep(0.033, 0.038, abs(mouth_uv.y)));
		float gasp_delta = length(mouth_uv / vec2(0.015, 0.018)) - 1.0;
		float gasp_aa = max(fwidth(gasp_delta) * 0.5, 0.015);
		float gasp = 1.0 - smoothstep(-gasp_aa, gasp_aa, gasp_delta);
		float ink = mix(worry, gasp, startle);
		expression_ink = ink * mouth_region * alarm;
		source = mix(source, vec3(1.0), mouth_region * alarm);
	}
	float eye_mask = eye_region * eye_open;
	float mouth = max(expression_ink, 1.0 - smoothstep(0.015, 0.06, max(source.r, max(source.g, source.b))));
	float skin = (1.0 - eye_mask) * (1.0 - max(mouth, closed_lid));
	if (smile > 0.0) { skin = (1.0 - eye_mask) * (1.0 - max(mouth, max(closed_lid, happy_lid))); }
	ALBEDO = mix(source, mix(source, snow_tint.rgb, 0.78), skin);
	// Resolve finite ink after the snowy tint; its antialiased footprint
	// retains the same dark readability as the original painted mouth.
	if (alarm > 0.0) { ALBEDO = mix(ALBEDO, vec3(0.008, 0.010, 0.014), expression_ink); }
	// Dielectric skin and the wet cornea use the engine's energy-conserving
	// GGX response, including real environment and local-light reflections.
	ROUGHNESS = mix(0.46, 0.105, eye_mask);
	SPECULAR = mix(0.48, 0.62, eye_mask);
	CLEARCOAT = mix(0.10, 0.72, eye_mask);
	CLEARCOAT_ROUGHNESS = mix(0.32, 0.075, eye_mask);
	// A corneal normal supplies rounded highlights without modifying the completed eye geometry.
	vec2 iris = clamp(eye_uv / 0.055, vec2(-1.0), vec2(1.0)) * 0.48;
	vec3 cornea = normalize(vec3(iris, sqrt(max(0.1, 1.0 - dot(iris, iris)))));
	float catchlight = 1.0 - smoothstep(0.003, 0.006, length(eye_uv - gaze - vec2(-0.014, 0.017)));
	ALBEDO = mix(ALBEDO, vec3(0.84, 0.90, 0.96), catchlight * eye_mask * 0.45);
	// Fine, fixed snowy facets perturb the real PBR normal. Resolve them into
	// a soft highlight as they become subpixel; never add emissive pinholes.
	vec3 grain_position = skin_position * crystal_density;
	vec3 cell = floor(grain_position);
	vec2 tilt = vec2(hash31(cell + 7.0), hash31(cell + 17.0)) - vec2(0.5);
	vec3 footprint = fwidth(grain_position);
	float pixel_span = max(footprint.x, max(footprint.y, footprint.z));
	float grain_visibility = skin * (1.0 - smoothstep(0.55, 1.2, pixel_span));
	float facet = smoothstep(0.82, 0.96, hash31(cell));
	vec3 snow_normal = normalize(vec3(tilt * (0.05 + facet * sparkle_strength * 0.075) * grain_visibility, 1.0));
	NORMAL_MAP = mix(snow_normal, cornea, eye_mask) * 0.5 + 0.5;
	ROUGHNESS = clamp(ROUGHNESS + (hash31(cell + 31.0) - 0.5) * 0.055 * grain_visibility
		- facet * sparkle_strength * 0.075 * grain_visibility, 0.08, 0.55);
#endif
}
