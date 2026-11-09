class_name UIPanel
extends PanelContainer
## The control panel. It lives in a SubViewport that is drawn on a quad in 3D and
## driven by laser pointers (VR) or the mouse (desktop test mode).
## Two pages: Browse (search/feeds/results) and Settings; the player controls are always visible.

signal submitted(text: String)
signal result_chosen(index: int)
signal result_download(index: int) # the small Download button on a result card
signal play_pause_pressed
signal seek_relative(seconds: float)
signal seek_to(seconds: float)
signal projection_pressed
signal quality_pressed
signal decoder_pressed
signal swap_eyes_toggled(on: bool)
signal recenter_pressed
signal hide_pressed
signal feed_pressed(key: String) # "history" | "downloads" | "subscriptions" | "watch_later" | "recommended"
signal account_pressed
signal screen_size_pressed
signal reset_screen_pressed
signal setting_pressed(key: String) # "environment" | "toy" | "accent" | "bias" | "bloom" | "repair"
signal discover_pressed(query: String)
signal topic_remove(index: int) # Edit mode: a topic was tapped
signal topic_save # "+ Save search"
signal topic_edit # Edit / Done
signal setup_retry_pressed

const KEY_ROWS := ["1234567890-", "qwertyuiop=", "asdfghjkl:/", "zxcvbnm.?&_"]
## One-tap topics so nobody has to type to find something to watch: [label, search query, kind].
## kind ("360", "180", "flat", "") is shown as a small badge. Users can remove these and save their own.
const DISCOVER := [["Travel", "vr180 3d travel experience", "180"], ["Concerts", "vr180 concert live", "180"],
	["Nature", "360 video nature 8k", "360"], ["Roller coasters", "360 roller coaster pov", "360"],
	["Space", "360 vr space earth", "360"], ["Underwater", "360 underwater vr", "360"],
	["Relax", "4k relaxing scenery", "flat"]]
const TOPIC_BADGES := {"360": "360°", "180": "VR180", "flat": "2D"}
const QUALITY_NAMES := {0: "Auto", 1080: "HD", 1440: "2K", 2160: "4K", 2880: "5.7K", 4320: "8K"}

var auto_keyboard := false # VR: show the on-screen keyboard whenever the search box is focused
const BG := Color(0.055, 0.06, 0.085, 0.975) # near-opaque: bright grids (Synthwave) shouldn't show through
const SURFACE := Color(1, 1, 1, 0.055)
const SURFACE_HOVER := Color(1, 1, 1, 0.11)
const TEXT := Color(0.93, 0.94, 0.97)
const TEXT_DIM := Color(0.62, 0.66, 0.75)

var accent := Color(0.3, 0.64, 1.0)
var input: LineEdit
var results_scroll: ScrollContainer
var results_grid: GridContainer
var thumbs: Thumbs
## id -> label for a card's Download button ("Download", "Saving 45%", "Saved", ...). Set by main.
var card_download_text: Callable
var _card_dl := {} # video id -> that card's Download button
## id -> label for a card's second button ("Send to Steam Frame"), "" = no such button. Set by main.
var card_send_text: Callable
var _card_send := {}
signal result_send(index: int)
signal results_near_end # scrolled close to the bottom of the list: time to load more
## "Allow videos from <device>?" bar under the header
var ask_bar: PanelContainer
var ask_label: Label
signal ask_answered(allow: bool)
var status_label: Label
var title_label: Label
var clock_label: Label
var slider: HSlider
var time_label: Label
var play_btn: Button
var proj_btn: Button
var quality_btn: Button
var screen_btn: Button
var swap_btn: CheckButton
var keyboard: VBoxContainer
var browse_page: VBoxContainer
var player_box: VBoxContainer # now-playing + controls; hidden until a video has been opened
var settings_page: VBoxContainer
var setup_page: VBoxContainer
var setup_text: Label
var setup_bar: ProgressBar
var setup_retry: Button
var about_label: Label
var settings_list: VBoxContainer
var topics_box: HFlowContainer # Browse: "Discover" topic pills
var subs_btn: Button
var speed_btn: Button
var download_btn: Button
var lang_box: HFlowContainer # Settings: which subtitle languages downloads keep
signal lang_toggled(code: String)
signal download_pressed
signal subs_pressed
signal speed_pressed
var pin_page: VBoxContainer
var pin_prompt: Label
var pin_dots: Label
var pin_hint: Label
var _pin := ""
signal pin_done(code: String) # "" = cancelled
const PIN_LENGTH := 4
var volume_slider: HSlider
signal volume_changed(v: float) # 0..1
var tab_browse: Button
var tab_settings: Button

var _setting_btns := {}
var _dragging := false
var _shift := false
var _letter_keys: Array[Button] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT) # anchors alone leave it at minimum size in a SubViewport
	apply_accent(accent)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	# Header: name, page tabs, clock
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	root.add_child(header)
	var mark := TextureRect.new()
	mark.texture = load("res://icon.svg")
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.custom_minimum_size = Vector2(50, 50)
	mark.size_flags_vertical = SIZE_SHRINK_CENTER
	header.add_child(mark)
	var logo := Label.new()
	logo.text = "FrameTube"
	logo.add_theme_font_size_override("font_size", 34)
	logo.add_theme_color_override("font_color", TEXT)
	header.add_child(logo)
	var dot := Label.new()
	dot.text = "  VR"
	dot.add_theme_font_size_override("font_size", 22)
	dot.set_meta("accent_text", true)
	header.add_child(dot)
	header.add_child(_spacer())
	tab_browse = _button("Browse", func(): show_page(false))
	tab_settings = _button("Settings", func(): show_page(true))
	for t in [tab_browse, tab_settings]:
		t.toggle_mode = true
		t.theme_type_variation = &"TabButton"
		header.add_child(t)
	header.add_child(_spacer())
	clock_label = Label.new()
	clock_label.add_theme_color_override("font_color", TEXT_DIM)
	header.add_child(clock_label)

	# --- Browse page
	browse_page = VBoxContainer.new()
	browse_page.add_theme_constant_override("separation", 12)
	browse_page.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(browse_page)

	var row := HBoxContainer.new()
	browse_page.add_child(row)
	input = LineEdit.new()
	input.placeholder_text = "Search YouTube or paste a URL"
	input.size_flags_horizontal = SIZE_EXPAND_FILL
	input.custom_minimum_size.y = 64
	input.text_submitted.connect(_submit)
	input.focus_entered.connect(func(): if auto_keyboard: keyboard.visible = true)
	row.add_child(input)
	var go := _button("Search", func(): _submit(input.text))
	go.theme_type_variation = &"AccentButton"
	go.custom_minimum_size.x = 100
	row.add_child(go)
	row.add_child(_button("Paste", _paste))
	row.add_child(_button("Keys", func(): keyboard.visible = not keyboard.visible))

	var feeds := HBoxContainer.new()
	feeds.add_theme_constant_override("separation", 8)
	browse_page.add_child(feeds)
	for f in [["Continue watching", "history"], ["Downloads", "downloads"], ["Subscriptions", "subscriptions"], ["Watch later", "watch_later"],
			["For you", "recommended"]]:
		var b := _button(f[0], feed_pressed.emit.bind(f[1]))
		b.theme_type_variation = &"ChipButton"
		feeds.add_child(b)

	topics_box = HFlowContainer.new() # wraps onto a second line when there are many
	topics_box.add_theme_constant_override("h_separation", 8)
	topics_box.add_theme_constant_override("v_separation", 8)
	browse_page.add_child(topics_box)
	set_topics(DISCOVER, false, "")

	# Results: two columns of video cards in a scroll area (thumbstick / mouse wheel scrolls it).
	results_scroll = ScrollContainer.new()
	results_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	results_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	browse_page.add_child(results_scroll)
	results_grid = GridContainer.new()
	results_grid.columns = 2
	results_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	results_grid.add_theme_constant_override("h_separation", 12)
	results_grid.add_theme_constant_override("v_separation", 12)
	results_scroll.add_child(results_grid)
	results_scroll.get_v_scroll_bar().value_changed.connect(func(_v): _check_near_end())
	thumbs = Thumbs.new()
	add_child(thumbs)

	# --- Settings page
	settings_page = VBoxContainer.new()
	settings_page.add_theme_constant_override("separation", 8)
	settings_page.size_flags_vertical = SIZE_EXPAND_FILL
	settings_page.visible = false
	root.add_child(settings_page)
	var settings_scroll := ScrollContainer.new() # scrolls with the thumbstick / mouse wheel
	settings_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	settings_page.add_child(settings_scroll)
	settings_list = VBoxContainer.new()
	settings_list.size_flags_horizontal = SIZE_EXPAND_FILL
	settings_list.add_theme_constant_override("separation", 16)
	settings_scroll.add_child(settings_list)

	_section("Watching")
	_setting_row("resume", "Resume videos", "Start where you stopped last time")
	_setting_row("end_action", "When a video ends", "Stop, play it again, or play the next video in the list")
	_setting_row("autohide", "Hide the menu while watching", "Tucks the menu away a few seconds after a video starts")
	_setting_row("topics", "Discover topics", "The one-tap searches above the video list. Save your own with \"+ Save\" after searching")
	_setting_row("topics_reset", "Original topics", "Bring back the topics FrameTube came with (replaces your list)")
	_setting_row("menu_size", "Menu size", "Press for preset sizes. Or squeeze grip on the menu to move it; grip it with both hands and pull apart / push together for any size")
	_setting_row("curve", "Screen shape", "Curve the screen around you, like a cinema")
	_setting_row("subs_size", "Subtitle size", "How big subtitles are")
	_setting_row("downloads", "Saved videos", "Videos you pressed Download on. Press to open their folder")
	_setting_row("save_to", "Save downloads to", "Here, or your Steam Frame: downloads here, then goes over Wi-Fi once FrameTube is open on both")
	_setting_row("link_receive", "Receive videos from other devices", "Let FrameTube on your other devices send videos here. You'll be asked once per device")
	_setting_row("subs_save", "Subtitles to save", "Which subtitle languages are kept with downloaded videos")
	lang_box = HFlowContainer.new()
	lang_box.add_theme_constant_override("h_separation", 8)
	lang_box.add_theme_constant_override("v_separation", 8)
	lang_box.visible = false
	settings_list.add_child(lang_box)
	_section("Safety & account")
	_setting_row("family", "Family-friendly filter",
		"Hides videos with adult or gory words in them, and blocks 18+ videos")
	_setting_row("account", "YouTube account",
		"Opens a browser window to sign in. Unlocks subscriptions, Watch later & age-limited videos")
	_setting_row("clear_history", "Watch history", "Remove everything from \"Continue watching\"")
	_setting_row("pin", "Parental lock", "A 4-digit PIN is needed to turn off the filter, change the account or clear history")
	_section("Room & look")
	_setting_row("environment", "Room", "What's around you when watching normal videos")
	_setting_row("toy", "Fidget toy", "Grab it with the grip button, throw it, or swipe it to spin")
	_setting_row("toy_mode", "When you let go of the toy", "It floats back to its spot, stays where you leave it, or falls to the floor. Recenter calls it back")
	_setting_row("haptics", "Vibration", "Controllers buzz when you touch the toy")
	_setting_row("hands", "Show in VR", "Your hands, your controllers, both or neither")
	_setting_row("accent", "Colour theme", "Colour of the menu, lights and toy")
	_setting_row("bias", "Ambient glow", "The video's colours softly light up the room")
	_setting_row("bloom", "Glow effects", "Turn off if things feel slow")
	_section("Advanced")
	_setting_row("decoder", "Video decoding", "GPU is faster; it switches automatically if not supported")
	_setting_row("repair", "Repair", "Re-download FrameTube's video helpers if videos won't play")
	about_label = Label.new()
	about_label.add_theme_font_size_override("font_size", 20)
	about_label.add_theme_color_override("font_color", TEXT_DIM)
	settings_page.add_child(about_label)

	# --- Setup page (first run / repair): one-time download of the video helpers
	setup_page = VBoxContainer.new()
	setup_page.add_theme_constant_override("separation", 24)
	setup_page.size_flags_vertical = SIZE_EXPAND_FILL
	setup_page.alignment = BoxContainer.ALIGNMENT_CENTER
	setup_page.visible = false
	root.add_child(setup_page)
	var welcome := Label.new()
	welcome.text = "Welcome to FrameTube"
	welcome.add_theme_font_size_override("font_size", 44)
	welcome.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	setup_page.add_child(welcome)
	var expl := Label.new()
	expl.text = "Getting ready for the first time: downloading the video helpers (about 300 MB).\nThis only happens once and takes a few minutes."
	expl.add_theme_color_override("font_color", TEXT_DIM)
	expl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	setup_page.add_child(expl)
	setup_bar = ProgressBar.new()
	setup_bar.custom_minimum_size = Vector2(0, 36)
	setup_bar.max_value = 1.0
	setup_bar.show_percentage = false
	setup_page.add_child(setup_bar)
	setup_text = Label.new()
	setup_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	setup_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	setup_page.add_child(setup_text)
	setup_retry = _button("Try again", func(): setup_retry_pressed.emit())
	setup_retry.theme_type_variation = &"AccentButton"
	setup_retry.size_flags_horizontal = SIZE_SHRINK_CENTER
	setup_retry.custom_minimum_size.x = 260
	setup_retry.visible = false
	setup_page.add_child(setup_retry)

	# --- PIN page (parental lock): prompt, dots, 3x4 keypad
	pin_page = VBoxContainer.new()
	pin_page.add_theme_constant_override("separation", 16)
	pin_page.size_flags_vertical = SIZE_EXPAND_FILL
	pin_page.alignment = BoxContainer.ALIGNMENT_CENTER
	pin_page.visible = false
	root.add_child(pin_page)
	pin_prompt = Label.new()
	pin_prompt.add_theme_font_size_override("font_size", 34)
	pin_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pin_page.add_child(pin_prompt)
	pin_dots = Label.new()
	pin_dots.add_theme_font_size_override("font_size", 54)
	pin_dots.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pin_dots.set_meta("accent_text", true)
	pin_page.add_child(pin_dots)
	pin_hint = Label.new()
	pin_hint.add_theme_color_override("font_color", TEXT_DIM)
	pin_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pin_page.add_child(pin_hint)
	var pad := GridContainer.new()
	pad.columns = 3
	pad.size_flags_horizontal = SIZE_SHRINK_CENTER
	pad.add_theme_constant_override("h_separation", 12)
	pad.add_theme_constant_override("v_separation", 12)
	pin_page.add_child(pad)
	for k in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "Cancel", "0", "Delete"]:
		var b := _button(k, _pin_key.bind(k))
		b.custom_minimum_size = Vector2(170, 84)
		b.add_theme_font_size_override("font_size", 34 if k.length() == 1 else 24)
		pad.add_child(b)

	# --- Now playing + player controls (always visible)
	player_box = VBoxContainer.new()
	player_box.add_theme_constant_override("separation", 12)
	player_box.visible = false
	root.add_child(player_box)
	var np := HBoxContainer.new()
	player_box.add_child(np)
	title_label = Label.new()
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.size_flags_horizontal = SIZE_EXPAND_FILL
	title_label.text = "Nothing playing"
	title_label.add_theme_font_size_override("font_size", 30)
	np.add_child(title_label)
	status_label = Label.new()
	status_label.add_theme_color_override("font_color", TEXT_DIM)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.max_lines_visible = 2
	root.add_child(status_label)
	root.move_child(status_label, player_box.get_index())

	ask_bar = PanelContainer.new()
	ask_bar.add_theme_stylebox_override("panel", _sb(Color(1, 1, 1, 0.07), 14, accent, 2, 12))
	ask_bar.visible = false
	var ask_row := HBoxContainer.new()
	ask_row.add_theme_constant_override("separation", 12)
	ask_bar.add_child(ask_row)
	ask_label = Label.new()
	ask_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ask_label.size_flags_horizontal = SIZE_EXPAND_FILL
	ask_label.custom_minimum_size.x = 50
	ask_row.add_child(ask_label)
	var allow := _button("Allow", func(): ask_answered.emit(true))
	allow.theme_type_variation = &"AccentButton"
	allow.custom_minimum_size.x = 140
	ask_row.add_child(allow)
	var deny := _button("Not now", func(): ask_answered.emit(false))
	deny.custom_minimum_size.x = 140
	ask_row.add_child(deny)
	root.add_child(ask_bar)
	root.move_child(ask_bar, 1) # right under the header, on every page

	var seek_row := HBoxContainer.new()
	player_box.add_child(seek_row)
	slider = HSlider.new()
	slider.size_flags_horizontal = SIZE_EXPAND_FILL
	slider.size_flags_vertical = SIZE_SHRINK_CENTER
	slider.custom_minimum_size.y = 44
	slider.step = 0.1
	slider.focus_mode = FOCUS_NONE
	slider.drag_started.connect(func(): _dragging = true)
	slider.drag_ended.connect(_on_drag_ended)
	seek_row.add_child(slider)
	time_label = Label.new()
	time_label.custom_minimum_size.x = 250
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	time_label.add_theme_color_override("font_color", TEXT_DIM)
	seek_row.add_child(time_label)

	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 8)
	player_box.add_child(ctl)
	ctl.add_child(_button("-30s", func(): seek_relative.emit(-30.0)))
	ctl.add_child(_button("-10s", func(): seek_relative.emit(-10.0)))
	play_btn = _button("Play", func(): play_pause_pressed.emit())
	play_btn.theme_type_variation = &"AccentButton"
	play_btn.custom_minimum_size.x = 170
	ctl.add_child(play_btn)
	ctl.add_child(_button("+10s", func(): seek_relative.emit(10.0)))
	ctl.add_child(_button("+30s", func(): seek_relative.emit(30.0)))
	ctl.add_child(_spacer())
	var vol_label := Label.new()
	vol_label.text = "Volume"
	vol_label.add_theme_color_override("font_color", TEXT_DIM)
	ctl.add_child(vol_label)
	volume_slider = HSlider.new()
	volume_slider.min_value = 0.0
	volume_slider.max_value = 1.0
	volume_slider.step = 0.01
	volume_slider.value = 1.0
	volume_slider.custom_minimum_size = Vector2(220, 44)
	volume_slider.size_flags_vertical = SIZE_SHRINK_CENTER
	volume_slider.focus_mode = FOCUS_NONE
	volume_slider.value_changed.connect(func(v: float): volume_changed.emit(v))
	ctl.add_child(volume_slider)
	ctl.add_child(_spacer())
	download_btn = _button("Download", func(): download_pressed.emit())
	download_btn.tooltip_text = "Save this video to watch without internet"
	ctl.add_child(download_btn)
	ctl.add_child(_button("Recenter", func(): recenter_pressed.emit()))
	ctl.add_child(_button("Hide menu", func(): hide_pressed.emit()))

	var view := HBoxContainer.new()
	view.add_theme_constant_override("separation", 8)
	player_box.add_child(view)
	proj_btn = _button("Type: Normal", func(): projection_pressed.emit())
	proj_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	view.add_child(proj_btn)
	screen_btn = _button("Screen: M", func(): screen_size_pressed.emit())
	view.add_child(screen_btn)
	view.add_child(_button("Reset", func(): reset_screen_pressed.emit()))
	quality_btn = _button("Quality: 4K", func(): quality_pressed.emit())
	view.add_child(quality_btn)
	subs_btn = _button("Subtitles: Off", func(): subs_pressed.emit())
	view.add_child(subs_btn)
	speed_btn = _button("Speed: 1×", func(): speed_pressed.emit())
	view.add_child(speed_btn)
	swap_btn = CheckButton.new()
	swap_btn.text = "Swap eyes"
	swap_btn.tooltip_text = "Fixes 3D that looks inside out"
	swap_btn.focus_mode = FOCUS_NONE
	swap_btn.toggled.connect(func(on: bool): swap_eyes_toggled.emit(on))
	view.add_child(swap_btn)

	keyboard = _build_keyboard()
	keyboard.visible = false
	root.add_child(keyboard)
	show_page(false)


func show_page(settings: bool) -> void:
	if setup_page.visible:
		return # setup has to finish first
	browse_page.visible = not settings
	settings_page.visible = settings
	tab_browse.set_pressed_no_signal(not settings)
	tab_settings.set_pressed_no_signal(settings)


## First-run / repair screen. While it's up, the rest of the menu is hidden.
func show_setup(on: bool) -> void:
	setup_page.visible = on
	browse_page.visible = not on
	settings_page.visible = false
	for t in [tab_browse, tab_settings]:
		t.disabled = on
	setup_retry.visible = false
	if not on:
		show_page(false)


## Parental-lock keypad. Emits pin_done(code) after 4 digits, or pin_done("") on Cancel.
func show_pin(prompt: String, hint := "") -> void:
	_pin = ""
	pin_prompt.text = prompt
	pin_hint.text = hint
	pin_dots.text = "○ ○ ○ ○"
	pin_page.visible = true
	browse_page.visible = false
	settings_page.visible = false
	for t in [tab_browse, tab_settings]:
		t.disabled = true


func hide_pin(back_to_settings := true) -> void:
	pin_page.visible = false
	for t in [tab_browse, tab_settings]:
		t.disabled = false
	show_page(back_to_settings)


func _pin_key(k: String) -> void:
	match k:
		"Cancel":
			pin_done.emit("")
			return
		"Delete":
			_pin = _pin.left(-1)
		_:
			if _pin.length() < PIN_LENGTH:
				_pin += k
	pin_dots.text = " ".join(PackedStringArray(range(PIN_LENGTH).map(func(i): return "●" if i < _pin.length() else "○")))
	if _pin.length() == PIN_LENGTH:
		var code := _pin
		_pin = ""
		pin_done.emit(code)


func set_setup_progress(text: String, fraction: float) -> void:
	setup_text.text = text
	setup_text.remove_theme_color_override("font_color")
	if fraction >= 0.0:
		setup_bar.value = fraction


func set_setup_failed(message: String) -> void:
	setup_text.text = message
	setup_text.add_theme_color_override("font_color", Color(1.0, 0.6, 0.55))
	setup_retry.visible = true


func set_about(text: String) -> void:
	about_label.text = text


func _submit(text: String) -> void:
	if auto_keyboard:
		keyboard.visible = false
	submitted.emit(text)


# --- Theme --------------------------------------------------------------------------------------

## Rebuilds the whole theme around an accent colour: glassy panel, soft buttons, accent highlights.
func apply_accent(c: Color) -> void:
	accent = c
	var th := Theme.new()
	th.default_font_size = 27

	add_theme_stylebox_override("panel", _sb(BG, 30, accent * Color(1, 1, 1, 0.55), 2, 26))

	# Buttons
	var btn := _sb(SURFACE, 14)
	btn.content_margin_left = 18
	btn.content_margin_right = 18
	th.set_stylebox("normal", "Button", btn)
	th.set_stylebox("hover", "Button", _sb(SURFACE_HOVER, 14, accent * Color(1, 1, 1, 0.7), 2, 18))
	th.set_stylebox("pressed", "Button", _sb(accent * Color(0.55, 0.55, 0.55, 0.9), 14, accent, 2, 18))
	th.set_stylebox("hover_pressed", "Button", _sb(accent * Color(0.65, 0.65, 0.65, 0.95), 14, accent, 2, 18))
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_stylebox("disabled", "Button", _sb(Color(1, 1, 1, 0.02), 14))
	th.set_color("font_color", "Button", TEXT)
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_pressed_color", "Button", Color.WHITE)
	th.set_color("font_hover_pressed_color", "Button", Color.WHITE)

	# Accent (primary) buttons
	th.set_type_variation("AccentButton", "Button")
	th.set_stylebox("normal", "AccentButton", _sb(accent * Color(0.85, 0.85, 0.85, 1), 14, Color(0, 0, 0, 0), 0, 18))
	th.set_stylebox("hover", "AccentButton", _sb(accent.lightened(0.15), 14, Color(1, 1, 1, 0.5), 2, 18))
	th.set_stylebox("pressed", "AccentButton", _sb(accent.darkened(0.25), 14, Color(0, 0, 0, 0), 0, 18))
	th.set_color("font_color", "AccentButton", Color(0.03, 0.04, 0.07))
	th.set_color("font_hover_color", "AccentButton", Color(0.02, 0.02, 0.04))

	# Chips (feed shortcuts) and header tabs
	th.set_type_variation("ChipButton", "Button")
	th.set_stylebox("normal", "ChipButton", _sb(Color(1, 1, 1, 0.035), 30, Color(1, 1, 1, 0.12), 1, 20))
	th.set_stylebox("hover", "ChipButton", _sb(accent * Color(1, 1, 1, 0.22), 30, accent, 2, 20))
	th.set_type_variation("TabButton", "Button")
	th.set_stylebox("normal", "TabButton", _sb(Color(0, 0, 0, 0), 12, Color(0, 0, 0, 0), 0, 20))
	th.set_stylebox("pressed", "TabButton", _sb(accent * Color(1, 1, 1, 0.25), 12, accent, 2, 20))
	th.set_stylebox("hover_pressed", "TabButton", _sb(accent * Color(1, 1, 1, 0.32), 12, accent, 2, 20))
	th.set_color("font_color", "TabButton", TEXT_DIM)

	# Text entry
	th.set_stylebox("normal", "LineEdit", _sb(Color(0, 0, 0, 0.35), 14, Color(1, 1, 1, 0.1), 1, 18))
	th.set_stylebox("focus", "LineEdit", _sb(Color(0, 0, 0, 0.45), 14, accent, 2, 18))
	th.set_color("font_color", "LineEdit", TEXT)
	th.set_color("font_placeholder_color", "LineEdit", TEXT_DIM * Color(1, 1, 1, 0.7))
	th.set_color("caret_color", "LineEdit", accent)

	# Video cards
	th.set_type_variation("PillButton", "Button") # see-through button over a Discover pill
	th.set_stylebox("normal", "PillButton", StyleBoxEmpty.new())
	th.set_stylebox("hover", "PillButton", _sb(accent * Color(1, 1, 1, 0.18), 30, accent, 2, 0))
	th.set_stylebox("pressed", "PillButton", _sb(accent * Color(1, 1, 1, 0.32), 30, accent, 2, 0))
	th.set_stylebox("hover_pressed", "PillButton", _sb(accent * Color(1, 1, 1, 0.32), 30, accent, 2, 0))
	th.set_type_variation("CardButton", "Button")
	th.set_stylebox("normal", "CardButton", StyleBoxEmpty.new()) # the card panel underneath draws the resting look
	th.set_stylebox("hover", "CardButton", _sb(accent * Color(1, 1, 1, 0.14), 18, accent, 2, 0))
	th.set_stylebox("pressed", "CardButton", _sb(accent * Color(1, 1, 1, 0.3), 18, accent, 2, 0))
	th.set_stylebox("hover_pressed", "CardButton", _sb(accent * Color(1, 1, 1, 0.3), 18, accent, 2, 0))

	# Results list (legacy)
	th.set_stylebox("panel", "ItemList", _sb(Color(0, 0, 0, 0.25), 16, Color(1, 1, 1, 0.06), 1, 10))
	th.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	th.set_stylebox("hovered", "ItemList", _sb(SURFACE_HOVER, 10))
	th.set_stylebox("selected", "ItemList", _sb(accent * Color(1, 1, 1, 0.3), 10))
	th.set_stylebox("selected_focus", "ItemList", _sb(accent * Color(1, 1, 1, 0.38), 10))
	th.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	th.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	th.set_constant("v_separation", "ItemList", 10)
	th.set_color("font_color", "ItemList", TEXT)
	th.set_color("font_hovered_color", "ItemList", Color.WHITE)
	th.set_color("font_selected_color", "ItemList", Color.WHITE)
	th.set_color("guide_color", "ItemList", Color(0, 0, 0, 0))

	# Scrollbars (results)
	var grab := _sb(Color(1, 1, 1, 0.18), 8)
	grab.content_margin_left = 6
	grab.content_margin_right = 6
	th.set_stylebox("grabber", "VScrollBar", grab)
	th.set_stylebox("grabber_highlight", "VScrollBar", _sb(accent * Color(1, 1, 1, 0.8), 8))
	th.set_stylebox("grabber_pressed", "VScrollBar", _sb(accent, 8))
	th.set_stylebox("scroll", "VScrollBar", _sb(Color(0, 0, 0, 0), 8))

	# Seek bar
	var track := _sb(Color(1, 1, 1, 0.12), 6)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	th.set_stylebox("slider", "HSlider", track)
	var filled := _sb(accent, 6)
	filled.content_margin_top = 4
	filled.content_margin_bottom = 4
	th.set_stylebox("grabber_area", "HSlider", filled)
	th.set_stylebox("grabber_area_highlight", "HSlider", filled)
	th.set_stylebox("background", "ProgressBar", _sb(Color(1, 1, 1, 0.1), 18, Color(0, 0, 0, 0), 0, 0))
	th.set_stylebox("fill", "ProgressBar", _sb(accent, 18, Color(0, 0, 0, 0), 0, 0))

	th.set_color("font_color", "Label", TEXT)
	th.set_color("font_color", "CheckButton", TEXT)
	th.set_color("font_hover_color", "CheckButton", Color.WHITE)
	th.set_color("font_pressed_color", "CheckButton", TEXT)
	theme = th
	_recolor_accent_text(self)


func _recolor_accent_text(n: Node) -> void:
	if n is Label and n.has_meta("accent_text"):
		n.add_theme_color_override("font_color", accent)
	for c in n.get_children():
		_recolor_accent_text(c)


static func _sb(bg: Color, radius: int, border := Color(0, 0, 0, 0), border_w := 0, margin := 14) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_content_margin_all(margin)
	s.anti_aliasing = true
	return s


# --- Public setters -----------------------------------------------------------------------------

func set_status(text: String) -> void:
	status_label.text = text


func set_title(text: String) -> void:
	title_label.text = text


func set_projection_name(text: String) -> void:
	proj_btn.text = "Type: " + text


## height 0 = Auto; `playing` (smaller side of the current video, 0 = none) is shown next to "Auto".
func set_quality(height: int, playing := 0) -> void:
	var t: String = QUALITY_NAMES.get(height, "%dp" % height)
	if height == 0 and playing > 0:
		t += " (%s)" % quality_name(playing)
	quality_btn.text = "Quality: " + t


## 3840 -> "8K", 1920 -> "4K", ... (by the video's smaller side, as yt-dlp's "res" counts it).
static func quality_name(res: int) -> String:
	if res >= 3600: return "8K"
	if res >= 2560: return "5.7K"
	if res >= 1800: return "4K"
	if res >= 1300: return "2K"
	if res >= 1000: return "HD"
	return "%dp" % res


func set_decoder(label: String) -> void:
	set_setting("decoder", label)


func set_account(label: String) -> void:
	set_setting("account", label)


func set_screen_size(label: String) -> void:
	screen_btn.text = "Screen: " + label


func set_setting(key: String, value: String) -> void:
	if _setting_btns.has(key):
		_setting_btns[key].text = value


## items: {id, title, [duration, channel, views, description, live, verified, resume]}
func show_results(items: Array) -> void:
	thumbs.cancel_pending()
	_card_dl.clear()
	_card_send.clear()
	for c in results_grid.get_children():
		c.queue_free()
	for i in items.size():
		results_grid.add_child(_make_card(items[i], i))
	results_scroll.scroll_vertical = 0
	show_page(false)


## More cards at the end of the list (infinite scrolling). first_index: index of items[0] overall.
func append_results(items: Array, first_index: int) -> void:
	for i in items.size():
		results_grid.add_child(_make_card(items[i], first_index + i))


func _check_near_end() -> void:
	var sb := results_scroll.get_v_scroll_bar()
	if results_grid.get_child_count() > 0 and sb.max_value - (sb.value + sb.page) < 700.0:
		results_near_end.emit()


const THUMB := Vector2(240, 135)
const DL_W := 165.0 # width of a card's Download button

## One result: [thumbnail with VR badges / duration / live tag / resume bar] [title, channel · views, snippet]
## The card is a PanelContainer (so it grows to fit its content) with a transparent Button stacked on
## top that takes the clicks and draws the hover/pressed highlight.
func _make_card(it: Dictionary, index: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _sb(Color(1, 1, 1, 0.035), 18, Color(1, 1, 1, 0.06), 1, 12))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	card.add_child(row)

	# Thumbnail, clipped to rounded corners by its (opaque: the clip uses its alpha) panel.
	var frame := PanelContainer.new()
	frame.custom_minimum_size = THUMB
	frame.size_flags_vertical = SIZE_SHRINK_CENTER # stays 16:9 even when the text makes the card taller
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	frame.add_theme_stylebox_override("panel", _sb(Color(0.13, 0.14, 0.18, 1.0), 12, Color(0, 0, 0, 0), 0, 0))
	row.add_child(frame)
	var pic := TextureRect.new()
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pic.custom_minimum_size = THUMB
	frame.add_child(pic)
	thumbs.fetch(str(it.get("id", "")), pic.set_texture)
	var overlay := Control.new() # chips drawn over the picture
	frame.add_child(overlay)
	var dur: float = it.get("duration", 0.0)
	if it.get("live", false):
		overlay.add_child(_corner(_chip("LIVE", Color(0.85, 0.12, 0.15), Color.WHITE, Vector2.ZERO), false))
	elif dur > 0.0:
		overlay.add_child(_corner(_chip(_fmt(dur), Color(0, 0, 0, 0.78), Color.WHITE, Vector2.ZERO), true))
	var resume: float = it.get("resume", 0.0)
	if resume > 0.0 and dur > 0.0: # how far you got, like YouTube's red bar
		var bar_bg := ColorRect.new()
		bar_bg.color = Color(1, 1, 1, 0.25)
		bar_bg.position = Vector2(0, THUMB.y - 5)
		bar_bg.size = Vector2(THUMB.x, 5)
		overlay.add_child(bar_bg)
		var bar := ColorRect.new()
		bar.color = accent
		bar.position = bar_bg.position
		bar.size = Vector2(THUMB.x * clampf(resume / dur, 0.03, 1.0), 5)
		overlay.add_child(bar)

	# Text
	var text := VBoxContainer.new()
	text.size_flags_horizontal = SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 4)
	row.add_child(text)
	var title := Label.new()
	title.text = it.get("title", "")
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.max_lines_visible = 2
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_font_size_override("font_size", 25)
	title.custom_minimum_size.x = 50 # let it wrap instead of widening the card
	text.add_child(title)
	var meta := PackedStringArray()
	if str(it.get("channel", "")) != "":
		meta.append(it.channel + (" ✓" if it.get("verified", false) else ""))
	if int(it.get("views", 0)) > 0:
		meta.append(_views(int(it.views)))
	if resume > 0.0:
		meta.append("resume at " + _fmt(resume))
	if not meta.is_empty():
		var m := Label.new()
		m.text = "  ·  ".join(meta)
		m.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		m.custom_minimum_size.x = 50
		m.add_theme_font_size_override("font_size", 21)
		m.add_theme_color_override("font_color", TEXT_DIM)
		text.add_child(m)
	var desc := str(it.get("description", ""))
	if desc != "":
		var dl := Label.new()
		dl.text = desc
		dl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		dl.custom_minimum_size.x = 50
		dl.add_theme_font_size_override("font_size", 19)
		dl.add_theme_color_override("font_color", TEXT_DIM * Color(1, 1, 1, 0.75))
		text.add_child(dl)
	# VR / resolution badges on the thumbnail's top-left corner
	var badges := YouTube.title_badges(str(it.get("title", "")), false)
	if not badges.is_empty():
		var bx := HBoxContainer.new()
		bx.add_theme_constant_override("separation", 5)
		bx.position = Vector2(8, 8)
		for b in badges:
			bx.add_child(_chip(b, accent.darkened(0.35) * Color(1, 1, 1, 0.92), Color.WHITE, Vector2.ZERO))
		overlay.add_child(bx)

	var id := str(it.get("id", ""))
	var has_dl: bool = id != "" and not it.get("live", false)
	if has_dl: # keep the text clear of the Download button (which sits in the layer on top)
		var reserve := Control.new()
		reserve.custom_minimum_size.x = DL_W
		row.add_child(reserve)
	_ignore_mouse(row)
	var hit := Button.new() # on top of everything: the whole card is one big button
	hit.theme_type_variation = &"CardButton"
	hit.focus_mode = FOCUS_NONE
	hit.pressed.connect(func(): result_chosen.emit(index))
	card.add_child(hit)
	# Download button on the card's right edge, above the card button so it gets its own clicks;
	# in the Downloads list a "Send to ..." button can sit above it.
	if has_dl:
		var layer := Control.new()
		layer.mouse_filter = MOUSE_FILTER_IGNORE
		card.add_child(layer)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 8)
		col.mouse_filter = MOUSE_FILTER_IGNORE
		# Right edge, vertically centred.
		col.anchor_left = 1.0
		col.anchor_right = 1.0
		col.anchor_top = 0.5
		col.anchor_bottom = 0.5
		col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		col.grow_vertical = Control.GROW_DIRECTION_BOTH
		layer.add_child(col)
		var send_text: String = card_send_text.call(id) if card_send_text.is_valid() else ""
		if send_text != "":
			var sb := _button(send_text, func(): result_send.emit(index))
			sb.theme_type_variation = &"ChipButton"
			sb.add_theme_font_size_override("font_size", 19)
			sb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			sb.custom_minimum_size = Vector2(DL_W, 52)
			sb.size.x = DL_W
			col.add_child(sb)
			_card_send[id] = sb
		var dl := _button(card_download_text.call(id) if card_download_text.is_valid() else "Download",
			func(): result_download.emit(index))
		dl.theme_type_variation = &"ChipButton"
		dl.add_theme_font_size_override("font_size", 19)
		dl.tooltip_text = "Save to watch without internet"
		dl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		dl.custom_minimum_size.x = DL_W
		if send_text != "":
			dl.custom_minimum_size.y = 52
		col.add_child(dl)
		_card_dl[id] = dl
	return card


## options: [[code, name], ...]; selected: codes that are on.
func set_lang_chips(options: Array, selected: Array) -> void:
	for c in lang_box.get_children():
		c.queue_free()
	for o in options:
		var on: bool = selected.has(o[0])
		var b := _button(("✓ " if on else "") + o[1], lang_toggled.emit.bind(o[0]))
		b.theme_type_variation = &"AccentButton" if on else &"ChipButton"
		lang_box.add_child(b)


## Re-reads every visible card's Download label (progress, saved, ...).
func refresh_card_downloads() -> void:
	if not card_download_text.is_valid():
		return
	for id in _card_dl:
		if is_instance_valid(_card_dl[id]):
			_card_dl[id].text = card_download_text.call(id)
	if card_send_text.is_valid():
		for id in _card_send:
			if is_instance_valid(_card_send[id]):
				_card_send[id].text = card_send_text.call(id)


func show_ask(text: String) -> void:
	ask_label.text = text
	ask_bar.visible = true


func hide_ask() -> void:
	ask_bar.visible = false


## Small rounded label: durations, LIVE, VR/resolution badges.
func _chip(text: String, bg: Color, fg: Color, pos: Vector2, border := Color(0, 0, 0, 0)) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _sb(bg, 8, border, 1 if border.a > 0.0 else 0, 0)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	p.position = pos
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", fg)
	p.add_child(l)
	return p


## Pin a chip to the thumbnail's bottom-right (or bottom-left) corner; it grows away from the corner.
func _corner(c: Control, right: bool) -> Control:
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.anchor_left = 1.0 if right else 0.0
	c.anchor_right = c.anchor_left
	var m := 8.0
	c.offset_top = -m
	c.offset_bottom = -m
	c.offset_left = -m if right else m
	c.offset_right = c.offset_left
	c.grow_vertical = Control.GROW_DIRECTION_BEGIN
	c.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	return c


func _ignore_mouse(n: Node) -> void:
	if n is Control:
		n.mouse_filter = MOUSE_FILTER_IGNORE
	for c in n.get_children():
		_ignore_mouse(c)


static func _views(n: int) -> String:
	if n >= 1_000_000:
		return "%s M views" % (("%.1f" % (n / 1e6)).trim_suffix(".0"))
	if n >= 1000:
		return "%s K views" % (("%.1f" % (n / 1e3)).trim_suffix(".0") if n < 10000 else str(n / 1000))
	return "%d view%s" % [n, "" if n == 1 else "s"]


func update_playback(pos: float, dur: float, paused: bool, playing: bool) -> void:
	if playing and not player_box.visible:
		player_box.visible = true
	play_btn.text = "Pause" if playing and not paused else "Play"
	if not _dragging:
		slider.max_value = maxf(dur, 1.0)
		slider.value = pos
	if not playing and dur <= 0.0:
		time_label.text = ""
	else:
		time_label.text = "%s / %s" % [_fmt(pos), _fmt(dur) if dur > 0 else "live"]
	clock_label.text = Time.get_time_string_from_system().left(5)


# --- Internals ----------------------------------------------------------------------------------

func _setting_row(key: String, title: String, hint: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var labels := VBoxContainer.new()
	labels.size_flags_horizontal = SIZE_EXPAND_FILL
	labels.add_theme_constant_override("separation", 0)
	var t := Label.new()
	t.text = title
	labels.add_child(t)
	var h := Label.new()
	h.text = hint
	h.add_theme_font_size_override("font_size", 21)
	h.add_theme_color_override("font_color", TEXT_DIM)
	h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART # a long hint wraps instead of pushing the button off the menu
	h.custom_minimum_size.x = 50
	labels.add_child(h)
	row.add_child(labels)
	var b := _button("-", _on_setting.bind(key))
	b.custom_minimum_size.x = 300
	b.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(b)
	_setting_btns[key] = b
	settings_list.add_child(row)


func _section(title: String) -> void:
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 24)
	l.set_meta("accent_text", true)
	l.add_theme_color_override("font_color", accent)
	if settings_list.get_child_count() > 0:
		settings_list.add_child(_gap(10))
	settings_list.add_child(l)


func _gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = h
	return c


func _on_setting(key: String) -> void:
	match key:
		"account": account_pressed.emit()
		"decoder": decoder_pressed.emit()
		_: setting_pressed.emit(key)


func _spacer(vertical := false) -> Control:
	var s := Control.new()
	if vertical:
		s.size_flags_vertical = SIZE_EXPAND_FILL
	else:
		s.size_flags_horizontal = SIZE_EXPAND_FILL
	return s


func _on_drag_ended(_changed: bool) -> void:
	_dragging = false
	seek_to.emit(slider.value)


func _paste() -> void:
	input.text = DisplayServer.clipboard_get().strip_edges()
	input.caret_column = input.text.length()


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 62)
	b.pressed.connect(cb)
	return b


func _build_keyboard() -> VBoxContainer:
	var kb := VBoxContainer.new()
	for keys: String in KEY_ROWS:
		var h := HBoxContainer.new()
		h.alignment = BoxContainer.ALIGNMENT_CENTER
		for ch in keys:
			var b := _button(ch, _type.bind(ch))
			b.custom_minimum_size = Vector2(86, 58)
			if ch.to_upper() != ch:
				_letter_keys.append(b)
			h.add_child(b)
		kb.add_child(h)
	var sp := HBoxContainer.new()
	sp.alignment = BoxContainer.ALIGNMENT_CENTER
	sp.add_child(_button("Shift", _toggle_shift))
	var space := _button("Space", _type.bind(" "))
	space.custom_minimum_size.x = 380
	sp.add_child(space)
	sp.add_child(_button("Backspace", _backspace))
	sp.add_child(_button("Clear", func(): input.text = ""))
	var enter := _button("Search", func(): _submit(input.text))
	enter.theme_type_variation = &"AccentButton"
	sp.add_child(enter)
	kb.add_child(sp)
	return kb


func _type(ch: String) -> void:
	input.text += ch.to_upper() if _shift else ch
	input.caret_column = input.text.length()
	if _shift:
		_toggle_shift() # one-shot shift


func _backspace() -> void:
	input.text = input.text.left(-1)
	input.caret_column = input.text.length()


func _toggle_shift() -> void:
	_shift = not _shift
	for b in _letter_keys:
		b.text = b.text.to_upper() if _shift else b.text.to_lower()


static func _fmt(t: float) -> String:
	var s := int(t)
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]


# --- Discover topics -----------------------------------------------------------------------------------

## topics: [[label, query, kind], ...]; editing: tapping removes; save_label: "" = no "+ Save" pill.
func set_topics(topics: Array, editing: bool, save_label: String) -> void:
	for c in topics_box.get_children():
		c.queue_free()
	var head := Label.new()
	head.text = "Discover"
	head.add_theme_color_override("font_color", TEXT_DIM)
	head.custom_minimum_size.y = 58
	head.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	topics_box.add_child(head)
	for i in topics.size():
		var t: Array = topics[i]
		var cb := topic_remove.emit.bind(i) if editing else discover_pressed.emit.bind(t[1])
		topics_box.add_child(_topic_pill(str(t[0]), str(t[2]) if t.size() > 2 else "", editing, cb))
	if save_label != "" and not editing:
		var sv := _button("+ Save \"%s\"" % save_label, func(): topic_save.emit())
		sv.theme_type_variation = &"ChipButton"
		sv.add_theme_color_override("font_color", accent)
		sv.set_meta("accent_text", true)
		sv.custom_minimum_size.y = 58
		topics_box.add_child(sv)
	if not topics.is_empty() or editing:
		var ed := _button("Done" if editing else "Edit", func(): topic_edit.emit())
		ed.theme_type_variation = &"AccentButton" if editing else &"ChipButton"
		ed.add_theme_font_size_override("font_size", 20)
		ed.custom_minimum_size.y = 58
		topics_box.add_child(ed)


## A pill: [badge] label. In edit mode: [×] label, with a red badge. A panel sized by its content,
## with a see-through button on top (same trick as the video cards).
func _topic_pill(label: String, kind: String, editing: bool, cb: Callable) -> Control:
	var pill := PanelContainer.new()
	var sb := _sb(Color(1, 1, 1, 0.045), 30, Color(1, 1, 1, 0.12), 1, 0)
	sb.content_margin_left = 12
	sb.content_margin_right = 18
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	pill.add_theme_stylebox_override("panel", sb)
	pill.custom_minimum_size.y = 58
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	pill.add_child(row)
	var badge_text: String = "×" if editing else TOPIC_BADGES.get(kind, "")
	if badge_text != "":
		var col := Color(0.85, 0.25, 0.3) if editing else (accent.darkened(0.3) if kind != "flat" else Color(1, 1, 1, 0.16))
		var chip := _chip(badge_text, col, Color.WHITE, Vector2.ZERO)
		chip.size_flags_vertical = SIZE_SHRINK_CENTER
		row.add_child(chip)
	else:
		sb.content_margin_left = 18
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 24)
	row.add_child(l)
	_ignore_mouse(row)
	var b := Button.new()
	b.focus_mode = FOCUS_NONE
	b.theme_type_variation = &"PillButton"
	b.pressed.connect(cb)
	pill.add_child(b)
	return pill
