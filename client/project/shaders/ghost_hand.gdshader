// Bare hands: a pale, see-through skin that brightens towards its outline,
// where the surface turns away from the eyes, and fades out past the wrist
// (the model's forearm stub). Drawn after a depth-only pass of the same mesh
// (hand_input.gd), so only the front surface shows and crossing fingers do
// not stack up brighter.

shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, blend_mix;

uniform vec3 body_color : source_color = vec3(0.82, 0.84, 0.90);
uniform vec3 rim_color : source_color = vec3(0.97, 0.97, 1.0);
uniform float body_alpha = 0.2;
uniform float rim_alpha = 0.8;
uniform float rim_power = 2.5;
// World space, set every frame: the wrist joint and the way to the palm.
uniform vec3 wrist = vec3(0.0);
uniform vec3 forward = vec3(0.0, 0.0, -1.0);

void fragment() {
	// abs(): the model's normals do not all face out.
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), rim_power);
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float fade = smoothstep(-0.035, 0.015, dot(world - wrist, forward));
	ALBEDO = mix(body_color, rim_color, rim);
	ALPHA = mix(body_alpha, rim_alpha, rim) * fade;
}
