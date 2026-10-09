// The bare hands as a silhouette (hand_input.gd): one warm tone from the
// menu's palette, lighter where it faces up and along its outline, with an
// anti-aliased edge, fading out towards the wrist where the model ends.
//
// Two passes keep it one clean layer in any pose: `fringe` off draws the
// solid inside and writes depth (a finger in front of the palm hides it),
// then `fringe` on blends only the soft outline over what is there.
// Premultiplied alpha, as the compositor reads Godot's layer: unlike mix it
// writes alpha with or without passthrough, so the hand also covers a screen
// the headset draws behind a hole punched to alpha 0 (Sharper text).
// hand_input.gd makes a copy with `stencil_mode read, compare_equal, 1` for
// passthrough: drawn only where a screen or panel marked the stencil
// (hand_mask.gdshader).
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_back, depth_draw_always, shadows_disabled;

uniform bool fringe = false;
// UiTheme.INK_2 lit from above, a deeper tone beneath, UiTheme.INK on the outline.
uniform vec3 lit : source_color = vec3(0.706, 0.675, 0.624);
uniform vec3 shade : source_color = vec3(0.44, 0.415, 0.38);
uniform vec3 rim : source_color = vec3(0.925, 0.902, 0.863);
// Palm space (the skeleton sits on the palm joint, +Y towards the fingers):
// the model ends in a rounded cap up to 1.3 cm above the wrist joint, wrist_y
// (set per hand): clear up to there, solid from 4 cm.
instance uniform float wrist_y = -0.06;

varying float along;

void vertex() {
	along = VERTEX.y;
}

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);  // 1 towards the eye, 0 on the outline
	float a = smoothstep(0.0, 0.3, facing) * smoothstep(wrist_y + 0.013, wrist_y + 0.04, along);
	if (fringe == (a > 0.99)) {
		discard;
	}
	float up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y * 0.5 + 0.5;
	a = fringe ? a : 1.0;
	ALBEDO = mix(rim, mix(shade, lit, up), smoothstep(0.25, 0.6, facing)) * a;
	ALPHA = a;
}
