// External-texture screen shader for the Immersive-2 VR client (Android/GLES3).
//
// Samples the hardware decoder's output directly from a GL_TEXTURE_EXTERNAL_OES
// texture (Godot ExternalTexture, fed by MediaCodec via a SurfaceTexture). The
// external sampler returns already-converted RGB, so there is no YUV unpacking.
// This shader is only ever instantiated on Android when a decoder is active, so
// the samplerExternalOES type never reaches a desktop GLES3 compile.

#extension GL_OES_EGL_image_external : require

shader_type spatial;
render_mode unshaded, cull_disabled;

// Decoded desktop frame (external OES texture).
uniform samplerExternalOES screen_external : source_color, filter_linear;

// SurfaceTexture transform (handles the GL vertical flip + any crop scale).
uniform mat4 tex_transform;

// Stream resolution in pixels (samplerExternalOES has no textureSize()).
uniform vec2 tex_size = vec2(1920.0, 1080.0);

uniform vec4 border_color : source_color = vec4(0.2, 0.2, 0.3, 1.0);
uniform float border_width : hint_range(0.0, 0.05) = 0.005;
uniform float brightness : hint_range(0.0, 2.0) = 1.0;
uniform float contrast : hint_range(0.0, 2.0) = 1.0;
uniform float curvature : hint_range(0.0, 0.5) = 0.0;

// Eye-tracked foveated rendering controls.
uniform int foveation_enabled : hint_range(0, 1) = 0;
uniform vec2 gaze_uv = vec2(0.5, 0.5);
uniform float foveation_strength : hint_range(0.0, 1.0) = 0.0;
uniform float foveation_inner_radius : hint_range(0.05, 0.5) = 0.18;
uniform float foveation_outer_radius : hint_range(0.2, 1.0) = 0.72;

vec4 sample_screen_color(vec2 sample_uv) {
	vec2 tc = (tex_transform * vec4(sample_uv, 0.0, 1.0)).xy;
	return texture(screen_external, tc);
}

void fragment() {
	vec2 uv = UV;

	if (curvature > 0.0) {
		vec2 centered = uv - 0.5;
		float dist = dot(centered, centered);
		uv = uv + centered * dist * curvature;
	}

	bool is_border = uv.x < border_width || uv.x > 1.0 - border_width ||
		uv.y < border_width || uv.y > 1.0 - border_width;

	if (is_border) {
		ALBEDO = border_color.rgb;
		ALPHA = border_color.a;
	} else {
		vec2 inner_uv = (uv - border_width) / (1.0 - 2.0 * border_width);
		inner_uv = clamp(inner_uv, 0.0, 1.0);

		vec4 color = sample_screen_color(inner_uv);

		if (foveation_enabled == 1 && foveation_strength > 0.001) {
			float dist_to_gaze = distance(inner_uv, clamp(gaze_uv, vec2(0.0), vec2(1.0)));
			float peripheral = smoothstep(foveation_inner_radius, foveation_outer_radius, dist_to_gaze);
			float foveation_mix = clamp(peripheral * foveation_strength, 0.0, 1.0);

			float bucket_px = mix(1.0, 8.0, foveation_mix);
			vec2 bucket_uv = (floor(inner_uv * tex_size / bucket_px) * bucket_px + (bucket_px * 0.5)) / tex_size;
			bucket_uv = clamp(bucket_uv, vec2(0.0), vec2(1.0));

			vec4 coarse_color = sample_screen_color(bucket_uv);
			float coarse_luma = dot(coarse_color.rgb, vec3(0.299, 0.587, 0.114));
			coarse_color.rgb = mix(coarse_color.rgb, vec3(coarse_luma), 0.15 * foveation_mix);
			color = mix(color, coarse_color, foveation_mix);
		}

		color.rgb = ((color.rgb - 0.5) * contrast + 0.5) * brightness;
		color.rgb = clamp(color.rgb, 0.0, 1.0);

		ALBEDO = color.rgb;
		ALPHA = 1.0;
	}
}
