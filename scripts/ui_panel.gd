class_name UIPanel
extends PanelContainer
## The control panel. It lives in a SubViewport that is drawn on a quad in 3D and
## driven by laser pointers (VR) or the mouse (desktop test mode).
## Two pages: Browse (search/feeds/results) and Settings; the player controls are always visible.

signal submitted(text: String)
signal result_chosen(index: int)
signal play_pause_pressed
signal seek_relative(seconds: float)
signal seek_to(seconds: float)
signal projection_pressed
signal quality_pressed
signal decoder_pressed
signal swap_eyes_toggled(on: bool)
signal recenter_pressed
signal hide_pressed
signal feed_pressed(key: String) # "history" | "subscriptions" | "watch_later" | "recommended"
signal account_pressed
signal screen_size_pressed
signal reset_screen_pressed
signal setting_pressed(key: String) # "environment" | "toy" | "accent" | "bias" | "bloom"

const KEY_ROWS := ["1234567890-", "qwertyuiop=", "asdfghjkl:/", "zxcvbnm.?&_"]
const BG := Color(0.055, 0.06, 0.085, 0.975) # near-opaque: bright grids (Synthwave) shouldn't show through
const SURFACE := Color(1, 1, 1, 0.055)
const SURFACE_HOVER := Color(1, 1, 1, 0.11)
const TEXT := Color(0.93, 0.94, 0.97)
const TEXT_DIM := Color(0.62, 0.66, 0.75)

var accent := Color(0.3, 0.64, 1.0)
var input: LineEdit
var results: ItemList
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
var settings_page: VBoxContainer
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
	input.text_submitted.connect(func(t: String): submitted.emit(t))
	row.add_child(input)
	var go := _button("Go", func(): submitted.emit(input.text))
	go.theme_type_variation = &"AccentButton"
	go.custom_minimum_size.x = 100
	row.add_child(go)
	row.add_child(_button("Paste", _paste))
	row.add_child(_button("Keys", func(): keyboard.visible = not keyboard.visible))

	var feeds := HBoxContainer.new()
	feeds.add_theme_constant_override("separation", 8)
	browse_page.add_child(feeds)
	for f in [["History", "history"], ["Subscriptions", "subscriptions"], ["Watch later", "watch_later"],
			["Recommended", "recommended"]]:
		var b := _button(f[0], feed_pressed.emit.bind(f[1]))
		b.theme_type_variation = &"ChipButton"
		feeds.add_child(b)

	results = ItemList.new()
	results.size_flags_vertical = SIZE_EXPAND_FILL
	results.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	results.item_selected.connect(func(i: int): result_chosen.emit(i))
	browse_page.add_child(results)

	# --- Settings page
	settings_page = VBoxContainer.new()
	settings_page.add_theme_constant_override("separation", 20)
	settings_page.size_flags_vertical = SIZE_EXPAND_FILL
	settings_page.visible = false
	root.add_child(settings_page)
	_setting_row("environment", "Environment", "The room around the flat screen")
	_setting_row("toy", "Fidget toy", "Grab with grip, throw it, swipe it to spin")
	_setting_row("accent", "Accent colour", "Panel, grid, toy and lighting tint")
	_setting_row("bias", "Bias lighting", "The video's colours softly light the room")
	_setting_row("bloom", "Bloom", "Glow on bright things (costs a little GPU)")
	_setting_row("account", "Account", "Sign-in for subscriptions etc. (Firefox works best)")
	_setting_row("decoder", "Video decoder", "GPU decoding saves CPU; falls back automatically")
	settings_page.add_child(_spacer(true))

	# --- Now playing + player controls (always visible)
	var np := HBoxContainer.new()
	root.add_child(np)
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

	var seek_row := HBoxContainer.new()
	root.add_child(seek_row)
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
	root.add_child(ctl)
	ctl.add_child(_button("-30s", func(): seek_relative.emit(-30.0)))
	ctl.add_child(_button("-10s", func(): seek_relative.emit(-10.0)))
	play_btn = _button("Play", func(): play_pause_pressed.emit())
	play_btn.theme_type_variation = &"AccentButton"
	play_btn.custom_minimum_size.x = 170
	ctl.add_child(play_btn)
	ctl.add_child(_button("+10s", func(): seek_relative.emit(10.0)))
	ctl.add_child(_button("+30s", func(): seek_relative.emit(30.0)))
	ctl.add_child(_spacer())
	ctl.add_child(_button("Recenter", func(): recenter_pressed.emit()))
	ctl.add_child(_button("Hide panel", func(): hide_pressed.emit()))

	var view := HBoxContainer.new()
	view.add_theme_constant_override("separation", 8)
	root.add_child(view)
	proj_btn = _button("View: Flat", func(): projection_pressed.emit())
	proj_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	view.add_child(proj_btn)
	screen_btn = _button("Screen: M", func(): screen_size_pressed.emit())
	view.add_child(screen_btn)
	view.add_child(_button("Reset", func(): reset_screen_pressed.emit()))
	quality_btn = _button("Max 2160p", func(): quality_pressed.emit())
	view.add_child(quality_btn)
	swap_btn = CheckButton.new()
	swap_btn.text = "Swap eyes"
	swap_btn.focus_mode = FOCUS_NONE
	swap_btn.toggled.connect(func(on: bool): swap_eyes_toggled.emit(on))
	view.add_child(swap_btn)

	keyboard = _build_keyboard()
	root.add_child(keyboard)
	show_page(false)


func show_page(settings: bool) -> void:
	browse_page.visible = not settings
	settings_page.visible = settings
	tab_browse.set_pressed_no_signal(not settings)
	tab_settings.set_pressed_no_signal(settings)


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

	# Results list
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
	proj_btn.text = "View: " + text


func set_quality(height: int) -> void:
	quality_btn.text = "Max %dp" % height


func set_decoder(label: String) -> void:
	set_setting("decoder", label)


func set_account(label: String) -> void:
	set_setting("account", label)


func set_screen_size(label: String) -> void:
	screen_btn.text = "Screen: " + label


func set_setting(key: String, value: String) -> void:
	if _setting_btns.has(key):
		_setting_btns[key].text = value


## items: {title, duration, channel, [resume]}
func show_results(items: Array) -> void:
	results.clear()
	for it in items:
		var dur := "  ·  %s" % _fmt(it.duration) if it.get("duration", 0) > 0 else ""
		var ch: String = it.get("channel", "")
		var resume := "   ›  resume at %s" % _fmt(it.resume) if it.get("resume", 0) > 0 else ""
		var by := "     %s" % ch if ch != "" else ""
		results.add_item("%s%s%s%s" % [it.title, by, dur, resume])
	show_page(false)


func update_playback(pos: float, dur: float, paused: bool, playing: bool) -> void:
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
	labels.add_child(h)
	row.add_child(labels)
	var b := _button("-", _on_setting.bind(key))
	b.custom_minimum_size.x = 300
	row.add_child(b)
	_setting_btns[key] = b
	settings_page.add_child(row)


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
	var enter := _button("Enter", func(): submitted.emit(input.text))
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
