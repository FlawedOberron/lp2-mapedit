// Stage preview with the map's baked light: colour map x vertex colour (the LP1 lightmap baked by
// lp2stage.py), like the game's static stage. bake_scale brightens the stored light to a display range.
// The baked light is emission; placed point / spot lights add on top (the sun and ambient are already in the bake).
shader_type spatial;
render_mode cull_disabled, ambient_light_disabled, specular_disabled;

uniform sampler2D albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_texture = false;
uniform float bake_scale = 4.0;

void fragment() {
	vec3 tex = has_texture ? texture(albedo, UV).rgb : vec3(0.7);
	ALBEDO = tex;
	EMISSION = tex * COLOR.rgb * bake_scale;
	ROUGHNESS = 1.0;
}

void light() {
	if (!LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
	}
}
