// The map's height fog over the view (fog.gd): a full-screen quad that rebuilds each pixel's world height from the
// depth buffer, so it has its own colour (Godot's fog has one colour for distance and height). As the game's:
// none at the top height, the colour at "strength" from the bottom height down.
shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 colour : source_color = vec3(0.6, 0.65, 0.7);
uniform float strength = 0.5;
uniform float top = 0.0;      // m
uniform float bottom = -10.0; // m

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	float t = clamp((top - world.y) / max(top - bottom, 0.01), 0.0, 1.0);
	ALBEDO = colour;
	ALPHA = t * strength;
}
