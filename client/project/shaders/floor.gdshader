// Floor under the user: a dark disc that is a little lighter where you stand
// and melts into the horizon colour towards its rim, so it never ends in a
// visible edge.

shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, blend_mix;

uniform vec3 floor_color : source_color = vec3(0.03, 0.03, 0.028);
uniform vec3 pool_color : source_color = vec3(0.09, 0.085, 0.075);
uniform vec3 horizon_color : source_color = vec3(0.10, 0.08, 0.065);

void fragment() {
	float r = length(UV - 0.5) * 2.0;           // 0 centre, 1 rim
	// The disc is 400 m wide: its rim sits a fraction of a degree under the
	// horizon, where it hands over to the sky's own below-horizon colour.
	vec3 col = mix(floor_color, horizon_color, smoothstep(0.01, 0.6, r));
	col += pool_color * exp(-r * r * 9000.0);    // light pool at your feet
	// Dither the dark fall-off so it does not band into rings.
	vec2 f = FRAGCOORD.xy;
	col += (fract(sin(dot(f, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) / 255.0;
	ALBEDO = col;
	ALPHA = 1.0 - smoothstep(0.6, 1.0, r);
}
