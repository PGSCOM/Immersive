// Screen rendering shader for Immersive-2 VR Client.
// Displays the streamed desktop content on a flat panel in VR.

shader_type spatial;
render_mode unshaded, cull_disabled;

// The streamed screen content texture.
uniform sampler2D screen_texture : source_color, filter_linear;

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

void fragment() {
    vec2 uv = UV;

    // Apply optional screen curvature
    if (curvature > 0.0) {
        vec2 centered = uv - 0.5;
        float dist = dot(centered, centered);
        uv = uv + centered * dist * curvature;
    }

    // Check if we're in the border region
    if (uv.x < border_width || uv.x > 1.0 - border_width ||
        uv.y < border_width || uv.y > 1.0 - border_width) {
        ALBEDO = border_color.rgb;
        ALPHA = border_color.a;
        return;
    }

    // Remap UV to exclude border
    vec2 inner_uv = (uv - border_width) / (1.0 - 2.0 * border_width);
    inner_uv = clamp(inner_uv, 0.0, 1.0);

    vec4 color;
    if (is_yuv == 1) {
        // NV12 decoding in L8 texture
        // Y data is in the top 2/3 of the texture
        float y = texture(screen_texture, vec2(inner_uv.x, inner_uv.y * (2.0 / 3.0))).r;
        
        // UV data is interleaved in the bottom 1/3
        // Calculate U and V offsets
        vec2 uv_pixel = vec2(inner_uv.x, (2.0 / 3.0) + (inner_uv.y / 3.0));
        
        // NV12 format has U and V alternating (U is even px, V is odd px)
        // We can approximate by taking nearest or just standard UV sample 
        // if the hardware filter is linear. Let's do simple conversion:
        float u = texture(screen_texture, uv_pixel).r - 0.5;
        // Since V is the next byte, we shift our X coordinate by 1 pixel assuming NV12.
        // Actually, just approximating with linear filter works decently, but we offset X slightly.
        float v = texture(screen_texture, uv_pixel + vec2(0.001, 0.0)).r - 0.5;
        
        y = 1.1643835 * (y - 0.0625);
        color.r = y + 1.5960267 * v;
        color.g = y - 0.3917622 * u - 0.8129680 * v;
        color.b = y + 2.0172321 * u;
        color.a = 1.0;
    } else {
        // Sample the normal screen texture
        color = texture(screen_texture, inner_uv);
    }

    // Apply brightness and contrast
    color.rgb = ((color.rgb - 0.5) * contrast + 0.5) * brightness;
    color.rgb = clamp(color.rgb, 0.0, 1.0);

    ALBEDO = color.rgb;
    ALPHA = 1.0;
}
