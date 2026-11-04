shader_type spatial;
render_mode unshaded, cull_back;

// Iridescent toy: accent body, rainbow fresnel rim that shifts with view angle and time,
// and a glow pulse (`energy`) when you poke, grab or spin it.
uniform vec3 accent : source_color = vec3(0.3, 0.64, 1.0);
uniform float energy = 0.0;

vec3 hue(float h) {
	return clamp(abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

void fragment() {
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 2.5);
	vec3 irid = hue(ndv * 0.7 + TIME * 0.06 + energy * 0.25);
	vec3 L = normalize(vec3(0.35, 0.8, 0.45)); // fixed key light in view space: reads well anywhere
	float diff = 0.35 + 0.65 * max(dot(NORMAL, L), 0.0);
	float spec = pow(max(dot(reflect(-L, NORMAL), VIEW), 0.0), 48.0);
	vec3 col = accent * diff * 0.55 + irid * fres * 1.1 + vec3(spec) * 0.9;
	col += mix(accent, irid, 0.5) * energy * 0.9; // pulse (bloom picks this up)
	ALBEDO = col;
}
