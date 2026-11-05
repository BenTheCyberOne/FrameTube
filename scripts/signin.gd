class_name SignIn
extends Node
## "Sign in to YouTube" from inside FrameTube.
##
## Opens a real browser window with a fresh, private FrameTube profile at Google's sign-in page,
## watches for the YouTube login to appear, copies it to user://cookies.txt (which yt-dlp then uses),
## closes the window and deletes the profile.
##
## Why a throwaway profile: YouTube keeps replacing ("rotating") the login cookies of any browser
## that has YouTube open, which quietly breaks copies of them. This profile is closed the moment the
## login exists and is never opened again, so the copy FrameTube keeps stays valid much longer than
## one read out of the user's everyday browser. yt-dlp refreshes the copy itself as it's used.
##
## Firefox:  the cookies are read from the profile with yt-dlp (Firefox stores them unencrypted).
## Chromium: (Chrome, Edge, Brave, Chromium) the cookies are read live over the browser's local
##           DevTools connection, which sidesteps Chrome's cookie encryption, then the browser is
##           told to close. FrameTube never attaches to the page itself, so the sign-in page sees
##           an ordinary browser.

signal progress(text: String)
signal finished(ok: bool, message: String)

const SIGNIN_URL := "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252F"
const LOGIN_COOKIE := "LOGIN_INFO" # set on youtube.com once the account is signed in there
const SESSION_COOKIES := ["__Secure-3PSID", "__Secure-1PSID", "SAPISID"]
const KEEP_DOMAINS := ["youtube.com", "google.com"]
const TIMEOUT := 15 * 60.0
const POLL_EVERY := 2.0

## Test hooks: another start page, headless browser, an output file, a cookie that counts as "signed in".
var start_url := SIGNIN_URL
var headless := false
var out_path := ""
var test_cookie := ""

var browser := {}
var _state := "idle" # idle | waiting | closing
var _pid := -1
var _profile := ""
var _t := 0.0
var _poll_t := 0.0
var _close_t := 0.0
var _ws: WebSocketPeer
var _ws_url := ""
var _msg_id := 0
var _thread: Thread
var _busy := false
var _result_ok := false
var _result_msg := ""


func active() -> bool:
	return _state != "idle"


static func cookies_path() -> String:
	return OS.get_user_data_dir().path_join("cookies.txt")


static func signed_in() -> bool:
	var f := cookies_path()
	if not FileAccess.file_exists(f):
		return false
	return _has_login(_parse_netscape(FileAccess.get_file_as_string(f)), "")


static func sign_out() -> void:
	DirAccess.remove_absolute(cookies_path())


## Browsers found on this machine, best first. Firefox leads: nothing at all is attached to it.
static func available() -> Array:
	var list := []
	if OS.get_name() == "Windows":
		var pf := OS.get_environment("ProgramFiles")
		var pf86 := OS.get_environment("ProgramFiles(x86)")
		var la := OS.get_environment("LOCALAPPDATA")
		var cands := [
			["Firefox", "firefox", ["/Mozilla Firefox/firefox.exe"]],
			["Chrome", "chromium", ["/Google/Chrome/Application/chrome.exe"]],
			["Edge", "chromium", ["/Microsoft/Edge/Application/msedge.exe"]],
			["Brave", "chromium", ["/BraveSoftware/Brave-Browser/Application/brave.exe"]],
		]
		for c in cands:
			for root in [pf, pf86, la]:
				var p: String = root + c[2][0]
				if root != "" and FileAccess.file_exists(p):
					list.append({"name": c[0], "kind": c[1], "cmd": p, "pre": [], "root": ""})
					break
		return list
	# Linux / SteamOS: a native install, else a Flatpak (SteamOS's Discover store installs Flatpaks).
	var home := OS.get_environment("HOME")
	var flatpak := _which(["flatpak"])
	var cands := [
		["Firefox", "firefox", ["firefox"], "org.mozilla.firefox"],
		["Chrome", "chromium", ["google-chrome-stable", "google-chrome"], "com.google.Chrome"],
		["Chromium", "chromium", ["chromium", "chromium-browser"], "org.chromium.Chromium"],
		["Edge", "chromium", ["microsoft-edge-stable", "microsoft-edge"], "com.microsoft.Edge"],
		["Brave", "chromium", ["brave-browser", "brave"], "com.brave.Browser"],
	]
	for c in cands:
		var native := _which(c[2])
		if native != "":
			list.append({"name": c[0], "kind": c[1], "cmd": native, "pre": [], "root": ""})
			continue
		var id: String = c[3]
		if flatpak != "" and (DirAccess.dir_exists_absolute("/var/lib/flatpak/app/" + id)
				or DirAccess.dir_exists_absolute(home + "/.local/share/flatpak/app/" + id)):
			# A Flatpak can only write inside its own data folder, so the profile goes there.
			list.append({"name": c[0], "kind": c[1], "cmd": flatpak, "pre": ["run", id],
				"root": home + "/.var/app/" + id})
	return list


## Opens the sign-in window. `choice` picks among available() (wraps around).
func start(choice := 0) -> void:
	if active():
		return
	var list := available()
	if list.is_empty():
		finished.emit(false, "No web browser found to sign in with. Install Firefox, then try again." +
			(" (On the Steam Frame: Desktop Mode > Discover > Firefox.)" if OS.get_name() != "Windows" else ""))
		return
	browser = list[choice % list.size()]
	var root: String = browser.root if browser.root != "" else OS.get_user_data_dir()
	_profile = root.path_join("frametube-signin")
	if OS.get_name() == "Windows":
		_profile = _profile.replace("/", "\\") # Firefox won't take a forward-slash profile path
	_rmtree(_profile)
	DirAccess.make_dir_recursive_absolute(_profile)

	var args := PackedStringArray(browser.pre)
	if browser.kind == "firefox":
		_write_firefox_prefs()
		args.append_array(["--no-remote", "--profile", _profile])
		if headless:
			args.append("--headless")
		args.append_array(["--new-window", start_url])
	else:
		args.append_array(["--user-data-dir=" + _profile, "--remote-debugging-port=0",
			"--no-first-run", "--no-default-browser-check", "--disable-sync", "--password-store=basic",
			"--new-window"])
		if headless:
			args.append("--headless=new")
		args.append(start_url)
	_pid = OS.create_process(browser.cmd, args)
	if _pid <= 0:
		finished.emit(false, "Couldn't open %s. Try again, or install Firefox." % browser.name)
		return
	_state = "waiting"
	_t = 0.0
	_poll_t = 3.0 # give the browser a moment to start
	_ws = null
	_ws_url = ""
	progress.emit("A %s window opened on the %s. Sign in to YouTube there; it closes by itself when you're done." %
		[browser.name, "computer screen" if OS.get_name() == "Windows" else "screen"])


func cancel() -> void:
	if active():
		_finish(false, "Sign-in cancelled.")


func _process(delta: float) -> void:
	if _state == "idle":
		return
	_t += delta
	if _ws != null:
		_pump_ws()
	if _state == "closing":
		# Let the browser shut down on its own (it writes its files), then make sure it's gone.
		_close_t -= delta
		if _close_t <= 0.0 or not OS.is_process_running(_pid):
			_kill_and_clean()
			_state = "idle"
			finished.emit(_result_ok, _result_msg)
		return
	if _t > TIMEOUT:
		_finish(false, "Sign-in took too long, so FrameTube closed the window. Try again when you're ready.")
		return
	if not OS.is_process_running(_pid):
		if browser.kind == "firefox" and not _busy:
			_export_firefox(true) # one last look: maybe they signed in and closed it themselves
		elif browser.kind != "firefox":
			_finish(false, "The sign-in window was closed before you finished signing in.")
		return
	_poll_t -= delta
	if _poll_t > 0.0:
		return
	_poll_t = POLL_EVERY
	if browser.kind == "firefox":
		if not _busy:
			_export_firefox(false)
	else:
		_poll_chromium()


# --- Firefox ------------------------------------------------------------------------------------

func _write_firefox_prefs() -> void:
	var prefs := [
		'user_pref("browser.shell.checkDefaultBrowser", false);',
		'user_pref("browser.aboutwelcome.enabled", false);',
		'user_pref("trailhead.firstrun.didSeeAboutWelcome", true);',
		'user_pref("browser.startup.homepage_override.mstone", "ignore");',
		'user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);',
		'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
		'user_pref("browser.sessionstore.resume_from_crash", false);',
		'user_pref("signon.rememberSignons", false);',
		'user_pref("extensions.autoDisableScopes", 15);',
	]
	var f := FileAccess.open(_profile.path_join("user.js"), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(prefs) + "\n")


func _export_firefox(final: bool) -> void:
	_busy = true
	var profile := _profile
	_thread = Thread.new()
	_thread.start(func():
		var tmp := OS.get_user_data_dir().path_join("signin-export.txt")
		DirAccess.remove_absolute(tmp)
		# No URL: yt-dlp still writes the cookie jar, then exits with a usage error. No network used.
		Bin.run("yt-dlp", PackedStringArray(["--ignore-config", "--cookies-from-browser", "firefox:" + profile,
			"--cookies", tmp]))
		var text := FileAccess.get_file_as_string(tmp) if FileAccess.file_exists(tmp) else ""
		DirAccess.remove_absolute(tmp)
		_on_firefox_export.call_deferred(_parse_netscape(text), final))


func _on_firefox_export(cookies: Array, final: bool) -> void:
	_thread.wait_to_finish()
	_busy = false
	if _state != "waiting":
		return
	if _has_login(cookies, test_cookie):
		_save(cookies)
	elif final:
		_finish(false, "The sign-in window was closed before you finished signing in.")


# --- Chrome / Edge / Brave / Chromium ------------------------------------------------------------

func _poll_chromium() -> void:
	if _ws == null:
		# The browser writes its DevTools port here once it's listening (we asked for a free port).
		var f := _profile.path_join("DevToolsActivePort")
		if not FileAccess.file_exists(f):
			return
		var lines := FileAccess.get_file_as_string(f).split("\n")
		if lines.size() < 2 or lines[1].strip_edges() == "":
			return
		_ws_url = "ws://127.0.0.1:%s%s" % [lines[0].strip_edges(), lines[1].strip_edges()]
		_ws = WebSocketPeer.new()
		_ws.inbound_buffer_size = 4 << 20
		if _ws.connect_to_url(_ws_url) != OK:
			_ws = null
		return
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_cdp("Storage.getCookies")
	elif _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_ws = null # reconnect next poll


func _cdp(method: String) -> void:
	_msg_id += 1
	_ws.send_text(JSON.stringify({"id": _msg_id, "method": method}))


func _pump_ws() -> void:
	_ws.poll()
	while _ws.get_available_packet_count() > 0:
		var msg = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if not (msg is Dictionary) or _state != "waiting":
			continue
		var result = msg.get("result")
		if not (result is Dictionary) or not result.has("cookies"):
			continue
		var cookies := []
		for c in result.cookies:
			var exp := 0
			if not c.get("session", false) and float(c.get("expires", 0)) > 0:
				exp = int(c.expires)
			cookies.append({"domain": str(c.domain), "path": str(c.get("path", "/")), "secure": bool(c.get("secure", false)),
				"expires": exp, "name": str(c.name), "value": str(c.value), "http_only": bool(c.get("httpOnly", false))})
		if _has_login(cookies, test_cookie):
			_save(cookies)


# --- Shared ---------------------------------------------------------------------------------------

func _save(cookies: Array) -> void:
	var lines := PackedStringArray(["# Netscape HTTP Cookie File", "# Saved by FrameTube's sign-in. Keep this file private."])
	var n := 0
	for c in cookies:
		var d: String = c.domain
		var keep := false
		for k in KEEP_DOMAINS:
			if d == k or d.ends_with("." + k):
				keep = true
		if not keep:
			continue
		lines.append("\t".join([("#HttpOnly_" if c.http_only else "") + d, "TRUE" if d.begins_with(".") else "FALSE",
			c.path, "TRUE" if c.secure else "FALSE", str(c.expires), c.name, c.value]))
		n += 1
	var path := out_path if out_path != "" else cookies_path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_finish(false, "Signed in, but FrameTube couldn't save it. Try again.")
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["600", path])
	print("[signin] saved %d cookies from %s" % [n, browser.name])
	_finish(true, "Signed in to YouTube. Subscriptions, Watch later and age-limited videos now work.")


func _finish(ok: bool, message: String) -> void:
	_result_ok = ok
	_result_msg = message
	_state = "closing"
	_close_t = 3.0
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_cdp("Browser.close") # a polite close for Chromium browsers
	else:
		_close_t = 0.0 # Firefox: just close it


func _kill_and_clean() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	# The profile holds a live Google session; don't leave it lying around. Files can stay locked for a
	# moment while the browser exits, so try again shortly after.
	_rmtree(_profile)
	var profile := _profile
	get_tree().create_timer(3.0).timeout.connect(func(): _rmtree(profile))


static func _has_login(cookies: Array, test_name: String) -> bool:
	var login := false
	var session := false
	for c in cookies:
		if test_name != "":
			if c.name == test_name:
				return true
			continue
		if c.name == LOGIN_COOKIE and str(c.domain).ends_with("youtube.com"):
			login = true
		if c.name in SESSION_COOKIES:
			session = true
	return login and session


static func _parse_netscape(text: String) -> Array:
	var out := []
	for line in text.split("\n"):
		line = line.strip_edges(false, true)
		var http_only := line.begins_with("#HttpOnly_")
		if http_only:
			line = line.trim_prefix("#HttpOnly_")
		if line == "" or line.begins_with("#"):
			continue
		var p := line.split("\t")
		if p.size() < 7:
			continue
		out.append({"domain": p[0], "path": p[2], "secure": p[3] == "TRUE", "expires": int(p[4]),
			"name": p[5], "value": p[6], "http_only": http_only})
	return out


static func _which(names: Array) -> String:
	for dir in OS.get_environment("PATH").split(":"):
		for n in names:
			var p: String = dir.path_join(n)
			if dir != "" and FileAccess.file_exists(p):
				return p
	return ""


static func _rmtree(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_rmtree(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
