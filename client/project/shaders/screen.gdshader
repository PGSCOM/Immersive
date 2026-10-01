// Screen rendering shader for Immersive-2 VR Client.
// Displays the streamed desktop content on a (flat or curved) panel in VR.

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



// Screen brightness adjustment.
uniform float brightness : hint_range(0.0, 2.0) = 1.0;

// Screen contrast adjustment.
uniform float contrast : hint_range(0.0, 2.0) = 1.0;

// Rounded corners, in metres: the mesh is a flat or curved screen of this size.
uniform vec2 panel_size_m = vec2(1.6, 0.9);
uniform float corner_radius_m = 0.014;


// 1 for NV12 YUV format (from MediaCodec), 0 for RGBA/MJPEG
uniform int is_yuv : hint_range(0, 1) = 0;

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
