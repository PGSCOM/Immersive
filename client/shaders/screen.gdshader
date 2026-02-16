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

    // Sample the screen texture
    vec4 color = texture(screen_texture, inner_uv);

    // Apply brightness and contrast
    color.rgb = ((color.rgb - 0.5) * contrast + 0.5) * brightness;
    color.rgb = clamp(color.rgb, 0.0, 1.0);

    ALBEDO = color.rgb;
    ALPHA = 1.0;
}
