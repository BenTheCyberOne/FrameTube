extends Node3D
## FrameTube: builds the scene in code. Runs in OpenXR when a runtime is available,
## otherwise in a desktop test mode (right-drag to look, click the panel).

const PROJECTIONS := ["Normal", "3D side-by-side", "360°", "360° 3D", "180°", "180° 3D", "360° (YouTube cube)"]
const QUALITIES := [1080, 1440, 2160, 2880, 4320]
const PANEL_PX := Vector2i(1500, 1050)
const PANEL_M := Vector2(1.5, 1.05)
const ACCOUNTS := ["", "firefox", "chrome", "edge", "brave", "chromium"] # yt-dlp --cookies-from-browser names
const SAVE_EVERY := 5.0
const MENU_SIZES := [["Normal", 1.0], ["Large", 1.2], ["Extra large", 1.4]]
const END_ACTIONS := ["Stop", "Replay", "Play next"]
const ACCENTS := [["Sky", Color(0.32, 0.66, 1.0)], ["Violet", Color(0.64, 0.5, 1.0)], ["Rose", Color(1.0, 0.4, 0.66)],
	["Mint", Color(0.22, 0.87, 0.73)], ["Amber", Color(1.0, 0.71, 0.3)], ["Lime", Color(0.63, 0.9, 0.38)]]

var xr_mode := false
var camera: Camera3D
var hands: Array[XRController3D] = []
var lasers := {}
var hits := {}
var flicked := {}
var active_hand: XRController3D

var engine: VideoEngine
var video_mat: ShaderMaterial
var sphere: MeshInstance3D
var screen: MeshInstance3D
var envs: Environments
var toy: FidgetToy
var accent_idx := 0
var _hand_prev := {} # controller -> last position (for swipe velocity)
var _poke_cooldown := {}
var _toy_hand: XRController3D = null
var content: Node3D
var panel: MeshInstance3D
var viewport: SubViewport
var ui: UIPanel

var store := Store.new()
var projection := 0
var quality_idx := 2
var rig: ScreenRig
var screen_hits := {} # controller -> ray hit on the video screen (or null)
var account_idx := 0
var _save_timer := 0.0
var current_url := ""
var _last_info := {}
var setup: ToolSetup
var resume_on := true
var end_action := 0
var autohide_on := true
var menu_size_idx := 0
var haptics_on := true
var _clear_confirm_until := 0.0
var _updated_after_error := false
var _last_search := ""
var _autotest_running := false
var _hint: Label3D
var _hint_shown := false
var _last_panel_use := 0.0
var search_results: Array = []
var _request := 0 # video loads
var _search_request := 0 # searches/feeds (separate, so a search never cancels a video load)
var _ptr_pos := Vector2.ZERO
var _ptr_down := false
var _scroll_accum := 0.0
var _mouse_look := false
var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	var xr := XRServer.find_interface("OpenXR")
	xr_mode = xr != null and xr.is_initialized()
	if xr_mode:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	_build_rig()
	_build_video_surfaces()
	_build_environment()
	_build_panel()
	toy = FidgetToy.new()
	add_child(toy)
	toy.touched.connect(_on_toy_touched)

	engine = VideoEngine.new()
	add_child(engine)
	engine.status.connect(ui.set_status)
	engine.decoder_changed.connect(func(hw: String): ui.set_decoder(VideoEngine._decoder_label(hw)))
	ui.decoder_pressed.connect(_cycle_decoder)
	engine.finished.connect(_on_finished)

	_load_settings()
	_set_projection(YouTube.FLAT)
	ui.auto_keyboard = xr_mode # VR: on-screen keyboard pops up when you tap the search box
	setup = ToolSetup.new()
	add_child(setup)
	setup.progress.connect(_on_setup_progress)
	setup.finished.connect(_on_setup_finished)
	ui.setup_retry_pressed.connect(_on_setup_retry)
	ui.discover_pressed.connect(_search)
	engine.playback_started.connect(_on_playback_started)
	_check_setup.call_deferred() # after _run_autotest has had a chance to set _autotest_running
	# Tracking isn't valid on the first frames; recenter once the headset pose settles.
	get_tree().create_timer(0.6).timeout.connect(_recenter)
	_run_autotest()


## Scripted playback test, driven by user args after `--`:
##   godot -- --play=<url> [--seek-at=12] [--seek-to=60] [--quit-at=24] [--shots=<dir>]
## Logs engine stats once per second, saves screenshots before the seek and at the end, then quits.
func _run_autotest() -> void:
	var opts := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			opts[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not opts.has("play"):
		return
	_autotest_running = not opts.has("welcome") # --welcome: keep the real startup list + menu auto-hide
	if opts.has("setup-test"): # --setup-test: run the real first-run download into user://bin, then quit
		_repair()
		var ok: Array = await setup.finished
		print("[setup] finished ok=%s msg=%s" % [ok[0], ok[1]])
		print("[setup] installed: ", DirAccess.get_files_at(ToolSetup.install_dir()))
		get_tree().quit()
		return
	# Tests don't touch the real settings/history unless asked (--persist), and start from 0 by default.
	store.persist = opts.has("persist")
	if not store.persist:
		store.history = []
	var seek_at := int(opts.get("seek-at", "12"))
	var seek_to := float(opts.get("seek-to", "60"))
	var quit_at := int(opts.get("quit-at", "24"))
	var shots: String = opts.get("shots", "")
	if opts.has("decoders"):
		engine.decoders = PackedStringArray(str(opts.decoders).split(","))
	print("[test] playing ", opts.play, " decoders=", engine.decoders)
	engine.status.connect(func(t: String): print("[test] status: ", t))
	panel.visible = opts.has("panel")
	if panel.visible:
		_place_panel()
	if opts.has("env"):
		envs.set_style(int(opts.env))
	if opts.has("toy"):
		toy.set_shape(int(opts.toy))
	if opts.has("accent"):
		accent_idx = int(opts.accent)
		_apply_accent()
	_refresh_setting_labels()
	if opts.has("settings"):
		ui.show_page(true)
	if opts.has("family"):
		YouTube.family_filter = opts.family == "1"
	if opts.has("end"):
		end_action = int(opts.end)
	_refresh_setting_labels()
	if opts.has("next-logic"): # "Play next" without touching YouTube: fake list, current = item 0
		search_results = [{"id": "AAAAAAAAAAA", "title": "First"}, {"id": "BBBBBBBBBBB", "title": "Second"}]
		current_url = "https://www.youtube.com/watch?v=AAAAAAAAAAA"
		end_action = 2
		var before := _request
		_on_finished()
		print("[next] status='%s' new_request=%s" % [ui.status_label.text, _request > before])
		current_url = "https://www.youtube.com/watch?v=BBBBBBBBBBB"
		_on_finished()
		print("[next] at end of list: status='%s'" % ui.status_label.text)
		get_tree().quit()
		return
	if opts.has("screen-test"):
		_screen_test.call_deferred(shots)
	if opts.has("poke-at"): # flick the toy at this second to see sparks/spin
		get_tree().create_timer(float(opts["poke-at"])).timeout.connect(
			func(): toy.poke(toy.global_position + Vector3(0.05, 0, 0.03), Vector3(-0.4, 1.0, 0.6)))
	if opts.has("file"):
		# Local file/image instead of YouTube: --play=x --file=<path> --size=WxH [--projection=N]
		var wh := str(opts.get("size", "1920x1080")).split("x")
		var info := {"title": opts.file.get_file(), "width": int(wh[0]), "height": int(wh[1]), "fps": 30.0,
			"duration": 0.0, "video_url": opts.file, "audio_url": "", "vcodec": "file", "probe": {}}
		_on_resolved(info, _request, opts.file, 0.0, opts.has("projection"))
		if opts.has("projection"):
			_set_projection(int(opts.projection))
	elif opts.has("welcome") and opts.play == "x":
		pass # startup shows its own list
	elif opts.has("search"):
		_search(str(opts.search))
	elif opts.has("feed"):
		_on_feed(str(opts.feed)) # --play=x --feed=subscriptions : list a feed instead of playing
	else:
		_play(opts.play, float(opts.get("start", "-1")))
	for sec in range(1, quit_at + 1):
		await get_tree().create_timer(1.0).timeout
		print("[test] t=%02ds %s" % [sec, JSON.stringify(engine.stats())])
		if shots != "" and (sec == seek_at - 1 or sec == quit_at):
			var path := shots.path_join("shot_%02ds.png" % sec)
			get_viewport().get_texture().get_image().save_png(path)
			viewport.get_texture().get_image().save_png(shots.path_join("panel_%02ds.png" % sec)) # menu, flat
			print("[test] screenshot ", path)
		if sec == seek_at:
			print("[test] seeking to ", seek_to)
			engine.seek(seek_to)
		if sec == int(opts.get("history-at", "-1")): # fake some watch progress on the current results
			for i in mini(3, search_results.size()):
				var r: Dictionary = search_results[i]
				var url: String = "https://www.youtube.com/watch?v=" + r.id
				store.touch(url, r.title, r.duration, r.channel, r.get("views", 0))
				store.set_position(url, r.duration * (0.25 + 0.25 * i))
			_on_feed("history")
		if sec == int(opts.get("choose-at", "-1")): # tap the first result
			print("[test] choosing result 0: ", search_results[0].title if not search_results.is_empty() else "(none)")
			_on_result_chosen(0)
		if sec == int(opts.get("seek-end-at", "-1")): # jump to 3 s before the end
			print("[test] seeking near the end of ", engine.duration)
			engine.seek(engine.duration - 3.0)
		if sec == int(opts.get("replay-at", "-1")):
			print("[test] re-opening the same video (should resume)")
			_play(opts.play)
	# --look=yaw,pitch;yaw,pitch...  (degrees; +yaw = turn right, +pitch = look up): one screenshot per view
	if opts.has("look") and shots != "":
		var i := 0
		for view in str(opts.look).split(";"):
			var yp := view.split(",")
			camera.rotation = Vector3(deg_to_rad(float(yp[1])), deg_to_rad(-float(yp[0])), 0)
			for _f in 3:
				await get_tree().process_frame
			var path := shots.path_join("look_%d.png" % i)
			get_viewport().get_texture().get_image().save_png(path)
			print("[test] view yaw=%s pitch=%s -> %s" % [yp[0], yp[1], path])
			i += 1
	print("[test] done. projection=", PROJECTIONS[projection], " title=", ui.title_label.text,
		" probe=", _last_info.get("probe", {}), " status=", ui.status_label.text)
	get_tree().quit()


## Scripted check of ScreenRig: one-hand drag, two-hand scale, push, resize, reset. Prints numbers + shots.
func _screen_test(shots: String) -> void:
	await get_tree().create_timer(1.0).timeout # let recenter run
	var cam := camera.global_position
	var report := func(step: String) -> void:
		var to_cam := (cam - screen.global_position).normalized()
		var facing := screen.global_basis.z.normalized().dot(to_cam)
		print("[screen] %-22s %s  pos=%s  facing=%.3f  label=%s" % [step, rig.describe(),
			screen.global_position.snapped(Vector3.ONE * 0.01), facing, rig.preset_label()])
		if shots != "":
			get_viewport().get_texture().get_image().save_png(shots.path_join("screen_%s.png" % step.split(" ")[0]))
	var ray_to := func(yaw_deg: float, pitch_deg: float) -> Vector3:
		return (Basis(Vector3.UP, deg_to_rad(-yaw_deg)) * Basis(Vector3.RIGHT, deg_to_rad(pitch_deg)) * Vector3.FORWARD).normalized()
	await get_tree().process_frame
	report.call("start")

	# One "hand" grabs the screen's upper-right area and swings 30 deg right, 15 deg up.
	var d0: Vector3 = ray_to.call(6.0, 4.0)
	print("[screen] grab ok: ", rig.grab("hand1", cam, d0))
	for i in 31:
		rig.drag({"hand1": [cam, ray_to.call(6.0 + i, 4.0 + i * 0.5)]})
		await get_tree().process_frame
	rig.release("hand1")
	report.call("dragged right+up")

	# Two hands: grab, then spread them from 0.4 m to 0.8 m apart -> height should double.
	var c := screen.global_position
	var l0 := cam + Vector3(-0.2, 0, 0)
	var r0 := cam + Vector3(0.2, 0, 0)
	var h_before := rig.height
	rig.grab("L", l0, (c - l0).normalized())
	rig.grab("R", r0, (c - r0).normalized())
	for i in 21:
		var s := 0.2 + 0.2 * i / 20.0
		var l := cam + Vector3(-s, 0, 0)
		var r := cam + Vector3(s, 0, 0)
		rig.drag({"L": [l, (c - l0).normalized()], "R": [r, (c - r0).normalized()]})
		await get_tree().process_frame
	rig.release("L")
	rig.release("R")
	report.call("two-hand x%.2f" % (rig.height / h_before))

	for i in 30: # thumbstick right for ~0.5 s: push away
		rig.adjust(0.0, 0.9 / 60.0)
	report.call("pushed away")
	for i in 30: # thumbstick down: shrink
		rig.adjust(-0.9 / 60.0, 0.0)
	report.call("shrunk")
	rig.next_preset()
	report.call("preset")
	_reset_screen()
	await get_tree().process_frame
	report.call("reset")


# --- Scene construction -------------------------------------------------------------------------

func _build_environment() -> void:
	envs = Environments.new()
	add_child(envs)
	envs.build(content)


func _build_rig() -> void:
	if xr_mode:
		var origin := XROrigin3D.new()
		add_child(origin)
		var cam := XRCamera3D.new()
		origin.add_child(cam)
		camera = cam
		for tracker in ["left_hand", "right_hand"]:
			var c := XRController3D.new()
			c.tracker = tracker
			c.pose = &"aim"
			origin.add_child(c)
			c.button_pressed.connect(_on_xr_button.bind(c, true))
			c.button_released.connect(_on_xr_button.bind(c, false))
			var laser := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.004, 0.004, 1.0)
			laser.mesh = bm
			var lm := StandardMaterial3D.new()
			lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			lm.albedo_color = Color(0.45, 0.75, 1.0)
			laser.material_override = lm
			c.add_child(laser)
			hands.append(c)
			lasers[c] = laser
			hits[c] = null
			flicked[c] = false
		active_hand = hands[1]
	else:
		camera = Camera3D.new()
		camera.position = Vector3(0, 1.6, 0)
		add_child(camera)
	camera.far = 1000.0


func _build_video_surfaces() -> void:
	video_mat = ShaderMaterial.new()
	video_mat.shader = preload("res://shaders/video.gdshader")

	content = Node3D.new()
	add_child(content)
	screen = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(2.4 * 16.0 / 9.0, 2.4)
	screen.mesh = qm
	screen.material_override = video_mat
	screen.position = Vector3(0, 1.6, -ScreenRig.DEFAULT_DIST)
	content.add_child(screen)
	rig = ScreenRig.new()
	add_child(rig)
	rig.setup(screen, camera, store)

	sphere = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 100.0
	sm.height = 200.0
	sm.radial_segments = 128
	sm.rings = 64
	sphere.mesh = sm
	sphere.material_override = video_mat
	sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sphere)


func _build_panel() -> void:
	viewport = SubViewport.new()
	viewport.size = PANEL_PX
	viewport.disable_3d = true
	viewport.transparent_bg = true # rounded glass corners
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	ui = UIPanel.new()
	viewport.add_child(ui)

	panel = MeshInstance3D.new()
	var pq := QuadMesh.new()
	pq.size = PANEL_M
	panel.mesh = pq
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.albedo_texture = viewport.get_texture()
	pmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# Alpha scissor: the rounded corners are cut out, the body renders as solid (opaque pass, writes
	# depth), so bright transparent things like the Synthwave grid can never show through the text.
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	pmat.alpha_scissor_threshold = 0.5
	pmat.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	panel.material_override = pmat
	add_child(panel)

	ui.submitted.connect(_on_submit)
	ui.result_chosen.connect(_on_result_chosen)
	ui.play_pause_pressed.connect(func(): engine.toggle_pause())
	ui.seek_relative.connect(func(s: float): engine.seek(engine.get_position() + s))
	ui.seek_to.connect(func(t: float): engine.seek(t))
	ui.projection_pressed.connect(_next_projection)
	ui.quality_pressed.connect(_cycle_quality)
	ui.swap_eyes_toggled.connect(_on_swap_eyes)
	ui.feed_pressed.connect(_on_feed)
	ui.account_pressed.connect(_cycle_account)
	ui.screen_size_pressed.connect(_cycle_screen)
	ui.recenter_pressed.connect(_recenter)
	ui.hide_pressed.connect(_toggle_panel)
	ui.setting_pressed.connect(_on_setting)
	ui.volume_changed.connect(_on_volume)
	ui.reset_screen_pressed.connect(_reset_screen)


# --- Frame loop ---------------------------------------------------------------------------------

func _process(delta: float) -> void:
	sphere.global_position = camera.global_position
	if xr_mode:
		_update_xr_pointers(delta)
		_update_hand_pokes(delta)
	ui.update_playback(engine.get_position(), engine.duration, engine.paused, engine.playing)
	envs.update(engine.average_color, screen.global_transform, engine.playing and screen.visible, delta)
	_save_timer += delta
	if _save_timer >= SAVE_EVERY:
		_save_timer = 0.0
		_save_position()


func _update_xr_pointers(delta: float) -> void:
	var rays := {}
	for c in hands:
		var o := c.global_position
		var d := -c.global_basis.z
		rays[c] = [o, d]
		var hit = _panel_hit(o, d)
		hits[c] = hit
		var sh = rig.hit(o, d) if hit == null else null # the panel sits in front of the screen
		screen_hits[c] = sh
		# Lasers: whenever the panel is up, or while you're handling the screen (grip held / holding it).
		var laser: MeshInstance3D = lasers[c]
		var handling := rig.holding(c) or c.is_button_pressed("grip_click")
		laser.visible = (panel.visible or handling) and c.get_has_tracking_data()
		var length := 2.0
		if hit != null:
			length = float(hit.dist)
		elif rig.holding(c):
			length = float(rig._grabs[c].dist)
		elif sh != null:
			length = float(sh.dist)
		laser.scale = Vector3(1, 1, length)
		laser.position = Vector3(0, 0, -length * 0.5)
	if rig.is_held():
		rig.drag(rays)

	if hits[active_hand] == null and not _ptr_down:
		for c in hands:
			if hits[c] != null:
				active_hand = c
	var h = hits[active_hand]
	if h != null and h.pixel.distance_to(_ptr_pos) > 0.5:
		_ptr_move(h.pixel)

	# Thumbstick: pointing at the panel -> scroll. At (or holding) the screen -> up/down resize,
	# left/right pull closer / push away. At nothing -> flick left/right to seek 10 s.
	for c in hands:
		var v := c.get_vector2("primary")
		var at_screen: bool = rig.holding(c) or screen_hits[c] != null
		if hits[c] == null and at_screen:
			var dz := func(x: float) -> float: return 0.0 if absf(x) < 0.25 else (x - signf(x) * 0.25) / 0.75
			var rs: float = dz.call(v.y) * delta * 0.9
			var ps: float = dz.call(v.x) * delta * 0.9
			if rs != 0.0 or ps != 0.0:
				rig.adjust(rs, ps, c)
			flicked[c] = absf(v.x) > 0.3 # don't fire a seek when the pointer slides off the screen
		elif hits[c] != null:
			_scroll_accum += v.y * delta * 10.0
			while _scroll_accum >= 1.0:
				_ptr_wheel(MOUSE_BUTTON_WHEEL_UP)
				_scroll_accum -= 1.0
			while _scroll_accum <= -1.0:
				_ptr_wheel(MOUSE_BUTTON_WHEEL_DOWN)
				_scroll_accum += 1.0
		elif absf(v.x) > 0.8 and not flicked[c]:
			flicked[c] = true
			engine.seek(engine.get_position() + 10.0 * signf(v.x))
		elif absf(v.x) < 0.3:
			flicked[c] = false


## Swiping a hand through the toy spins/pushes it (works with the panel hidden too).
func _update_hand_pokes(delta: float) -> void:
	for c in hands:
		var p := c.global_position
		var v: Vector3 = (p - _hand_prev.get(c, p)) / maxf(delta, 1e-4)
		_hand_prev[c] = p
		_poke_cooldown[c] = maxf(_poke_cooldown.get(c, 0.0) - delta, 0.0)
		if toy.grabbed_by == c or _poke_cooldown[c] > 0.0 or v.length() < 0.35:
			continue
		if p.distance_to(toy.global_position) < FidgetToy.RADIUS + 0.03:
			_toy_hand = c
			toy.poke(p, v)
			_poke_cooldown[c] = 0.2


func _on_toy_touched(strength: float) -> void:
	var c := _toy_hand if _toy_hand else (toy.grabbed_by as XRController3D)
	if c:
		if haptics_on:
			c.trigger_haptic_pulse("haptic", 0.0, clampf(strength, 0.15, 1.0), 0.06, 0.0)


func _on_xr_button(action: String, c: XRController3D, pressed: bool) -> void:
	match action:
		"grip_click":
			# Grip grabs the toy if your hand is on it, otherwise the screen if you're pointing at it.
			_toy_hand = c
			if pressed:
				if not toy.try_grab(c):
					rig.grab(c, c.global_position, -c.global_basis.z)
			else:
				toy.release(c)
				rig.release(c)
		"trigger_click":
			if pressed and hits[c] != null:
				active_hand = c
				_ptr_move(hits[c].pixel)
				_ptr_button(true)
			elif not pressed and _ptr_down and c == active_hand:
				_ptr_button(false)
		"by_button", "menu_button":
			if pressed:
				_toggle_panel()
		"ax_button":
			if pressed and hits[c] == null:
				engine.toggle_pause()
		"primary_click":
			if pressed:
				_recenter()


# --- Desktop test mode input --------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if viewport.gui_get_focus_owner() is LineEdit:
			viewport.push_input(event, true)
			get_viewport().set_input_as_handled()
			return
		if event.pressed and not event.echo:
			match event.keycode:
				KEY_SPACE: engine.toggle_pause()
				KEY_LEFT: engine.seek(engine.get_position() - 10.0)
				KEY_RIGHT: engine.seek(engine.get_position() + 10.0)
				KEY_TAB, KEY_H: _toggle_panel()
				KEY_R: _recenter()
				KEY_P: _next_projection()
				KEY_UP: _set_volume(ui.volume_slider.value + 0.1)
				KEY_DOWN: _set_volume(ui.volume_slider.value - 0.1)
		return
	if xr_mode:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_look = event.pressed
			return
		var hit = _mouse_hit(event.position)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if not event.pressed:
				return
			if hit != null:
				_ptr_move(hit.pixel)
				_ptr_wheel(event.button_index)
			else:
				# Over the screen: scroll resizes, Shift+scroll pushes it away / pulls it closer.
				var o := camera.project_ray_origin(event.position)
				var d := camera.project_ray_normal(event.position)
				if rig.hit(o, d) != null:
					var s := 0.08 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.08
					if event.shift_pressed:
						rig.adjust(0.0, s)
					else:
						rig.adjust(s, 0.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			# Clicking the toy flicks it (if it's in front of the panel along the ray).
			var o := camera.project_ray_origin(event.position)
			var d := camera.project_ray_normal(event.position)
			var tt := toy.hit_ray(o, d)
			if event.pressed and tt > 0.0 and (hit == null or tt < float(hit.dist)):
				toy.poke(o + d * tt, d * 1.4 + Vector3(randf_range(-0.6, 0.6), 0.7, 0.0))
				return
			if event.pressed:
				if hit != null:
					_ptr_move(hit.pixel)
					_ptr_button(true)
				else:
					viewport.gui_release_focus()
					rig.grab("mouse", o, d) # left-drag the screen to move it
			else:
				if _ptr_down:
					_ptr_button(false)
				rig.release("mouse")
	elif event is InputEventMouseMotion:
		if rig.holding("mouse"):
			rig.drag({"mouse": [camera.project_ray_origin(event.position), camera.project_ray_normal(event.position)]})
		elif _mouse_look:
			_yaw -= event.relative.x * 0.004
			_pitch = clampf(_pitch - event.relative.y * 0.004, -1.5, 1.5)
			camera.rotation = Vector3(_pitch, _yaw, 0)
		else:
			var hit = _mouse_hit(event.position)
			if hit != null:
				_ptr_move(hit.pixel)


func _mouse_hit(pos: Vector2) -> Variant:
	return _panel_hit(camera.project_ray_origin(pos), camera.project_ray_normal(pos))


# --- Panel pointer plumbing ---------------------------------------------------------------------

## Ray vs. panel quad. Returns {pixel: Vector2, dist: float} or null.
func _panel_hit(origin: Vector3, dir: Vector3) -> Variant:
	if not panel.visible:
		return null
	var inv := panel.global_transform.affine_inverse()
	var lo := inv * origin
	var ld := inv.basis * dir
	if absf(ld.z) < 1e-6:
		return null
	var t := -lo.z / ld.z
	if t <= 0.0:
		return null
	var p := lo + ld * t
	var uv := Vector2(p.x / PANEL_M.x + 0.5, 0.5 - p.y / PANEL_M.y)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return null
	return {"pixel": uv * Vector2(PANEL_PX), "dist": t}


func _ptr_move(px: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = px
	e.global_position = px
	e.relative = px - _ptr_pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if _ptr_down else 0
	_ptr_pos = px
	viewport.push_input(e, true)


func _ptr_button(pressed: bool) -> void:
	_ptr_down = pressed
	_last_panel_use = Time.get_ticks_msec() / 1000.0 # (auto-hide leaves the menu alone while you use it)
	var e := InputEventMouseButton.new()
	e.position = _ptr_pos
	e.global_position = _ptr_pos
	e.button_index = MOUSE_BUTTON_LEFT
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	e.pressed = pressed
	viewport.push_input(e, true)


func _ptr_wheel(index: MouseButton) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.position = _ptr_pos
		e.global_position = _ptr_pos
		e.button_index = index
		e.pressed = pressed
		viewport.push_input(e, true)


# --- Layout -------------------------------------------------------------------------------------

func _flat_forward() -> Vector3:
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	return fwd.normalized() if fwd.length_squared() > 1e-4 else Vector3.FORWARD


func _recenter() -> void:
	var fwd := _flat_forward()
	var yaw := atan2(-fwd.x, -fwd.z)
	var eye := camera.global_position
	content.global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(eye.x, 0.0, eye.z))
	rig.place_default(eye.y) # a hand-placed screen keeps its spot relative to you
	sphere.rotation = Vector3(0, yaw, 0)
	envs.set_yaw(yaw)
	# The toy rests low and to the right, within arm's reach and outside the panel.
	var toy_spot := Vector3(0.45, eye.y - 0.55, -0.42) if xr_mode else Vector3(0.85, eye.y - 0.12, -0.9)
	toy.set_home(content.global_transform * toy_spot)
	if panel.visible:
		_place_panel()


func _place_panel() -> void:
	var fwd := _flat_forward()
	var eye := camera.global_position
	var s: float = MENU_SIZES[menu_size_idx][1] # a bigger menu sits a little further away, a little lower
	panel.scale = Vector3.ONE * s
	var pos := eye + fwd * (1.15 + 0.5 * (s - 1.0))
	pos.y = eye.y - 0.35 * s
	var basis := Basis.looking_at(fwd, Vector3.UP) * Basis(Vector3.RIGHT, deg_to_rad(-20.0))
	panel.global_transform = Transform3D(basis, pos)


func _toggle_panel() -> void:
	panel.visible = not panel.visible
	if panel.visible:
		_place_panel()
	elif _ptr_down:
		_ptr_button(false)


func _set_projection(p: int) -> void:
	projection = p
	video_mat.set_shader_parameter("mode", p)
	var flat := p <= YouTube.FLAT_SBS
	screen.visible = flat and current_url != "" # no empty black rectangle before the first video
	envs.set_flat(flat)
	sphere.visible = not flat
	_resize_screen()
	ui.set_projection_name(PROJECTIONS[p])


func _resize_screen() -> void:
	var aspect := 16.0 / 9.0
	if engine and engine.height > 0:
		aspect = float(engine.width) / engine.height
		if projection == YouTube.FLAT_SBS and aspect > 2.5:
			aspect *= 0.5 # full-width SBS: each eye is half the frame
	rig.set_aspect(aspect)


## User picked a projection by hand: apply it and remember it for this video.
func _next_projection() -> void:
	_set_projection((projection + 1) % PROJECTIONS.size())
	if current_url != "":
		store.set_projection(current_url, projection)


func _on_swap_eyes(on: bool) -> void:
	video_mat.set_shader_parameter("swap_eyes", on)
	store.set_setting("swap_eyes", on)


func _cycle_quality() -> void:
	quality_idx = (quality_idx + 1) % QUALITIES.size()
	store.set_setting("quality_idx", quality_idx)
	ui.set_quality(QUALITIES[quality_idx])
	if current_url != "" and engine.playing:
		_play(current_url, engine.get_position(), true)


# --- Settings, history & feeds ------------------------------------------------------------------

func _load_settings() -> void:
	quality_idx = clampi(int(store.get_setting("quality_idx", 2)), 0, QUALITIES.size() - 1)
	ui.set_quality(QUALITIES[quality_idx])
	ui.set_screen_size(rig.preset_label())
	rig.changed.connect(_on_screen_changed)
	var dec := engine.decoders.find(str(store.get_setting("decoder", engine.decoders[0])))
	engine.preferred_decoder = maxi(dec, 0)
	engine.decoder_index = engine.preferred_decoder
	ui.set_decoder(VideoEngine._decoder_label(engine.decoders[engine.decoder_index]))
	var swap := bool(store.get_setting("swap_eyes", false))
	ui.swap_btn.set_pressed_no_signal(swap)
	video_mat.set_shader_parameter("swap_eyes", swap)
	account_idx = maxi(ACCOUNTS.find(str(store.get_setting("account", ""))), 0)
	_apply_account()
	accent_idx = clampi(int(store.get_setting("accent_idx", 0)), 0, ACCENTS.size() - 1)
	envs.bias_light = bool(store.get_setting("bias", true))
	envs.bloom = bool(store.get_setting("bloom", true))
	envs.set_style(clampi(int(store.get_setting("environment", 0)), 0, Environments.STYLES.size() - 1))
	toy.set_shape(clampi(int(store.get_setting("toy", 0)), 0, FidgetToy.SHAPES.size() - 1))
	resume_on = bool(store.get_setting("resume", true))
	end_action = clampi(int(store.get_setting("end_action", 0)), 0, END_ACTIONS.size() - 1)
	autohide_on = bool(store.get_setting("autohide", true))
	menu_size_idx = clampi(int(store.get_setting("menu_size", 0)), 0, MENU_SIZES.size() - 1)
	haptics_on = bool(store.get_setting("haptics", true))
	YouTube.family_filter = bool(store.get_setting("family", true)) # on by default
	var vol := clampf(float(store.get_setting("volume", 1.0)), 0.0, 1.0)
	ui.volume_slider.set_value_no_signal(vol)
	_apply_volume(vol)
	_apply_accent()
	_refresh_setting_labels()


func _on_volume(v: float) -> void:
	_apply_volume(v)
	store.set_setting("volume", v)


func _set_volume(v: float) -> void:
	ui.volume_slider.value = clampf(v, 0.0, 1.0) # emits value_changed -> _on_volume


func _apply_volume(v: float) -> void:
	AudioServer.set_bus_mute(0, v <= 0.001)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v, 0.001)))


func _on_setting(key: String) -> void:
	match key:
		"environment":
			envs.set_style((envs.style + 1) % Environments.STYLES.size())
			store.set_setting("environment", envs.style)
		"toy":
			toy.set_shape((toy.shape + 1) % FidgetToy.SHAPES.size())
			store.set_setting("toy", toy.shape)
		"accent":
			accent_idx = (accent_idx + 1) % ACCENTS.size()
			store.set_setting("accent_idx", accent_idx)
			_apply_accent()
		"bias":
			envs.set_bias_light(not envs.bias_light)
			store.set_setting("bias", envs.bias_light)
		"bloom":
			envs.set_bloom(not envs.bloom)
			store.set_setting("bloom", envs.bloom)
		"repair":
			_repair()
		"resume":
			resume_on = not resume_on
			store.set_setting("resume", resume_on)
		"end_action":
			end_action = (end_action + 1) % END_ACTIONS.size()
			store.set_setting("end_action", end_action)
		"autohide":
			autohide_on = not autohide_on
			store.set_setting("autohide", autohide_on)
		"menu_size":
			menu_size_idx = (menu_size_idx + 1) % MENU_SIZES.size()
			store.set_setting("menu_size", menu_size_idx)
			_place_panel()
		"family":
			YouTube.family_filter = not YouTube.family_filter
			store.set_setting("family", YouTube.family_filter)
			ui.set_status("Family-friendly filter is " + ("on. New searches leave out adult and gory videos." if YouTube.family_filter else "off."))
		"haptics":
			haptics_on = not haptics_on
			store.set_setting("haptics", haptics_on)
		"clear_history":
			var now := Time.get_ticks_msec() / 1000.0
			if store.history.is_empty():
				pass
			elif now < _clear_confirm_until: # second press within 4 s: do it
				_clear_confirm_until = 0.0
				store.history.clear()
				store.save_history()
				ui.set_status("Watch history cleared.")
			else:
				_clear_confirm_until = now + 4.0
				ui.set_setting("clear_history", "Press again to clear")
				get_tree().create_timer(4.1).timeout.connect(_refresh_setting_labels)
				return
	_refresh_setting_labels()


func _apply_accent() -> void:
	var c: Color = ACCENTS[accent_idx][1]
	ui.apply_accent(c)
	envs.set_accent(c)
	toy.set_accent(c)
	for c2 in lasers:
		(lasers[c2].material_override as StandardMaterial3D).albedo_color = c


func _refresh_setting_labels() -> void:
	ui.set_setting("environment", Environments.STYLES[envs.style])
	ui.set_setting("toy", FidgetToy.SHAPES[toy.shape])
	ui.set_setting("accent", ACCENTS[accent_idx][0])
	ui.set_setting("bias", "On" if envs.bias_light else "Off")
	ui.set_setting("bloom", "On" if envs.bloom else "Off")
	ui.set_setting("resume", "On" if resume_on else "Off")
	ui.set_setting("end_action", END_ACTIONS[end_action])
	ui.set_setting("autohide", "On" if autohide_on else "Off")
	ui.set_setting("menu_size", MENU_SIZES[menu_size_idx][0])
	ui.set_setting("family", "On" if YouTube.family_filter else "Off")
	ui.set_setting("haptics", "On" if haptics_on else "Off")
	if Time.get_ticks_msec() / 1000.0 > _clear_confirm_until:
		ui.set_setting("clear_history", "Clear (%d)" % store.history.size() if not store.history.is_empty() else "Empty")


func _cycle_decoder() -> void:
	var i := (engine.decoder_index + 1) % engine.decoders.size()
	store.set_setting("decoder", engine.decoders[i])
	engine.set_decoder(i)


func _cycle_screen() -> void:
	rig.next_preset()


func _on_screen_changed(text: String) -> void:
	ui.set_screen_size(rig.preset_label())
	ui.set_status(text)


func _reset_screen() -> void:
	rig.reset(camera.global_position.y)
	ui.set_screen_size(rig.preset_label())


func _cycle_account() -> void:
	account_idx = (account_idx + 1) % ACCOUNTS.size()
	store.set_setting("account", ACCOUNTS[account_idx])
	_apply_account()
	if ACCOUNTS[account_idx] != "":
		ui.set_status("Using your %s login. Sign in to YouTube in %s first; Chrome/Edge on Windows may block this (Firefox works best)." % [ACCOUNTS[account_idx], ACCOUNTS[account_idx].capitalize()])


func _apply_account() -> void:
	YouTube.cookies_browser = ACCOUNTS[account_idx]
	if YouTube.cookies_file() != "":
		ui.set_account("cookies.txt")
	else:
		ui.set_account(ACCOUNTS[account_idx].capitalize() if ACCOUNTS[account_idx] != "" else "Not signed in")


func _on_feed(key: String) -> void:
	if key == "history":
		search_results = []
		for h in store.history:
			search_results.append({"id": h.id, "url": h.url, "title": h.title, "duration": h.get("duration", 0.0),
				"channel": h.get("channel", ""), "views": int(h.get("views", 0)),
				"resume": store.resume_position(h.url)})
		ui.show_results(search_results)
		ui.set_status("Pick up where you left off." if not search_results.is_empty() else "Nothing watched yet.")
		return
	_search_request += 1
	ui.set_status("Loading...")
	_run_async(func(): return YouTube.feed(key), _on_search_done.bind(_search_request))


func _save_position() -> void:
	if current_url != "" and engine.playing and not engine.buffering:
		store.set_position(current_url, engine.get_position())
		store.save_history()


func _on_finished() -> void:
	match END_ACTIONS[end_action]:
		"Replay":
			ui.set_status("Playing again.")
			engine.seek(0.0)
			return
		"Play next":
			var id := Store.video_id(current_url)
			for i in search_results.size():
				if search_results[i].id == id and i + 1 < search_results.size():
					var nxt: Dictionary = search_results[i + 1]
					if current_url != "":
						store.set_position(current_url, 0.0)
					ui.set_status("Up next: " + str(nxt.title))
					_play(nxt.get("url", "https://www.youtube.com/watch?v=" + nxt.id), 0.0)
					return
			ui.set_status("That was the last video in the list.")
		_:
			ui.set_status("Finished.")
	if current_url != "":
		store.set_position(current_url, 0.0) # watched to the end: next time start over
		store.save_history()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if engine:
			_save_position()


# --- Search / playback --------------------------------------------------------------------------

## Startup: make sure the video helpers exist (download them on first run), then get going.
func _check_setup() -> void:
	ui.set_status("Starting up...")
	_run_async(ToolSetup.missing_tools, _on_missing_checked)


func _on_missing_checked(missing: PackedStringArray) -> void:
	if missing.is_empty():
		_on_ready_to_use()
	else:
		_run_setup(missing)


func _run_setup(tools: PackedStringArray) -> void:
	if not panel.visible:
		_toggle_panel()
	ui.show_setup(true)
	ui.set_status("")
	ui.set_setup_progress("Starting download...", 0.0)
	setup.install(tools)


func _on_setup_progress(text: String, fraction: float) -> void:
	ui.set_setup_progress(text, fraction)


func _on_setup_finished(ok: bool, message: String) -> void:
	if not ok:
		ui.set_setup_failed(message)
		return
	ui.show_setup(false)
	_on_ready_to_use()


func _on_setup_retry() -> void:
	_run_async(ToolSetup.missing_tools, _on_missing_checked)


## Settings > Repair: re-download every helper.
func _repair() -> void:
	_run_setup(PackedStringArray(["yt-dlp", "ffmpeg", "deno"]))


func _on_ready_to_use() -> void:
	ui.set_status("")
	_run_async(Bin.versions, _on_versions)
	# Keep yt-dlp fresh in the background (YouTube changes often).
	if ToolSetup.update_due(int(store.get_setting("ytdlp_checked", 0))):
		store.set_setting("ytdlp_checked", int(Time.get_unix_time_from_system()))
		_run_async(ToolSetup.update_ytdlp, _ignore)
	# Something to look at straight away: what you were watching, or a Discover topic.
	if _autotest_running:
		return
	if not store.history.is_empty():
		_on_feed("history")
		ui.set_status("Welcome back! Pick up where you left off, or tap a Discover topic.")
	else:
		_search(UIPanel.DISCOVER[0][1], "Here are some VR videos to get you started. Tap one to play!")


## A failed load: say what happened in plain words. If it looks like YouTube changed something,
## update yt-dlp once and retry automatically.
func _handle_error(raw: String, retry: Callable) -> void:
	push_warning("yt-dlp: " + raw)
	var e := YouTube.friendly_error(raw)
	if e.update and not _updated_after_error:
		_updated_after_error = true
		ui.set_status("Updating FrameTube's YouTube helper, one moment...")
		_run_async(ToolSetup.update_ytdlp, _retry_after_update.bind(retry))
		return
	ui.set_status(e.message)


func _retry_after_update(_ok: bool, retry: Callable) -> void:
	retry.call()


func _on_versions(v: Dictionary) -> void:
	ui.set_about("FrameTube  ·  yt-dlp %s  ·  %s" % [v["yt-dlp"], v["ffmpeg"].get_slice(" Copyright", 0)])


func _ignore(_result: Variant) -> void:
	pass


## When a video starts: tuck the menu away after a moment so it doesn't block the view (unless you're
## using it). The first time, show how to get it back.
func _on_playback_started() -> void:
	if _autotest_running:
		return
	var started_at := Time.get_ticks_msec() / 1000.0
	await get_tree().create_timer(3.0).timeout
	if not autohide_on or not panel.visible or _last_panel_use > started_at or ui.keyboard.visible:
		return
	_toggle_panel()
	if not bool(store.get_setting("menu_hint_shown", false)):
		store.set_setting("menu_hint_shown", true)
		_show_hint("Press B / Y (or Menu) to bring the menu back" if xr_mode else "Press Tab to bring the menu back")


func _show_hint(text: String) -> void:
	if _hint == null:
		_hint = Label3D.new()
		_hint.font_size = 44
		_hint.pixel_size = 0.0012
		_hint.outline_size = 10
		_hint.no_depth_test = true
		_hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_hint.position = Vector3(0, -0.28, -1.2)
		camera.add_child(_hint)
	_hint.text = text
	_hint.modulate = Color(1, 1, 1, 1)
	_hint.visible = true
	var tw := create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(_hint, "modulate:a", 0.0, 1.0)
	tw.tween_callback(func(): _hint.visible = false)


func _on_submit(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	viewport.gui_release_focus()
	if text.begins_with("http") or text.contains("youtu.be") or text.contains("youtube.com"):
		_play(text)
	else:
		_search(text)


func _search(query: String, done_message := "") -> void:
	_search_request += 1
	_last_search = query
	ui.set_status("Searching...")
	_run_async(func(): return YouTube.search(query), _on_search_done.bind(_search_request, done_message))


func _on_search_done(r: Dictionary, id: int, done_message := "") -> void:
	if id != _search_request:
		return
	if r.has("error"):
		if r.error.begins_with("This needs your YouTube account"):
			ui.set_status(r.error)
		else:
			_handle_error(r.error, func(): _search(_last_search))
		return
	_updated_after_error = false
	search_results = r.results
	ui.show_results(search_results)
	if search_results.is_empty():
		ui.set_status("Nothing found. Try other words.")
	else:
		var msg := done_message if done_message != "" else "Tap a video to play it."
		var hidden := int(r.get("hidden", 0))
		if hidden > 0:
			msg += "  (Family filter hid %d video%s.)" % [hidden, "" if hidden == 1 else "s"]
		ui.set_status(msg)


func _on_result_chosen(i: int) -> void:
	if i < search_results.size():
		var r: Dictionary = search_results[i]
		_play(r.get("url", "https://www.youtube.com/watch?v=" + r.id))


## start < 0 means "resume from history if there's a saved position".
func _play(url: String, start := -1.0, keep_projection := false) -> void:
	if setup.busy:
		return # helpers still downloading; the setup screen is up
	_save_position() # remember where we were in the previous video
	_request += 1
	if start < 0.0:
		start = store.resume_position(url) if resume_on else 0.0
	ui.set_status("Loading video..." if start <= 0.0 else "Loading, resuming at %s..." % UIPanel._fmt(start))
	var h: int = QUALITIES[quality_idx]
	_run_async(func(): return YouTube.resolve(url, h), _on_resolved.bind(_request, url, start, keep_projection))


func _on_resolved(r: Dictionary, id: int, url: String, start: float, keep_projection: bool) -> void:
	if id != _request:
		return
	if r.has("error"):
		_handle_error(r.error, func(): _play(url, start, keep_projection))
		return
	_updated_after_error = false
	current_url = url
	_last_info = r
	engine.open(r, start)
	video_mat.set_shader_parameter("tex_y", engine.tex_y)
	video_mat.set_shader_parameter("tex_uv", engine.tex_uv)
	video_mat.set_shader_parameter("has_video", true)
	var saved := store.saved_projection(url)
	if keep_projection:
		_resize_screen()
	elif saved >= 0 and saved < PROJECTIONS.size():
		_set_projection(saved) # user corrected the guess for this video before
	else:
		_set_projection(YouTube.guess_projection(r))
	store.touch(url, r.title, r.duration, r.get("channel", ""), int(r.get("views", 0)))
	_refresh_setting_labels() # history count
	ui.set_title("%s   (%dx%d %s)" % [r.title, r.width, r.height, r.vcodec.get_slice(".", 0)])


## Runs `job` on a worker thread, then calls `done(result)` on the main thread.
func _run_async(job: Callable, done: Callable) -> void:
	var th := Thread.new()
	th.start(_async_body.bind(th, job, done))


func _async_body(th: Thread, job: Callable, done: Callable) -> void:
	var r = job.call()
	_async_finish.call_deferred(th, done, r)


func _async_finish(th: Thread, done: Callable, r: Variant) -> void:
	th.wait_to_finish()
	done.call(r)
