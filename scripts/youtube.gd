class_name YouTube
extends RefCounted
## Thin wrapper around the yt-dlp CLI. Every function blocks — call them from a thread.

enum { FLAT, FLAT_SBS, SPHERE_360, SPHERE_360_TB, SPHERE_180, SPHERE_180_SBS, SPHERE_360_EAC }

## Signed-in access. A cookies.txt (Netscape format) in user:// or next to the app wins; otherwise,
## if set, yt-dlp reads the login cookies straight from this browser ("firefox", "chrome", "edge", ...).
static var cookies_browser := ""
## Set when yt-dlp reports that the saved sign-in stopped working (YouTube signed it out).
static var signin_expired := false

const FEEDS := {
	"subscriptions": "https://www.youtube.com/feed/subscriptions",
	"watch_later": "https://www.youtube.com/playlist?list=WL",
	"recommended": "https://www.youtube.com/",
}


## Family-friendly filter: hides results whose title, description or channel match these (whole words /
## phrases), refuses 18+ videos, and asks YouTube to leave the worst terms out of searches.
static var family_filter := true
const FAMILY_BLOCK := [
	"sexy", "sex", "sexual", "lingerie", "bikini", "underwear", "nsfw", "18\\+", "onlyfans", "erotic", "erotica",
	"nude", "nudity", "naked", "topless", "twerk", "twerking", "booty", "boudoir", "seductive", "sensual",
	"stripper", "striptease", "fetish", "hot girls?", "girlfriend experience", "asmr girlfriend", "try[ -]?on",
	"tries on", "model olena", "pole dance", "lap dance", "hotness", "hotties?", "babes?", "busty", "cleavage",
	"thicc", "swimsuits?", "spicy", "body ?paint(ing)?", "vr ?girls?", "dangerous beauty", "flexibility",
	"gore", "gory", "graphic violence", "jumpscare",
	"jump scare", "horror", "murder", "creepypasta",
	# (not "killer", "blood", "strip": killer whales, blood moons and the Las Vegas Strip are fine)
]
const FAMILY_QUERY_EXCLUDE := " -sexy -lingerie -bikini -twerk -nsfw -horror"


static func family_ok(item: Dictionary) -> bool:
	if not family_filter:
		return true
	var text := ("%s %s %s" % [item.get("title", ""), item.get("description", ""), item.get("channel", "")]).to_lower()
	return not _matches("\\b(" + "|".join(FAMILY_BLOCK) + ")\\b", text)


static func search(query: String, count := 20) -> Dictionary:
	var q := query + (FAMILY_QUERY_EXCLUDE if family_filter else "")
	return list("ytsearch%d:%s" % [count, q], count)


## A feed key from FEEDS (needs an account), or any yt-dlp playlist/search target.
static func feed(key: String, count := 30) -> Dictionary:
	var r := list(FEEDS.get(key, key), count)
	var empty: bool = r.has("error") or r.results.is_empty()
	if empty and cookie_args().is_empty():
		r.error = "This needs your YouTube account. Open Settings and press Sign in."
	return r


static func list(target: String, count := 30) -> Dictionary:
	var args := _common_args()
	args.append_array(["--flat-playlist", "--playlist-end", str(count), "-J", target])
	var data = _run_json(args)
	if data is String:
		return {"error": data}
	var results := []
	var hidden := 0
	for e in data.get("entries", []):
		if typeof(e) != TYPE_DICTIONARY or _str(e, "id") == "":
			continue
		var ie := _str(e, "ie_key")
		if ie != "" and ie != "Youtube": # skip channels/playlists/shelves mixed into feeds
			continue
		var channel := _str(e, "channel")
		if channel == "":
			channel = _str(e, "uploader")
		var verified = e.get("channel_is_verified")
		var item := {
			"id": _str(e, "id"),
			"title": _str(e, "title", "(untitled)"),
			"duration": _num(e, "duration"),
			"channel": channel,
			"views": int(_num(e, "view_count")),
			"description": _str(e, "description").replace("\n", " ").strip_edges(),
			"live": _str(e, "live_status") == "is_live",
			"verified": verified is bool and verified,
		}
		if family_ok(item):
			results.append(item)
		else:
			hidden += 1
	return {"results": results, "hidden": hidden}


## Subtitle choices for a video: every human-made track, plus auto-generated captions in the video's own
## language and in English (YouTube machine-translates auto captions into ~100 languages; those are skipped).
## Each: {code, name, auto, url} with url pointing at YouTube's clean "json3" timed-text format.
static func subtitle_tracks(data: Dictionary) -> Array:
	var tracks := []
	var seen := {}
	var lang := _str(data, "language")
	for pass_auto in [false, true]:
		var src = data.get("automatic_captions" if pass_auto else "subtitles")
		if not src is Dictionary:
			continue
		for code: String in src:
			if code == "live_chat" or seen.has(code + str(pass_auto)):
				continue
			var base := code.get_slice("-", 0)
			if pass_auto and not (code.ends_with("-orig") or base == "en" or (lang != "" and base == lang)):
				continue
			if pass_auto and code != base and not code.ends_with("-orig"):
				continue # skip regional duplicates of auto captions
			var url := ""
			var name := code
			for f in src[code]:
				if f is Dictionary and _str(f, "ext") == "json3":
					url = _str(f, "url")
					name = _str(f, "name", code)
			if url == "":
				continue
			seen[code + str(pass_auto)] = true
			name = name.replace(" (Original)", "").strip_edges() + (" (auto)" if pass_auto else "")
			if seen.has("name:" + name):
				continue # e.g. auto "en" and "en-orig" are the same English captions
			seen["name:" + name] = true
			tracks.append({"code": base, "name": name, "auto": pass_auto, "url": url})
			if tracks.size() >= 10:
				return tracks
	return tracks


## Quick visual tags from the title (search results don't carry projection or resolution metadata).
static func title_badges(title: String, live := false) -> PackedStringArray:
	var t := title.to_lower()
	var b := PackedStringArray()
	if live:
		b.append("LIVE")
	if _matches("\\bvr ?180\\b|\\b180 ?(°|degrees?|vr|3d)", t):
		b.append("VR180")
	elif _matches("\\b360\\b", t):
		b.append("360°")
	if _matches("\\b3d\\b|stereo", t):
		b.append("3D")
	if _matches("\\b(16|12|8) ?k\\b", t):
		b.append("8K+")
	elif _matches("\\b(5\\.7|6) ?k\\b", t):
		b.append("5.7K")
	elif _matches("\\b4 ?k\\b|\\buhd\\b|2160p", t):
		b.append("4K")
	return b


## Auto quality: the sharpest stream this machine plays smoothly. 360/180 videos spread their pixels
## around you, so they need far more of them than a flat screen does: 4K over 360 degrees is only about
## 10 pixels per degree, half of what the headset shows. So: VR videos up to 8K (5.7K when it's over
## 30 fps), flat ones up to 4K. `auto_limit` lowers the ceiling after playback couldn't keep up.
const AUTO := 0
const AUTO_VR_MAX := 4320
const AUTO_VR_HIGH_FPS_MAX := 2880
const AUTO_FLAT_MAX := 2160
static var auto_limit := 4320


static func auto_caps() -> Vector2i: # x = VR videos, y = flat videos
	var vr := AUTO_VR_MAX
	if Engine.get_architecture_name().begins_with("arm"):
		vr = 2160 # the Frame by itself, without a PC: decoding is all on its CPU
	vr = mini(vr, auto_limit)
	return Vector2i(vr, mini(AUTO_FLAT_MAX, vr))


## Picks the best video stream up to max_height (preferring VP9, which ffmpeg decodes fast)
## plus the best audio stream, and returns their direct URLs. max_height = AUTO: see auto_caps().
static func resolve(url: String, max_height: int) -> Dictionary:
	var auto := max_height == AUTO
	if auto:
		max_height = auto_caps().x
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
	if family_filter and int(_num(data, "age_limit")) >= 18:
		return {"error": "FAMILY: This video is for adults only, so the family-friendly filter blocked it."}
	if family_filter and not family_ok({"title": _str(data, "title"), "channel": _str(data, "channel")}):
		return {"error": "FAMILY: The family-friendly filter blocked this video."}

	var headers = v.get("http_headers", {})
	var live = data.get("is_live")
	var ua: String = str(headers.get("User-Agent", "")) if headers is Dictionary else ""
	var ch := _str(data, "channel")
	var probe := probe_vr(_str(v, "url"), ua)
	if auto and req is Array:
		# Now that we know what kind of video it is, maybe step down (same format list, no new request).
		var caps := auto_caps()
		var vr := guess_projection({"probe": probe, "title": _str(data, "title")}) != FLAT
		var cap := caps.x if vr else caps.y
		if vr and _num(v, "fps") > 31.0:
			cap = mini(cap, AUTO_VR_HIGH_FPS_MAX)
		if mini(w, h) > cap:
			var alt := _best_video_under(data.get("formats", []), cap)
			if not alt.is_empty():
				v = alt
				w = int(_num(v, "width"))
				h = int(_num(v, "height"))
	return {
		"subs": subtitle_tracks(data),
		"language": _str(data, "language"),
		"probe": probe,
		"id": _str(data, "id"),
		"channel": ch if ch != "" else _str(data, "uploader"),
		"views": int(_num(data, "view_count")),
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


## yt-dlp lists formats sorted worst to best by our -S order (resolution first, then VP9), so the
## last video-only one that fits is the best one under the cap.
static func _best_video_under(formats: Variant, cap: int) -> Dictionary:
	if not (formats is Array):
		return {}
	for i in range(formats.size() - 1, -1, -1):
		var f = formats[i]
		if not (f is Dictionary) or _str(f, "vcodec", "none") == "none" or _str(f, "acodec", "none") != "none":
			continue
		var fw := int(_num(f, "width"))
		var fh := int(_num(f, "height"))
		if fw > 0 and fh > 0 and mini(fw, fh) <= cap and _str(f, "url") != "" and _str(f, "protocol", "https").begins_with("http"):
			return f
	return {}


## Turns yt-dlp's technical errors into something a non-technical person can act on.
## "update": true when the cause may be YouTube changing something (worth updating yt-dlp and retrying).
static func friendly_error(raw: String) -> Dictionary:
	if raw.begins_with("FAMILY: "):
		return {"message": raw.trim_prefix("FAMILY: ") + " (You can turn it off in Settings.)", "update": false}
	var t := raw.to_lower()
	var rules := [
		["couldn't run yt-dlp", "FrameTube's video helpers are missing. Open Settings and press Repair.", false],
		["requested format|no video formats|unable to extract|signature|nsig",
			"Couldn't load this video. YouTube may have changed something.", true],
		["confirm your age|age-restricted|inappropriate for some users",
			"This video is age-restricted. Sign in to YouTube (Settings > Sign in) to watch it.", false],
		["not a bot|sign in to confirm",
			"YouTube wants a sign-in right now (this happens now and then). Try again in a few minutes, or sign in to YouTube in Settings to avoid it.", false],
		["private video", "This video is private.", false],
		["members-only|join this channel|members only", "This video is for channel members only.", false],
		["premieres in|will begin in|this live event will", "This video hasn't started yet. Try again later.", false],
		["video unavailable|not available|has been removed|account associated|terminated|copyright",
			"This video isn't available.", false],
		["unable to download webpage|getaddrinfo|name or service|timed out|network is unreachable|connection",
			"Can't reach YouTube. Check your internet connection and try again.", false],
		["cookie", "Your YouTube sign-in stopped working. Open Settings and sign in again.", false],
	]
	for r in rules:
		if _matches(r[0], t):
			return {"message": r[1], "update": r[2]}
	return {"message": "Couldn't load this video. YouTube may have changed something.", "update": true}


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
	var a := PackedStringArray(["--ignore-config"]) # warnings go to stderr; only ERROR lines are shown
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
	if res.err.contains("cookies are no longer valid"):
		signin_expired = true
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
