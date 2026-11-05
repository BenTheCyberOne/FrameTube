class_name Subtitles
extends Node
## Loads a YouTube timed-text track in "json3" format and answers "what should be on screen at time t?".
## json3: {"events": [{"tStartMs", "dDurationMs", "segs": [{"utf8"}]}]}. Auto-generated captions roll two
## lines (each event appends to the previous), so up to two overlapping cues are shown, oldest first.

signal loaded(ok: bool)

var cues: Array = [] # [start_s, end_s, text], sorted by start
var _http: HTTPRequest
var _last_idx := 0


func clear() -> void:
	cues = []
	_last_idx = 0
	if _http:
		_http.cancel_request()


## A web address, or a saved .json3 file (downloads).
func load_url(url: String) -> void:
	clear()
	if not url.begins_with("http"):
		cues = parse_json3(FileAccess.get_file_as_string(url)) if FileAccess.file_exists(url) else []
		loaded.emit.call_deferred(not cues.is_empty())
		return
	if _http == null:
		_http = HTTPRequest.new()
		_http.use_threads = true
		_http.timeout = 20.0
		add_child(_http)
		_http.request_completed.connect(_on_done)
	_http.request(url)


func _on_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		loaded.emit(false)
		return
	cues = parse_json3(body.get_string_from_utf8())
	loaded.emit(not cues.is_empty())


static func parse_json3(text: String) -> Array:
	var data = JSON.parse_string(text)
	var out := []
	if not data is Dictionary:
		return out
	for e in data.get("events", []):
		if not e is Dictionary or not e.has("segs"):
			continue
		var s := ""
		for seg in e.segs:
			if seg is Dictionary:
				s += str(seg.get("utf8", ""))
		s = s.strip_edges()
		if s == "":
			continue
		var start := float(e.get("tStartMs", 0)) / 1000.0
		var dur := float(e.get("dDurationMs", 2000)) / 1000.0
		out.append([start, start + maxf(dur, 0.3), s])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out


## Text to show at media time t ("" for nothing). Cheap: walks from the last position.
func text_at(t: float) -> String:
	if cues.is_empty():
		return ""
	if _last_idx >= cues.size() or cues[_last_idx][0] > t:
		_last_idx = 0 # seeked backwards
	while _last_idx + 1 < cues.size() and cues[_last_idx + 1][0] <= t:
		_last_idx += 1
	var lines := PackedStringArray()
	for i in range(maxi(_last_idx - 3, 0), _last_idx + 1): # recent cues that are still on
		if cues[i][0] <= t and t < cues[i][1] and not lines.has(cues[i][2]):
			lines.append(cues[i][2])
	while lines.size() > 2:
		lines.remove_at(0)
	return "\n".join(lines)
