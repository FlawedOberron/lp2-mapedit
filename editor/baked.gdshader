// Stage preview with the map's baked light. Two sources:
// - lp2bake.py's ray-traced bake (CUSTOM0-3, see geometry.gd load_bake): the light components (sun, sky, ground,
//   placed lights, glow; bounces included), combined here with the live settings (the uniforms, set by lighting.gd)
//   as lp2bake.py combine() does, so the Lighting window's sliders show without a re-bake;
// - else the vertex colour (the LP1 lightmap baked by lp2stage.py), or a bake made with older settings.
// The game multiplies colour map x light in gamma space, so the vertex colour is linearised (^2.2) before it scales
// the (linear) albedo: without that a bake of 0.3 showed as mid grey and interiors glowed. bake_scale brightens the
// stored light to that range. The baked light is emission; placed point / spot lights add on top (the sun and ambient
// are already in the bake).
shader_type spatial;
render_mode cull_disabled, ambient_light_disabled, specular_disabled;

uniform sampler2D albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_texture = false;
uniform float bake_scale = 4.0;
uniform bool use_bake = false;
uniform vec3 sun_k = vec3(1.0);      // sun colour x strength
uniform vec3 sky_k = vec3(0.15);     // sky colour x strength
uniform vec3 ground_k = vec3(0.1);   // ground colour x sky strength
uniform float lights_k = 1.0;
uniform float glow_k = 1.0;
uniform float gain = 0.48;           // lp2bake.py CALIBRATION x 2^exposure
uniform float min_light = 0.01;

varying vec4 c0;
varying vec4 c1;
varying vec4 c2;
varying vec4 c3;

void vertex() {
	c0 = CUSTOM0;
	c1 = CUSTOM1;
	c2 = CUSTOM2;
	c3 = CUSTOM3;
}

void fragment() {
	vec3 tex = has_texture ? texture(albedo, UV).rgb : vec3(0.7);
	vec3 light;
	if (use_bake && c0.a > 0.5) {
		vec3 l = c0.rgb * sun_k + c1.rgb * sky_k + c2.rgb * ground_k + c3.rgb * lights_k + vec3(c1.a, c2.a, c3.a) * glow_k;
		l *= gain;
		light = sqrt(l * l + min_light * min_light);   // the floor, softly
	} else {
		light = pow(COLOR.rgb * bake_scale, vec3(2.2));
	}
	ALBEDO = tex;
	EMISSION = tex * light;
	ROUGHNESS = 1.0;
}

void light() {
	if (!LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
	}
}
