class_name Thumbs
extends Node
## Downloads and caches YouTube thumbnails: the small 320x180 "mqdefault" JPEG (no letterbox bars,
## ~15 KB). Memory cache for this session + disk cache in user://thumbs so history shows instantly.

const MAX_PARALLEL := 6
const DISK := "user://thumbs"
const DISK_LIMIT := 1500 # files; above this the cache is cleared on startup

var _mem := {} # id -> Texture2D (or null = failed this session)
var _waiting := {} # id -> Array[Callable]
var _queue: Array[String] = []
var _active := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DISK)
	var files := DirAccess.get_files_at(DISK)
	if files.size() > DISK_LIMIT:
		for f in files:
			DirAccess.remove_absolute(DISK.path_join(f))


## Calls `cb(texture)` when the thumbnail is ready (right away if cached). Pass a bound method of the
## node that shows it (e.g. `rect.set_texture`): if that node is freed first, the call is skipped.
func fetch(id: String, cb: Callable) -> void:
	if id == "":
		return
	if _mem.has(id):
		if _mem[id] != null:
			cb.call(_mem[id])
		return
	if _waiting.has(id):
		_waiting[id].append(cb)
		return
	_waiting[id] = [cb]
	var path := DISK.path_join(id + ".jpg")
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load_jpg_from_buffer(FileAccess.get_file_as_bytes(path)) == OK:
			_finish(id, ImageTexture.create_from_image(img))
			return
	_queue.append(id)
	_pump()


## Drop queued (not yet started) downloads, e.g. when a new search replaces the list.
func cancel_pending() -> void:
	for id in _queue:
		_waiting.erase(id)
	_queue.clear()


func _pump() -> void:
	while _active < MAX_PARALLEL and not _queue.is_empty():
		var id: String = _queue.pop_front()
		_active += 1
		var h := HTTPRequest.new()
		h.use_threads = true
		h.timeout = 15.0
		add_child(h)
		h.request_completed.connect(_on_done.bind(id, h))
		if h.request("https://i.ytimg.com/vi/%s/mqdefault.jpg" % id) != OK:
			_on_done(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(), id, h)


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, id: String,
		h: HTTPRequest) -> void:
	h.queue_free()
	_active -= 1
	var tex: Texture2D = null
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var img := Image.new()
		if img.load_jpg_from_buffer(body) == OK:
			tex = ImageTexture.create_from_image(img)
			var f := FileAccess.open(DISK.path_join(id + ".jpg"), FileAccess.WRITE)
			if f:
				f.store_buffer(body)
	_finish(id, tex)
	_pump()


func _finish(id: String, tex: Texture2D) -> void:
	_mem[id] = tex
	for cb in _waiting.get(id, []):
		if tex != null and cb.is_valid():
			cb.call(tex)
	_waiting.erase(id)
