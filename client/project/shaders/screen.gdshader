// Screen rendering shader for Immersive-2 VR Client.
// Displays the streamed desktop content on a flat panel in VR.

shader_type spatial;
render_mode unshaded, cull_disabled;

// The streamed screen content texture (RGBA / MJPEG path).
// Mipmaps + anisotropic filtering greatly reduce the shimmering/aliasing of
// fine desktop text when the panel is minified or viewed at an angle.
uniform sampler2D screen_texture : source_color, filter_linear_mipmap_anisotropic;

// Same texture, point-sampled, for the NV12 (hardware decoder) path. NV12 is
// a tightly packed L8 image whose Y/U/V bytes are unpacked manually below, so
// it MUST be read with exact texels: linear filtering blends the packed planes
// together (wrong colors) and, because the NV12 texture has no mipmaps, a
// mipmap filter leaves it "incomplete" and returns black on GLES/Compatibility.
// screen_panel.gd binds this to the same ImageTexture as screen_texture.
uniform sampler2D screen_texture_nv12 : source_color, filter_nearest;

// Screen border color.
uniform vec4 border_color : source_color = vec4(0.2, 0.2, 0.3, 1.0);

// Border width in UV space.
uniform float border_width : hint_range(0.0, 0.05) = 0.005;

// Screen brightness adjustment.
uniform float brightness : hint_range(0.0, 2.0) = 1.0;

// Screen contrast adjustment.
uniform float contrast : hint_range(0.0, 2.0) = 1.0;

// Slight curvature for immersion (0 = flat, 1 = max curve).
uniform float curvature : hint_range(0.0, 0.5) = 0.0;

// 1 for NV12 YUV format (from MediaCodec), 0 for RGBA/MJPEG
uniform int is_yuv : hint_range(0, 1) = 0;

// Eye-tracked foveated rendering controls.
uniform int foveation_enabled : hint_range(0, 1) = 0;
uniform vec2 gaze_uv = vec2(0.5, 0.5);
uniform float foveation_strength : hint_range(0.0, 1.0) = 0.0;
uniform float foveation_inner_radius : hint_range(0.05, 0.5) = 0.18;
uniform float foveation_outer_radius : hint_range(0.2, 1.0) = 0.72;

vec4 sample_screen_color(vec2 sample_uv) {
    if (is_yuv == 1) {
        // NV12 packed into an L8 texture of size (w, h*1.5):
        //   rows [0, h)      → Y plane
        //   rows [h, 1.5h)   → interleaved UV pairs (u at even col, v at odd)
        vec2 tex_size = vec2(textureSize(screen_texture_nv12, 0));
        float texel_x = 1.0 / tex_size.x;

        // Y: top 2/3 of the texture
        float y = texture(screen_texture_nv12, vec2(sample_uv.x, sample_uv.y * (2.0 / 3.0))).r;

        // UV: bottom 1/3. One (u,v) byte pair covers 2 luma columns, so the
        // pair for luma column px starts at texel floor(px/2)*2.
        float px = sample_uv.x * tex_size.x;
        float pair_x = (floor(px * 0.5) * 2.0 + 0.5) * texel_x;
        float uv_y = (2.0 / 3.0) + (sample_uv.y / 3.0);
        float u = texture(screen_texture_nv12, vec2(pair_x, uv_y)).r - 0.5;
        float v = texture(screen_texture_nv12, vec2(pair_x + texel_x, uv_y)).r - 0.5;

        // BT.601 limited range
        y = 1.1643835 * (y - 0.0625);
        return vec4(
            y + 1.5960267 * v,
            y - 0.3917622 * u - 0.8129680 * v,
            y + 2.0172321 * u,
            1.0
        );
    }

    return texture(screen_texture, sample_uv);
}

void fragment() {
    vec2 uv = UV;

    // Apply optional screen curvature
    if (curvature > 0.0) {
        vec2 centered = uv - 0.5;
        float dist = dot(centered, centered);
        uv = uv + centered * dist * curvature;
    }

    // Check if we're in the border region.
    bool is_border = uv.x < border_width || uv.x > 1.0 - border_width ||
        uv.y < border_width || uv.y > 1.0 - border_width;

    if (is_border) {
        ALBEDO = border_color.rgb;
        ALPHA = border_color.a;
    } else {
        // Remap UV to exclude border
        vec2 inner_uv = (uv - border_width) / (1.0 - 2.0 * border_width);
        inner_uv = clamp(inner_uv, 0.0, 1.0);

        vec4 color = sample_screen_color(inner_uv);

        if (foveation_enabled == 1 && foveation_strength > 0.001) {
            float dist_to_gaze = distance(inner_uv, clamp(gaze_uv, vec2(0.0), vec2(1.0)));
            float peripheral = smoothstep(foveation_inner_radius, foveation_outer_radius, dist_to_gaze);
            float foveation_mix = clamp(peripheral * foveation_strength, 0.0, 1.0);

            // Periphery uses increasingly coarse UV buckets to emulate lower detail.
            vec2 tex_size = vec2(textureSize(screen_texture, 0));
            float bucket_px = mix(1.0, 8.0, foveation_mix);
            vec2 bucket_uv = (floor(inner_uv * tex_size / bucket_px) * bucket_px + (bucket_px * 0.5)) / tex_size;
            bucket_uv = clamp(bucket_uv, vec2(0.0), vec2(1.0));

            vec4 coarse_color = sample_screen_color(bucket_uv);
            float coarse_luma = dot(coarse_color.rgb, vec3(0.299, 0.587, 0.114));
            coarse_color.rgb = mix(coarse_color.rgb, vec3(coarse_luma), 0.15 * foveation_mix);
            color = mix(color, coarse_color, foveation_mix);
        }

        // Apply brightness and contrast
        color.rgb = ((color.rgb - 0.5) * contrast + 0.5) * brightness;
        color.rgb = clamp(color.rgb, 0.0, 1.0);

        ALBEDO = color.rgb;
        ALPHA = 1.0;
    }
}
