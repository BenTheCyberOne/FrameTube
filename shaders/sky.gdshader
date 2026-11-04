shader_type sky;
render_mode disable_fog;

// 0 Midnight, 1 Starfield, 2 Synthwave, 3 Aurora, 4 Cinema (dark; room geometry does the work), 5 Daydream
uniform int style = 0;
uniform vec3 accent : source_color = vec3(0.3, 0.64, 1.0);
// Bias lighting: the video's average colour washes the sky in front of you, gently.
uniform vec3 glow : source_color = vec3(0.0);
uniform float glow_strength = 0.0;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
			mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
			mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += a * noise3(p);
		p = p * 2.03 + vec3(1.7, 9.2, 4.1);
		a *= 0.5;
	}
	return s;
}

// Point stars: one candidate per grid cell on a sphere of radius `scale`. ~2 px each in VR, twinkling.
float stars(vec3 d, float scale, float density) {
	vec3 p = d * scale;
	vec3 c = floor(p);
	float h = hash13(c);
	if (h > density) {
		return 0.0;
	}
	vec3 center = c + 0.5 + (vec3(hash13(c + 1.3), hash13(c + 2.7), hash13(c + 5.1)) - 0.5) * 0.5;
	float tw = 0.65 + 0.35 * sin(TIME * (0.4 + 2.0 * hash13(c + 9.1)) + h * 60.0);
	return smoothstep(0.3, 0.0, length(p - center)) * tw * (0.35 + 0.65 * hash13(c + 4.4));
}

void sky() {
	vec3 d = EYEDIR;
	float y = d.y;
	vec3 col;

	if (style == 0) { // Midnight
		col = mix(vec3(0.02, 0.03, 0.06), vec3(0.003, 0.004, 0.012), smoothstep(0.0, 0.6, y));
		col += accent * 0.07 * exp(-abs(y) * 9.0);
		col += vec3(0.8, 0.86, 1.0) * stars(d, 150.0, 0.035) * smoothstep(0.02, 0.3, y);
	} else if (style == 1) { // Starfield
		float band = exp(-pow(dot(d, normalize(vec3(0.35, 1.0, 0.25))) * 3.2, 2.0)); // milky-way band
		float n = fbm(d * 2.2 + vec3(0.0, 0.0, TIME * 0.004));
		float n2 = fbm(d * 5.0 - vec3(TIME * 0.003));
		vec3 neb = mix(accent, vec3(accent.b, accent.r * 0.5, accent.g) + vec3(0.25, 0.0, 0.2), n2);
		col = neb * pow(n, 3.5) * (0.12 + 0.6 * band);
		col += vec3(0.85, 0.75, 0.95) * band * 0.025;
		col += vec3(1.0) * stars(d, 150.0, 0.045 + band * 0.12);
		col += vec3(0.7, 0.8, 1.0) * 0.6 * stars(d, 310.0, 0.05 + band * 0.1);
	} else if (style == 2) { // Synthwave
		vec3 top = vec3(0.015, 0.0, 0.06);
		vec3 hor = vec3(0.55, 0.08, 0.42);
		col = mix(hor, top, smoothstep(-0.02, 0.5, y));
		// Sun above and behind the screen (the screen covers the low sky), striped in its lower part.
		vec3 sun_dir = normalize(vec3(0.0, 0.5, -1.0));
		float sd = acos(clamp(dot(d, sun_dir), -1.0, 1.0));
		float r = 0.3;
		float elev = asin(clamp(y, -1.0, 1.0));
		float sun_elev = asin(sun_dir.y);
		float v = clamp((elev - (sun_elev - r)) / (2.0 * r), 0.0, 1.0); // 0 = bottom of the sun, 1 = top
		float band = fract(v * 7.0 + TIME * 0.06);
		float gaps = step(0.6, v) + step(mix(0.55, 0.12, v / 0.6), band); // stripes thin out going up
		vec3 sun = mix(vec3(1.0, 0.12, 0.5), vec3(1.0, 0.82, 0.25), smoothstep(0.1, 0.95, v)) * 1.05;
		col = mix(col, sun, smoothstep(r, r - 0.006, sd) * clamp(gaps, 0.0, 1.0) * step(0.0, y));
		col += vec3(1.0, 0.3, 0.8) * 0.22 * exp(-max(sd - r, 0.0) * 4.0) * step(0.0, y);
		col += vec3(1.0) * stars(d, 150.0, 0.03) * smoothstep(0.3, 0.7, y);
		if (y < 0.0) {
			col = hor * 0.25;
		}
	} else if (style == 3) { // Aurora
		col = mix(vec3(0.008, 0.035, 0.05), vec3(0.0, 0.004, 0.014), smoothstep(0.0, 0.7, y));
		col += vec3(0.9) * stars(d, 150.0, 0.04) * smoothstep(0.02, 0.25, y);
		if (y > 0.02) {
			vec2 p = d.xz / (y + 0.12); // a flat "sky layer" above you
			float a = 0.0;
			for (int i = 0; i < 3; i++) {
				float fi = float(i);
				float wave = fbm(vec3(p * 0.45 + vec2(fi * 3.1, 0.0), TIME * 0.04 + fi * 2.0));
				float curtain = abs(p.y + 1.4 + fi * 0.9 + (wave - 0.5) * 2.4); // ahead of you (-Z)
				a += exp(-curtain * 5.0) * (0.55 + 0.45 * sin(p.x * 2.5 + TIME * 0.25 + fi * 2.0));
			}
			float fade = smoothstep(0.02, 0.18, y);
			col += mix(vec3(0.1, 1.0, 0.55), accent, 0.3) * a * 0.55 * fade;
			col += vec3(0.6, 0.2, 0.9) * a * 0.18 * smoothstep(0.25, 0.7, y);
		}
	} else if (style == 4) { // Cinema
		col = vec3(0.003);
	} else { // Daydream
		col = mix(vec3(0.98, 0.82, 0.86), vec3(0.42, 0.58, 0.95), smoothstep(-0.05, 0.6, y));
		if (y > 0.0) {
			vec2 p = d.xz / (y + 0.25); // cloud layer: large, soft shapes
			float c = fbm(vec3(p * 1.1 + vec2(TIME * 0.01, 0.0), 0.5));
			float cover = smoothstep(0.42, 0.62, c) * smoothstep(0.02, 0.25, y);
			vec3 cloud = mix(vec3(1.0, 0.93, 0.95), vec3(1.0), smoothstep(0.5, 0.75, c));
			col = mix(col, cloud, cover * 0.85);
		}
	}

	col += glow * glow_strength * pow(max(-d.z, 0.0), 3.0);
	COLOR = col;
}
