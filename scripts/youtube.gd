class_name YouTube
extends RefCounted
## Thin wrapper around the yt-dlp CLI. Every function blocks — call them from a thread.

enum { FLAT, FLAT_SBS, SPHERE_360, SPHERE_360_TB, SPHERE_180, SPHERE_180_SBS, SPHERE_360_EAC }

## Signed-in access. A cookies.txt (Netscape format) in user:// or next to the app wins; otherwise,
## if set, yt-dlp reads the login cookies straight from this browser ("firefox", "chrome", "edge", ...).
static var cookies_browser := ""

const FEEDS := {
	"subscriptions": "https://www.youtube.com/feed/subscriptions",
	"watch_later": "https://www.youtube.com/playlist?list=WL",
	"recommended": "https://www.youtube.com/",
}


static func search(query: String, count := 15) -> Dictionary:
	return list("ytsearch%d:%s" % [count, query], count)


## A feed key from FEEDS (needs an account), or any yt-dlp playlist/search target.
static func feed(key: String, count := 30) -> Dictionary:
	var r := list(FEEDS.get(key, key), count)
	var empty: bool = r.has("error") or r.results.is_empty()
	if empty and cookie_args().is_empty():
		r.error = "This needs your YouTube account. Pick a browser with the Account button, or put cookies.txt in the app folder."
	return r


static func list(target: String, count := 30) -> Dictionary:
	var args := _common_args()
	args.append_array(["--flat-playlist", "--playlist-end", str(count), "-J", target])
	var data = _run_json(args)
	if data is String:
		return {"error": data}
	var results := []
	for e in data.get("entries", []):
		if typeof(e) != TYPE_DICTIONARY or _str(e, "id") == "":
			continue
		var ie := _str(e, "ie_key")
		if ie != "" and ie != "Youtube": # skip channels/playlists/shelves mixed into feeds
			continue
		var channel := _str(e, "channel")
		if channel == "":
			channel = _str(e, "uploader")
		results.append({
			"id": _str(e, "id"),
			"title": _str(e, "title", "(untitled)"),
			"duration": _num(e, "duration"),
			"channel": channel,
		})
	return {"results": results}


## Picks the best video stream up to max_height (preferring VP9, which ffmpeg decodes fast)
## plus the best audio stream, and returns their direct URLs.
static func resolve(url: String, max_height: int) -> Dictionary:
	var args := _common_args()
	args.append_array(["--no-playlist", "-J", "-f", "bv*+ba/b", "-S", "res:%d,vcodec:vp9" % max_height, url])
	var data = _run_json(args)
	if data is String:
		return {"error": data}

	var v := {}
	var a := {}
	var req = data.get("requested_formats")
	if req is Array:
		for f in req:
			if _str(f, "vcodec", "none") != "none":
				v = f
			elif _str(f, "acodec", "none") != "none":
				a = f
	else:
		v = data
		if _str(data, "acodec", "none") != "none":
			a = data
	if v.is_empty() or _str(v, "url") == "":
		return {"error": "No playable video format found."}
	var w := int(_num(v, "width"))
	var h := int(_num(v, "height"))
	if w <= 0 or h <= 0:
		return {"error": "yt-dlp didn't report the video size."}

	var headers = v.get("http_headers", {})
	var live = data.get("is_live")
	var ua: String = str(headers.get("User-Agent", "")) if headers is Dictionary else ""
	return {
		"probe": probe_vr(_str(v, "url"), ua),
		"title": _str(data, "title", "(untitled)"),
		"duration": _num(data, "duration"),
		"is_live": live is bool and live,
		"video_url": _str(v, "url"),
		"audio_url": _str(a, "url"),
		"width": w,
		"height": h,
		"fps": _num(v, "fps"),
		"vcodec": _str(v, "vcodec"),
		"user_agent": ua,
	}


## Blocking. Reads the stream header with `ffmpeg -i` and reports its VR metadata:
##   stereo:    "2d" | "sbs" | "tb" | ""      (from the Stereo 3D side data)
##   spherical: "equirect" | "mesh" | ""      (mesh = YouTube's cubemap/mesh projection, ffmpeg can't name it)
##   tiled:     true when the equirect has bounds (a partial sphere, i.e. 180)
static func probe_vr(url: String, user_agent := "") -> Dictionary:
	var args := PackedStringArray(["-hide_banner", "-nostdin"])
	if user_agent != "":
		args.append_array(["-user_agent", user_agent])
	args.append_array(["-i", url])
	var text := ""
	for attempt in 5:
		text = Bin.run("ffmpeg", args).err # exits 1 ("no output file"), that's fine
		if not text.contains("403 Forbidden"):
			break
		OS.delay_msec(750) # googlevideo refuses fresh URLs for a few seconds sometimes
	var r := {"stereo": "", "spherical": "", "tiled": false}
	if text.contains("Stereo 3D: side by side"):
		r.stereo = "sbs"
	elif text.contains("Stereo 3D: top and bottom"):
		r.stereo = "tb"
	elif text.contains("Stereo 3D: 2D"):
		r.stereo = "2d"
	if text.contains("Spherical Mapping: tiled equirectangular"):
		r.spherical = "equirect"
		r.tiled = true
	elif text.contains("Spherical Mapping: equirectangular"):
		r.spherical = "equirect"
	elif text.contains("Unknown spherical metadata type 3") or text.contains("projection type: ytmp") \
			or text.contains("Spherical Mapping: cubemap"):
		r.spherical = "mesh"
	return r


## Stream metadata first (reliable when present), then title keywords. The user can always cycle
## the projection manually.
static func guess_projection(info: Dictionary) -> int:
	var probe: Dictionary = info.get("probe", {})
	var stereo: String = probe.get("stereo", "")
	var spherical: String = probe.get("spherical", "")
	var title := str(info.get("title", "")).to_lower()
	var is180 := _matches("\\bvr ?180\\b|\\b180 ?(°|degrees?|vr|3d)", title)
	var is360 := _matches("\\b360\\b", title)
	var is3d := _matches("\\b3d\\b|stereo", title)

	if stereo == "sbs":
		return SPHERE_180_SBS # VR180; side-by-side 360 is practically nonexistent on YouTube
	if stereo == "tb":
		return SPHERE_360_TB
	if spherical == "mesh":
		return SPHERE_180 if is180 else SPHERE_360_EAC
	if spherical == "equirect":
		return SPHERE_180 if probe.get("tiled", false) or is180 else SPHERE_360

	# No usable metadata: fall back to the title.
	if is180:
		return SPHERE_180_SBS
	if is360:
		return SPHERE_360_TB if is3d else SPHERE_360
	if is3d and _matches("\\bvr\\b", title):
		return SPHERE_180_SBS # "3D VR" without 360 is almost always VR180
	if _matches("\\bvr\\b", title):
		return SPHERE_360
	return FLAT


static func _common_args() -> PackedStringArray:
	var a := PackedStringArray(["--no-warnings", "--ignore-config"])
	var deno := Bin.find_local("deno")
	if deno != "":
		a.append_array(["--js-runtimes", "deno:" + deno])
	a.append_array(cookie_args())
	return a


static func cookies_file() -> String:
	for p in [OS.get_user_data_dir().path_join("cookies.txt"),
			OS.get_executable_path().get_base_dir().path_join("cookies.txt"),
			ProjectSettings.globalize_path("res://cookies.txt") if OS.has_feature("editor") else ""]:
		if p != "" and FileAccess.file_exists(p):
			return p
	return ""


static func cookie_args() -> PackedStringArray:
	var f := cookies_file()
	if f != "":
		return PackedStringArray(["--cookies", f])
	if cookies_browser != "":
		return PackedStringArray(["--cookies-from-browser", cookies_browser])
	return PackedStringArray()


## Runs yt-dlp and returns the parsed JSON Dictionary, or an error String.
static func _run_json(args: PackedStringArray) -> Variant:
	var res := Bin.run("yt-dlp", args)
	var code: int = res.code
	if code == -1:
		return "Couldn't run yt-dlp. Put it in the bin folder or on PATH."
	var data = JSON.parse_string(res.out.strip_edges())
	if data is Dictionary:
		return data
	var errors := PackedStringArray()
	for line in res.err.split("\n"):
		line = line.strip_edges()
		if line.begins_with("ERROR"):
			errors.append(line)
	if not errors.is_empty():
		return "\n".join(errors)
	return "yt-dlp failed (exit code %d). Try updating it (yt-dlp -U)." % code


static func _matches(pattern: String, text: String) -> bool:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search(text) != null


static func _str(d: Dictionary, key: String, default := "") -> String:
	var v = d.get(key)
	return default if v == null else str(v)


static func _num(d: Dictionary, key: String) -> float:
	var v = d.get(key)
	return float(v) if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT else 0.0
