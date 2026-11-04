class_name Store
extends RefCounted
## Persists settings (user://settings.cfg) and watch history with resume positions (user://history.json).

const SETTINGS_PATH := "user://settings.cfg"
const HISTORY_PATH := "user://history.json"
const MAX_HISTORY := 60
const RESUME_MIN := 15.0 # don't bother resuming in the first / last 15 s

var history: Array = [] # newest first: {id, url, title, duration, pos, projection, watched_at}
var persist := true # false = keep changes in memory only (test runs)
var _cfg := ConfigFile.new()


func _init() -> void:
	_cfg.load(SETTINGS_PATH) # missing file is fine
	var f := FileAccess.open(HISTORY_PATH, FileAccess.READ)
	if f:
		var data = JSON.parse_string(f.get_as_text())
		if data is Array:
			history = data


func get_setting(key: String, default: Variant) -> Variant:
	return _cfg.get_value("app", key, default)


func set_setting(key: String, value: Variant) -> void:
	_cfg.set_value("app", key, value)
	if persist:
		_cfg.save(SETTINGS_PATH)


func find(url: String) -> Dictionary:
	var id := video_id(url)
	for h in history:
		if h.id == id:
			return h
	return {}


## Where to resume this video, or 0 to start from the beginning.
func resume_position(url: String) -> float:
	var h := find(url)
	if h.is_empty():
		return 0.0
	var pos := float(h.get("pos", 0.0))
	var dur := float(h.get("duration", 0.0))
	if pos < RESUME_MIN or (dur > 0.0 and pos > dur - RESUME_MIN):
		return 0.0
	return pos


## Projection the user picked manually for this video last time, or -1.
func saved_projection(url: String) -> int:
	return int(find(url).get("projection", -1))


## Move (or add) the video to the top of the history.
func touch(url: String, title: String, duration: float, channel := "", views := 0) -> void:
	var h := find(url)
	if h.is_empty():
		h = {"id": video_id(url), "url": url, "pos": 0.0, "projection": -1}
	else:
		history.erase(h)
	h.title = title
	h.duration = duration
	if channel != "":
		h.channel = channel
	if views > 0:
		h.views = views
	h.watched_at = Time.get_unix_time_from_system()
	history.push_front(h)
	if history.size() > MAX_HISTORY:
		history.resize(MAX_HISTORY)
	save_history()


func set_position(url: String, pos: float) -> void:
	var h := find(url)
	if not h.is_empty():
		h.pos = pos


func set_projection(url: String, projection: int) -> void:
	var h := find(url)
	if not h.is_empty():
		h.projection = projection
		save_history()


func save_history() -> void:
	if not persist:
		return
	var f := FileAccess.open(HISTORY_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(history))


static func video_id(url: String) -> String:
	var re := RegEx.new()
	re.compile("(?:v=|youtu\\.be/|/shorts/|/live/|/embed/)([A-Za-z0-9_-]{11})")
	var m := re.search(url)
	return m.get_string(1) if m else url
