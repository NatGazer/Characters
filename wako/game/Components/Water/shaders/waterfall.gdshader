shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_lambert_wrap, specular_schlick_ggx;

// Falling sheet of a Waterfall. UV.x = across (0..1), UV.y = time of flight from the lip (s, negative on the lip run-up),
// UV2.x = fall fraction (0 lip .. 1 pool), UV2.y = arc length (m), COLOR.r = layer (0 front / on the rock, 1 inner /
// tumbling top layer), COLOR.g = 1 for a cascade. Every texture feature is advected by the time of flight, so it
// accelerates with the water and stretches into streaks as it falls (no scrolling mismatch, no seams).
// The look: glassy and whole over the lip; lower down the sheet tears into ragged jets (columns with holes between
// them), the thick core aerates to white while the thin edges stay translucent and shed droplets.

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable; // falls_noise.png: R streaks, G billows, B bubbles, A grain
uniform sampler2D jets_tex : filter_linear_mipmap, repeat_enable;  // falls_jets.png: R jets, G holes, B drops, A core
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform vec3 sky_color = vec3(0.5, 0.6, 0.75);           // what the glassy water reflects (set from the sky)
uniform vec3 glass_tint : source_color = vec3(0.62, 0.8, 0.74); // clear water over the lip tints what's behind it
uniform vec3 water_color : source_color = vec3(0.05, 0.12, 0.11);
uniform vec3 foam_color : source_color = vec3(0.8, 0.83, 0.84);
uniform float width_m = 6.0;
uniform float drop_m = 10.0;
uniform float flow_rate = 1.0;       // time multiplier (thin falls look faster)
uniform float breakup = 1.0;         // how ragged the lower sheet gets
uniform float soft_depth = 0.8;      // metres of soft fade where the sheet meets rock / water
uniform float falls_time = 0.0;

varying float fallf;
varying float tof;
varying float layer;
varying float casc;

void vertex() {
	fallf = UV2.x;
	tof = UV.y;
	layer = COLOR.r;
	casc = COLOR.g;
	float ts = tof * 0.45 - falls_time * flow_rate * 0.45 + layer * 0.37;
	float n = textureLod(noise_tex, vec2(UV.x * width_m / 9.0, ts), 0.0).g;
	float n2 = textureLod(noise_tex, vec2(UV.x * width_m / 4.0 + 0.3, ts * 2.1), 0.0).g;
	// The sheet flutters and thickens as it falls (billowing out of the plane, more at the bottom); a cascade boils.
	float amp = mix(0.6 + width_m * 0.04, 0.25 + layer * 0.35, casc);
	VERTEX += NORMAL * ((n - 0.5) * 0.5 + (n2 - 0.5) * 0.25) * smoothstep(0.03, 0.5, fallf + casc) * amp;
}

vec3 depth_to_view(vec2 uv, float depth, mat4 inv_proj) {
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return v.xyz / v.w;
}

void fragment() {
	float x = UV.x + layer * 0.29; // the inner layer gets its own streaks
	float xm = x * width_m;        // metres across
	float t = falls_time * flow_rate;
	float ts = tof - t + layer * 0.41;
	// Streaks and billows (falls_noise) plus jets / holes / drops / core billows (falls_jets), all advected.
	vec2 u1 = vec2(xm / 5.5, ts * 0.75);
	vec2 u2 = vec2(xm / 2.1 + 0.37, ts * 1.7);
	float s1 = texture(noise_tex, u1).r;
	float s2 = texture(noise_tex, u2).r;
	float billow = texture(noise_tex, vec2(xm / 8.0 + 0.61, ts * 0.42)).g;
	float bub = texture(noise_tex, vec2(xm / 1.4, ts * 1.3)).b;
	float grain = texture(noise_tex, vec2(xm / 0.9, ts * 2.6)).a;
	float wander = (billow - 0.5) * 1.2 * fallf;
	float jets = texture(jets_tex, vec2((xm + wander) / 3.4, ts * 0.5)).r;
	float jets2 = texture(jets_tex, vec2((xm - wander) / 1.5 + 0.43, ts * 0.9)).r;
	float holes = texture(jets_tex, vec2(xm / 5.0 + 0.3, ts * 0.33)).g;
	float drops = texture(jets_tex, vec2(xm / 1.1, ts * 1.2)).b;
	float core = texture(jets_tex, vec2(xm / 6.5 + 0.7, ts * 0.28)).a;
	float streak = s1 * 0.6 + s2 * 0.4;
	float jj = jets * 0.65 + jets2 * 0.35;

	float edge = abs(UV.x * 2.0 - 1.0);
	// Thickness of the water across the sheet: a thick core, thin sides; the core billows.
	float thick = (1.0 - pow(edge, 2.2)) * (0.7 + 0.45 * core);
	// Aeration: glassy over the lip, white a few metres down (sooner for a small fall), churned near the pool.
	float aer_len = mix(clamp(4.0 / drop_m, 0.08, 0.35), 0.02, casc);
	float aer = smoothstep(-0.02, aer_len, fallf);
	float white = aer * (0.4 + billow * 0.45 + core * 0.25) * (0.55 + 0.6 * thick) + (streak - 0.5) * 0.7 * aer + bub * 0.2 * aer
		+ smoothstep(0.75, 1.0, fallf) * 0.3;
	white += smoothstep(-0.25, 0.0, tof) * (1.0 - aer) * (s2 * 0.5); // white threads already forming on the lip
	white = mix(white, white * 0.55, smoothstep(0.55, 1.0, edge));   // thin edges stay glassy
	// A cascade tumbles: white where the water hits the rock steps, dark glassy runs between them.
	white = mix(white, clamp(smoothstep(0.35, 0.8, jj * 0.6 + core * 0.4 + (billow - 0.5) * 0.5) - (1.0 - thick) * 0.4, 0.0, 1.0), casc);
	white = clamp(white, 0.0, 1.0);
	// Foam clumps: big aerated slugs of water riding down the sheet with darker, glassier water between them, so
	// the free fall is never one even white curtain (it read as a flat streaky ribbon).
	float clump = texture(noise_tex, vec2(xm / 3.2 + 0.13, ts * 0.21)).g * 0.65 + texture(jets_tex, vec2(xm / 2.4 + 0.51, ts * 0.38)).a * 0.35;
	float clumpy = smoothstep(0.3, 0.75, clump);
	float freefall = aer * (1.0 - casc);
	white *= mix(1.0, mix(0.42, 1.12, clumpy), freefall);
	white = clamp(white - (0.55 - jj) * 0.45 * freefall, 0.0, 1.0);

	// Coverage: whole near the lip, then torn into jets with holes between them, ragged edges shedding drops.
	float br = clamp(fallf * breakup * (1.0 - casc * 0.5), 0.0, 1.2);
	float density = thick * mix(1.0, 0.55, smoothstep(0.05, 0.5, br)) + 0.1
		+ (jj - 0.5) * (0.3 + 2.0 * br)
		+ (holes - 0.6) * 1.5 * br
		+ (s2 - 0.5) * 0.25 + (grain - 0.5) * 0.12
		- br * 0.3
		- smoothstep(0.45, 1.0, edge + ((jets2 - 0.5) * 0.4 + (grain - 0.5) * 0.25) * smoothstep(0.0, 0.2, fallf)) * (0.3 + 0.75 * fallf + 0.5 * casc);
	float a = smoothstep(0.12, 0.34, density);
	// Drops separating from the torn edges and the lower sheet.
	float shed = smoothstep(0.25, 0.75, edge + br * 0.45) * smoothstep(0.04, 0.3, fallf) * (1.0 - casc);
	a = max(a, smoothstep(0.35, 0.8, drops) * shed * 0.85);
	// The run-up over the lip fades in on top of the river surface (which ends at the lip).
	float runup = smoothstep(-0.45, 0.2, tof);
	a *= runup;
	// Free fall: the inner layer only once the fall has separated. Cascade: the top layer is the patchy white churn.
	a *= mix(1.0 - layer * (1.0 - smoothstep(0.05, 0.25, fallf)), 1.0 - layer * (1.0 - smoothstep(0.35, 0.7, white * core + bub * 0.3)), casc);
	// Soft where the sheet meets rock or plunges into the pool.
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec3 sv = depth_to_view(SCREEN_UV, raw, INV_PROJECTION_MATRIX);
	float gap = length(sv) - length(VERTEX);
	a *= clamp(gap / mix(soft_depth, 0.6, casc), 0.0, 1.0);

	// Streak relief: across-gradient of the streak texture bends the normal sideways (glints run down the sheet).
	float gx = texture(noise_tex, u1 + vec2(0.012, 0.0)).r - s1 + (texture(noise_tex, u2 + vec2(0.02, 0.0)).r - s2) * 0.5;
	float gj = texture(jets_tex, vec2(xm / 3.4 + 0.015, ts * 0.5)).r - jets;
	float gy = billow - texture(noise_tex, vec2(xm / 8.0 + 0.61, ts * 0.42 + 0.02)).g;
	vec3 n = FRONT_FACING ? NORMAL : -NORMAL;
	n = normalize(n + TANGENT * (gx * 6.0 + gj * 4.0) + BINORMAL * gy * 2.0);
	NORMAL = n;
	// Glassy (not yet aerated) water: refracts what is behind it and reflects the sky at grazing angles.
	float nv = clamp(dot(n, VIEW), 0.0, 1.0);
	float fres = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
	vec3 behind = textureLod(screen_tex, SCREEN_UV + n.xy * 0.025, 1.5).rgb;
	// Reflection: the on-screen sky where the reflected ray's direction shows it, else the sky colour.
	vec3 rv = reflect(-VIEW, n);
	vec3 refl = sky_color;
	vec4 cinf = PROJECTION_MATRIX * vec4(rv, 0.0);
	if (cinf.w > 0.0) {
		vec2 iuv = cinf.xy / cinf.w * 0.5 + 0.5;
		if (iuv.x > 0.0 && iuv.x < 1.0 && iuv.y > 0.0 && iuv.y < 1.0 && texture(depth_tex, iuv).r <= 0.000001) {
			refl = textureLod(screen_tex, iuv, 2.0).rgb;
		}
	}
	// A thick tongue of water: mostly its own body colour, with a little of what is behind showing through.
	vec3 body = mix(behind * glass_tint, water_color * 4.5 * (0.5 + 0.5 * sky_color), 0.5 * runup * (0.4 + 0.6 * thick));
	vec3 glass = body * (1.0 - fres) + mix(water_color * 2.0, refl, 0.75) * fres;
	float glassy = 1.0 - white;
	// Foam is lumpy: shadowed pockets between bright billows; lit from the sky as well (it glows in a shaded gorge).
	float lump = mix(0.55, 1.1, clamp(billow * 0.5 + grain * 0.25 + core * 0.25 + clumpy * 0.3 - 0.12, 0.0, 1.0));
	ALBEDO = mix(water_color * 0.4, foam_color * lump, white);
	EMISSION = glass * glassy + foam_color * sky_color * 0.18 * white * lump;
	// Thin water is translucent: alpha follows the thickness of the column (the white core is opaque).
	ALPHA = a * mix(mix(0.45, 0.95, clamp(thick * 1.2, 0.0, 1.0)), 0.97, white);
	ROUGHNESS = mix(0.06, 0.7, white);
	SPECULAR = mix(0.5, 0.2, white);
	// Light through the thin aerated water.
	BACKLIGHT = mix(water_color * 2.0, foam_color, white) * 0.5;
}
