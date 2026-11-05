class_name Downloads
extends Node
## Saving videos for offline watching. Nothing is saved unless the user presses Download.
##
## Files go to the system Videos folder (Videos/FrameTube) so they're easy to find, copy or delete
## outside the app; an index (user://downloads.json) remembers what each file is. Playing a video
## that's been saved uses the file instead of streaming it, so it works without internet.
## One download runs at a time; more wait in a queue.

signal changed # list, queue or progress changed
signal done(id: String, ok: bool, message: String)

const INDEX := "user://downloads.json"

var items := {} # id -> {id, url, title, channel, views, duration, width, height, fps, vcodec, projection, age_limit, file, bytes, added}
var queue: Array = [] # pending jobs: {id, url, height, info, projection}
var current := {} # running job + {percent, phase, phases, cancelled}
## Which subtitle languages to save with a video: "all", "orig" (the video's own language) and/or
## language codes ("en", "es", ...). Empty = save none. Set from Settings by main.
var save_langs: Array = ["all"]
var _pid := -1
var _thread: Thread


func _ready() -> void:
	_load()


static func folder() -> String:
	var movies := OS.get_system_dir(OS.SYSTEM_DIR_MOVIES)
	var dir := movies.path_join("FrameTube") if movies != "" else OS.get_user_data_dir().path_join("videos")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func has(id: String) -> bool:
	return items.has(id)


func state(id: String) -> String:
	if items.has(id):
		return "saved"
	if not current.is_empty() and current.id == id:
		return "downloading"
	for j in queue:
		if j.id == id:
			return "queued"
	return ""


## Short text for the Download button for this video.
func label(id: String, is_live := false) -> String:
	match state(id):
		"saved": return "Saved"
		"downloading": return "Saving %d%%" % int(current.get("percent", 0.0))
		"queued": return "Queued"
	return "Can't save live" if is_live else "Download"


## info: the resolved video (YouTube.resolve); projection: what the user is watching it as.
func add(url: String, info: Dictionary, height: int, projection := -1) -> void:
	var id := Store.video_id(url)
	if id == "" or state(id) != "":
		return
	queue.append({"id": id, "url": url, "height": height, "info": info, "projection": projection})
	_next()
	changed.emit()


func cancel(id: String) -> void:
	for i in queue.size():
		if queue[i].id == id:
			queue.remove_at(i)
			changed.emit()
			return
	if not current.is_empty() and current.id == id:
		current.cancelled = true
		if _pid > 0 and OS.is_process_running(_pid):
			_kill_tree(_pid)


func remove(id: String) -> void:
	if not items.has(id):
		return
	var f: String = items[id].file
	_remove_file(f, 10)
	for t in items[id].get("subs", []):
		DirAccess.remove_absolute(str(t.url))
	items.erase(id)
	_save()
	changed.emit()


## The player may still have the file open for a moment after stopping (Windows won't delete it then).
func _remove_file(f: String, tries: int) -> void:
	if not FileAccess.file_exists(f) or DirAccess.remove_absolute(f) == OK or tries <= 0:
		return
	get_tree().create_timer(0.5).timeout.connect(_remove_file.bind(f, tries - 1))


## The saved file as a ready-to-play info Dictionary (like YouTube.resolve returns), or {}.
func local_info(url: String) -> Dictionary:
	var id := Store.video_id(url)
	if not items.has(id):
		return {}
	var e: Dictionary = items[id]
	if not FileAccess.file_exists(e.file):
		items.erase(id) # deleted outside the app
		_save()
		changed.emit()
		return {}
	return {"id": id, "title": e.title, "channel": e.channel, "views": e.views, "duration": e.duration,
		"width": e.width, "height": e.height, "fps": e.fps, "vcodec": e.vcodec, "is_live": false,
		"video_url": e.file, "audio_url": e.file, "user_agent": "", "subs": _local_subs(e), "probe": {},
		"projection_hint": e.projection, "age_limit": e.age_limit, "offline": true}


func _local_subs(e: Dictionary) -> Array:
	return e.get("subs", []).filter(func(t): return FileAccess.file_exists(str(t.url)))


## For the Browse page's "Downloads" list (newest first).
func list() -> Array:
	var out := []
	for e in items.values():
		out.append({"id": e.id, "url": e.url, "title": e.title, "duration": e.duration, "channel": e.channel,
			"views": e.views, "description": "Saved on this device · " + size_text(e.bytes), "added": e.added})
	out.sort_custom(func(a, b): return a.added > b.added)
	return out


func total_bytes() -> int:
	var n := 0
	for e in items.values():
		n += int(e.bytes)
	return n


static func size_text(b: int) -> String:
	if b >= 1 << 30:
		return "%.1f GB" % (b / float(1 << 30))
	return "%d MB" % maxi(1, b >> 20)


# --- Running downloads -----------------------------------------------------------------------------

func _next() -> void:
	if not current.is_empty() or queue.is_empty():
		return
	current = queue.pop_front()
	current.percent = 0.0
	current.cancelled = false
	var info: Dictionary = current.info
	var a := str(info.get("audio_url", ""))
	current.phases = 2 if a != "" and a != str(info.get("video_url", "")) else 1
	current.phase = 0
	_thread = Thread.new()
	_thread.start(_run.bind(current.duplicate()))


## Worker thread: runs yt-dlp, reports progress, returns via _finished.
func _run(job: Dictionary) -> void:
	var dir := folder()
	var pathfile := OS.get_user_data_dir().path_join("download-path.txt")
	DirAccess.remove_absolute(pathfile)
	var args := YouTube._common_args()
	var ff := Bin.find_local("ffmpeg")
	if ff != "":
		args.append_array(["--ffmpeg-location", ff])
	args.append_array(["--no-playlist", "--newline", "--progress-delta", "0.5",
		# Same format choice as streaming, so the saved copy matches what was being watched.
		"-f", "bv*+ba/b", "-S", "res:%d,vcodec:vp9" % job.height,
		"--merge-output-format", "mkv", "--match-filters", "!is_live & live_status!=is_upcoming",
		"--progress-template", "download:FTP %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(info.format_id)s",
		"--print-to-file", "after_move:%(filepath)s", pathfile, # UTF-8 file: stdout would mangle non-ASCII names
		"-o", dir.path_join("%(title).80B [%(id)s].%(ext)s"), job.url])
	var p := OS.execute_with_pipe(Bin.find("yt-dlp"), args) # blocking pipes: reads wait for output
	if p.is_empty():
		_finished.call_deferred(job, "", "FrameTube's video helpers are missing. Open Settings and press Repair.")
		return
	_set_pid.call_deferred(p.pid)
	var state := {"fmt": "", "phase": 0}
	var errors := PackedStringArray()
	var f: FileAccess = p.stdio
	var pending := ""
	while true:
		# Chunks, not get_line(): on a pipe get_line() gives up as soon as no byte is waiting.
		var chunk := f.get_buffer(4096)
		if chunk.is_empty():
			break
		pending += chunk.get_string_from_utf8()
		var lines := pending.split("
")
		pending = lines[lines.size() - 1]
		for i in lines.size() - 1:
			_parse_progress(lines[i].strip_edges(), state)
	var err := Bin._read_all(p.stderr).get_string_from_utf8()
	for l in err.split("\n"):
		if l.begins_with("ERROR"):
			errors.append(l)
	p.stdio.close()
	p.stderr.close()
	while OS.is_process_running(p.pid):
		OS.delay_msec(20)
	var path := FileAccess.get_file_as_string(pathfile).strip_edges() if FileAccess.file_exists(pathfile) else ""
	DirAccess.remove_absolute(pathfile)
	var msg := "\n".join(errors)
	if msg == "" and path == "":
		msg = err.strip_edges().right(400)
	if path == "" and msg == "" and err.contains("does not pass filter"):
		msg = "LIVE"
	_finished.call_deferred(job, path, msg)


## "FTP <downloaded> <total> <estimate> <format id>": one line per progress update (worker thread).
func _parse_progress(line: String, state: Dictionary) -> void:
	if not line.begins_with("FTP "):
		return
	var v := line.split(" ")
	if v.size() < 5:
		return
	if state.fmt != "" and v[4] != state.fmt:
		state.phase += 1 # video done, audio started
	state.fmt = v[4]
	var total := float(v[2]) if v[2].is_valid_float() else (float(v[3]) if v[3].is_valid_float() else 0.0)
	var frac := clampf(float(v[1]) / total, 0.0, 1.0) if total > 0.0 and v[1].is_valid_float() else 0.0
	_progress.call_deferred(state.phase, frac)


## yt-dlp's executable is a small launcher that starts the real program (and that starts ffmpeg), so
## stop the whole family, not just the launcher.
static func _kill_tree(pid: int) -> void:
	if OS.get_name() == "Windows":
		OS.execute("taskkill", ["/T", "/F", "/PID", str(pid)])
	else:
		OS.execute("pkill", ["-KILL", "-P", str(pid)])
		OS.kill(pid)


func _set_pid(pid: int) -> void:
	_pid = pid
	if current.get("cancelled", false):
		_kill_tree(pid)


func _progress(phase: int, frac: float) -> void:
	if current.is_empty():
		return
	# The video stream is most of the size; the audio track that follows is small.
	var pct := frac * 100.0
	if current.phases == 2:
		pct = (frac * 92.0) if phase == 0 else (92.0 + frac * 8.0)
	current.percent = maxf(current.get("percent", 0.0), pct)
	changed.emit()


func _finished(job: Dictionary, path: String, error: String) -> void:
	_thread.wait_to_finish()
	_pid = -1
	var cancelled: bool = current.get("cancelled", false)
	current = {}
	var id: String = job.id
	if cancelled or path == "" or not FileAccess.file_exists(path):
		if not cancelled:
			printerr("[downloads] failed: ", error if error != "" else "(no file, no error)")
		_clean_partial(id)
		var msg := "Download cancelled."
		if not cancelled:
			msg = "Live streams can't be saved." if error == "LIVE" else \
				"Couldn't save this video. " + YouTube.friendly_error(error).message
		done.emit(id, false, msg)
	else:
		var info: Dictionary = job.info
		items[id] = {"id": id, "url": job.url, "title": str(info.get("title", id)), "channel": str(info.get("channel", "")),
			"views": int(info.get("views", 0)), "duration": float(info.get("duration", 0.0)),
			"width": int(info.get("width", 0)), "height": int(info.get("height", 0)), "fps": float(info.get("fps", 30.0)),
			"vcodec": str(info.get("vcodec", "")), "projection": int(job.projection), "age_limit": int(info.get("age_limit", 0)),
			"file": path, "bytes": _file_size(path), "added": int(Time.get_unix_time_from_system()), "subs": []}
		_save()
		changed.emit()
		var n := await _save_subs(id, pick_subs(info.get("subs", []), save_langs, str(info.get("language", ""))))
		if not items.has(id): # deleted while the subtitles were saving
			_next()
			return
		done.emit(id, true, "Saved \"%s\" for offline watching (%s%s)." % [items[id].title, size_text(items[id].bytes),
			"" if n == 0 else ", %d subtitle track%s" % [n, "" if n == 1 else "s"]])
	changed.emit()
	_next()


## The tracks to keep for the chosen languages.
static func pick_subs(tracks: Array, langs: Array, video_lang: String) -> Array:
	if langs.has("all"):
		return tracks
	var own := video_lang.get_slice("-", 0)
	return tracks.filter(func(t): return langs.has(t.code) or (langs.has("orig") and own != "" and t.code == own))


## Saves the video's subtitle tracks (json3, as streamed) next to the file, so they work offline too.
## A track that fails to download is just skipped. Returns how many were saved.
func _save_subs(id: String, tracks: Array) -> int:
	if tracks.is_empty():
		return 0
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	var base: String = str(items[id].file).get_basename()
	var saved := []
	for t in tracks:
		var dest := "%s.%s%s.json3" % [base, t.code, "-auto" if t.get("auto", false) else ""]
		var n := 2
		while saved.any(func(x): return x.url == dest):
			dest = "%s.%s%s-%d.json3" % [base, t.code, "-auto" if t.get("auto", false) else "", n]
			n += 1
		http.download_file = dest
		if http.request(str(t.url)) != OK:
			continue
		var r: Array = await http.request_completed
		if r[0] == HTTPRequest.RESULT_SUCCESS and r[1] == 200 and FileAccess.file_exists(dest):
			saved.append({"code": t.code, "name": t.name, "auto": t.get("auto", false), "url": dest})
		else:
			DirAccess.remove_absolute(dest)
	http.queue_free()
	if items.has(id):
		items[id].subs = saved
		_save()
	else:
		for x in saved: # the video was deleted meanwhile
			DirAccess.remove_absolute(x.url)
	return saved.size()


## yt-dlp leaves .part / per-format files behind when stopped; they all carry the video id.
func _clean_partial(id: String) -> void:
	var dir := folder()
	for f in DirAccess.get_files_at(dir):
		if f.contains("[%s]" % id):
			DirAccess.remove_absolute(dir.path_join(f))


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else 0


func _load() -> void:
	if not FileAccess.file_exists(INDEX):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(INDEX))
	if data is Dictionary:
		for id in data:
			var e = data[id]
			if e is Dictionary and FileAccess.file_exists(str(e.get("file", ""))):
				items[id] = e


func _save() -> void:
	var f := FileAccess.open(INDEX, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(items, "\t"))
