// Marks where a screen or panel is in the stencil buffer and draws nothing:
// in passthrough the bare hands (hand.gdshader) show only there, where the
// real hand is hidden. main.gd puts it on each as material_overlay, drawn
// before the hands (render_priority -2). No depth test: a screen drawn by the
// headset (Sharper text) only has Godot's hole punch, not quite the same
// surface, and whatever covers a screen is a panel marking too. The stencil
// lives in Godot's own
// depth buffer: keep xr/openxr/submit_depth_buffer off (an OpenXR depth
// swapchain has none, and the hands would show everywhere).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled;
stencil_mode write, compare_always, 1;

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
