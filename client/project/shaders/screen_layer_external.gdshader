// Feeds a screen's OpenXR compositor layer when the picture comes from the
// hardware decoder: draws the MediaCodec ExternalTexture (OES) into the
// layer's SubViewport, with the same orientation fix and SurfaceTexture
// transform as screen_external.gdshader.

shader_type canvas_item;

uniform samplerExternalOES screen_external : source_color, filter_linear;
uniform mat4 tex_transform;
uniform int flip_x : hint_range(0, 1) = 0;
uniform int flip_y : hint_range(0, 1) = 1;

void fragment() {
	vec2 oriented = vec2(
		flip_x == 1 ? 1.0 - UV.x : UV.x,
		flip_y == 1 ? 1.0 - UV.y : UV.y);
	vec2 tc = (tex_transform * vec4(oriented, 0.0, 1.0)).xy;
	COLOR = vec4(texture(screen_external, tc).rgb, 1.0);
}
