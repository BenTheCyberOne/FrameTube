class_name FidgetToy
extends Node3D
## A little floating toy next to you. Grab it (grip) and throw it, or poke/swipe it with your hand to spin it.
## When let go it drifts back to its spot on a soft spring. Desktop: click it.
## Simple hand-rolled physics (no physics engine): velocity + spring home + damping + floor bounce.

signal touched(strength: float) # for haptics

const SHAPES := ["Orb", "Cube", "Spinner", "Donut", "Off"]
const RADIUS := 0.07 # grab / hit radius (m)
const SPRING := 4.0 # pull back home
const DAMPING := 2.0 # linear damping (with SPRING: a playful, slightly bouncy return)
const SPIN_DAMPING := 0.3 # spins keep going for a while — that's the fun part

var shape := 0
var home := Vector3(0.75, 1.2, -0.75)
var vel := Vector3.ZERO
var ang := Vector3.ZERO # angular velocity (world axis * rad/s)
var grabbed_by: Node3D = null

var _grab_offset := Transform3D.IDENTITY
var _hand_prev_pos := Vector3.ZERO
var _hand_prev_basis := Basis.IDENTITY
var _hand_vel := Vector3.ZERO
var _hand_ang := Vector3.ZERO
var _mesh_root: Node3D
var _mat: ShaderMaterial
var _spark_mat: StandardMaterial3D
var _sparks: CPUParticles3D
var _energy := 0.0
var _placed := false


func _ready() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/fidget.gdshader")
	_mesh_root = Node3D.new()
	add_child(_mesh_root)

	_sparks = CPUParticles3D.new()
	_sparks.emitting = false
	_sparks.one_shot = true
	_sparks.amount = 28
	_sparks.lifetime = 0.7
	_sparks.explosiveness = 1.0
	_sparks.local_coords = false
	_sparks.direction = Vector3.UP
	_sparks.spread = 180.0
	_sparks.initial_velocity_min = 0.25
	_sparks.initial_velocity_max = 0.8
	_sparks.gravity = Vector3(0, -0.6, 0)
	_sparks.damping_min = 0.5
	_sparks.damping_max = 1.5
	_sparks.scale_amount_min = 0.5
	_sparks.scale_amount_max = 1.2
	var curve := Curve.new() # shrink out
	curve.add_point(Vector2(0, 1))
	curve.add_point(Vector2(1, 0))
	_sparks.scale_amount_curve = curve
	var sm := SphereMesh.new()
	sm.radius = 0.004
	sm.height = 0.008
	sm.radial_segments = 6
	sm.rings = 3
	_spark_mat = StandardMaterial3D.new()
	_spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spark_mat.albedo_color = Color(1.6, 1.6, 1.6)
	sm.material = _spark_mat
	_sparks.mesh = sm
	add_child(_sparks)
	set_shape(0)


func set_shape(i: int) -> void:
	shape = clampi(i, 0, SHAPES.size() - 1)
	for c in _mesh_root.get_children():
		c.queue_free()
	visible = SHAPES[shape] != "Off"
	match SHAPES[shape]:
		"Orb":
			var m := SphereMesh.new()
			m.radius = 0.055
			m.height = 0.11
			m.radial_segments = 40
			m.rings = 20
			_add_mesh(m)
		"Cube":
			var m := BoxMesh.new()
			m.size = Vector3.ONE * 0.085
			_add_mesh(m)
		"Donut":
			var m := TorusMesh.new()
			m.inner_radius = 0.028
			m.outer_radius = 0.062
			m.rings = 48
			m.ring_segments = 20
			_add_mesh(m, Basis(Vector3.RIGHT, PI / 2))
		"Spinner": # classic three-lobe fidget spinner, spins about its local Y axis
			var hub := CylinderMesh.new()
			hub.top_radius = 0.02
			hub.bottom_radius = 0.02
			hub.height = 0.016
			_add_mesh(hub)
			for k in 3:
				var a := TAU * k / 3.0
				var lobe := CylinderMesh.new()
				lobe.top_radius = 0.026
				lobe.bottom_radius = 0.026
				lobe.height = 0.012
				_add_mesh(lobe, Basis.IDENTITY, Vector3(cos(a), 0, sin(a)) * 0.048)
				var arm := BoxMesh.new()
				arm.size = Vector3(0.05, 0.01, 0.022)
				_add_mesh(arm, Basis(Vector3.UP, -a), Vector3(cos(a), 0, sin(a)) * 0.024)


func set_accent(c: Color) -> void:
	_mat.set_shader_parameter("accent", c)
	_spark_mat.albedo_color = Color(c.r * 2.0, c.g * 2.0, c.b * 2.0) # >1: blooms


## Move the toy's resting spot (on recenter). Snaps there the first time.
func set_home(p: Vector3) -> void:
	home = p
	if not _placed:
		global_position = p
		_placed = true


func _process(delta: float) -> void:
	if not visible:
		return
	if grabbed_by:
		global_transform = (grabbed_by.global_transform * _grab_offset).orthonormalized()
		# Track hand motion so a throw carries its velocity and spin.
		var hp := grabbed_by.global_position
		_hand_vel = _hand_vel.lerp((hp - _hand_prev_pos) / maxf(delta, 1e-4), 0.5)
		var q := Quaternion((grabbed_by.global_basis * _hand_prev_basis.inverse()).orthonormalized())
		var w := q.get_axis() * q.get_angle() / maxf(delta, 1e-4) if q.get_angle() > 1e-5 else Vector3.ZERO
		_hand_ang = _hand_ang.lerp(w, 0.5)
		_hand_prev_pos = hp
		_hand_prev_basis = grabbed_by.global_basis
	else:
		vel += (home - global_position) * SPRING * delta
		vel *= exp(-DAMPING * delta)
		global_position += vel * delta
		if global_position.y < RADIUS: # bounce off the floor
			global_position.y = RADIUS
			vel.y = absf(vel.y) * 0.6
		ang *= exp(-SPIN_DAMPING * delta)
		var idle := Vector3(0.0, 0.25, 0.0) # always a lazy turn, so it looks alive
		var w := ang + idle
		if w.length() > 1e-4:
			global_basis = (Basis(w.normalized(), w.length() * delta) * global_basis).orthonormalized()
	_energy = move_toward(_energy, 0.0, delta * 1.2)
	_mat.set_shader_parameter("energy", _energy + minf(ang.length() * 0.02, 0.6))


func try_grab(hand: Node3D) -> bool:
	if not visible or grabbed_by != null:
		return false
	if hand.global_position.distance_to(global_position) > RADIUS + 0.08:
		return false
	grabbed_by = hand
	_grab_offset = hand.global_transform.affine_inverse() * global_transform
	_hand_prev_pos = hand.global_position
	_hand_prev_basis = hand.global_basis
	_hand_vel = Vector3.ZERO
	_hand_ang = Vector3.ZERO
	_pulse(0.6)
	return true


func release(hand: Node3D) -> void:
	if grabbed_by != hand:
		return
	grabbed_by = null
	vel = _hand_vel
	ang = _constrain_spin(_hand_ang * 1.3)
	_pulse(clampf(vel.length() * 0.3, 0.2, 1.0))


## Push the toy at `point` with velocity `push` (a hand swiping through it, or a click).
func poke(point: Vector3, push: Vector3) -> void:
	if not visible or grabbed_by != null:
		return
	vel += push * 0.7
	var r := point - global_position
	ang = _constrain_spin(ang + r.cross(push) * 70.0)
	_pulse(clampf(push.length() * 0.5, 0.25, 1.0))


## Ray test for clicking. Returns the distance along the ray, or -1.
func hit_ray(origin: Vector3, dir: Vector3) -> float:
	if not visible:
		return -1.0
	var oc := origin - global_position
	var b := oc.dot(dir)
	var c := oc.length_squared() - RADIUS * RADIUS
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	var t := -b - sqrt(disc)
	return t if t > 0.0 else -1.0


## A spinner only really spins about its axle: keep that component (and boost it, it's low-friction).
func _constrain_spin(w: Vector3) -> Vector3:
	if SHAPES[shape] != "Spinner":
		return w
	var axle := global_basis.y.normalized()
	return axle * w.dot(axle) * 1.8 + w * 0.05


func _pulse(strength: float) -> void:
	_energy = maxf(_energy, strength)
	_sparks.amount = int(lerpf(10, 32, strength))
	_sparks.restart()
	touched.emit(strength)


func _add_mesh(m: Mesh, basis := Basis.IDENTITY, pos := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _mat
	mi.transform = Transform3D(basis, pos)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_root.add_child(mi)
