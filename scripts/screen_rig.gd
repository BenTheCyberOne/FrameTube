class_name ScreenRig
extends Node
## Placement and size of the flat video screen.
##  - Grab (grip / left mouse) while pointing at it: it follows your ray, keeping the grabbed spot under it.
##  - Grab with both hands: pull apart / push together to scale.
##  - Thumbstick / scroll: resize, push away / pull closer.
## The screen always turns to face you, so you can put it overhead to watch lying down.
## Placement is stored relative to `content` (the recentred frame), so Recenter keeps it; reset() restores it.

signal changed(text: String) # human-readable feedback while adjusting

const PRESETS := [["S", 1.6], ["M", 2.4], ["L", 3.4], ["XL", 4.8]] # label, height in metres
const DEFAULT_HEIGHT := 2.4
const DEFAULT_DIST := 4.0
const MIN_HEIGHT := 0.5
const MAX_HEIGHT := 16.0
const MIN_DIST := 0.8
const MAX_DIST := 25.0

var screen: MeshInstance3D
var camera: Camera3D
var store: Store
var height := DEFAULT_HEIGHT
var aspect := 16.0 / 9.0
var custom := false # placed by hand; otherwise it sits at the default spot in front of you
var curve_mode := 0 # 0 flat, 1 curved, 2 extra curved
var size := Vector2(DEFAULT_HEIGHT * 16.0 / 9.0, DEFAULT_HEIGHT) # arc length x height for curved screens
var _radius := 0.0 # curvature radius of the current mesh (0 = flat)
const CURVES := ["Flat", "Curved", "Extra curved"]

var _grabs := {} # holder (controller node or "mouse") -> {dist, local: Vector2, h, regrab}
var _two := {} # two-hand scaling: {sep0, h0}
var _save_in := -1.0


func setup(p_screen: MeshInstance3D, p_camera: Camera3D, p_store: Store) -> void:
	screen = p_screen
	camera = p_camera
	store = p_store
	var legacy_idx := int(store.get_setting("screen_idx", 1)) # older builds stored a preset index
	height = float(store.get_setting("screen_height", PRESETS[clampi(legacy_idx, 0, PRESETS.size() - 1)][1]))
	custom = bool(store.get_setting("screen_custom", false))
	if custom:
		screen.transform = store.get_setting("screen_xform", screen.transform)
	curve_mode = clampi(int(store.get_setting("screen_curve", 0)), 0, CURVES.size() - 1)
	apply_size()


func set_aspect(a: float) -> void:
	aspect = a
	apply_size()


func apply_size() -> void:
	size = Vector2(height * aspect, height)
	var max_w := height * 3.0 # keep ultra-wide videos from wrapping around you
	if size.x > max_w:
		size *= max_w / size.x
	_rebuild_mesh(true)


func set_curve(mode: int) -> void:
	curve_mode = clampi(mode, 0, CURVES.size() - 1)
	_rebuild_mesh(true)


## Curvature follows the viewing distance: "Curved" bends gently, "Extra curved" wraps the screen
## around you (every point the same distance away, like an IMAX dome). Rebuilt when it changes noticeably.
func _rebuild_mesh(force: bool) -> void:
	if curve_mode == 0:
		if force or not screen.mesh is QuadMesh:
			var q := QuadMesh.new()
			q.size = size
			screen.mesh = q
			_radius = 0.0
		return
	var d := distance() if camera and screen.is_inside_tree() else DEFAULT_DIST
	if d < 0.5:
		d = DEFAULT_DIST
	var r := d * (1.8 if curve_mode == 1 else 1.0)
	r = maxf(r, (size.x * 0.5) / deg_to_rad(75.0)) # never wrap more than 150 degrees
	if not force and _radius > 0.0 and absf(r - _radius) / _radius < 0.05:
		return
	_radius = r
	screen.mesh = _arc_mesh(size, r)


## Cylindrical strip: centre at the origin facing +Z, edges bending towards the viewer.
static func _arc_mesh(sz: Vector2, r: float) -> ArrayMesh:
	var n := 48
	var half := (sz.x * 0.5) / r
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	for i in n + 1:
		var a := -half + 2.0 * half * i / n
		var x := r * sin(a)
		var z := r * (1.0 - cos(a))
		var nrm := Vector3(-sin(a), 0, cos(a))
		for row in 2: # top, bottom
			verts.append(Vector3(x, sz.y * (0.5 - row), z))
			norms.append(nrm)
			uvs.append(Vector2(float(i) / n, row))
	var idx := PackedInt32Array()
	for i in n: # Godot's front faces wind clockwise
		var tl := i * 2
		var bl := tl + 1
		var tr := tl + 2
		var br := tl + 3
		idx.append_array([tl, tr, br, tl, br, bl])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Default spot (unless the user placed it): straight ahead at eye height. Local to `content`.
func place_default(eye_y: float) -> void:
	if not custom:
		screen.transform = Transform3D(Basis.IDENTITY, Vector3(0, eye_y, -DEFAULT_DIST))
	_rebuild_mesh(true) # curvature depends on where you are now


func reset(eye_y: float) -> void:
	custom = false
	height = DEFAULT_HEIGHT
	_grabs.clear()
	_two = {}
	apply_size()
	place_default(eye_y)
	_save_soon()
	changed.emit("Screen reset. " + describe())


func next_preset() -> void:
	var next: Array = PRESETS[0]
	for p in PRESETS:
		if p[1] > height + 0.05:
			next = p
			break
	height = next[1]
	apply_size()
	_save_soon()
	changed.emit(describe())


func preset_label() -> String:
	for p in PRESETS:
		if absf(p[1] - height) < 0.05:
			return p[0]
	return "%.1f m" % height


func describe() -> String:
	return "Screen %.1f m tall, %.1f m away" % [height, distance()]


func distance() -> float:
	return screen.global_position.distance_to(camera.global_position)


## Ray vs. screen quad. Returns {local: Vector2 (metres from centre), dist: float} or null.
func hit(origin: Vector3, dir: Vector3) -> Variant:
	if not screen.visible:
		return null
	var inv := screen.global_transform.affine_inverse()
	var lo := inv * origin
	var ld := inv.basis * dir
	if _radius > 0.0:
		return _hit_curved(lo, ld)
	if absf(ld.z) < 1e-6:
		return null
	var t := -lo.z / ld.z
	if t <= 0.0:
		return null
	var p := lo + ld * t
	if absf(p.x) > size.x * 0.5 or absf(p.y) > size.y * 0.5:
		return null
	return {"local": Vector2(p.x, p.y), "dist": t}


## Ray vs. the curved strip (a cylinder around local Y, centred at z = radius). local.x = arc length.
func _hit_curved(lo: Vector3, ld: Vector3) -> Variant:
	var r := _radius
	var ox := lo.x
	var oz := lo.z - r
	var a := ld.x * ld.x + ld.z * ld.z
	if a < 1e-9:
		return null
	var b := 2.0 * (ox * ld.x + oz * ld.z)
	var c := ox * ox + oz * oz - r * r
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return null
	var sq := sqrt(disc)
	var half := (size.x * 0.5) / r
	for t in [(-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a)]:
		if t <= 0.0:
			continue
		var p: Vector3 = lo + ld * t
		var ang := atan2(p.x, r - p.z)
		if r - p.z > 0.0 and absf(ang) <= half and absf(p.y) <= size.y * 0.5:
			return {"local": Vector2(r * ang, p.y), "dist": t}
	return null


func holding(holder: Variant) -> bool:
	return _grabs.has(holder)


func is_held() -> bool:
	return not _grabs.is_empty()


func grab(holder: Variant, origin: Vector3, dir: Vector3) -> bool:
	var h = hit(origin, dir)
	if h == null:
		return false
	_grabs[holder] = {"dist": h.dist, "local": h.local, "h": height, "regrab": false}
	if _grabs.size() == 2:
		_two = {"sep0": -1.0, "h0": height}
	return true


func release(holder: Variant) -> void:
	if not _grabs.erase(holder):
		return
	_two = {}
	for g in _grabs.values():
		g.regrab = true # the remaining hand re-anchors where it now points, so nothing jumps
	custom = true
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
		height = clampf(_two.h0 * sep / _two.sep0, MIN_HEIGHT, MAX_HEIGHT)
		apply_size()
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
				g.h = height
			g.regrab = false
		target += r[0] + r[1] * g.dist
		local += g.local * (height / g.h) # grab point scales with the screen
	target /= _grabs.size()
	local /= _grabs.size()
	_place_by_point(target, local)
	_rebuild_mesh(false)
	custom = true
	changed.emit(describe())


## Thumbstick / scroll. resize > 0 grows, push > 0 moves it away (both are per-call log factors).
func adjust(resize: float, push: float, holder: Variant = null) -> void:
	if resize != 0.0:
		height = clampf(height * exp(resize), MIN_HEIGHT, MAX_HEIGHT)
		apply_size()
	if push != 0.0:
		if holder != null and _grabs.has(holder):
			_grabs[holder].dist = clampf(_grabs[holder].dist * exp(push), MIN_DIST, MAX_DIST)
		else:
			var cam := camera.global_position
			var d := screen.global_position - cam
			var nd := clampf(d.length() * exp(push), MIN_DIST, MAX_DIST)
			var c := cam + d.normalized() * nd
			screen.global_transform = Transform3D(_facing(c), c)
			_rebuild_mesh(false)
			custom = true
	_save_soon()
	changed.emit(describe())


func _process(delta: float) -> void:
	if _save_in >= 0.0:
		_save_in -= delta
		if _save_in < 0.0:
			store.set_setting("screen_height", height)
			store.set_setting("screen_custom", custom)
			store.set_setting("screen_xform", screen.transform)


func _save_soon() -> void:
	_save_in = 0.8 # debounce: settle first, then write once


## Put the screen so that its point `local` (metres from centre) lands on world point `p`, facing the viewer.
func _place_by_point(p: Vector3, local: Vector2) -> void:
	var basis := _facing(p)
	var center := p - basis * Vector3(local.x, local.y, 0.0)
	basis = _facing(center) # refine once with the real centre
	center = p - basis * Vector3(local.x, local.y, 0.0)
	screen.global_transform = Transform3D(basis, center)


## Orientation whose +Z (the quad's front) points back at the camera.
func _facing(center: Vector3) -> Basis:
	var d := center - camera.global_position
	if d.length_squared() < 0.01:
		return screen.global_basis
	d = d.normalized()
	var up := Vector3.UP if absf(d.y) < 0.97 else -camera.global_basis.z # overhead: keep "up" = where you face
	return Basis.looking_at(d, up)
