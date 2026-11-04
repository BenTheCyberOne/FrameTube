class_name ToolSetup
extends Node
## Installs and maintains the helper programs (yt-dlp, ffmpeg, deno) so nobody has to do it by hand.
## Downloads each from its official GitHub release, verifies the published SHA-256, extracts just the
## executable, and puts it in user://bin (which Bin.find() checks). Also keeps yt-dlp up to date.

signal progress(text: String, fraction: float) # fraction < 0 = indeterminate
signal finished(ok: bool, message: String)

const YTDLP := "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
const FFMPEG := "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/"
const DENO := "https://github.com/denoland/deno/releases/latest/download/"
const UPDATE_EVERY := 3 * 24 * 3600 # check for a newer yt-dlp every 3 days

## Per platform: tool -> [asset file, checksum file, archive member to extract ("" = the asset itself), MB]
const MANIFEST := {
	"windows_x86_64": {
		"yt-dlp": [YTDLP, "yt-dlp.exe", "SHA2-256SUMS", "", 18],
		"ffmpeg": [FFMPEG, "ffmpeg-master-latest-win64-gpl.zip", "checksums.sha256", "bin/ffmpeg.exe", 200],
		"deno": [DENO, "deno-x86_64-pc-windows-msvc.zip", "deno-x86_64-pc-windows-msvc.zip.sha256sum", "deno.exe", 43],
	},
	"linux_arm64": {
		"yt-dlp": [YTDLP, "yt-dlp_linux_aarch64", "SHA2-256SUMS", "", 39],
		"ffmpeg": [FFMPEG, "ffmpeg-master-latest-linuxarm64-gpl.tar.xz", "checksums.sha256", "bin/ffmpeg", 130],
		"deno": [DENO, "deno-aarch64-unknown-linux-gnu.zip", "deno-aarch64-unknown-linux-gnu.zip.sha256sum", "deno", 40],
	},
	"linux_x86_64": {
		"yt-dlp": [YTDLP, "yt-dlp_linux", "SHA2-256SUMS", "", 35],
		"ffmpeg": [FFMPEG, "ffmpeg-master-latest-linux64-gpl.tar.xz", "checksums.sha256", "bin/ffmpeg", 130],
		"deno": [DENO, "deno-x86_64-unknown-linux-gnu.zip", "deno-x86_64-unknown-linux-gnu.zip.sha256sum", "deno", 43],
	},
}

var busy := false
var _http: HTTPRequest
var _dl_label := ""
var _dl_base := 0.0 # progress fraction before this download
var _dl_share := 0.0 # this download's share of the total


static func platform_key() -> String:
	var arch := "arm64" if OS.has_feature("arm64") else "x86_64"
	return ("windows_" if OS.get_name() == "Windows" else "linux_") + arch


static func install_dir() -> String:
	return OS.get_user_data_dir().path_join("bin")


## Tools that can't be found anywhere (bundled, user://bin, or PATH).
static func missing_tools() -> PackedStringArray:
	var missing := PackedStringArray()
	for t in ["yt-dlp", "ffmpeg", "deno"]:
		if Bin.find_local(t) != "":
			continue
		if t != "deno" and Bin.run(t, PackedStringArray(["--version" if t == "yt-dlp" else "-version"])).code != -1:
			continue # on PATH (deno is optional when absent locally: yt-dlp also looks for it on PATH)
		missing.append(t)
	return missing


func _process(_delta: float) -> void:
	if _http and _dl_label != "":
		var total := _http.get_body_size()
		var got := _http.get_downloaded_bytes()
		var f := float(got) / total if total > 0 else 0.0
		progress.emit("%s  %d / %s MB" % [_dl_label, got / 1048576, str(total / 1048576) if total > 0 else "?"],
			_dl_base + _dl_share * f)


## Install whatever is missing (or everything, with force). Emits progress, then finished.
func install(tools: PackedStringArray) -> void:
	if busy:
		return
	busy = true
	var plat := platform_key()
	if not MANIFEST.has(plat):
		busy = false
		finished.emit(false, "Automatic setup isn't available for this system (%s)." % plat)
		return
	DirAccess.make_dir_recursive_absolute(install_dir())
	var total_mb := 0.0
	for t in tools:
		total_mb += MANIFEST[plat][t][4]
	var done_mb := 0.0
	for t in tools:
		var m: Array = MANIFEST[plat][t]
		_dl_base = done_mb / total_mb
		_dl_share = m[4] / total_mb
		var err: String = await _install_one(t, m)
		if err != "":
			busy = false
			_dl_label = ""
			finished.emit(false, err)
			return
		done_mb += m[4]
	busy = false
	_dl_label = ""
	progress.emit("All set!", 1.0)
	finished.emit(true, "")


func _install_one(tool_name: String, m: Array) -> String:
	var base: String = m[0]
	var asset: String = m[1]
	var nice: String = {"yt-dlp": "YouTube helper", "ffmpeg": "video decoder", "deno": "YouTube helper (part 2)"}[tool_name]
	var tmp := OS.get_user_data_dir().path_join("download")
	DirAccess.make_dir_recursive_absolute(tmp)
	var archive := tmp.path_join(asset)

	# 1. Published checksum (small text file)
	_dl_label = ""
	progress.emit("Checking %s..." % nice, _dl_base)
	var sums: Variant = await _fetch_text(base + m[2])
	if sums == null:
		return "Couldn't reach GitHub to download the %s. Check your internet connection and try again." % nice
	var expected := _find_hash(sums, asset)
	if expected == "":
		return "Couldn't verify the %s download (no checksum published)." % nice

	# 2. The file itself
	_dl_label = "Downloading %s" % nice
	if not await _fetch_file(base + asset, archive):
		_dl_label = ""
		return "The download of the %s was interrupted. Check your internet connection and try again." % nice
	_dl_label = ""

	# 3. Verify (off the main thread: these files are big)
	progress.emit("Verifying %s..." % nice, _dl_base + _dl_share)
	var actual: String = await _in_thread(func(): return _sha256_file(archive))
	if actual != expected:
		DirAccess.remove_absolute(archive)
		return "The %s download was damaged (checksum mismatch). Please try again." % nice

	# 4. Extract + install
	progress.emit("Installing %s..." % nice, _dl_base + _dl_share)
	var dest := install_dir().path_join(tool_name + (".exe" if OS.get_name() == "Windows" else ""))
	var member: String = m[3]
	var err := ""
	if member == "":
		err = _move(archive, dest)
	elif asset.ends_with(".zip"):
		err = await _in_thread(func(): return _extract_zip(archive, member, dest))
	else:
		err = await _in_thread(func(): return _extract_tar(archive, member, dest, tmp))
	DirAccess.remove_absolute(archive)
	if err != "":
		return "Couldn't install the %s: %s" % [nice, err]
	if OS.get_name() != "Windows":
		OS.execute("chmod", PackedStringArray(["+x", dest]))
	return ""


## Keep yt-dlp current (YouTube changes often). Only touches our own managed copy. Blocking: use a thread.
static func update_ytdlp() -> bool:
	var managed := install_dir().path_join("yt-dlp" + (".exe" if OS.get_name() == "Windows" else ""))
	if not FileAccess.file_exists(managed):
		return false
	var r := Bin.run("yt-dlp", PackedStringArray(["-U"]))
	return r.code == 0


static func update_due(last_check: int) -> bool:
	return Time.get_unix_time_from_system() - last_check > UPDATE_EVERY


# --- helpers ------------------------------------------------------------------------------------

func _new_http() -> HTTPRequest:
	var h := HTTPRequest.new()
	h.use_threads = true
	h.max_redirects = 10 # GitHub release links redirect to a CDN
	h.timeout = 0.0
	add_child(h)
	return h


func _fetch_text(url: String) -> Variant:
	var h := _new_http()
	h.request(url)
	var res: Array = await h.request_completed
	h.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return null
	return (res[3] as PackedByteArray).get_string_from_utf8()


func _fetch_file(url: String, path: String) -> bool:
	_http = _new_http()
	_http.download_file = path
	_http.download_chunk_size = 1 << 20
	_http.request(url)
	var res: Array = await _http.request_completed
	_http.queue_free()
	_http = null
	return res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200


## Checksum files come in a few formats ("hash  name", "hash *name", PowerShell's "Hash : HASH").
static func _find_hash(sums: String, asset: String) -> String:
	var re := RegEx.new()
	re.compile("[0-9a-fA-F]{64}")
	var lines := sums.split("\n")
	for line in lines:
		if line.contains(asset):
			var m := re.search(line)
			if m:
				return m.get_string().to_lower()
	if lines.size() < 8: # single-file checksum (deno): just take the hash
		var m := re.search(sums)
		if m:
			return m.get_string().to_lower()
	return ""


static func _sha256_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(1 << 20))
	return ctx.finish().hex_encode()


static func _extract_zip(archive: String, member: String, dest: String) -> String:
	var z := ZIPReader.new()
	if z.open(archive) != OK:
		return "couldn't open the archive"
	for name in z.get_files():
		if name == member or name.ends_with("/" + member):
			var data := z.read_file(name)
			z.close()
			return _write(dest, data)
	z.close()
	return "%s not found in the archive" % member


## .tar.xz (Linux ffmpeg): use the system tar, which every Linux (incl. SteamOS) has.
static func _extract_tar(archive: String, member: String, dest: String, tmp: String) -> String:
	var out_dir := tmp.path_join("x")
	_rmtree(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	# Extract everything: works with both GNU tar (SteamOS) and bsdtar (Windows/macOS); wildcards don't.
	var code := OS.execute("tar", PackedStringArray(["-xJf", archive, "-C", out_dir]))
	if code != 0:
		_rmtree(out_dir)
		return "tar failed (%d)" % code
	var err := "%s not found in the archive" % member
	for d in DirAccess.get_directories_at(out_dir):
		var p := out_dir.path_join(d).path_join(member)
		if FileAccess.file_exists(p):
			err = _move(p, dest)
			break
	_rmtree(out_dir)
	return err


static func _rmtree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_rmtree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


static func _move(from: String, to: String) -> String:
	if FileAccess.file_exists(to):
		DirAccess.remove_absolute(to)
	return "" if DirAccess.rename_absolute(from, to) == OK else "couldn't write %s" % to


static func _write(path: String, data: PackedByteArray) -> String:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "couldn't write %s" % path
	f.store_buffer(data)
	return ""


func _in_thread(job: Callable) -> Variant:
	var th := Thread.new()
	th.start(job)
	while th.is_alive():
		await get_tree().process_frame
	return th.wait_to_finish()
