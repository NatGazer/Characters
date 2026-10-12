shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert_wrap, specular_disabled, vertex_lighting;

// Waterfall mist / spray puffs (GPUParticles3D draw pass). Camera-facing billboards from a 2x2 atlas, lit per vertex
// plus the sky light a cloud of droplets scatters (`ambient_light`, so it stays white in a shaded gorge), faded where they touch geometry, where they dip towards the pool surface (which is
// transparent and not in the depth buffer, so a puff crossing it would otherwise show a hard line) and near the camera.

uniform sampler2D puff_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec4 albedo : source_color = vec4(0.84, 0.86, 0.88, 1.0);
uniform float floor_y = -100000.0; // world height of the water under the puffs
uniform float floor_fade = 1.5;    // metres above floor_y over which puffs fade in
uniform float soft_distance = 1.5;
uniform float near_fade = 4.0;
uniform vec3 ambient_light = vec3(0.0); // sky light the mist scatters (so it never turns into dark smoke)

varying float world_y;

void vertex() {
	// Billboard (particles): face the camera, keep the particle's scale and spin (INSTANCE_CUSTOM.x).
	mat4 m = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	float c = cos(INSTANCE_CUSTOM.x);
	float s = sin(INSTANCE_CUSTOM.x);
	m = m * mat4(vec4(c, -s, 0.0, 0.0), vec4(s, c, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	m = m * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * m;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	world_y = (m * vec4(VERTEX, 1.0)).y;
	// 2x2 atlas: the frame comes from the particle's animation offset (INSTANCE_CUSTOM.z).
	float frame = clamp(floor(INSTANCE_CUSTOM.z * 4.0), 0.0, 3.0);
	UV = UV * 0.5 + vec2(mod(frame, 2.0), floor(frame / 2.0)) * 0.5;
}

void fragment() {
	vec4 t = texture(puff_tex, UV);
	ALBEDO = albedo.rgb * COLOR.rgb * t.rgb;
	// Soft, uneven edges (the atlas puff's alpha squared) so the spray never reads as round billboards.
	float a = albedo.a * COLOR.a * t.a * t.a;
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	sp.xyz /= sp.w;
	a *= clamp((VERTEX.z - sp.z) / soft_distance, 0.0, 1.0);
	a *= smoothstep(floor_y, floor_y + floor_fade, world_y);
	a *= smoothstep(0.5, near_fade, -VERTEX.z);
	ALPHA = a;
	// Spray lights up against the sun (forward scattering): a lit mist, not grey smoke.
	BACKLIGHT = albedo.rgb * 0.6;
	EMISSION = ALBEDO * ambient_light * 0.55;
}
