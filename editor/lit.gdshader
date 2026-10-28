// Stage preview under the Lighting window's live sun / ambient. The map's baked light (vertex colour, see
// baked.gdshader) stands in for occlusion: where the bake is dark (interiors, under cover) the flat ambient is
// cut, so insides don't glow. The sun still shades from its real-time shadows. Unbaked meshes (white) are unchanged.
shader_type spatial;
render_mode cull_disabled, specular_disabled;

uniform sampler2D albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_texture = false;
uniform float bake_scale = 2.0;

void fragment() {
	ALBEDO = has_texture ? texture(albedo, UV).rgb : vec3(0.7);
	ROUGHNESS = 1.0;
	float bake = pow(max(COLOR.r, max(COLOR.g, COLOR.b)) * bake_scale, 2.2);   // gamma-space light, as baked.gdshader
	AO = clamp(bake, 0.05, 1.0);
	AO_LIGHT_AFFECT = 0.0;   // ambient only
}
