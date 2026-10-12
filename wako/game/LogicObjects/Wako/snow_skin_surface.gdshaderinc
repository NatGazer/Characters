uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
// Keep snowy white below full reflectance so the rounded native mesh remains
// readable in workshop sunlight. The sky and lights supply the highlights.
uniform vec4 snow_tint : source_color = vec4(0.82, 0.875, 0.93, 1.0);
uniform float crystal_density = 125.0;
uniform float sparkle_strength : hint_range(0.0, 1.0) = 0.65;
// Expression belongs to the mesh instance; every helper shares the same skin.
// Blink/overall lid openness (1 = the lid shape below, 0 = closed seam).
instance uniform float eye_openness : hint_range(0.0, 1.0) = 1.0;
// Pupil gaze in atlas UV (U up, V toward Wako's left); |gaze| <= .021.
instance uniform vec2 gaze_uv_offset = vec2(0.0);
instance uniform float eye_reactivity : hint_range(0.0, 1.0) = 0.0;
// A raised lower lid forms a happy crescent inside the existing iris islands.
instance uniform float eye_smile : hint_range(0.0, 1.0) = 0.0;
// Live danger preset: worried lids (outer upper lid lowered) and a frown.
instance uniform float face_alarm : hint_range(0.0, 1.0) = 0.0;
// Under alarm: the mouth opens into a gasp "O".
instance uniform float face_startle : hint_range(0.0, 1.0) = 0.0;
// x upper lid close (-.4 wide ... 0 disc top ... 1 shut), y lower lid raise (0...1),
// z brow tilt (-1 worried: outer half lowered ... +1 determined: inner half lowered),
// w wink (+ closes the first atlas eye, - the second).
instance uniform vec4 eye_lids = vec4(0.0);
// x pupil dilation (-1 pinpoint ... +1 wide), y vergence (UV toward the nose),
// z eye pop (0...1 enlarges the painted disc for surprise), w unused.
instance uniform vec4 eye_iris = vec4(0.0);
// x open (0...1), y curve (-1 frown ... 0 painted smile ... +1 grin),
// z width (-1 pucker/round ... +1 wide), w skew (-1...1, one corner up).
instance uniform vec4 mouth_shape = vec4(0.0);
varying vec3 skin_position;

// Original atlas islands: U runs up the face, V runs toward Wako's left.
const vec2 EYE_A = vec2(0.409, 0.715);
const vec2 EYE_B = vec2(0.409, 0.914);
const vec2 MOUTH = vec2(0.323, 0.815);
const float IRIS_R = 0.055;

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
	vec2 eye_a = UV - EYE_A;
	vec2 eye_b = UV - EYE_B;
	bool first_eye = dot(eye_a, eye_a) < dot(eye_b, eye_b);
	vec2 eye_uv = first_eye ? eye_a : eye_b;
	float eye_dist = length(eye_uv);
	// This finite patch contains the painted mouth arc and every procedural
	// mouth shape, clear of both irises (the disc nearest point is U +.046).
	vec2 mouth_uv = UV - MOUTH;
	float mouth_region = (1.0 - smoothstep(0.024, 0.030, mouth_uv.x)) * smoothstep(-0.050, -0.044, mouth_uv.x)
		* (1.0 - smoothstep(0.052, 0.060, abs(mouth_uv.y)));
#ifdef EYE_TEMPORAL_PASS
	// The additive pass adds zero RGB and one reactive alpha. Original opaque
	// colour, gloss, SSR, snowy grains, depth and skinned motion stay untouched.
	// The socket (lids, pop, shifted disc) and mouth share the reactive clock.
	float socket = 1.0 - smoothstep(0.072, 0.080, eye_dist);
	if (max(socket, mouth_region) <= 0.001) { discard; }
	ALBEDO = vec3(0.0);
	ALPHA = 1.0;
#else
	// Screen derivatives are taken once, in uniform control flow, and reused
	// by the resampled iris below so mip selection never sees the remap.
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	vec3 source = texture(albedo_texture, UV).rgb;
	float alarm = clamp(face_alarm, 0.0, 1.0);
	float startle = clamp(face_startle, 0.0, 1.0);
	float eye_region = 0.0;
	float eye_open = 0.0;
	float closed_lid = 0.0;
	float lid_line = 0.0;
	float happy_lid = 0.0;
	if (eye_dist < 0.085) {
		float side = first_eye ? 1.0 : -1.0;
		// +1 toward the nose for both mirrored islands.
		float inward = clamp(side * eye_uv.y / IRIS_R, -1.0, 1.0);
		float smile = clamp(eye_smile, 0.0, 1.0) * (1.0 - alarm);
		float wink = clamp(side * eye_lids.w, 0.0, 1.0);
		float openness = clamp(eye_openness, 0.0, 1.0) * (1.0 - wink);
		// Iris: resample the painted disc. The rim and socket stay put while the
		// dark pupil travels inside it (plus a small whole-disc shift), so the
		// fixed lids and catchlight never swim with the gaze.
		vec2 gaze = gaze_uv_offset;
		float gaze_length = length(gaze);
		if (gaze_length > 0.021) { gaze *= 0.021 / gaze_length; }
		gaze.y += side * clamp(eye_iris.y, 0.0, 0.008);
		float pop = 1.0 + 0.075 * clamp(eye_iris.z, 0.0, 1.0);
		vec2 disc = (eye_uv - gaze * 0.3) / pop;
		float disc_r = length(disc);
		float rim = clamp(1.0 - disc_r * disc_r / (IRIS_R * IRIS_R), 0.0, 1.0);
		vec2 pupil = disc - gaze * (0.7 / pop) * rim;
		float pupil_r = length(pupil);
		if (pupil_r < IRIS_R && pupil_r > 0.000001) {
			// Radial remap with a fixed limbal edge: r' = R (r/R)^k.
			pupil *= pow(pupil_r / IRIS_R, exp2(0.65 * clamp(eye_iris.x, -1.0, 1.0)) - 1.0);
		}
		float local_weight = 1.0 - smoothstep(0.064, 0.082, eye_dist);
		vec2 iris_uv = (first_eye ? EYE_A : EYE_B) + mix(eye_uv, pupil, local_weight);
		vec3 iris = textureGrad(albedo_texture, iris_uv, uv_dx, uv_dy).rgb;
		// Constriction reads as a small black pupil inside a lifted navy iris.
		float constrict = clamp(-eye_iris.x, 0.0, 1.0);
		if (constrict > 0.0) {
			float pupil_size = mix(0.022, 0.011, constrict);
			float from_pupil = length(eye_uv - gaze);
			float iris_lift = constrict * smoothstep(pupil_size, pupil_size + 0.005, from_pupil)
				* (1.0 - smoothstep(0.036, 0.046, disc_r));
			iris = mix(iris, iris + vec3(0.07, 0.12, 0.26), iris_lift);
		}
		eye_region = max(smoothstep(0.025, 0.09, iris.b - iris.r), 1.0 - smoothstep(0.051, 0.057, disc_r)) * local_weight;
		// Lids live in the socket frame. Both edges are explicit curves, so
		// blinks, squints, smiles and alarm only move edges: no doubled lids.
		float y = clamp(eye_uv.y / IRIS_R, -1.0, 1.0);
		float lc = y * y;
		float upper_close = clamp(eye_lids.x - 0.06 * alarm, -0.4, 1.0);
		float lower_raise = clamp(eye_lids.y + 0.35 * wink, 0.0, 1.0);
		float brow_tilt = clamp(eye_lids.z - 0.9 * alarm, -1.0, 1.0);
		float upper = 0.060 - 0.068 * upper_close - 0.012 * lc * clamp(upper_close * 3.0, 0.0, 1.0);
		upper -= 0.028 * abs(brow_tilt) * smoothstep(-0.7, 1.0, brow_tilt >= 0.0 ? inward : -inward);
		float lower = -0.060 + 0.056 * lower_raise + 0.010 * lc * lower_raise;
		// The original happy crescent: an arched raised lower lid.
		float happy_seam = 0.017 * (1.0 - lc) - 0.004 * lc;
		float happy_upper = happy_seam + 0.044 * (1.0 - lc) + 0.051 * lc;
		float happy_lower = happy_seam + 0.007 * (1.0 - lc) - 0.004 * lc;
		float smile_shape = smoothstep(0.0, 1.0, smile);
		upper = mix(upper, min(upper, happy_upper), smile_shape);
		lower = mix(lower, max(lower, happy_lower), smile_shape);
		// Lids meet slightly below the centre (the upper lid travels furthest).
		// A wink closes into the happy arch: a playful, not a sleepy, wink.
		float seam = mix(-0.004 + 0.006 * lc, happy_seam, max(smile_shape, 0.8 * wink));
		float upper_edge = mix(seam, upper, openness);
		float lower_edge = min(mix(seam, lower, openness), upper_edge);
		float upper_delta = eye_uv.x - upper_edge;
		float lower_delta = eye_uv.x - lower_edge;
		// Resolve both edges of the finite opening together at every angle: a
		// broad footprint must not leave an opaque iris streak outside it.
		float upper_aa = max(fwidth(upper_delta) * 0.5, 0.00045);
		float lower_aa = max(fwidth(lower_delta) * 0.5, 0.00045);
		eye_open = clamp(smoothstep(-lower_aa, lower_aa, lower_delta)
			- smoothstep(-upper_aa, upper_aa, upper_delta), 0.0, 1.0);
		eye_open *= smoothstep(0.0, 0.08, openness);
		// The whole socket shows the resampled disc (white skin around it), so
		// the original painted rim never ghosts beside a shifted/popped iris;
		// a closing lid covers the socket with skin, soft rim included.
		source = mix(source, iris, local_weight);
		source = mix(source, vec3(1.0), local_weight * (1.0 - eye_open));
		// A thin lid line where a lowered lid crosses the light iris rim.
		float lid_band = clamp(smoothstep(-upper_aa, upper_aa, upper_delta)
			- smoothstep(-upper_aa, upper_aa, upper_delta - 0.0016), 0.0, 1.0);
		float lower_band = clamp(smoothstep(-lower_aa, lower_aa, lower_delta + 0.0012)
			- smoothstep(-lower_aa, lower_aa, lower_delta), 0.0, 1.0) * smoothstep(0.08, 0.25, lower_raise);
		lid_line = max(lid_band * 0.55, lower_band * 0.4) * eye_region * smoothstep(0.24, 0.45, openness)
			* (1.0 - smoothstep(0.036, 0.048, abs(eye_uv.y))) * (1.0 - smoothstep(0.0, 0.3, smile));
		// A soft curved seam makes a fully closed blink readable rather than
		// exposing a thin strip of blue pupil or changing the eye geometry.
		float seam_delta = eye_uv.x - seam;
		float seam_aa = max(fwidth(seam_delta) * 0.5, 0.00045);
		float seam_line = clamp(smoothstep(-seam_aa, seam_aa, seam_delta + 0.0014)
			- smoothstep(-seam_aa, seam_aa, seam_delta - 0.0014), 0.0, 1.0)
			* (1.0 - smoothstep(0.034, 0.047, abs(eye_uv.y)));
		closed_lid = seam_line * eye_region * (1.0 - smoothstep(0.06, 0.24, openness));
		if (smile > 0.0) {
			// Restrained lower-lid ink: both edges resolved together so it
			// never widens into a grazing black spike.
			float happy_line = clamp(smoothstep(-lower_aa, lower_aa, lower_delta + 0.0008)
				- smoothstep(-lower_aa, lower_aa, lower_delta - 0.0008), 0.0, 1.0);
			happy_lid = happy_line * eye_region * smile_shape * smoothstep(0.24, 0.45, openness)
				* (1.0 - smoothstep(0.034, 0.047, abs(eye_uv.y)));
		}
	}
	// Mouth: the painted arc is always replaced by the same procedural stroke
	// (fitted to the atlas paint: centre -.0115, ends +.006 at V +-.035), so a
	// neutral face matches the original and every shape changes continuously.
	float mouth_ink = 0.0;
	float mouth_inner = 0.0;
	float tongue = 0.0;
	if (mouth_region > 0.0) {
		source = mix(source, vec3(1.0), mouth_region);
		float open = clamp(mouth_shape.x + 0.75 * startle * alarm, 0.0, 1.0);
		float curve = clamp(mix(mouth_shape.y, -1.0, alarm * (1.0 - 0.6 * startle)), -1.0, 1.0);
		float width = clamp(mouth_shape.z - 0.65 * startle * alarm, -1.0, 1.0);
		float skew = clamp(mouth_shape.w, -1.0, 1.0);
		float round_shape = clamp(-width, 0.0, 1.0);
		float half_width = 0.035 * (1.0 + 0.30 * width);
		float bend = (curve >= 0.0 ? 1.0 + 0.45 * curve : 1.0 + 1.75 * curve) * (1.0 - 0.85 * round_shape * open);
		float s = mouth_uv.y / half_width;
		float sc = clamp(s, -1.0, 1.0);
		float s2 = sc * sc;
		float centre = -0.0044 + bend * (0.0073 * s2 + 0.0104 * s2 * s2 - 0.0071) + 0.006 * skew * sc;
		float slope = (bend * (0.0146 * sc + 0.0416 * s2 * sc) + 0.006 * skew) / half_width;
		float lip = sqrt(max(1.0 - s2, 0.0));
		float upper_lip = centre + open * mix(0.004, 0.016, round_shape) * lip;
		float lower_lip = centre - open * mix(0.017, 0.020, round_shape) * lip;
		float inside = max(lower_lip - mouth_uv.x, mouth_uv.x - upper_lip);
		float stroke = 0.0036;
		float d = abs(s) <= 1.0 ? inside / sqrt(1.0 + slope * slope) - stroke
			: length(vec2(mouth_uv.x - centre, abs(mouth_uv.y) - half_width)) - stroke;
		float mouth_aa = max(fwidth(d) * 0.75, 0.0004);
		mouth_ink = (1.0 - smoothstep(-mouth_aa, mouth_aa, d)) * mouth_region;
		float inner_aa = max(fwidth(inside) * 0.75, 0.0004);
		mouth_inner = (1.0 - smoothstep(-inner_aa, inner_aa, inside + 0.0009)) * (1.0 - step(1.0, abs(s)))
			* smoothstep(0.03, 0.16, open);
		tongue = mouth_inner * smoothstep(0.30, 0.65, open) * (1.0 - round_shape)
			* (1.0 - smoothstep(lower_lip + 0.0035, lower_lip + 0.009 * open + 0.004, mouth_uv.x));
	}
	float eye_mask = eye_region * eye_open;
	float painted_ink = 1.0 - smoothstep(0.015, 0.06, max(source.r, max(source.g, source.b)));
	float skin = (1.0 - eye_mask) * (1.0 - max(max(painted_ink, mouth_ink), max(closed_lid, happy_lid)));
	ALBEDO = mix(source, mix(source, snow_tint.rgb, 0.78), skin);
	// Resolve finite ink after the snowy tint; its antialiased footprint
	// retains the same dark readability as the original painted mouth.
	vec3 mouth_colour = mix(vec3(0.008, 0.010, 0.014), mix(vec3(0.07, 0.02, 0.03), vec3(0.58, 0.22, 0.25), tongue), mouth_inner);
	ALBEDO = mix(ALBEDO, mouth_colour, mouth_ink);
	ALBEDO = mix(ALBEDO, vec3(0.06, 0.10, 0.16), closed_lid * 0.92);
	ALBEDO = mix(ALBEDO, vec3(0.10, 0.16, 0.22), happy_lid * 0.65);
	ALBEDO = mix(ALBEDO, vec3(0.05, 0.08, 0.13), lid_line);
	// Dielectric skin and the wet cornea use the engine's energy-conserving
	// GGX response, including real environment and local-light reflections.
	ROUGHNESS = mix(mix(0.46, 0.105, eye_mask), 0.3, mouth_inner);
	SPECULAR = mix(0.48, 0.62, eye_mask);
	CLEARCOAT = mix(0.10, 0.72, eye_mask);
	CLEARCOAT_ROUGHNESS = mix(0.32, 0.075, eye_mask);
	// A corneal normal supplies rounded highlights without modifying the completed eye geometry.
	vec2 cornea_tilt = clamp(eye_uv / IRIS_R, vec2(-1.0), vec2(1.0)) * 0.48;
	vec3 cornea = normalize(vec3(cornea_tilt, sqrt(max(0.1, 1.0 - dot(cornea_tilt, cornea_tilt)))));
	// Wet catchlights are fixed in the socket (same side for both eyes): the
	// pupil visibly travels under them and they never swim with the gaze.
	float catch_main = 1.0 - smoothstep(0.0040, 0.0066, length((eye_uv - vec2(0.019, -0.017)) * vec2(1.0, 0.85)));
	float catch_small = (1.0 - smoothstep(0.0014, 0.0028, length(eye_uv - vec2(-0.017, 0.014)))) * 0.6;
	ALBEDO = mix(ALBEDO, vec3(0.86, 0.92, 0.98), max(catch_main, catch_small) * eye_mask * 0.62);
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
