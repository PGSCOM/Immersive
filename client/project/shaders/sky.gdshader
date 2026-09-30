// Sky for the VR workspace: a vertical gradient with a warm band of light
// along the horizon, an optional low sun and a sparse field of fixed stars.
// Static on purpose (no TIME), so Godot never re-bakes the radiance map.

shader_type sky;

uniform vec3 zenith_color : source_color = vec3(0.02, 0.025, 0.025);
uniform vec3 horizon_color : source_color = vec3(0.10, 0.08, 0.065);
uniform vec3 ground_color : source_color = vec3(0.015, 0.015, 0.014);
// Warm light hugging the horizon.
uniform vec3 glow_color : source_color = vec3(0.45, 0.22, 0.12);
uniform float glow_strength = 0.35;
uniform float glow_height = 14.0;  // larger = thinner band
uniform vec3 sun_direction = vec3(0.35, 0.06, -0.93);
uniform vec3 sun_color : source_color = vec3(1.0, 0.72, 0.5);
uniform float sun_strength = 0.0;
uniform float star_density = 0.012;  // share of sky cells holding a star
uniform float star_brightness = 0.55;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col;
	if (h >= 0.0) {
		col = mix(horizon_color, zenith_color, pow(h, 0.42));
		col += glow_color * glow_strength * exp(-h * glow_height);
		// Sun: a soft disc plus a wide halo, only when it is switched on.
		float sd = max(dot(d, normalize(sun_direction)), 0.0);
		col += sun_color * sun_strength * (smoothstep(0.9993, 0.9997, sd) * 2.0 + pow(sd, 18.0) * 0.35);
		// Stars: one candidate per cell of a direction grid, fading out near
		// the horizon haze.
		vec3 p = d * 170.0;
		vec3 cell = floor(p);
		float r = hash13(cell);
		if (r > 1.0 - star_density) {
			vec3 centre = cell + 0.5 + (vec3(hash13(cell + 7.1), hash13(cell + 3.7), hash13(cell + 1.3)) - 0.5) * 0.6;
			float dist = length(p - centre);
			float star = smoothstep(0.16, 0.0, dist) * (0.4 + 0.6 * hash13(cell + 11.0));
			col += vec3(1.0, 0.94, 0.86) * star * star_brightness * smoothstep(0.04, 0.35, h);
		}
	} else {
		// Below the horizon the floor takes over within a few degrees; keep
		// the horizon colour (and a trace of the glow) until then so the two
		// meet without a seam.
		col = mix(horizon_color, ground_color, smoothstep(0.0, 0.3, -h));
		col += glow_color * glow_strength * exp(h * glow_height * 3.0) * 0.5;
	}
	// Dark gradients band in 8 bits: dither by less than one step.
	col += (hash13(vec3(FRAGCOORD.xy, 1.7)) - 0.5) / 255.0;
	COLOR = col;
}
