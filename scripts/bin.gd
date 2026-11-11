class_name Bin
extends RefCounted
## Locates the helper executables (yt-dlp, ffmpeg, deno).
## Search order: <project>/bin (editor) or <exe dir>/bin (export), then user://bin, then PATH.


static func _exe(tool_name: String) -> String:
	return tool_name + (".exe" if OS.get_name() == "Windows" else "")


## Absolute path of a bundled copy, or "" if there isn't one.
static func find_local(tool_name: String) -> String:
	var exe := _exe(tool_name)
	var dirs := PackedStringArray()
	if OS.has_feature("editor"):
		dirs.append(ProjectSettings.globalize_path("res://bin"))
	else:
		dirs.append(OS.get_executable_path().get_base_dir().path_join("bin"))
	dirs.append(OS.get_user_data_dir().path_join("bin"))
	for d in dirs:
		var p := d.path_join(exe)
		if FileAccess.file_exists(p):
			make_executable(p)
			return p
	return ""


## Bundled copy if present, otherwise the bare name so the OS resolves it via PATH.
static func find(tool_name: String) -> String:
	var p := find_local(tool_name)
	return p if p != "" else _exe(tool_name)


## Blocking. Runs a tool and returns {"code": int, "out": String, "err": String}; code -1 = couldn't start.
## Reads raw bytes and decodes them as UTF-8 ourselves: OS.execute() on Windows decodes output with
## the wrong code page, which mangles non-ASCII titles ("360°" -> "360Â°").
static func run(tool_name: String, args: PackedStringArray) -> Dictionary:
	var p := OS.execute_with_pipe(find(tool_name), args)
	if p.is_empty():
		return {"code": -1, "out": "", "err": ""}
	var out := _read_all(p.stdio)
	var err := _read_all(p.stderr)
	p.stdio.close()
	p.stderr.close()
	while OS.is_process_running(p.pid):
		OS.delay_msec(5)
	var code := OS.get_process_exit_code(p.pid)
	var err_text := err.get_string_from_utf8()
	# Linux/macOS: when the program can't be started, Godot's child process prints this and kills itself
	# (exit code 9). Report it as "couldn't start", the same as on Windows.
	if err_text.begins_with("Could not create child process"):
		code = -1
	return {"code": code, "out": out.get_string_from_utf8(), "err": err_text}


## Linux/macOS: gives a file the "run" permission (rwxr-xr-x) if it's missing. If a program can't be started,
## Godot's child process kills itself, which shows up as exit code 9 with no output at all.
static func make_executable(path: String) -> void:
	if OS.get_name() == "Windows" or not FileAccess.file_exists(path):
		return
	var perms := FileAccess.get_unix_permissions(path)
	if perms & FileAccess.UNIX_EXECUTE_OWNER:
		return
	var err := FileAccess.set_unix_permissions(path, perms | 0x1ED) # 0755
	if err != OK:
		push_warning("Couldn't make %s runnable (error %d)" % [path, err])


static func _read_all(f: FileAccess) -> PackedByteArray:
	var buf := PackedByteArray()
	while true:
		var chunk := f.get_buffer(65536) # pipe-sized reads (see VideoEngine.PIPE_CHUNK)
		if chunk.is_empty():
			break
		buf.append_array(chunk)
	return buf


## Blocking. Returns {"yt-dlp": "<version or empty>", "ffmpeg": "<version or empty>"}.
static func versions() -> Dictionary:
	var r := {}
	for tool_name in ["yt-dlp", "ffmpeg"]:
		var res := run(tool_name, PackedStringArray(["--version"] if tool_name == "yt-dlp" else ["-version"]))
		r[tool_name] = res.out.get_slice("\n", 0).strip_edges() if res.code == 0 else ""
	return r
