shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

// Raw NV12 straight from ffmpeg: full-res luma (R8) + half-res interleaved chroma (RG8: r=U, g=V).
// NV12 is what GPU decoders produce natively, so no CPU-side pixel conversion is needed.
uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_uv : filter_linear, repeat_disable;

// 0 flat, 1 flat 3D side-by-side, 2 360 mono, 3 360 3D top/bottom, 4 180 mono, 5 180 3D side-by-side,
// 6 360 YouTube equi-angular cubemap (EAC)
uniform int mode = 0;
uniform bool swap_eyes = false;
uniform bool has_video = false;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

vec3 yuv_to_rgb(vec2 uv) {
	// BT.709, limited (TV) range — what YouTube serves.
	float y = (texture(tex_y, uv).r - 0.0625) * 1.1644;
	vec2 c = (texture(tex_uv, uv).rg - 0.5) * 1.1384;
	float u = c.x;
	float v = c.y;
	return clamp(vec3(
		y + 1.5748 * v,
		y - 0.1873 * u - 0.4681 * v,
		y + 1.8556 * u), 0.0, 1.0);
}

// YouTube's EAC layout, 3x2 cells:  [left][front][right] / [down][back][up]
// Top row upright; back rotated 90 deg; up/down rotated 90 deg and mirrored. Orientations were fitted
// face-by-face against ffmpeg's v360=eac reference (see README).
vec2 eac_uv(vec3 d) {
	vec3 a = abs(d);
	vec2 f;
	vec2 cell;
	if (a.z >= a.x && a.z >= a.y) {
		if (d.z < 0.0) { f = vec2(d.x, -d.y) / a.z; cell = vec2(1.0, 0.0); } // front
		else           { f = vec2(d.y, -d.x) / a.z; cell = vec2(1.0, 1.0); } // back
	} else if (a.x >= a.y) {
		if (d.x < 0.0) { f = vec2(-d.z, -d.y) / a.x; cell = vec2(0.0, 0.0); } // left
		else           { f = vec2(d.z, -d.y) / a.x;  cell = vec2(2.0, 0.0); } // right
	} else {
		if (d.y >= 0.0) { f = vec2(-d.z, -d.x) / a.y; cell = vec2(2.0, 1.0); } // up
		else            { f = vec2(d.z, -d.x) / a.y;  cell = vec2(0.0, 1.0); } // down
	}
	f = (4.0 / PI) * atan(f); // equi-angular: equal angle per pixel
	// Pull in by ~1 px so linear filtering doesn't bleed the neighbouring face across cube edges.
	vec2 cell_px = vec2(textureSize(tex_y, 0)) / vec2(3.0, 2.0);
	f *= 1.0 - 2.0 / cell_px;
	return (cell + (f + 1.0) * 0.5) / vec2(3.0, 2.0);
}

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

void fragment() {
	bool right = (VIEW_INDEX == VIEW_RIGHT) != swap_eyes;
	float eye = right ? 0.5 : 0.0;
	vec2 uv = UV;
	bool inside = true;

	if (mode == 1) {
		uv.x = uv.x * 0.5 + eye;
	} else if (mode == 6) {
		uv = eac_uv(normalize(local_pos));
	} else if (mode >= 2) {
		// Equirectangular lookup from the direction to this fragment (viewer sits at the sphere's center).
		vec3 d = normalize(local_pos);
		float lon = atan(d.x, -d.z); // 0 = straight ahead (-Z), + = to the right
		float lat = asin(clamp(d.y, -1.0, 1.0));
		float v = 0.5 - lat / PI;
		if (mode <= 3) {
			uv = vec2(lon / TAU + 0.5, v);
			if (mode == 3) {
				uv.y = uv.y * 0.5 + eye;
			}
		} else {
			inside = abs(lon) <= PI * 0.5;
			uv = vec2(lon / PI + 0.5, v);
			if (mode == 5) {
				uv.x = uv.x * 0.5 + eye;
			}
		}
	}

	vec3 col = vec3(0.0);
	if (inside && has_video) {
		col = srgb_to_linear(yuv_to_rgb(uv));
	}
	ALBEDO = col;
}
