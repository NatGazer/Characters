uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
// Keep snowy white below full reflectance so the rounded native mesh remains
// readable in workshop sunlight. The sky and lights supply the highlights.
uniform vec4 snow_tint : source_color = vec4(0.82, 0.875, 0.93, 1.0);
uniform float crystal_density = 125.0;
uniform float sparkle_strength : hint_range(0.0, 1.0) = 0.65;
// Expression belongs to the mesh instance; every helper shares the same skin.
// Blink/overall lid openness (1 = the lid shape below, 0 = closed seam).
instance uniform float eye_openness : hint_range(0.0, 1.0) = 1.0;
// Gaze in atlas UV (U up, V toward Wako's left); |gaze| <= GAZE_MAX. Half
// moves the whole painted disc, half moves the pupil inside its fixed rim.
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
// z eye pop (0...1 enlarges the painted disc for surprise),
// w squeeze (0...1 effort: both eyes pinched shut into a "> <" crease).
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
// The socket is resampled out to SOCKET_R (white skin around the moving
// disc) and blends back into the atlas by SOCKET_FADE, inside the white
// clearance of both islands (the nearest other paint is .086 away).
const float SOCKET_R = 0.073;
const float SOCKET_FADE = 0.082;
const float GAZE_MAX = 0.030;
// Atlas radius where the painted navy ring begins; the soft black core
// inside it is replaced by a crisp pupil.
const float RING_IN = 0.033;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

// Antialiasing half-width of f(UV) from its UV gradient and the screen
// derivatives of UV, taken once in uniform control flow (no fwidth() in
// divergent branches).
float aa_width(vec2 grad, vec2 uv_dx, vec2 uv_dy) {
	return max(0.5 * (abs(dot(grad, uv_dx)) + abs(dot(grad, uv_dy))), 0.0004);
}

float ink_band(float delta, float half_width, float aa) {
	return clamp(smoothstep(-aa, aa, delta + half_width) - smoothstep(-aa, aa, delta - half_width), 0.0, 1.0);
}

// Polynomial smooth maximum (rounded intersection corners).
float smooth_max(float a, float b, float k) {
	float h = max(k - abs(a - b), 0.0) / k;
	return max(a, b) + h * h * k * 0.25;
}

// Open lid shapes in iris radii (x up from the socket centre) at lateral
// position yn (-1...1): (upper, lower, closed seam).
vec3 lid_shape(float yn, float side, float uc, float lr, float tilt, float smile_shape, float wink, float squeeze, float lift) {
	float y2 = yn * yn;
	float inward = side * yn;
	float slant = abs(tilt);
	// Upper lid: an arc that hugs the disc at rest (no flat cap) and stays
	// convex as it lowers, its corners .4-.5R below its middle. Worry and
	// determination lean the whole lid (a straight slant across the disc on
	// a flatter arc), never a pinched corner that meets the rim at an
	// acute angle.
	float upper = 1.0 - 1.5 * uc - mix(0.5, 0.42, smoothstep(0.0, 0.7, uc)) * (1.0 - 0.6 * slant) * y2 + 0.75 * lift;
	upper -= slant * (0.16 + 0.36 * clamp(tilt >= 0.0 ? inward : -inward, -1.0, 1.0));
	// Lower lid: rests under the disc; the cheek lifts it as a gentle
	// upward arc, so partial openings are lenses rather than bars.
	float lower = -1.04 + 0.6 * lr + mix(0.5, 0.2, lr) * y2 + 0.35 * lift;
	// The original happy crescent: an arched raised lower lid. Partial
	// smiles push a wide, flatter arch up from below (the cheek rises most
	// in the middle), so the lower edge is convex at every smile amount.
	float happy_seam = (0.017 * (1.0 - y2) - 0.004 * y2) / IRIS_R;
	float happy_upper = (0.061 * (1.0 - y2) + 0.047 * y2) / IRIS_R;
	upper = mix(upper, min(upper, happy_upper), smile_shape);
	lower = smooth_max(lower, mix(-1.15, 0.436, smile_shape) - mix(0.25, 0.58, smile_shape) * y2, 0.18);
	// Closed seam: a gentle low curve (the upper lid travels furthest); a
	// smile or wink closes into the happy arch, a squeeze into a raised arch.
	float seam = -0.55 + 0.16 * y2 + 0.25 * lr + 0.4 * lift;
	seam = mix(seam, happy_seam, max(smile_shape, 0.8 * wink));
	seam = mix(seam, 0.1 - 0.3 * y2, squeeze);
	return vec3(upper, lower, seam);
}

// Lid edges for an openness: the upper lid's height follows openness, its
// arc flattens into the seam only near closure, and the lower lid waits for
// the upper one (so the upper lid carries most of every blink).
vec2 lid_edges(vec3 shape, vec3 centre, float openness) {
	float upper = mix(centre.z, centre.x, openness)
		+ mix(shape.z - centre.z, shape.x - centre.x, smoothstep(0.0, 0.4, openness));
	float lower = mix(shape.z, shape.y, smoothstep(0.0, 0.55, openness));
	return vec2(upper, min(lower, upper));
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
	float socket = 1.0 - smoothstep(SOCKET_R, SOCKET_FADE, eye_dist);
	if (max(socket, mouth_region) <= 0.001) { discard; }
	ALBEDO = vec3(0.0);
	ALPHA = 1.0;
#else
	// Screen derivatives are taken once, in uniform control flow, and reused
	// by the resampled iris and every analytic edge antialias below.
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	vec3 source = texture(albedo_texture, UV).rgb;
	float alarm = clamp(face_alarm, 0.0, 1.0);
	float startle = clamp(face_startle, 0.0, 1.0);
	float eye_region = 0.0;
	float eye_open = 0.0;
	float lid_ink = 0.0;
	float catch_gain = 0.0;
	float catch_x = 0.019;
	if (eye_dist < SOCKET_FADE) {
		float side = first_eye ? 1.0 : -1.0;
		float smile = clamp(eye_smile, 0.0, 1.0) * (1.0 - alarm);
		float smile_shape = smoothstep(0.0, 1.0, smile);
		float wink = clamp(side * eye_lids.w, 0.0, 1.0);
		float squeeze = clamp(eye_iris.w, 0.0, 1.0);
		float openness = clamp(eye_openness, 0.0, 1.0) * (1.0 - wink) * (1.0 - smoothstep(0.0, 0.5, squeeze));
		float dil = clamp(eye_iris.x, -1.0, 1.0);
		float pop = 1.0 + 0.075 * clamp(eye_iris.z, 0.0, 1.0);
		// Gaze: half moves the whole disc inside the white socket, half moves
		// a crisp pupil inside the disc's fixed rim. Catchlights and lids stay
		// in the socket, so nothing swims with the gaze.
		vec2 gaze = gaze_uv_offset;
		float gaze_length = length(gaze);
		if (gaze_length > GAZE_MAX) { gaze *= GAZE_MAX / gaze_length; }
		gaze.y += side * clamp(eye_iris.y, 0.0, 0.008);
		vec2 disc_shift = gaze * 0.5;
		vec2 pupil_shift = gaze * 0.5 / pop;
		vec2 disc = (eye_uv - disc_shift) / pop;
		float disc_r = length(disc);
		vec2 from_pupil = disc - pupil_shift;
		float fp = length(from_pupil);
		vec2 dir = fp > 0.000001 ? from_pupil / fp : vec2(1.0, 0.0);
		// Distance from the pupil centre to the fixed rim along this ray.
		float b = dot(pupil_shift, dir);
		float to_rim = -b + sqrt(max(b * b - dot(pupil_shift, pupil_shift) + IRIS_R * IRIS_R, 0.0));
		float pupil_r = IRIS_R * clamp(0.5 * exp2(0.42 * dil), 0.34, 0.68);
		// The painted navy ring (RING_IN...R) is laid between the pupil edge
		// and the rim; past the rim the atlas falloff continues into white.
		float ring = (fp - pupil_r) / max(to_rim - pupil_r, 0.002);
		float tex_r = ring < 1.0 ? mix(RING_IN, IRIS_R, clamp(ring, 0.0, 1.0)) : IRIS_R + (fp - to_rim);
		float local_weight = 1.0 - smoothstep(SOCKET_R, SOCKET_FADE, eye_dist);
		vec3 iris = textureGrad(albedo_texture, (first_eye ? EYE_A : EYE_B) + dir * min(tex_r, 0.068), uv_dx, uv_dy).rgb;
		float pupil_aa = aa_width(dir / pop, uv_dx, uv_dy);
		float pupil = 1.0 - smoothstep(pupil_r - pupil_aa, pupil_r + pupil_aa, fp);
		iris = mix(iris, vec3(0.004, 0.006, 0.012), pupil);
		// The wet cornea is the painted disc itself.
		float disc_aa = aa_width(disc / max(disc_r, 0.000001) / pop, uv_dx, uv_dy);
		eye_region = (1.0 - smoothstep(IRIS_R - 0.0015 - disc_aa, IRIS_R + 0.0015 + disc_aa, disc_r)) * local_weight;
		// Lids live in the socket frame: they slide sideways with the disc
		// (the opening keeps hugging it) and lift a little with an upward gaze.
		float uc = clamp(eye_lids.x - 0.06 * alarm, -0.4, 1.0);
		float lr = clamp(eye_lids.y, 0.0, 1.0);
		float tilt = clamp(eye_lids.z - 0.9 * alarm, -1.0, 1.0);
		float lift = disc_shift.x / IRIS_R;
		// The lid arcs continue past the disc to almond corners (no flat clamp).
		float yn = clamp((eye_uv.y - disc_shift.y) / IRIS_R, -1.45, 1.45);
		const float H = 0.04;
		vec3 centre = lid_shape(0.0, side, uc, lr, tilt, smile_shape, wink, squeeze, lift);
		vec3 shape = lid_shape(yn, side, uc, lr, tilt, smile_shape, wink, squeeze, lift);
		vec3 shape_a = lid_shape(clamp(yn - H, -1.45, 1.45), side, uc, lr, tilt, smile_shape, wink, squeeze, lift);
		vec3 shape_b = lid_shape(clamp(yn + H, -1.45, 1.45), side, uc, lr, tilt, smile_shape, wink, squeeze, lift);
		vec2 edges = lid_edges(shape, centre, openness);
		vec2 slope = (lid_edges(shape_b, centre, openness) - lid_edges(shape_a, centre, openness)) / (2.0 * H);
		float seam_slope = (shape_b.z - shape_a.z) / (2.0 * H);
		vec3 delta = vec3(eye_uv.x) - vec3(edges, shape.z) * IRIS_R;
		float upper_aa = aa_width(vec2(1.0, -slope.x), uv_dx, uv_dy);
		float lower_aa = aa_width(vec2(1.0, -slope.y), uv_dx, uv_dy);
		float seam_aa = aa_width(vec2(1.0, -seam_slope), uv_dx, uv_dy);
		// Each lid meets the disc rim through a rounded corner (a smooth
		// intersection of their distances: k ~.12R, growing to ~.34R for a
		// fully slanted lid and .3R for a smiling cheek), so a slanted or
		// arched lid never leaves a pointed wedge on the rim.
		// The rim distance sits just outside the painted soft edge, so a lid
		// that does not cross the disc changes nothing.
		float norm_upper = sqrt(1.0 + slope.x * slope.x);
		float norm_lower = sqrt(1.0 + slope.y * slope.y);
		float d_rim = (disc_r - IRIS_R) * pop - 0.0015;
		float rim_aa = disc_aa * pop;
		float k_upper = (0.12 + 0.22 * abs(tilt)) * IRIS_R;
		float k_lower = (0.12 + 0.18 * smile_shape) * IRIS_R;
		float d_upper = smooth_max(delta.x / norm_upper, d_rim, k_upper);
		float d_lower = smooth_max(-delta.y / norm_lower, d_rim, k_lower);
		float lid_rule = clamp(0.5 + 0.5 * (delta.x / norm_upper - d_rim) / k_upper, 0.0, 1.0);
		float aa_upper = mix(rim_aa, upper_aa / norm_upper, lid_rule);
		float aa_lower = mix(rim_aa, lower_aa / norm_lower, clamp(0.5 + 0.5 * (-delta.y / norm_lower - d_rim) / k_lower, 0.0, 1.0));
		// Both edges of the finite opening resolve together at every angle: a
		// broad footprint never leaves an opaque iris streak outside it.
		eye_open = clamp(1.0 - smoothstep(-aa_lower, aa_lower, d_lower) - smoothstep(-aa_upper, aa_upper, d_upper), 0.0, 1.0);
		eye_open *= smoothstep(0.0, 0.06, openness);
		// The whole socket shows the resampled disc on white skin, so the
		// original painted rim never ghosts beside a shifted or popped iris;
		// a closing lid covers the socket with skin.
		source = mix(source, mix(vec3(1.0), iris, eye_open), local_weight);
		// Lash line only where a lowered lid really crosses the dark disc
		// (never at rest, where the lid just hugs the rim).
		float lid_cover = sqrt(max(1.0 - yn * yn, 0.0)) + lift - edges.x;
		// The lash rides the rounded opening edge and fades out through the
		// corner where the rim takes over (no line floating past the eye).
		float lash = ink_band(d_upper - 0.0009, 0.0009, aa_upper) * smoothstep(0.14, 0.32, lid_cover) * smoothstep(0.3, 0.7, lid_rule);
		float lower_line = ink_band(delta.y + 0.0006, 0.0006, lower_aa) * smoothstep(0.1, 0.3, lr);
		float lid_lines = max(lash * 0.6, lower_line * 0.35) * eye_region * smoothstep(0.3, 0.6, openness)
			* (1.0 - smoothstep(0.0, 0.3, smile));
		// A soft curved seam makes a closed blink readable (never a strip of
		// pupil); a squeeze pinches it into a "> <" crease. The closed ink is
		// ONE stroke at every squeeze: both arms start on the seam and open
		// like scissors about the nose-side tip, so a seam and a crease are
		// never drawn over each other.
		float lateral = 1.0 - smoothstep(0.034, 0.047, abs(eye_uv.y - disc_shift.y));
		float pinch = smoothstep(0.44, 0.68, squeeze);
		float across = side * (eye_uv.y - disc_shift.y * (1.0 - pinch));
		float flank = across < 0.028 ? 0.33 * pinch : 0.0;
		float arm = 0.33 * pinch * clamp(0.028 - across, 0.0, 0.072);
		float closed_x = mix(shape.z * IRIS_R, -0.002, pinch);
		float closed_slope = (1.0 - pinch) * seam_slope;
		float upper_arm_slope = closed_slope - side * flank;
		float lower_arm_slope = closed_slope + side * flank;
		float closed_half = mix(0.0021 + 0.0006 * squeeze, 0.0029, pinch);
		float upper_arm = ink_band(eye_uv.x - closed_x - arm, closed_half * sqrt(1.0 + upper_arm_slope * upper_arm_slope),
			aa_width(vec2(1.0, -upper_arm_slope), uv_dx, uv_dy));
		float lower_arm = ink_band(eye_uv.x - closed_x + arm, closed_half * sqrt(1.0 + lower_arm_slope * lower_arm_slope),
			aa_width(vec2(1.0, -lower_arm_slope), uv_dx, uv_dy));
		float closed_reach = (1.0 - smoothstep(mix(0.034, 0.0285, pinch), mix(0.047, 0.0315, pinch), across))
			* (1.0 - smoothstep(mix(0.034, 0.038, pinch), mix(0.047, 0.045, pinch), -across));
		float closed_ink = max(upper_arm, lower_arm) * closed_reach * mix(eye_region, local_weight, pinch)
			* (1.0 - smoothstep(0.06, 0.24, openness));
		float happy_lid = 0.0;
		if (smile > 0.0) {
			// Restrained lower-lid ink: both edges resolved together so it
			// never widens into a grazing black spike.
			happy_lid = ink_band(delta.y, 0.0008, lower_aa) * eye_region * smile_shape * smoothstep(0.24, 0.45, openness) * lateral;
		}
		lid_ink = max(max(lid_lines, closed_ink * 0.92), happy_lid * 0.65);
		// The main catchlight stays fixed in the socket but just inside the
		// expression's opening (a squint, a draw or a happy crescent keeps
		// its sparkle); blinks and winks simply cover it.
		vec3 catch_lids = lid_shape(clamp((-0.017 - disc_shift.y) / IRIS_R, -1.45, 1.45), side, uc, lr, tilt, smile_shape, wink, squeeze, lift);
		catch_x = min(max(0.019, catch_lids.y * IRIS_R + 0.0075), catch_lids.x * IRIS_R - 0.0075);
		// Worry and wide pupils read as wetter, brighter eyes.
		catch_gain = 0.62 + 0.22 * alarm + 0.2 * clamp(dil, 0.0, 1.0);
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
		// A round "O" narrows as it opens, with mirrored lips (no flat top).
		float half_width = 0.035 * (1.0 + 0.30 * width) * (1.0 - 0.3 * round_shape * clamp(open * 1.4, 0.0, 1.0));
		// An opening "O" loses the smile/frown bend of its centre line (a bent
		// centre would flatten its top into a cup).
		float bend = (curve >= 0.0 ? 1.0 + 0.45 * curve : 1.0 + 1.75 * curve) * (1.0 - round_shape * smoothstep(0.0, 0.3, open));
		float s = mouth_uv.y / half_width;
		float sc = clamp(s, -1.0, 1.0);
		float s2 = sc * sc;
		float centre = -0.0044 + bend * (0.0073 * s2 + 0.0104 * s2 * s2 - 0.0071) + 0.006 * skew * sc;
		float slope = (bend * (0.0146 * sc + 0.0416 * s2 * sc) + 0.006 * skew) / half_width;
		float lip = sqrt(max(1.0 - s2, 0.0));
		float upper_amp = open * mix(0.004, 0.0185, smoothstep(0.0, 0.6, round_shape));
		float lower_amp = open * mix(0.017, 0.0190, round_shape);
		float upper_lip = centre + upper_amp * lip;
		float lower_lip = centre - lower_amp * lip;
		// Perpendicular distance to each lip along its own slope, so an "O" or
		// a wide-open mouth keeps an even outline on its steep sides.
		float lip_slope = -sc / (max(lip, 0.3) * half_width);
		float upper_slope = slope + upper_amp * lip_slope;
		float lower_slope = slope - lower_amp * lip_slope;
		float upper_norm = sqrt(1.0 + upper_slope * upper_slope);
		float lower_norm = sqrt(1.0 + lower_slope * lower_slope);
		float above = (mouth_uv.x - upper_lip) / upper_norm;
		float below = (lower_lip - mouth_uv.x) / lower_norm;
		float inside = max(above, below);
		vec2 inside_grad = above >= below ? vec2(1.0, -upper_slope) / upper_norm : vec2(1.0, -lower_slope) / lower_norm;
		float stroke = 0.0036;
		// The stroke body holds while the foot of the perpendicular stays on
		// the arc; beyond it a round cap ends the stroke (no spike above the
		// steep corners).
		float slope_norm = sqrt(1.0 + slope * slope);
		float foot = mouth_uv.y + (mouth_uv.x - centre) * slope / (slope_norm * slope_norm);
		float end_side = foot >= 0.0 ? 1.0 : -1.0;
		float end_centre = -0.0044 + bend * 0.0106 + 0.006 * skew * end_side;
		vec2 cap = vec2(mouth_uv.x - end_centre, mouth_uv.y - end_side * half_width);
		bool body = abs(foot) <= half_width && abs(s) <= 1.0;
		float d_arc = body ? inside : length(cap);
		vec2 arc_grad = body ? inside_grad : cap / max(length(cap), 0.000001);
		// An open round mouth is a true ellipse ring (no flat sides or
		// end-cap "ears"), taken along the bent centre line so a shout or an
		// "uh-oh" keeps its frown; its distance blends in as the "O" opens.
		vec2 o_radius = vec2(max(0.5 * (upper_amp + lower_amp), 0.0015), half_width);
		vec2 o_point = vec2(mouth_uv.x - centre - 0.5 * (upper_amp - lower_amp), mouth_uv.y);
		vec2 o_normal = o_point / (o_radius * o_radius);
		float o_k0 = length(o_point / o_radius);
		float d_o = o_k0 * (o_k0 - 1.0) / max(length(o_normal), 0.000001);
		float o_weight = smoothstep(0.0, 0.5, round_shape) * smoothstep(0.05, 0.25, open);
		float d_open = mix(d_arc, d_o, o_weight);
		vec2 d_grad = normalize(mix(arc_grad, o_normal / max(length(o_normal), 0.000001), o_weight) + vec2(0.000001, 0.0));
		float mouth_aa = aa_width(d_grad, uv_dx, uv_dy) * 1.5;
		mouth_ink = (1.0 - smoothstep(-mouth_aa, mouth_aa, d_open - stroke)) * mouth_region;
		mouth_inner = (1.0 - smoothstep(-mouth_aa, mouth_aa, d_open + 0.0009)) * smoothstep(0.03, 0.16, open);
		tongue = mouth_inner * smoothstep(0.30, 0.65, open) * (1.0 - smoothstep(0.15, 0.55, round_shape))
			* (1.0 - smoothstep(lower_lip + 0.0035, lower_lip + 0.009 * open + 0.004, mouth_uv.x));
	}
	float eye_mask = eye_region * eye_open;
	float painted_ink = 1.0 - smoothstep(0.015, 0.06, max(source.r, max(source.g, source.b)));
	float skin = (1.0 - eye_mask) * (1.0 - max(max(painted_ink, mouth_ink), lid_ink));
	ALBEDO = mix(source, mix(source, snow_tint.rgb, 0.78), skin);
	// Resolve finite ink after the snowy tint; its antialiased footprint
	// retains the same dark readability as the original painted mouth.
	vec3 mouth_colour = mix(vec3(0.008, 0.010, 0.014), mix(vec3(0.07, 0.02, 0.03), vec3(0.58, 0.22, 0.25), tongue), mouth_inner);
	ALBEDO = mix(ALBEDO, mouth_colour, mouth_ink);
	ALBEDO = mix(ALBEDO, vec3(0.05, 0.08, 0.13), lid_ink);
	// Dielectric skin and a softly wet cornea. The painted catchlights carry
	// the sparkle; the clearcoat stays broad and fades at grazing views, so
	// the sky/ground horizon never draws a second lid line across the eye.
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ROUGHNESS = mix(mix(0.46, 0.36, eye_mask), 0.3, mouth_inner);
	SPECULAR = mix(0.48, 0.4, eye_mask);
	CLEARCOAT = mix(0.10, 0.14 * smoothstep(0.12, 0.5, facing), eye_mask);
	CLEARCOAT_ROUGHNESS = mix(0.32, 0.34, eye_mask);
	// A corneal normal supplies rounded highlights without modifying the completed eye geometry.
	vec2 cornea_tilt = clamp(eye_uv / IRIS_R, vec2(-1.0), vec2(1.0)) * 0.36;
	vec3 cornea = normalize(vec3(cornea_tilt, sqrt(max(0.1, 1.0 - dot(cornea_tilt, cornea_tilt)))));
	// Wet catchlights are fixed in the socket (same side for both eyes): the
	// pupil visibly travels under them and they never swim with the gaze.
	float catch_main = 1.0 - smoothstep(0.0040, 0.0066, length((eye_uv - vec2(catch_x, -0.017)) * vec2(1.0, 0.85)));
	float catch_small = (1.0 - smoothstep(0.0014, 0.0028, length(eye_uv - vec2(-0.017, 0.014)))) * 0.6;
	ALBEDO = mix(ALBEDO, vec3(0.86, 0.92, 0.98), clamp(max(catch_main, catch_small) * eye_mask * catch_gain, 0.0, 0.95));
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
