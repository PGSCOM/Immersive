// External-texture screen shader for the Immersive-2 VR client (Android/GLES3).
//
// Samples the hardware decoder's output directly from a GL_TEXTURE_EXTERNAL_OES
// texture (Godot ExternalTexture, fed by MediaCodec via a SurfaceTexture). The
// external sampler returns already-converted RGB, so there is no YUV unpacking.
// This shader is only ever instantiated on Android when a decoder is active, so
// the samplerExternalOES type never reaches a desktop GLES3 compile.

shader_type spatial;
render_mode unshaded, cull_disabled;

// Decoded desktop frame (external OES texture).
uniform samplerExternalOES screen_external : source_color, filter_linear;

// SurfaceTexture transform (handles the GL vertical flip + any crop scale).
uniform mat4 tex_transform;

// Orientation compensation for how the MediaCodec→SurfaceTexture→OES frame is
// laid out in the external texture vs. Godot's top-left UV convention. On the
// Pico the decoded frame is vertically mirrored, so flip_y is on by default and
// flip_x is off. This is purely a TEXTURE-sampling concern — it is NOT mirrored
// into the controller→mouse mapping (screen_panel.gd::uv_to_pixel), which is a
// separate geometric mapping that assumes an upright display. 1 = flip that
// axis, 0 = leave it. Tune until the panel reads upright and un-mirrored.
uniform int flip_x : hint_range(0, 1) = 0;
uniform int flip_y : hint_range(0, 1) = 1;

// Stream resolution in pixels (samplerExternalOES has no textureSize()).
uniform vec2 tex_size = vec2(1920.0, 1080.0);

uniform float brightness : hint_range(0.0, 2.0) = 1.0;
uniform float contrast : hint_range(0.0, 2.0) = 1.0;

// Rounded corners, in metres: the mesh is a flat or curved screen of this size.
uniform vec2 panel_size_m = vec2(1.6, 0.9);
uniform float corner_radius_m = 0.014;

vec4 sample_screen_color(vec2 sample_uv) {
	// Apply the orientation correction BEFORE the SurfaceTexture transform.
	// Pre-rotating the sample UV by 180° (flip both axes) exactly cancels a
	// 180°-rotated display regardless of what tex_transform contains, because
	// the rotation is its own inverse.
	vec2 oriented = vec2(
		flip_x == 1 ? 1.0 - sample_uv.x : sample_uv.x,
		flip_y == 1 ? 1.0 - sample_uv.y : sample_uv.y);
	vec2 tc = (tex_transform * vec4(oriented, 0.0, 1.0)).xy;
	return texture(screen_external, tc);
}

void fragment() {
	// Rounded corners: drop fragments outside a rounded rectangle.
	vec2 half_size = panel_size_m * 0.5;
	vec2 q = abs((UV - 0.5) * panel_size_m) - (half_size - corner_radius_m);
	if (length(max(q, 0.0)) > corner_radius_m) {
		discard;
	}

	vec2 inner_uv = UV;
	vec4 color = sample_screen_color(inner_uv);

	color.rgb = ((color.rgb - 0.5) * contrast + 0.5) * brightness;
	color.rgb = clamp(color.rgb, 0.0, 1.0);

	// No ALPHA write: that would make the screen a transparent, depth-sorted
	// object (slower, and drawn over things in front of it).
	ALBEDO = color.rgb;
}
