shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled, fog_disabled;

// Waterfall droplets (GPUParticles3D draw pass, particle_flag_align_y on): each quad is a streak stretched along the
// particle's velocity (its Y axis) and turned around that axis to face the camera. Lit from the sky colour plus a
// sun glint when the drop is between the camera and the sun (drops light up against the light).

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 light_color = vec3(0.8, 0.85, 0.9);
uniform vec3 sun_dir = vec3(0.3, 0.8, 0.2);
uniform float soft_distance = 0.4;
uniform float near_fade = 1.5;

varying vec3 to_cam_w;

void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	vec3 y = MODEL_MATRIX[1].xyz;
	float sy = max(length(y), 1e-5);
	y /= sy;
	vec3 tc = normalize(CAMERA_POSITION_WORLD - pos);
	vec3 x = cross(y, tc);
	float lx = length(x);
	x = lx > 1e-4 ? x / lx : normalize(INV_VIEW_MATRIX[0].xyz);
	float sx = length(MODEL_MATRIX[0].xyz);
	vec3 z = cross(x, y);
	mat4 m = mat4(vec4(x * sx, 0.0), vec4(y * sy, 0.0), vec4(z, 0.0), vec4(pos, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * m;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	to_cam_w = tc;
}

void fragment() {
	// A streak: bright core, soft sides, tapering towards the tail.
	float d = abs(UV.x * 2.0 - 1.0);
	float along = UV.y;
	float a = (1.0 - d * d) * smoothstep(0.0, 0.2, along) * (1.0 - smoothstep(0.35, 1.0, along) * 0.8);
	a *= COLOR.a;
	float dz = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, dz, 1.0);
	sp.xyz /= sp.w;
	a *= clamp((VERTEX.z - sp.z) / soft_distance, 0.0, 1.0);
	a *= smoothstep(0.3, near_fade, -VERTEX.z);
	float glint = pow(max(dot(-to_cam_w, normalize(sun_dir)), 0.0), 12.0) * 3.0;
	ALBEDO = light_color * (1.0 + glint) * (0.85 + 0.3 * (1.0 - d));
	ALPHA = clamp(a * 0.75, 0.0, 1.0);
}
