class_name VideoEngine
extends Node
## Plays a stream by running two ffmpeg subprocesses:
##   video -> raw NV12 on stdout -> R8 luma + RG8 chroma textures (converted to RGB in the shader)
##   audio -> f32le PCM on stdout -> AudioStreamGenerator
## Audio is the master clock; video frames are shown when their timestamp comes due.
## Seeking restarts both processes with -ss.
##
## Video decoding tries each entry of `decoders` in order (GPU hwaccels first, "none" = CPU).
## A named hwaccel that isn't available makes ffmpeg fail outright rather than fall back,
## so on such a failure we step down to the next decoder and respawn.

signal status(text: String)
signal finished
signal decoder_changed(decoder: String)

## Preference-ordered ffmpeg -hwaccel values; "none" means CPU decoding.
static func default_decoders() -> PackedStringArray:
	if OS.get_name() == "Windows":
		return PackedStringArray(["vulkan", "d3d11va", "none"])
	return PackedStringArray(["vulkan", "none"])

var decoders := default_decoders()
var preferred_decoder := 0 # index into decoders that each open() starts from
var decoder_index := 0 # what's actually in use (may have stepped down)

const MAX_VIDEO_QUEUE := 4
const MAX_AUDIO_QUEUE := 24
const AUDIO_CHUNK_FRAMES := 2048
const MAX_RECONNECTS := 3
const MAX_STREAM_RETRIES := 12
const RETRY_DELAY_MS := 750

var tex_y: ImageTexture
var tex_uv: ImageTexture

var width := 0
var height := 0
var fps := 30.0
var duration := 0.0
var playing := false
var paused := false
var buffering := false

var _video_url := ""
var _audio_url := ""
var _user_agent := ""

var _session := 0
var _mutex := Mutex.new()
var _procs: Array[int] = []
var _pipes: Array[FileAccess] = []
var _threads: Array[Thread] = []
var _vqueue: Array = [] # [pts, Image y, Image uv]
var _aqueue: Array = [] # PackedVector2Array chunks
var _video_eof := false
var _audio_eof := false
var _error_text := ""
var _frames_shown := 0
var _reconnects := 0
var _stream_retries := 0
var _audio_retries := 0
var _retry_at := 0
var _audio_start := 0.0 # media time where the current audio process starts
var _audio_base := 0.0 # media time of the first sample actually pushed to the output
var _audio_drop := 0 # sample frames still to discard (audio joined late)
var _audio_got_data := false
var _video_got_data := false

var _player: AudioStreamPlayer
var _gen: AudioStreamGeneratorPlayback
var _mix_rate := 48000.0
var _audio_pushed := 0
var _gen_capacity := 0
var _pending := PackedVector2Array()

var _start_time := 0.0
var _clock := 0.0
var _finished_emitted := false


func _ready() -> void:
	_mix_rate = AudioServer.get_mix_rate()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _mix_rate
	gen.buffer_length = 0.5
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	add_child(_player)


func _exit_tree() -> void:
	_stop_decoders()


# --- Public API ------------------------------------------------------------------------------

func open(info: Dictionary, start := 0.0) -> void:
	stop()
	width = int(info.width) & ~1 # 4:2:0 chroma needs even dimensions
	height = int(info.height) & ~1
	decoder_index = preferred_decoder
	decoder_changed.emit(decoders[decoder_index])
	fps = float(info.fps) if float(info.fps) > 1.0 else 30.0
	duration = float(info.duration)
	_video_url = info.video_url
	_audio_url = info.audio_url
	_user_agent = str(info.get("user_agent", ""))
	_reconnects = 0
	stat_uploaded = 0
	stat_skipped = 0
	stat_audio_frames = 0
	_make_textures()
	playing = true
	paused = false
	_restart(start)


func stop() -> void:
	_stop_decoders()
	if _player:
		_player.stop()
	_gen = null
	playing = false
	buffering = false


func toggle_pause() -> void:
	set_paused(not paused)


func set_paused(p: bool) -> void:
	if not playing:
		return
	paused = p
	_player.stream_paused = p


func seek(t: float) -> void:
	if not playing and not _finished_emitted:
		return
	if duration > 0.0:
		t = clampf(t, 0.0, maxf(duration - 1.0, 0.0))
	else:
		t = maxf(t, 0.0)
	playing = true
	_restart(t)


func get_position() -> float:
	return _start_time + _clock


## Switch decoder (index into `decoders`); restarts the current video at the same spot.
func set_decoder(index: int) -> void:
	preferred_decoder = clampi(index, 0, decoders.size() - 1)
	decoder_index = preferred_decoder
	decoder_changed.emit(decoders[decoder_index])
	if playing:
		_restart(get_position())


## Diagnostics: cumulative counters since open(), plus current queue depths.
var stat_uploaded := 0 # frames actually put on screen
var stat_skipped := 0 # frames decoded but superseded before display (decoder/clock catch-up)
var stat_audio_frames := 0

func stats() -> Dictionary:
	_mutex.lock()
	var d := {
		"pos": snappedf(get_position(), 0.01),
		"buffering": buffering,
		"decoder": decoders[decoder_index],
		"shown": stat_uploaded,
		"skipped": stat_skipped,
		"vq": _vqueue.size(),
		"aq": _aqueue.size(),
		"audio_s": snappedf(stat_audio_frames / _mix_rate, 0.01),
		"video_eof": _video_eof,
		"audio_eof": _audio_eof,
		"err": _error_text,
	}
	_mutex.unlock()
	if _gen != null and _audio_pushed > 0:
		var filled := _gen_capacity - _gen.get_frames_available()
		var audio_t := _audio_base + float(_audio_pushed - filled) / _mix_rate - AudioServer.get_output_latency()
		d["av_ms"] = int((audio_t - get_position()) * 1000.0) # + = audio ahead of picture
	return d


# --- Main-thread pump ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not playing:
		return

	if buffering:
		# googlevideo often answers 403 for the first few seconds after a URL is issued (measured
		# 0-3 s), then accepts it. Retry a stream that died before delivering anything, spaced out.
		_mutex.lock()
		var audio_failed := _audio_url != "" and _audio_eof and not _audio_got_data
		var video_failed := _video_eof and not _video_got_data
		var verr := _error_text
		_mutex.unlock()
		# Video failed for a reason other than the server refusing us -> the decoder is the likely
		# culprit (GPU hwaccel unavailable or can't handle this codec). Step down immediately.
		if video_failed and not verr.contains("403") and decoder_index < decoders.size() - 1:
			var failed := decoders[decoder_index]
			decoder_index += 1
			decoder_changed.emit(decoders[decoder_index])
			push_warning("Decoder '%s' failed, falling back to '%s': %s" % [failed, decoders[decoder_index], verr])
			status.emit("GPU decoder '%s' unavailable, trying %s..." % [failed, _decoder_label(decoders[decoder_index])])
			_mutex.lock()
			_video_eof = false
			_error_text = ""
			_mutex.unlock()
			if not _spawn_video(_session):
				_video_eof = true
			return
		if video_failed and _stream_retries < MAX_STREAM_RETRIES:
			if not _retry_due():
				return
			_stream_retries += 1
			status.emit("Stream refused, retrying (%d/%d)..." % [_stream_retries, MAX_STREAM_RETRIES])
			_mutex.lock()
			_video_eof = false
			_error_text = ""
			_mutex.unlock()
			if not _spawn_video(_session):
				_video_eof = true
			return
		_mutex.lock()
		# Start as soon as video is ready. If the audio URL is still being refused, don't wait for
		# it: it keeps retrying below and joins mid-playback, trimmed to stay in sync.
		var audio_ready := _audio_eof or _aqueue.size() >= 4
		var ready := _vqueue.size() > 0 and (audio_ready or audio_failed)
		var dead := _video_eof and _vqueue.is_empty()
		var err := _error_text
		_mutex.unlock()
		if dead:
			buffering = false
			playing = false
			status.emit("Playback failed: " + err if err != "" else "Playback failed (ffmpeg produced no frames).")
			return
		if not ready:
			return
		buffering = false
		status.emit("")

	_retry_audio()
	if _gen == null and _audio_got_data:
		_start_audio_output()
	if not paused:
		_feed_audio()
		_clock += delta
		_sync_to_audio()
	_present()
	_check_end()


func _retry_due() -> bool:
	var now := Time.get_ticks_msec()
	if _retry_at == 0:
		_retry_at = now + RETRY_DELAY_MS
	if now < _retry_at:
		return false
	_retry_at = 0
	return true


## Audio died before delivering anything (typically googlevideo's early 403): respawn it, spaced out,
## starting at the current playback position.
func _retry_audio() -> void:
	if _audio_url == "" or _audio_got_data or _audio_retries >= MAX_STREAM_RETRIES:
		return
	_mutex.lock()
	var failed := _audio_eof
	_mutex.unlock()
	if not failed or not _retry_due():
		return
	_audio_retries += 1
	_audio_eof = false
	_spawn_audio(_session, get_position())


## First audio data of this session has arrived: start the output and drop whatever part of it
## is already in the past (when audio joins after video started).
func _start_audio_output() -> void:
	_player.play()
	_player.stream_paused = paused
	_gen = _player.get_stream_playback()
	_gen_capacity = _gen.get_frames_available()
	_audio_pushed = 0
	var late := get_position() - _audio_start
	_audio_drop = int(late * _mix_rate) if late > 0.0 else 0
	_audio_base = _audio_start + _audio_drop / _mix_rate


func _feed_audio() -> void:
	if _gen == null:
		return
	while _audio_drop > 0: # discard audio that belongs before the current position
		if _pending.is_empty():
			_mutex.lock()
			if not _aqueue.is_empty():
				_pending = _aqueue.pop_front()
			_mutex.unlock()
			if _pending.is_empty():
				return
		var d := mini(_audio_drop, _pending.size())
		_pending = _pending.slice(d)
		_audio_drop -= d
	var avail := _gen.get_frames_available()
	while avail > 0:
		if _pending.is_empty():
			_mutex.lock()
			if not _aqueue.is_empty():
				_pending = _aqueue.pop_front()
			_mutex.unlock()
			if _pending.is_empty():
				return
		var n := mini(avail, _pending.size())
		if n == _pending.size():
			_gen.push_buffer(_pending)
			_pending = PackedVector2Array()
		else:
			_gen.push_buffer(_pending.slice(0, n))
			_pending = _pending.slice(n)
		_audio_pushed += n
		stat_audio_frames += n
		avail -= n


func _sync_to_audio() -> void:
	if _gen == null or _audio_pushed == 0:
		return
	_mutex.lock()
	var drained := _audio_eof and _aqueue.is_empty()
	_mutex.unlock()
	var filled := _gen_capacity - _gen.get_frames_available()
	if drained and _pending.is_empty() and filled <= 0:
		return # audio is over; let the wall clock run out the video
	var audio_t := _audio_base + float(_audio_pushed - filled) / _mix_rate - AudioServer.get_output_latency()
	if audio_t < _audio_base:
		return
	var diff := audio_t - get_position()
	if absf(diff) > 0.25:
		_clock = audio_t - _start_time # big jump (stall/underrun): snap
	else:
		_clock += diff * 0.05 # small drift: ease


func _present() -> void:
	var clock := get_position()
	var frame = null
	_mutex.lock()
	# Always show the first frame of a session immediately (seek preview while paused).
	while not _vqueue.is_empty() and (_vqueue[0][0] <= clock + 0.001 or _frames_shown == 0):
		if frame != null:
			stat_skipped += 1
		frame = _vqueue.pop_front()
		_frames_shown += 1
	_mutex.unlock()
	if frame != null:
		stat_uploaded += 1
		tex_y.update(frame[1])
		tex_uv.update(frame[2])
		if stat_uploaded % 4 == 1:
			average_color = _average_color(frame[1], frame[2])


## Average colour of the current picture (sRGB), for bias lighting. Updated every 4th frame.
var average_color := Color.BLACK

## Coarse 8x6 sample grid of a YUV frame -> mean RGB. Cheap: 48 pixel reads.
static func _average_color(y_img: Image, uv_img: Image) -> Color:
	var w := uv_img.get_width()
	var h := uv_img.get_height()
	var sum := Vector3.ZERO
	for j in 6:
		for i in 8:
			var cx := int((i + 0.5) / 8.0 * w)
			var cy := int((j + 0.5) / 6.0 * h)
			var yv := (y_img.get_pixel(cx * 2, cy * 2).r - 0.0625) * 1.1644
			var c := uv_img.get_pixel(cx, cy)
			var u := (c.r - 0.5) * 1.1384
			var v := (c.g - 0.5) * 1.1384
			sum += Vector3(yv + 1.5748 * v, yv - 0.1873 * u - 0.4681 * v, yv + 1.8556 * u).clamp(Vector3.ZERO, Vector3.ONE)
	sum /= 48.0
	return Color(sum.x, sum.y, sum.z)


func _check_end() -> void:
	_mutex.lock()
	var video_done := _video_eof and _vqueue.is_empty()
	var audio_done := _audio_eof and _aqueue.is_empty()
	_mutex.unlock()
	if not video_done or _finished_emitted:
		return
	# Stream died well before the end (network hiccup / expired URL)? Reconnect at the current spot.
	var pos := get_position()
	if duration > 0.0 and pos < duration - 3.0 and _reconnects < MAX_RECONNECTS:
		_reconnects += 1
		status.emit("Stream dropped, reconnecting (%d/%d)..." % [_reconnects, MAX_RECONNECTS])
		_restart(pos)
		return
	if audio_done and _pending.is_empty():
		_finished_emitted = true
		playing = false
		_player.stop()
		finished.emit()


# --- Decoder sessions ---------------------------------------------------------------------------

func _restart(t: float) -> void:
	_stop_decoders()
	_session += 1
	var s := _session
	_start_time = t
	_clock = 0.0
	_vqueue.clear()
	_aqueue.clear()
	_pending = PackedVector2Array()
	_video_eof = false
	_audio_eof = _audio_url == ""
	_error_text = ""
	_frames_shown = 0
	_finished_emitted = false
	_player.stop()
	_gen = null
	_audio_pushed = 0
	_audio_got_data = false
	_video_got_data = false
	_stream_retries = 0
	_audio_retries = 0
	_retry_at = 0
	_audio_drop = 0
	_audio_start = t
	_audio_base = t
	buffering = true
	status.emit("Buffering...")

	if not _spawn_video(s):
		playing = false
		buffering = false
		status.emit("Couldn't start ffmpeg. Put it in the bin folder or on PATH.")
		return
	if _audio_url != "":
		_spawn_audio(s)


func _spawn_video(s: int) -> bool:
	var hw := decoders[decoder_index]
	var args := _input_args(_start_time, _video_url, hw)
	args.append_array([
		"-an", "-sn", "-dn",
		"-vf", "scale=%d:%d" % [width, height],
		"-pix_fmt", "nv12", "-r", str(fps),
		"-f", "rawvideo", "pipe:1",
	])
	return _spawn(args, _video_loop, s)


static func _decoder_label(hw: String) -> String:
	match hw:
		"none": return "CPU"
		"d3d11va": return "GPU (D3D11)"
		"vulkan": return "GPU (Vulkan)"
		"cuda": return "GPU (CUDA)"
		"vaapi": return "GPU (VA-API)"
	return hw


func _spawn_audio(s: int, t := -1.0) -> void:
	_audio_start = _start_time if t < 0.0 else t
	var args := _input_args(_audio_start, _audio_url)
	args.append_array([
		"-vn", "-sn", "-dn",
		"-ac", "2", "-ar", str(int(_mix_rate)),
		"-f", "f32le", "pipe:1",
	])
	if not _spawn(args, _audio_loop, s):
		_audio_eof = true


func _input_args(t: float, url: String, hwaccel := "none") -> PackedStringArray:
	var a := PackedStringArray(["-hide_banner", "-loglevel", "error", "-nostdin"])
	if hwaccel != "none":
		a.append_array(["-hwaccel", hwaccel])
	if url.begins_with("http"):
		a.append_array(["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"])
		if _user_agent != "":
			a.append_array(["-user_agent", _user_agent])
	if t > 0.0:
		a.append_array(["-ss", "%.3f" % t])
	a.append_array(["-i", url])
	return a


func _spawn(args: PackedStringArray, loop: Callable, s: int) -> bool:
	var p := OS.execute_with_pipe(Bin.find("ffmpeg"), args)
	if p.is_empty():
		return false
	_procs.append(p.pid)
	_pipes.append(p.stdio)
	_pipes.append(p.stderr)
	var th := Thread.new()
	_threads.append(th)
	th.start(loop.bind(s, p.stdio, p.stderr))
	return true


func _stop_decoders() -> void:
	_session += 1 # tells running threads to bail out
	for pid in _procs:
		OS.kill(pid) # unblocks any thread stuck reading the pipe
	for th in _threads:
		if th.is_started():
			th.wait_to_finish()
	for f in _pipes:
		f.close()
	_procs.clear()
	_threads.clear()
	_pipes.clear()


func _make_textures() -> void:
	var y := Image.create_empty(width, height, false, Image.FORMAT_R8)
	y.fill(Color(16.0 / 255.0, 0, 0))
	var c := Image.create_empty(width >> 1, height >> 1, false, Image.FORMAT_RG8)
	c.fill(Color(0.5, 0.5, 0))
	tex_y = ImageTexture.create_from_image(y)
	tex_uv = ImageTexture.create_from_image(c)


# --- Worker threads -----------------------------------------------------------------------------

func _video_loop(s: int, pipe: FileAccess, err: FileAccess) -> void:
	var w := width
	var h := height
	var cw := w >> 1
	var ch := h >> 1
	var ysize := w * h
	var uvsize := cw * ch * 2 # interleaved U,V
	var start := _start_time
	var frame_dur := 1.0 / fps
	var n := 0
	while s == _session:
		var y := _read_exact(pipe, ysize, s)
		var uv := _read_exact(pipe, uvsize, s) if y.size() == ysize else PackedByteArray()
		if uv.size() < uvsize:
			break
		var frame := [
			start + n * frame_dur,
			Image.create_from_data(w, h, false, Image.FORMAT_R8, y),
			Image.create_from_data(cw, ch, false, Image.FORMAT_RG8, uv),
		]
		n += 1
		while s == _session:
			_mutex.lock()
			var ok := _vqueue.size() < MAX_VIDEO_QUEUE
			if ok:
				_vqueue.append(frame)
				_video_got_data = true
			_mutex.unlock()
			if ok:
				break
			OS.delay_msec(2)
	if s == _session:
		var msg := err.get_buffer(4096).get_string_from_utf8().strip_edges()
		_mutex.lock()
		_video_eof = true
		if msg != "":
			_error_text = msg
		_mutex.unlock()


func _audio_loop(s: int, pipe: FileAccess, err: FileAccess) -> void:
	var chunk_bytes := AUDIO_CHUNK_FRAMES * 8 # 2 channels * 4-byte float
	while s == _session:
		var buf := _read_exact(pipe, chunk_bytes, s)
		var floats := buf.to_float32_array()
		var frames := floats.size() >> 1
		if frames > 0:
			var chunk := PackedVector2Array()
			chunk.resize(frames)
			for i in frames:
				chunk[i] = Vector2(floats[i * 2], floats[i * 2 + 1])
			while s == _session:
				_mutex.lock()
				var ok := _aqueue.size() < MAX_AUDIO_QUEUE
				if ok:
					_aqueue.append(chunk)
					_audio_got_data = true
				_mutex.unlock()
				if ok:
					break
				OS.delay_msec(5)
		if buf.size() < chunk_bytes:
			break
	if s == _session:
		var msg := err.get_buffer(4096).get_string_from_utf8().strip_edges()
		if msg != "":
			push_warning("ffmpeg (audio): " + msg)
		_mutex.lock()
		_audio_eof = true
		_mutex.unlock()


## Pipes return ~32 KB per read, but get_buffer(n) allocates and zero-fills n bytes on every call,
## so asking for a whole 12 MB frame at once is ~12x slower than asking in pipe-sized pieces.
const PIPE_CHUNK := 65536

func _read_exact(pipe: FileAccess, size: int, s: int) -> PackedByteArray:
	var buf := pipe.get_buffer(mini(size, PIPE_CHUNK))
	while buf.size() < size and s == _session:
		var more := pipe.get_buffer(mini(size - buf.size(), PIPE_CHUNK))
		if more.is_empty():
			break # EOF or process killed
		buf.append_array(more)
	return buf
