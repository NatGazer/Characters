shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, diffuse_lambert_wrap;

// Churning white water where a Waterfall hits its pool (or the foot of a cascade). Oval disc mesh: UV.x = angle
// (0..1), UV.y = radius (0 centre .. 1 rim), UV2 = metres from the impact (x downstream, y across).
// The splash zone is solid white along the impact line; around it foam boils up and is carried away by an analytic
// current (radial outflow that slows as it spreads, plus the drift into the outflow), advected with a dual-phase flow
// map so it never stretches. Turbulence rings run outward from the impact and push foam lines ahead of them.

uniform sampler2D foam_tex : filter_linear_mipmap, repeat_enable;  // river_foam.png: R lace, G streaks, B flecks, A patches
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable; // falls_noise.png: G billows, B bubbles
uniform vec3 foam_color : source_color = vec3(0.8, 0.83, 0.84);
uniform float radius_m = 8.0;
uniform float impact_half_width = 3.0; // half the width of the line where the sheet hits
uniform float outflow_speed = 1.2;     // m/s drift towards the outflow (+x of UV2)
uniform float falls_time = 0.0;
uniform float intensity = 1.0;
uniform vec2 dir_w = vec2(0.0, 1.0);  // world xz of UV2.x (downstream)
uniform vec2 side_w = vec2(1.0, 0.0); // world xz of UV2.y (across)

varying vec3 wpos;
varying vec2 q;

float impact_dist(vec2 p) {
	return length(vec2(p.x, max(abs(p.y) - impact_half_width, 0.0)));
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	q = UV2;
	// A heaving boil where the fall hits.
	float d = impact_dist(q);
	float boil = textureLod(noise_tex, wpos.xz * 0.12 + vec2(falls_time * 0.05, 0.0), 0.0).g;
	VERTEX.y += ((boil - 0.3) * 0.5 + 0.15) * (1.0 - smoothstep(0.0, radius_m * 0.45, d)) * intensity;
}

void fragment() {
	float t = falls_time;
	float d = impact_dist(q);
	float R = radius_m;
	// The current: away from the impact line, slowing as it spreads, plus the drift into the outflow.
	vec2 away = vec2(q.x, sign(q.y) * max(abs(q.y) - impact_half_width, 0.0));
	vec2 rad = away / max(length(away), 0.3);
	vec2 vel = rad * (outflow_speed * 2.4 / (1.0 + d * 0.3)) + vec2(outflow_speed * 0.7, 0.0);
	float period = 1.6;
	float jit = texture(noise_tex, q / 17.0).g;
	float ph0 = fract(t / period + jit);
	float ph1 = fract(ph0 + 0.5);
	float w0 = 1.0 - abs(ph0 * 2.0 - 1.0);
	vec2 qa = q - vel * ph0 * period;
	vec2 qb = q - vel * ph1 * period + vec2(3.1, 1.7);
	vec4 fa = texture(foam_tex, qa / 2.6);
	vec4 fb = texture(foam_tex, qb / 2.6);
	vec4 fo = mix(fb, fa, w0);
	float la = texture(foam_tex, qa / 0.95 + 0.37).r;
	float lb = texture(foam_tex, qb / 0.95 + 0.37).r;
	float fine = mix(lb, la, w0);
	float bub = texture(noise_tex, wpos.xz * 0.35 + vec2(0.0, t * 0.05)).b;
	// Turbulence rings running outward from the impact, fading with distance.
	float ring_ph = (d - t * 1.7) / 1.4;
	float ring = sin(ring_ph * TAU + fo.a * 2.0);
	float ring_env = exp(-d / (R * 0.45)) * smoothstep(0.3, 1.5, d);
	// Broken, not concentric contour lines: the rings only show where the foam pattern lets them.
	float ring_foam = smoothstep(0.7, 1.0, ring) * ring_env * smoothstep(0.35, 0.75, fine * 0.6 + fo.a * 0.6);
	// Coverage: solid white along the impact, boiling patches around it, lace towards the rim (longer downstream).
	float reach = R * (q.x > 0.0 ? 1.0 : 0.6);
	float cov = clamp(1.0 - d / reach, 0.0, 1.0);
	cov = clamp(cov * (0.55 + 0.75 * cov) * intensity, 0.0, 1.0);
	float pat = fo.r * 0.6 + fine * 0.35 + fo.a * 0.25 + bub * 0.12;
	float lace = clamp((pat - (1.08 - cov * 1.1)) * 2.4, 0.0, 1.0);
	float core = 1.0 - smoothstep(max(R * 0.12, 0.8), max(R * 0.3, 2.0), d);
	float foam = max(core * 0.95 * intensity, lace);
	foam = max(foam, ring_foam * 0.8);
	foam = max(foam, smoothstep(0.6, 0.95, fo.b) * cov * 0.5);
	foam *= 1.0 - smoothstep(0.82, 1.0, UV.y);
	// Relief: the rings and the lumpy foam tilt the normal (the sun glints on the rings between the foam).
	vec2 g = rad * cos(ring_ph * TAU + fo.a * 2.0) * ring_env * 0.18 + (vec2(fa.r - fb.r, fine - fo.r)) * 0.25 * cov;
	vec2 gw = dir_w * g.x + side_w * g.y;
	vec3 nw = normalize(vec3(-gw.x, 1.0, -gw.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	ALBEDO = foam_color * mix(0.72, 1.02, clamp(fine * 0.6 + fo.r * 0.5, 0.0, 1.0));
	ALPHA = clamp(foam, 0.0, 0.97);
	ROUGHNESS = 0.75;
	SPECULAR = 0.25;
	BACKLIGHT = foam_color * 0.25;
}
