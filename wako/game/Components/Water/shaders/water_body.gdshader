shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

// Lakes and rivers (WaterBody). Same look language as the FFT ocean (ocean_surface.gdshader): refraction of the
// scene behind with Beer-Lambert absorption over the path through the water, caustics on the submerged floor, screen-space
// reflections with the on-screen sky (or an analytic sky) for rays that escape, shore/contact foam and rain rings.
// Lakes: wind ripples from scrolling gradient maps + gust patches.
// Rivers: a dual-phase flow map (two phases half a period apart, crossfaded, with a per-area phase jitter so there is
// no global pulse) advects three scales of detail normals, boils and foam along the per-vertex surface current
// (faster in the core, slow at the banks, pushed outward in bends, back-flow in the eddies below them). White water
// comes from the river analysis (steep stretches, hydraulic jumps at the base of steps, boulder wakes) and persists
// downstream as streaks; standing waves are real vertex displacement (stationary, wavelength 2 pi v^2 / g) with
// analytic per-pixel normals; the tongue before a drop goes glassy; aerated water glows turquoise under the foam.
//
// Mesh attributes (rivers): UV = (u, v) metres (across, downstream), UV2 = surface current in UV space (m/s),
// COLOR = (lateral 0..1, end fade, white water, foam trail), CUSTOM0 = (wave amplitude m, hydraulic jump, glassy lip,
// foam lines), CUSTOM1 = (wave phase rad, wave number rad/m, boulder pillow m, eddy weight), TANGENT = downstream.
// WaterBody._wave_height() mirrors river_wave() so height queries match the drawn surface.

#include "res://Components/Ocean/shaders/ocean_common.gdshaderinc"

#define SSR_STEPS 28

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D ripple_normals : filter_linear_mipmap, repeat_enable; // lake_ripples.png: RG slope, B gusts
uniform sampler2D flow_normals : filter_linear_mipmap, repeat_enable;   // river_flow.png: RG slope, B streaks
uniform sampler2D foam_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D river_foam : filter_linear_mipmap, repeat_enable;     // river_foam.png: R lace, G streaks, B flecks, A patches
uniform sampler2D river_boils : filter_linear, repeat_enable;           // river_boils.png: RG dir, B dist, A cell id
uniform sampler2D rain_tex : filter_linear, repeat_enable;

uniform bool is_river = false;
uniform bool cam_inside = false;    // the camera is in this body's water (back faces are only drawn then)
uniform vec2 wind_dir = vec2(0.0, 1.0);
uniform float wind_speed = 3.0;
uniform float rain = 0.0;
uniform float water_time = 0.0;

uniform float normal_strength = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform vec3 water_albedo : source_color = vec3(0.0, 0.02, 0.018);
uniform vec3 foam_color : source_color = vec3(0.84, 0.87, 0.85);
uniform float foam_amount = 1.0;
uniform float shore_foam = 1.0;
uniform float refraction_strength = 0.05;
uniform float ssr_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sky_zenith = vec3(0.25, 0.45, 0.9);
uniform vec3 sky_horizon = vec3(0.7, 0.8, 0.9);
uniform float edge_softness = 0.1;  // metres of water column over which the shoreline fades in
uniform float flow_tile = 5.5;      // metres per river ripple tile
uniform float turbidity = 0.0;      // rivers: suspended silt, extra in-scattering per metre of path
uniform vec3 silt_tint = vec3(1.7, 1.35, 0.75); // silt in-scattering relative to the clear water scatter (olive-brown)
uniform int debug_view = 0;         // 1 reflection, 2 refraction, 3 normals, 4 foam, 5 flow

varying vec3 wpos;
varying vec2 flow_uv;
varying vec2 flow_vel;
varying vec3 along_w;
varying float lat;
varying float fade;
varying float fresnel;
varying float foam_amt;
varying float rough_var;
varying float from_below;
varying vec4 rv_c0;
varying vec4 rv_c1;
varying vec2 rv_wt;

// Standing waves (+ a slow travelling ripple on top). ph = integrated phase, x = metres across, s = metres downstream.
// The crests bend and break up across the channel (never a row of parallel bars).
float river_wave(float ph, float x, float s, float t) {
	return sin(ph + 2.2 * sin(0.35 * x + 0.09 * s)) * (0.55 + 0.45 * sin(0.7 * x + 0.2 * s + 1.7)) + 0.3 * sin(ph * 1.63 - 0.9 * x + t * 1.7);
}

// d(river_wave)/dx, d/ds for wave number kw.
vec2 river_wave_grad(float ph, float kw, float x, float s, float t) {
	float q = 0.35 * x + 0.09 * s;
	float A = ph + 2.2 * sin(q);
	float r = 0.7 * x + 0.2 * s + 1.7;
	float B = 0.55 + 0.45 * sin(r);
	float C = ph * 1.63 - 0.9 * x + t * 1.7;
	float cA = cos(A);
	float sA = sin(A);
	float cC = cos(C);
	float dAdx = 2.2 * cos(q) * 0.35;
	float dAds = kw + 2.2 * cos(q) * 0.09;
	return vec2(cA * dAdx * B + sA * 0.315 * cos(r) - 0.27 * cC, cA * dAds * B + sA * 0.09 * cos(r) + 0.489 * cC * kw);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	along_w = normalize((MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz + vec3(1e-5, 0.0, 0.0));
	flow_uv = UV;
	flow_vel = UV2;
	lat = COLOR.r * 2.0 - 1.0;
	fade = COLOR.g;
	rv_wt = COLOR.ba;
	rv_c0 = CUSTOM0;
	rv_c1 = CUSTOM1;
	if (is_river) {
		// Standing waves and boulder pillows (stationary: the water moves through them).
		float h = river_wave(rv_c1.x, UV.x, UV.y, water_time) * rv_c0.x + rv_c1.z;
		VERTEX.y += h * fade;
		// Rivers sit 2 cm under their nominal level, and slip further under where they fade into a lake (or the sea):
		// wherever a river overlaps a lake at the same height, the lake deterministically wins the depth test.
		VERTEX.y -= 0.02 + (1.0 - fade) * 0.08;
	} else {
		float amp = clamp(wind_speed * 0.005, 0.0, 0.05);
		vec2 wp2 = vec2(-wind_dir.y, wind_dir.x);
		float h = sin(dot(wpos.xz, wind_dir) * 1.1 - water_time * 1.9) * 0.6 + sin(dot(wpos.xz, wp2) * 0.7 + dot(wpos.xz, wind_dir) * 0.5 - water_time * 1.3) * 0.4;
		float edge = 1.0 - smoothstep(0.85, 1.0, abs(lat)); // flat at the banks (no gaps against the terrain)
		VERTEX.y += h * amp * fade * edge;
	}
}

vec2 slope_tex(sampler2D s, vec2 uv) {
	return texture(s, uv).rg * 2.0 - 1.0;
}

vec3 depth_to_view(vec2 uv, float depth, mat4 inv_proj) {
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return v.xyz / v.w;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist = length(wp - cam);
	vec2 fw = fwidth(wp.xz);
	float px_m = max(max(fw.x, fw.y), 1e-4);
	float t = water_time;
	vec2 grad = vec2(0.0);
	float lost = 0.0;       // ripple slope that mipmapping averaged away -> roughness
	float white = 0.0;      // foam coverage from the water itself (streaks, rapids)
	float spd = 0.0;
	float steep = 0.0;      // rivers: white-water amount (aeration)
	float jump = 0.0;
	float lip = 0.0;
	float foam_shade = 1.0;  // bubbly foam is not uniformly white (holes, shadowed pockets)
	if (!FRONT_FACING && !cam_inside) discard; // the underside only shows from inside the water

	if (!is_river) {
		// --- Lake: wind ripples ---
		vec2 wd = wind_dir;
		vec2 wp2 = vec2(-wd.y, wd.x);
		float gust = texture(ripple_normals, wp.xz / 190.0 - wd * t * (0.003 + wind_speed * 0.0012)).b;
		float gust2 = texture(ripple_normals, wp.xz / 71.0 + wp2 * t * 0.004 - wd * t * 0.006).b;
		float calm = 1.0 - smoothstep(0.5, 4.0, wind_speed);
		float patches = smoothstep(0.3, 0.85, gust * 0.7 + gust2 * 0.45);
		float str = (0.035 + 0.075 * wind_speed) * mix(mix(0.25, 1.6, patches), mix(0.4, 1.3, patches), calm);
		str = min(str, 1.4) * normal_strength;
		float drift = 0.03 + wind_speed * 0.012;
		// Three layers, rotated against each other so the tiles never line up.
		mat2 r1 = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
		mat2 r2 = mat2(vec2(0.28, -0.96), vec2(0.96, 0.28));
		float T1 = 11.0, T2 = 4.3, T3 = 1.7;
		vec2 g1 = slope_tex(ripple_normals, wp.xz / T1 + wd * t * drift / T1);
		vec2 g2 = transpose(r1) * slope_tex(ripple_normals, (r1 * wp.xz) / T2 + (r1 * (wd * 0.8 + wp2 * 0.3)) * t * drift * 1.3 / T2);
		vec2 g3 = transpose(r2) * slope_tex(ripple_normals, (r2 * wp.xz) / T3 + (r2 * (wd * 0.6 - wp2 * 0.4)) * t * drift * 1.7 / T3);
		float l1 = smoothstep(1.0, 12.0, px_m * 512.0 / T1);
		float l2 = smoothstep(1.0, 12.0, px_m * 512.0 / T2);
		float l3 = smoothstep(1.0, 12.0, px_m * 512.0 / T3);
		grad = (g1 * 0.55 * (1.0 - l1) + g2 * 0.4 * (1.0 - l2) + g3 * 0.28 * (1.0 - l3)) * str;
		lost = (0.55 * l1 + 0.4 * l2 + 0.28 * l3) * str;
	} else {
		// --- River ---
		spd = length(flow_vel);
		float ww = rv_wt.x;          // white water from the river analysis
		float trail = rv_wt.y;       // foam carried downstream
		float amp = rv_c0.x;
		jump = rv_c0.y;
		lip = rv_c0.z;
		float lines = rv_c0.w;
		float eddy = rv_c1.w;
		// Static breakup across the channel: a step pours in chutes and white tongues, not a uniform comb.
		vec4 stat = texture(river_foam, flow_uv * vec2(1.0 / 4.0, 1.0 / 6.5) + vec2(0.37, 0.11));
		// Chutes: streaks of dark glassy water running through the white of a step or a rapid.
		float chute = texture(river_foam, vec2(flow_uv.x / 3.1, flow_uv.y / 26.0) + vec2(0.71, 0.3)).a * 0.6
			+ texture(river_foam, vec2(flow_uv.x / 7.3 + flow_uv.y * 0.013, flow_uv.y / 47.0) + vec2(0.23, 0.61)).r * 0.55;
		ww = clamp(ww * mix(0.6, 1.2, stat.a) * mix(0.35, 1.15, smoothstep(0.3, 0.75, chute)), 0.0, 1.0);
		steep = ww;
		// Dual-phase advection along the local current. The phase is offset per area (low-frequency jitter) so the
		// crossfade never pulses in sync over the whole river.
		float period = 1.2;
		float jitter = texture(flow_normals, flow_uv / 37.0).b * 1.7 + texture(ripple_normals, flow_uv / 23.0).b;
		float ph0 = fract(t / period + jitter);
		float ph1 = fract(ph0 + 0.5);
		float w0 = 1.0 - abs(ph0 * 2.0 - 1.0);
		vec2 uvA = flow_uv - flow_vel * (ph0 * period);
		vec2 uvB = flow_uv - flow_vel * (ph1 * period) + vec2(3.71, 5.29);
		// Detail normals at three scales: long flow lines, mid chop, fine turbulent chop (rough water only).
		float T1 = flow_tile, T2 = flow_tile * 0.38, T3 = flow_tile * 0.15;
		vec2 gA = slope_tex(flow_normals, uvA / T1) * 0.55 + slope_tex(ripple_normals, uvA / T2 + 0.31) * 0.4;
		vec2 gB = slope_tex(flow_normals, uvB / T1) * 0.55 + slope_tex(ripple_normals, uvB / T2 + 0.31) * 0.4;
		vec2 g = mix(gB, gA, w0);
		float rough_w = clamp(ww + jump * 0.5, 0.0, 1.0);
		float l1 = smoothstep(1.0, 12.0, px_m * 512.0 / T1);
		float l3 = smoothstep(1.0, 12.0, px_m * 512.0 / T3);
		if (rough_w > 0.02 && l3 < 0.99) {
			vec2 fA = slope_tex(ripple_normals, uvA / T3 + vec2(0.13, 0.71));
			vec2 fB = slope_tex(ripple_normals, uvB / T3 + vec2(0.13, 0.71));
			g += mix(fB, fA, w0) * rough_w * 0.9 * (1.0 - l3);
		}
		float str = (0.1 + 0.035 * spd + 0.55 * rough_w + 0.15 * eddy) * (1.0 - 0.75 * lip) * normal_strength * (1.0 + wind_speed * 0.02);
		// Boils: domes of upwelling water that swell, spread a ring of foam and fade, drifting with the current.
		float boil_on = clamp(jump * 0.9 + ww * 0.45 + eddy * 0.5, 0.0, 1.0) * (1.0 - lip) + 0.12;
		float ring = 0.0;
		vec2 gboil = vec2(0.0);
		if (dist < 120.0) {
			for (int i = 0; i < 2; i++) {
				vec2 buv = (i == 0 ? uvA : uvB) / 7.5 + vec2(0.21, 0.0);
				vec4 c = texture(river_boils, buv);
				float life = fract(t * 0.23 + c.a * 7.13);
				float r = 0.25 + 0.7 * life;
				float d = c.b;
				float live = step(0.35, fract(c.a * 13.7)) * (1.0 - life) * smoothstep(0.0, 0.08, life);
				float inside = step(d, r);
				float dh = -2.0 * d / (r * r) * inside * live;
				vec2 dir = c.rg * 2.0 - 1.0;
				float wgt = i == 0 ? w0 : 1.0 - w0;
				gboil += dir * dh * 0.35 * wgt;
				float rr = (d - r) / 0.09;
				ring += exp(-rr * rr) * live * wgt;
			}
			float near = 1.0 - smoothstep(50.0, 120.0, dist);
			gboil *= boil_on * near;
			ring *= boil_on * near;
		}
		// Tile-space slope -> world: u = side (right of the flow), v = downstream.
		vec2 along2 = normalize(along_w.xz);
		vec2 side2 = vec2(-along2.y, along2.x);
		vec2 gw = river_wave_grad(rv_c1.x, rv_c1.y, flow_uv.x, flow_uv.y, t) * amp;
		vec2 gt = g * str * (1.0 - l1) + gboil + gw;
		grad = side2 * gt.x + along2 * gt.y;
		lost = str * l1 + rough_w * 0.6 * l3;
		// --- Foam from the water itself ---
		// Two scales of bubbly lace, both advected; coverage thresholds them softly (translucent, lacy edges).
		vec4 fa = texture(river_foam, uvA * vec2(1.0 / 2.4, 1.0 / 3.4));
		vec4 fb = texture(river_foam, uvB * vec2(1.0 / 2.4, 1.0 / 3.4));
		vec4 fo = mix(fb, fa, w0);
		float la = texture(river_foam, uvA * vec2(1.0 / 0.9, 1.0 / 1.3) + vec2(0.61, 0.27)).r;
		float lb = texture(river_foam, uvB * vec2(1.0 / 0.9, 1.0 / 1.3) + vec2(0.61, 0.27)).r;
		float lace2 = mix(lb, la, w0);
		// Rafts of foam stretched along the flow (lace, 3:1) with a few longer streak lines.
		vec4 ra = texture(river_foam, uvA * vec2(1.0 / 1.8, 1.0 / 5.5) + vec2(0.5, 0.0));
		vec4 rb = texture(river_foam, uvB * vec2(1.0 / 1.8, 1.0 / 5.5) + vec2(0.5, 0.0));
		vec4 rr = mix(rb, ra, w0);
		float streak = rr.r * 0.75 + rr.g * 0.35;
		float pat = fo.r * 0.55 + lace2 * 0.35 + fo.a * 0.25;
		// White water: dense aerated foam where the analysis says so, broken into lace at its edges.
		float cw = clamp(ww * 1.1 + jump * 0.2, 0.0, 1.0);
		float wfoam = clamp((pat - (1.12 - cw)) * 2.3, 0.0, 1.0) * smoothstep(0.02, 0.2, cw);
		// Trail foam: rafts of old foam drifting downstream in streaks, thinning out; foam lines (eddy fences, the
		// core convergence line, boulder wakes).
		float tr_amt = clamp(trail * 1.1 + lines * 0.9, 0.0, 1.2);
		float tfoam = clamp((pat * 0.5 + streak * 0.6 - (1.2 - tr_amt * 0.7)) * 2.0, 0.0, 1.0) * smoothstep(0.02, 0.25, tr_amt) * (0.55 + 0.45 * rr.a);
		float flecks = smoothstep(0.6, 0.95, fo.b) * (0.15 + 0.85 * clamp(trail + lines, 0.0, 1.0)) * 0.6;
		white = max(max(wfoam, tfoam * 0.85), max(flecks * 0.6, smoothstep(0.3, 0.95, ring) * 0.7 * (0.6 + 0.4 * lace2)));
		foam_shade = mix(0.72, 1.0, smoothstep(0.2, 0.8, lace2 * 0.6 + fo.r * 0.5));
		// Far away the pattern averages out: fade to the mean coverage.
		float far = smoothstep(60.0, 300.0, dist);
		white = mix(white, cw * 0.7 + trail * 0.12, far);
		white *= foam_amount;
	}

	// --- Rain: ring ripples near the camera (same drop texture as the ocean) ---
	if (rain > 0.001 && dist < 45.0) {
		vec2 rip = vec2(0.0);
		for (int k = 0; k < 2; k++) {
			vec4 r = texture(rain_tex, wp.xz * (k == 0 ? 0.42 : 0.31) + vec2(0.37, 0.61) * float(k));
			float life = fract(r.b + t * (k == 0 ? 1.1 : 0.93));
			float ring = life - 1.0 + r.a;
			float amp = sin(clamp(ring * 9.0, 0.0, 3.0) * PI) * clamp(1.0 - life * 1.15, 0.0, 1.0) * step(0.001, r.a);
			rip += (r.rg * 2.0 - 1.0) * amp;
		}
		grad += rip * rain * 0.45 * (1.0 - smoothstep(15.0, 45.0, dist));
	}

	float alpha0 = roughness * roughness;
	rough_var = sqrt(sqrt(alpha0 * alpha0 + lost * lost * 0.02 + rain * 0.0004)) * (1.0 - 0.4 * lip);
	vec3 n_world = normalize(vec3(-grad.x, 1.0, -grad.y));
	bool below = !FRONT_FACING;
	from_below = below ? 1.0 : 0.0;

	// --- Scene behind the surface ---
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec3 scene_view = depth_to_view(SCREEN_UV, raw_depth, INV_PROJECTION_MATRIX);
	float scene_y = (INV_VIEW_MATRIX * vec4(scene_view, 1.0)).y;
	float col_depth = raw_depth <= 0.000001 ? 1e4 : max(wp.y - scene_y, 0.0);

	// --- Foam: shore line + the water's own white water, thresholded through the bubbly texture ---
	vec2 fuv = (is_river ? flow_uv - vec2(0.0, spd * t * 0.5) : wp.xz) * 0.21;
	float foam_n = texture(foam_tex, fuv + vec2(t * 0.011, t * 0.006)).r;
	float foam_n2 = texture(foam_tex, fuv * 0.41 - vec2(t * 0.004, 0.0)).r;
	float shore = 0.0;
	if (!below) {
		float band_w = is_river ? 0.22 + steep * 0.45 : 0.22 + wind_speed * 0.015;
		float band = 1.0 - smoothstep(0.0, band_w, col_depth);
		float lap = 0.5 + 0.5 * sin(col_depth * 14.0 - t * 1.3 + foam_n2 * 6.0);
		// Rivers: foam gathers on the banks in patches (and along fast water), not as an even outline.
		float strength = is_river ? (0.25 + steep * 0.7 + spd * 0.06) * smoothstep(0.25, 0.75, foam_n2 + steep * 0.4) : 0.18 + wind_speed * 0.035;
		shore = band * mix(0.5, 1.0, lap) * strength * shore_foam;
	}
	// Shore foam: coverage thresholded through the bubbly texture (lace). River white water already has its structure.
	float coverage = clamp(shore, 0.0, 1.0);
	float lace = smoothstep(1.0 - coverage, 1.0 - coverage + 0.3, foam_n * 0.7 + foam_n2 * 0.4);
	float foam = clamp(mix(lace, coverage * 0.55, smoothstep(40.0, 250.0, dist)) * coverage * 1.5 + white * 0.9, 0.0, 1.0);
	foam_amt = foam;

	vec3 n_view = normalize((VIEW_MATRIX * vec4(below ? -n_world : n_world, 0.0)).xyz);
	vec3 v = normalize(-VERTEX);
	float soft = clamp(col_depth / max(edge_softness, 1e-3), 0.0, 1.0);

	if (!below) {
		// --- Refraction ---
		float depth_fade = clamp(col_depth * 0.6, 0.0, 1.0);
		vec2 refr_uv = SCREEN_UV - n_view.xz * refraction_strength * depth_fade / max(1.0, dist * 0.05);
		float refr_depth = texture(depth_tex, refr_uv).r;
		vec3 refr_view = depth_to_view(refr_uv, refr_depth, INV_PROJECTION_MATRIX);
		if (length(refr_view) < length(VERTEX)) {
			refr_uv = SCREEN_UV;
			refr_depth = raw_depth;
			refr_view = scene_view;
		}
		vec3 refr_world = (INV_VIEW_MATRIX * vec4(refr_view, 1.0)).xyz;
		vec3 floor_col = textureLod(screen_tex, refr_uv, 0.0).rgb;
		float path = max(length(refr_view) - length(VERTEX), 0.0);
		bool is_sky = refr_depth <= 0.000001;
		if (is_sky) path = 1e4;
		float fl_depth = max(wp.y - refr_world.y, 0.0);
		if (!is_sky) {
			floor_col *= exp(-absorption * fl_depth * 0.7);
			floor_col += floor_col * caustics(refr_world, fl_depth) * 1.8 * (1.0 - steep);
		}
		// Silt: extra extinction and in-scattering over the path (the bed fades out in the deep middle of a river).
		vec3 ext = absorption + vec3(turbidity);
		vec3 tr = exp(-ext * path);
		vec3 inscat = scatter_color * mix(vec3(1.0), silt_tint, clamp(turbidity * 2.5, 0.0, 1.0));
		vec3 water = floor_col * tr + inscat * (1.0 - tr);
		// Aerated water (bubbles under white water) scatters light back up: a turquoise-white glow.
		water += scatter_color * (steep * 6.0 + jump * 3.0) * (1.0 - tr * 0.5);

		// --- Screen-space reflection (march + binary refinement: flat lakes mirror their shores crisply) ---
		vec3 r_view = reflect(-v, n_view);
		vec3 ssr = vec3(0.0);
		float ssr_hit = 0.0;
		float nv = clamp(dot(n_view, v), 0.0, 1.0);
		fresnel = mix(pow(1.0 - nv, 5.0 * exp(-2.69 * rough_var)) / (1.0 + 22.7 * pow(rough_var, 1.5)), 1.0, 0.02);
		fresnel *= soft;
		// March only where the reflection is strong enough to see (looking down into the water it is ~2%).
		if (ssr_strength > 0.0 && r_view.z < 0.0 && fresnel > 0.04) {
			float step_len = 0.3 + dist * 0.018;
			vec3 p = VERTEX;
			vec3 prev = p;
			for (int i = 0; i < SSR_STEPS; i++) {
				prev = p;
				p += r_view * step_len;
				step_len *= 1.15;
				vec4 clip = PROJECTION_MATRIX * vec4(p, 1.0);
				vec2 suv = clip.xy / clip.w * 0.5 + 0.5;
				if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0 || clip.w <= 0.0) break;
				float sd = texture(depth_tex, suv).r;
				vec3 sv = depth_to_view(suv, sd, INV_PROJECTION_MATRIX);
				float diff = sv.z - p.z;
				if (diff > 0.0 && sd > 0.000001) {
					if (diff < step_len * 3.0) {
						vec3 lo = prev;
						vec3 hi = p;
						for (int b = 0; b < 4; b++) {
							vec3 mid = (lo + hi) * 0.5;
							vec4 mc = PROJECTION_MATRIX * vec4(mid, 1.0);
							vec2 muv = mc.xy / mc.w * 0.5 + 0.5;
							vec3 mv = depth_to_view(muv, texture(depth_tex, muv).r, INV_PROJECTION_MATRIX);
							if (mv.z - mid.z > 0.0) hi = mid; else lo = mid;
						}
						vec4 hc = PROJECTION_MATRIX * vec4(hi, 1.0);
						suv = hc.xy / hc.w * 0.5 + 0.5;
						vec2 edge = smoothstep(vec2(0.0), vec2(0.07), suv) * smoothstep(vec2(0.0), vec2(0.07), 1.0 - suv);
						ssr_hit = edge.x * edge.y * (1.0 - smoothstep(0.6, 1.0, float(i) / float(SSR_STEPS)));
						ssr = textureLod(screen_tex, suv, rough_var * 6.0).rgb;
					}
					break;
				}
			}
		}
		ssr_hit *= ssr_strength;
		// Sky: the real on-screen sky where the reflected direction shows, else an analytic gradient.
		vec3 r_world = (INV_VIEW_MATRIX * vec4(r_view, 0.0)).xyz;
		float ry = max(r_world.y, 0.0);
		vec3 sky = mix(sky_horizon, sky_zenith, pow(ry, 0.45));
		vec4 cinf = PROJECTION_MATRIX * vec4(r_view, 0.0);
		if (cinf.w > 0.0) {
			vec2 iuv = cinf.xy / cinf.w * 0.5 + 0.5;
			if (iuv.x > 0.0 && iuv.x < 1.0 && iuv.y > 0.0 && iuv.y < 1.0 && texture(depth_tex, iuv).r <= 0.000001) {
				vec2 e = smoothstep(vec2(0.0), vec2(0.06), iuv) * smoothstep(vec2(0.0), vec2(0.06), 1.0 - iuv);
				sky = mix(sky, textureLod(screen_tex, iuv, 1.0 + rough_var * 5.0).rgb, e.x * e.y);
			}
		}
		vec3 refl = mix(sky, ssr, ssr_hit);
		ALBEDO = mix(water_albedo, foam_color * foam_shade, foam);
		EMISSION = (water * (1.0 - fresnel) + refl * fresnel) * (1.0 - foam);
		if (debug_view == 1) { ALBEDO = vec3(0.0); EMISSION = refl * fresnel; }
		if (debug_view == 2) { ALBEDO = vec3(0.0); EMISSION = water; }
		if (debug_view == 3) { ALBEDO = vec3(0.0); EMISSION = n_world * 0.5 + 0.5; }
		if (debug_view == 4) { ALBEDO = vec3(0.0); EMISSION = vec3(white, foam, shore); }
		if (debug_view == 5) { ALBEDO = vec3(0.0); EMISSION = vec3(max(flow_vel.x, 0.0), max(flow_vel.y, 0.0), max(-flow_vel.y, 0.0)) * 0.3; }
		SPECULAR = 0.0;
		ROUGHNESS = mix(rough_var, 0.85, foam);
		NORMAL = n_view;
		ALPHA = soft * fade;
		if (ALPHA < 0.01) discard; // invisible parts must not write depth (a lake under a faded river end)
	} else {
		// --- Seen from below: Snell's window and total internal reflection ---
		vec3 tdir = refract(-v, n_view, 1.333);
		vec3 col;
		float nv = clamp(dot(n_view, v), 0.0, 1.0);
		if (dot(tdir, tdir) < 1e-4) {
			col = scatter_color * 1.8;
			fresnel = 1.0;
		} else {
			vec4 clip = PROJECTION_MATRIX * vec4(VERTEX + tdir * 8.0, 1.0);
			vec2 suv = clamp(clip.xy / clip.w * 0.5 + 0.5, vec2(0.001), vec2(0.999));
			vec3 above = textureLod(screen_tex, mix(SCREEN_UV, suv, 0.6), 0.0).rgb;
			col = mix(scatter_color * 1.8, above, (1.0 - pow(1.0 - nv, 5.0)) * smoothstep(0.0, 0.25, nv));
			fresnel = 0.0;
		}
		ALBEDO = vec3(0.0);
		EMISSION = mix(col, foam_color * scatter_color * 6.0, foam * 0.6);
		SPECULAR = 0.0;
		ROUGHNESS = 1.0;
		NORMAL = n_view;
		ALPHA = fade;
		if (ALPHA < 0.01) discard;
	}
}

float smith_masking_shadowing(float cos_theta, float alpha) {
	float a = cos_theta / (alpha * sqrt(max(1.0 - cos_theta * cos_theta, 1e-5)));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(float cos_theta, float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	if (from_below < 0.5) {
		vec3 halfway = normalize(LIGHT + VIEW);
		float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
		float dot_nv = max(dot(NORMAL, VIEW), 2e-5);
		float r = max(mix(rough_var, 0.85, foam_amt), 0.02);
		float light_mask = smith_masking_shadowing(r, dot_nv);
		float view_mask = smith_masking_shadowing(r, dot_nl);
		float distr = ggx_distribution(dot(NORMAL, halfway), r);
		float geo = 1.0 / (1.0 + light_mask + view_mask);
		SPECULAR_LIGHT += fresnel * distr * geo / (4.0 * dot_nv + 0.1) * ATTENUATION * LIGHT_COLOR * (1.0 - foam_amt);
		DIFFUSE_LIGHT += dot_nl * mix(water_albedo, foam_color, foam_amt) * ATTENUATION * LIGHT_COLOR / PI;
	}
}
