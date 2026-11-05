class_name HandVisuals
extends Node3D
## Shows one of your hands in VR:
##  - Holding a controller: the headset's own 3D model of it when the runtime offers one (OpenXR render
##    models), otherwise a simple stand-in.
##  - Hand tracking (controller put down): your hand, drawn from the tracked joints.
## Lives under the XROrigin3D (joint poses are in origin space). Turned on/off from Settings.

const JOINTS := 26
## [from, to] joint pairs (XRHandTracker.HandJoint numbering): wrist to each finger base, then each finger.
const BONES := [[1, 2], [2, 3], [3, 4], [4, 5],
	[1, 6], [6, 7], [7, 8], [8, 9], [9, 10],
	[1, 11], [11, 12], [12, 13], [13, 14], [14, 15],
	[1, 16], [16, 17], [17, 18], [18, 19], [19, 20],
	[1, 21], [21, 22], [22, 23], [23, 24], [24, 25],
	[6, 11], [11, 16], [16, 21]] # across the knuckles: reads as a palm
const TIPS := [5, 10, 15, 20, 25]

var side := "left"
var grip: XRNode3D # follows the controller's grip pose (see setup)
var tracker_name: StringName
var shown := true

var _ctrl_root: Node3D # stand-in + runtime model, under `grip`
var _fallback: Node3D
var _render_models := 0
var _hand_root: Node3D
var _joints: Array[MeshInstance3D] = []
var _bones: Array[MeshInstance3D] = []
var _skin: StandardMaterial3D
var _tip_mat: StandardMaterial3D
var _body_mat: StandardMaterial3D
var _accent_mat: StandardMaterial3D


## p_grip: an XRController3D (pose "grip") for this hand, already in the tree under the XROrigin3D.
func setup(p_side: String, p_grip: XRNode3D) -> void:
	side = p_side
	grip = p_grip
	tracker_name = &"/user/hand_tracker/" + side
	_build_materials()
	_ctrl_root = Node3D.new()
	grip.add_child(_ctrl_root)
	_fallback = _build_controller()
	_ctrl_root.add_child(_fallback)
	var xr := XRServer.find_interface("OpenXR")
	if xr and xr.is_initialized() and ClassDB.class_exists("OpenXRRenderModelManager"):
		var m: Node3D = ClassDB.instantiate("OpenXRRenderModelManager")
		m.set("tracker", 2 if side == "left" else 3) # Left Hand / Right Hand
		m.set("make_local_to_pose", "grip")
		m.connect("render_model_added", func(_rm): _render_models += 1)
		m.connect("render_model_removed", func(_rm): _render_models = maxi(_render_models - 1, 0))
		_ctrl_root.add_child(m)
	_build_hand()


func set_shown(on: bool) -> void:
	shown = on
	visible = on
	if _ctrl_root:
		_ctrl_root.visible = on


func set_accent(c: Color) -> void:
	if _accent_mat:
		_accent_mat.albedo_color = c
		_accent_mat.emission = c
		_tip_mat.albedo_color = c.lerp(Color.WHITE, 0.5)


func _process(_delta: float) -> void:
	if not shown:
		return
	var ht := XRServer.get_tracker(tracker_name) as XRHandTracker
	var hand_on := ht != null and ht.has_tracking_data
	_hand_root.visible = hand_on
	if hand_on:
		_update_hand(ht)
	# An optically tracked hand means the controller isn't in it (it'd be drawn on top of your fingers).
	var optical := hand_on and ht.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	_ctrl_root.visible = not optical
	_fallback.visible = _render_models == 0 # the runtime's real model wins


func _update_hand(ht: XRHandTracker) -> void:
	var pos: Array[Vector3] = []
	pos.resize(JOINTS)
	var ok: Array[bool] = []
	ok.resize(JOINTS)
	for j in JOINTS:
		var f := ht.get_hand_joint_flags(j)
		ok[j] = (f & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
		pos[j] = ht.get_hand_joint_transform(j).origin
		var mi := _joints[j]
		mi.visible = ok[j] and j != 0 # 0 = palm centre, not drawn
		if mi.visible:
			var r := ht.get_hand_joint_radius(j)
			r = r if r > 0.002 else 0.009
			mi.transform = Transform3D(Basis.from_scale(Vector3.ONE * r), pos[j])
	for b in BONES.size():
		var a: int = BONES[b][0]
		var c: int = BONES[b][1]
		var mi := _bones[b]
		mi.visible = ok[a] and ok[c] and pos[a].distance_to(pos[c]) > 0.002
		if mi.visible:
			var r := minf(ht.get_hand_joint_radius(a), ht.get_hand_joint_radius(c))
			r = (r if r > 0.002 else 0.008) * 0.85
			mi.transform = _segment(pos[a], pos[c], r)


## A unit cylinder (height 1 along Y) stretched from a to b.
static func _segment(a: Vector3, b: Vector3, r: float) -> Transform3D:
	var d := b - a
	var y := d.normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x * r, y * d.length(), z * r), (a + b) * 0.5)


func _build_hand() -> void:
	_hand_root = Node3D.new()
	_hand_root.visible = false
	add_child(_hand_root)
	var sphere := SphereMesh.new() # unit radius, scaled per joint
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 10
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	for j in JOINTS:
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = _tip_mat if TIPS.has(j) else _skin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hand_root.add_child(mi)
		_joints.append(mi)
	for b in BONES:
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		mi.material_override = _skin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hand_root.add_child(mi)
		_bones.append(mi)


## A plain, generic controller: rounded handle along the grip axis (-Z forward), a ring at the front.
func _build_controller() -> Node3D:
	var root := Node3D.new()
	var handle := CapsuleMesh.new()
	handle.radius = 0.019
	handle.height = 0.12
	var h := MeshInstance3D.new()
	h.mesh = handle
	h.material_override = _body_mat
	h.transform = Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 0, 0.02))
	root.add_child(h)
	var head := CylinderMesh.new() # face where the thumb rests
	head.top_radius = 0.03
	head.bottom_radius = 0.032
	head.height = 0.022
	var hm := MeshInstance3D.new()
	hm.mesh = head
	hm.material_override = _body_mat
	hm.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-35.0)), Vector3(0, 0.012, -0.05))
	root.add_child(hm)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.028
	ring.outer_radius = 0.034
	ring.rings = 32
	ring.ring_segments = 8
	var rm := MeshInstance3D.new()
	rm.mesh = ring
	rm.material_override = _accent_mat
	rm.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-35.0)), Vector3(0, 0.024, -0.057))
	root.add_child(rm)
	for mi in root.get_children():
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


func _build_materials() -> void:
	_skin = StandardMaterial3D.new()
	_skin.albedo_color = Color(0.82, 0.86, 0.95)
	_skin.roughness = 0.55
	_skin.rim_enabled = true
	_skin.rim = 0.6
	_skin.emission_enabled = true # still visible in the dark cinema room
	_skin.emission = Color(0.42, 0.45, 0.52)
	_tip_mat = _skin.duplicate()
	_tip_mat.albedo_color = Color(0.7, 0.85, 1.0)
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.2, 0.21, 0.25)
	_body_mat.roughness = 0.35
	_body_mat.metallic = 0.2
	_body_mat.rim_enabled = true
	_body_mat.rim = 0.5
	_body_mat.emission_enabled = true
	_body_mat.emission = Color(0.06, 0.065, 0.08)
	_accent_mat = StandardMaterial3D.new()
	_accent_mat.albedo_color = Color(0.32, 0.66, 1.0)
	_accent_mat.emission_enabled = true
	_accent_mat.emission = Color(0.32, 0.66, 1.0)
	_accent_mat.emission_energy_multiplier = 1.5
