// Stage preview under the Lighting window's live sun / ambient. The map's baked light (vertex colour, see
// baked.gdshader) stands in for occlusion: where the bake is dark (interiors, under cover) the flat ambient is
// cut, so insides don't glow. The sun still shades from its real-time shadows. Unbaked meshes (white) are unchanged.
shader_type spatial;
render_mode cull_disabled, specular_disabled;

uniform bool cull_back = false;   // back faces dropped (the preview's triangles are wound to their normals)
uniform sampler2D albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_texture = false;
uniform bool cutout = false;   // alpha-tested (the game cuts out texels under half alpha)
uniform float bake_scale = 2.0;

void fragment() {
	if (cull_back && !FRONT_FACING) {
		discard;
	}
	if (cutout && has_texture && texture(albedo, UV).a < 0.5) {
		discard;
	}
	ALBEDO = has_texture ? texture(albedo, UV).rgb : vec3(0.7);
	ROUGHNESS = 1.0;
	float bake = pow(max(COLOR.r, max(COLOR.g, COLOR.b)) * bake_scale, 2.2);   // gamma-space light, as baked.gdshader
	AO = clamp(bake, 0.05, 1.0);
	AO_LIGHT_AFFECT = 0.0;   // ambient only
}
