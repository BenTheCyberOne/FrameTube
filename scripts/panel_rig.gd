class_name PanelRig
extends Node
## Placement and size of the menu.
##  - Grip while pointing at the menu: it follows your hand, keeping the spot you grabbed under the laser.
##  - Grip it with both hands: pull apart / push together to make it bigger / smaller.
##  - Holding it, thumbstick up/down resizes, left/right pulls it closer / pushes it away.
##  - Desktop: Ctrl+scroll over the menu resizes it, Ctrl+left-drag moves it.
## The spot is remembered relative to where you were looking when the menu opened, so it always pops up
## in the same place in your view (also after turning around or lying down).

signal changed(text: String)

const MIN_SCALE := 0.45
const MAX_SCALE := 2.0
const TILT := -20.0 # default: tilted back a little, like a laptop screen below eye level

var panel: MeshInstance3D
var camera: Camera3D
var store: Store
var panel_m := Vector2.ONE
var size := 1.0 # 1.0 = the normal 1.5 m wide menu
var custom := false # moved by hand
var rel := Transform3D.IDENTITY # where it sits in the "head frame" (see _head_frame), without scale

var _frame := Transform3D.IDENTITY # head frame at the moment the menu was opened
var _grabs := {} # holder -> {dist, local: Vector2 (menu metres at size 1)}
var _two := {} # two hands: {sep0, s0}
var _save_in := -1.0


func setup(p_panel: MeshInstance3D, p_camera: Camera3D, p_store: Store, p_panel_m: Vector2, legacy_size: float) -> void:
	panel = p_panel
	camera = p_camera
	store = p_store
	panel_m = p_panel_m
	size = clampf(float(store.get_setting("menu_scale", legacy_size)), MIN_SCALE, MAX_SCALE)
	custom = bool(store.get_setting("menu_custom", false))
	var r = store.get_setting("menu_rel", false)
	if r is Transform3D:
		rel = r
	else:
		custom = false


## Show the menu in front of you (or at the spot you moved it to, relative to where you look now).
func place() -> void:
	_frame = _head_frame()
	if custom:
		_apply(_frame * rel)
		return
	var fwd := -_frame.basis.z
	var eye := _frame.origin
	var pos := eye + fwd * (1.15 + 0.5 * (size - 1.0)) # a bigger menu sits a little further away, a little lower
	pos.y = eye.y - 0.35 * size
	_apply(Transform3D(Basis.looking_at(fwd, Vector3.UP) * Basis(Vector3.RIGHT, deg_to_rad(TILT)), pos))


## Back to the default spot, at this size.
func reset(p_size: float) -> void:
	size = clampf(p_size, MIN_SCALE, MAX_SCALE)
	custom = false
	_grabs.clear()
	_two = {}
	place()
	_save_soon()


func holding(holder: Variant) -> bool:
	return _grabs.has(holder)


func is_held() -> bool:
	return not _grabs.is_empty()


func grab(holder: Variant, origin: Vector3, dir: Vector3) -> bool:
	var h = hit(origin, dir)
	if h == null:
		return false
	_grabs[holder] = {"dist": h.dist, "local": h.local, "regrab": false}
	if _grabs.size() == 2:
		_two = {"sep0": -1.0, "s0": size}
	return true


func release(holder: Variant) -> void:
	if not _grabs.erase(holder):
		return
	_two = {}
	for g in _grabs.values():
		g.regrab = true # the other hand re-anchors where it points now, so nothing jumps
	_save_soon()


## Per frame while held. rays: holder -> [origin, dir].
func drag(rays: Dictionary) -> void:
	if _grabs.is_empty():
		return
	if _grabs.size() == 2 and not _two.is_empty():
		var pts: Array = []
		for holder in _grabs:
			pts.append(rays[holder][0])
		var sep: float = pts[0].distance_to(pts[1])
		if _two.sep0 < 0.0:
			_two.sep0 = maxf(sep, 0.05)
		size = clampf(_two.s0 * sep / _two.sep0, MIN_SCALE, MAX_SCALE)
	var target := Vector3.ZERO
	var local := Vector2.ZERO
	for holder in _grabs:
		var g: Dictionary = _grabs[holder]
		var r: Array = rays[holder]
		if g.regrab:
			var hh = hit(r[0], r[1])
			if hh != null:
				g.dist = hh.dist
				g.local = hh.local
			g.regrab = false
		target += r[0] + r[1] * g.dist
		local += g.local
	target /= _grabs.size()
	local /= _grabs.size()
	_place_by_point(target, local * size)
	changed.emit(describe())


## Thumbstick / scroll. resize > 0 grows, push > 0 moves it away (per-call log factors).
func adjust(resize: float, push: float, holder: Variant = null) -> void:
	var t := panel.global_transform.orthonormalized()
	if resize != 0.0:
		size = clampf(size * exp(resize), MIN_SCALE, MAX_SCALE)
	if push != 0.0:
		var cam := camera.global_position
		var d := t.origin - cam
		var nd := clampf(d.length() * exp(push), 0.4, 4.0)
		if holder != null and _grabs.has(holder):
			_grabs[holder].dist = clampf(_grabs[holder].dist * exp(push), 0.3, 4.5)
		t.origin = cam + d.normalized() * nd
		t.basis = _facing(t.origin)
		rel = _frame.affine_inverse() * t
		custom = true
	_apply(t)
	_save_soon()
	changed.emit(describe())


func describe() -> String:
	return "Menu %d%% size. Grip it to move it, or grip with both hands and pull apart to resize." % roundi(size * 100.0)


## Ray vs. the menu. Returns {local: Vector2 (metres at size 1, from the centre), dist} or null.
func hit(origin: Vector3, dir: Vector3) -> Variant:
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
	if absf(p.x) > panel_m.x * 0.5 or absf(p.y) > panel_m.y * 0.5:
		return null
	return {"local": Vector2(p.x, p.y), "dist": t}


func _apply(t: Transform3D) -> void:
	t.basis = t.basis.orthonormalized() * Basis.from_scale(Vector3.ONE * size)
	panel.global_transform = t


func _place_by_point(p: Vector3, local: Vector2) -> void:
	var basis := _facing(p)
	var center := p - basis * Vector3(local.x, local.y, 0.0)
	basis = _facing(center)
	center = p - basis * Vector3(local.x, local.y, 0.0)
	var t := Transform3D(basis, center)
	_apply(t)
	rel = _frame.affine_inverse() * t
	custom = true


## Front (+Z) towards your eyes.
func _facing(center: Vector3) -> Basis:
	var d := center - camera.global_position
	if d.length_squared() < 0.01:
		return panel.global_basis.orthonormalized()
	d = d.normalized()
	var up := Vector3.UP if absf(d.y) < 0.97 else -camera.global_basis.z
	return Basis.looking_at(d, up)


## Where you are, turned the way you face (level).
func _head_frame() -> Transform3D:
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 1e-4 else Vector3.FORWARD
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), camera.global_position)


func _process(delta: float) -> void:
	if _save_in >= 0.0:
		_save_in -= delta
		if _save_in < 0.0:
			store.set_setting("menu_scale", size)
			store.set_setting("menu_custom", custom)
			store.set_setting("menu_rel", rel)


func _save_soon() -> void:
	_save_in = 0.8
