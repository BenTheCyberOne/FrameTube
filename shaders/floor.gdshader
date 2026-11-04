shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, blend_mix, depth_draw_opaque;

uniform vec3 base : source_color = vec3(0.012, 0.014, 0.022);
uniform vec3 line_color : source_color = vec3(0.3, 0.64, 1.0);
uniform float line_strength = 0.3;
uniform float grid_size = 1.0;
uniform float scroll = 0.0; // grid scroll speed towards you (synthwave)
uniform vec3 horizon : source_color = vec3(0.02, 0.03, 0.06); // fade-out colour, matches the sky
uniform float fade_dist = 20.0;
// Bias lighting: a pool of the video's colour on the floor in front of the screen.
uniform vec3 glow : source_color = vec3(0.0);
uniform float glow_strength = 0.0;
uniform vec3 screen_pos = vec3(0.0, 1.6, -4.0);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz / grid_size;
	p.y += TIME * scroll;
	vec2 w = fwidth(p);
	vec2 g = abs(fract(p - 0.5) - 0.5) / max(w, vec2(1e-4)); // anti-aliased grid lines
	float line = 1.0 - min(min(g.x, g.y), 1.0);
	line *= 1.0 - smoothstep(0.15, 0.6, max(w.x, w.y)); // lines dissolve where cells get tiny

	float dist = length(wpos.xz - CAMERA_POSITION_WORLD.xz);
	float fade = smoothstep(fade_dist, fade_dist * 0.25, dist);
	float pool = exp(-length((wpos.xz - screen_pos.xz) * vec2(0.35, 0.5)));

	vec3 col = base + line_color * line * line_strength + glow * pool * glow_strength;
	// Fade through the horizon colour into transparency, so the floor melts into the sky (no hard edge).
	ALBEDO = mix(horizon, col, smoothstep(0.0, 0.6, fade));
	ALPHA = smoothstep(0.0, 0.35, fade);
}
