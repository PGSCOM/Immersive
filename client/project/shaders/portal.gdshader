// Passthrough portal shader for Immersive-2.
//
// A portal is a "window" cut into the virtual scene that reveals the real world
// through the headset's passthrough cameras. The technique: the portal surface
// writes *transparent* pixels (ALPHA = 0) while still writing depth, so it
// occludes the virtual content behind it and lets the alpha-blended passthrough
// compositor show through. For circular portals, fragments outside the disc are
// discarded so the surrounding virtual scene stays visible.
//
// Requires the OpenXR environment blend mode to be ALPHA_BLEND and the viewport
// to be transparent (see main.gd::_apply_passthrough_settings). When passthrough
// is not active the portal simply renders an empty (transparent) hole.

shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, unshaded, shadows_disabled;

// 1 = circular portal (discard outside the inscribed disc), 0 = rectangular.
uniform int is_circle : hint_range(0, 1) = 0;

// Thin edge highlight so the portal rim is visible against the real world.
uniform vec4 edge_color : source_color = vec4(0.35, 0.75, 1.0, 0.9);
uniform float edge_width : hint_range(0.0, 0.2) = 0.04;

void fragment() {
	vec2 centered = UV - vec2(0.5);

	if (is_circle == 1) {
		// Distance from centre in UV space; the inscribed disc has radius 0.5.
		float r = length(centered) * 2.0;
		if (r > 1.0) {
			discard;  // outside the circle → keep the virtual scene
		}
		if (r > 1.0 - edge_width * 2.0) {
			ALBEDO = edge_color.rgb;
			ALPHA = edge_color.a;
		} else {
			ALPHA = 0.0;  // inside → reveal passthrough
		}
	} else {
		// Rectangular portal: highlight a thin border, transparent interior.
		float bx = step(0.5 - edge_width, abs(centered.x));
		float by = step(0.5 - edge_width, abs(centered.y));
		if (bx > 0.5 || by > 0.5) {
			ALBEDO = edge_color.rgb;
			ALPHA = edge_color.a;
		} else {
			ALPHA = 0.0;
		}
	}
}
