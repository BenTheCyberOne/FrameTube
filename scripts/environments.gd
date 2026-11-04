class_name Environments
extends Node3D
## Background "rooms" around the flat screen: procedural sky + grid floor (+ props for Cinema), tinted by the
## accent colour and lit by the video's average colour (bias lighting). All procedural — no asset files.

const STYLES := ["Midnight", "Starfield", "Synthwave", "Aurora", "Cinema", "Daydream"]

# Per style: floor base, grid line colour (null = accent), line strength, grid size, scroll, horizon, glow on floor
const FLOOR := [
	[Color(0.012, 0.014, 0.024), null, 0.22, 1.0, 0.0, Color(0.02, 0.03, 0.06), 0.35],
	[Color(0.004, 0.004, 0.01), null, 0.10, 2.0, 0.0, Color(0.003, 0.003, 0.008), 0.25],
	[Color(0.03, 0.0, 0.05), Color(1.0, 0.25, 0.8), 1.1, 1.5, 0.5, Color(0.14, 0.02, 0.11), 0.3],
	[Color(0.006, 0.02, 0.03), Color(0.2, 0.9, 0.6), 0.10, 3.0, 0.0, Color(0.008, 0.035, 0.05), 0.3],
	[Color(0.045, 0.012, 0.016), Color(0, 0, 0), 0.0, 1.0, 0.0, Color(0.01, 0.003, 0.004), 0.6],
	[Color(0.62, 0.64, 0.74), Color(1, 1, 1), 0.35, 1.0, 0.0, Color(0.9, 0.8, 0.86), 0.2],
]

var style := 0
var accent := Color(0.3, 0.64, 1.0)
var bias_light := true
var bloom := true

var env: Environment
var sky_mat: ShaderMaterial
var floor_mesh: MeshInstance3D
var floor_mat: ShaderMaterial
var cinema: Node3D
var screen_light: OmniLight3D
var _flat := true
var _glow := Color.BLACK
var _strips: Array[StandardMaterial3D] = []


## content = the recentred node that holds the screen; room props are parented to it.
func build(content: Node3D) -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32 # nothing reflective; keep the animated sky cheap
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.08, 0.08, 0.1)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.glow_intensity = 0.7
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 0.85
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	floor_mat = ShaderMaterial.new()
	floor_mat.shader = preload("res://shaders/floor.gdshader")
	floor_mesh = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80, 80)
	floor_mesh.mesh = pm
	floor_mesh.material_override = floor_mat
	floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_mesh)

	screen_light = OmniLight3D.new()
	screen_light.omni_range = 14.0
	screen_light.omni_attenuation = 1.2
	screen_light.position = Vector3(0, 1.6, -3.4)
	content.add_child(screen_light)
	cinema = _build_cinema()
	content.add_child(cinema)
	set_style(0)


func set_style(i: int) -> void:
	style = clampi(i, 0, STYLES.size() - 1)
	sky_mat.set_shader_parameter("style", style)
	var f: Array = FLOOR[style]
	floor_mat.set_shader_parameter("base", f[0])
	floor_mat.set_shader_parameter("line_color", accent if f[1] == null else f[1])
	floor_mat.set_shader_parameter("line_strength", f[2])
	floor_mat.set_shader_parameter("grid_size", f[3])
	floor_mat.set_shader_parameter("scroll", f[4])
	floor_mat.set_shader_parameter("horizon", f[5])
	floor_mat.set_shader_parameter("glow_strength", f[6] if bias_light else 0.0)
	_update_visibility()


func set_accent(c: Color) -> void:
	accent = c
	sky_mat.set_shader_parameter("accent", c)
	for m in _strips:
		m.emission = c
	set_style(style)


func set_bias_light(on: bool) -> void:
	bias_light = on
	set_style(style)


func set_bloom(on: bool) -> void:
	bloom = on
	_update_visibility()


## Flat modes show the room; sphere modes cover everything with the video (and skip bloom on it).
func set_flat(flat: bool) -> void:
	_flat = flat
	_update_visibility()


## Rotate the sky with recentering so the Synthwave sun / aurora stay behind the screen.
func set_yaw(yaw: float) -> void:
	env.sky_rotation = Vector3(0, yaw, 0)


## Called every frame with the video's average colour (sRGB) and the screen's transform
## (the screen can be moved, so the light pool and the cinema's screen light follow it).
func update(video_color: Color, screen_xf: Transform3D, playing: bool, delta: float) -> void:
	var target := video_color.srgb_to_linear() if playing and bias_light else Color.BLACK
	_glow = _glow.lerp(target, 1.0 - exp(-delta * 4.0)) # smooth, so cuts don't strobe
	floor_mat.set_shader_parameter("glow", _glow)
	floor_mat.set_shader_parameter("screen_pos", screen_xf.origin)
	screen_light.global_position = screen_xf.origin + screen_xf.basis.z.normalized() * 0.6
	sky_mat.set_shader_parameter("glow", _glow)
	sky_mat.set_shader_parameter("glow_strength", 0.12 if bias_light and style != 5 else 0.0)
	var lum := _glow.get_luminance()
	screen_light.light_color = _glow if lum > 0.001 else Color.BLACK
	screen_light.light_energy = (1.2 + lum * 7.0) if bias_light and style == 4 else 0.0
	# Cinema without bias lighting still needs to be visible: a dim warm house light.
	env.ambient_light_color = Color(0.09, 0.08, 0.09) if style == 4 and bias_light else Color(0.16, 0.14, 0.14)


func _update_visibility() -> void:
	floor_mesh.visible = _flat
	cinema.visible = _flat and style == 4
	env.glow_enabled = bloom and _flat


func _build_cinema() -> Node3D:
	var root := Node3D.new()
	var wall := _mat(Color(0.16, 0.14, 0.16), 0.9)
	var velvet := _mat(Color(0.5, 0.05, 0.09), 1.0)
	var seat := _mat(Color(0.38, 0.05, 0.07), 0.8)

	# Room shell from inward-facing quads. (BoxMesh.flip_faces only flips winding, not normals, so a
	# flipped box stays black inside.) Room: x -6.5..6.5, y 0..6, z -10.5..5.5; the floor shader is the floor.
	var ceiling := _mat(Color(0.07, 0.06, 0.07), 1.0)
	_quad(Vector2(13, 6), Vector3(0, 3, -10.5), Basis.IDENTITY, wall, root) # front (behind the screen)
	_quad(Vector2(13, 6), Vector3(0, 3, 5.5), Basis(Vector3.UP, PI), wall, root) # back
	_quad(Vector2(16, 6), Vector3(-6.5, 3, -2.5), Basis(Vector3.UP, PI / 2), wall, root) # left
	_quad(Vector2(16, 6), Vector3(6.5, 3, -2.5), Basis(Vector3.UP, -PI / 2), wall, root) # right
	_quad(Vector2(13, 16), Vector3(0, 6, -2.5), Basis(Vector3.RIGHT, PI / 2), ceiling, root) # ceiling

	# Warm sconces along the side walls give the room shape even when the video is dark.
	var lamp := _mat(Color.BLACK, 1.0)
	lamp.emission_enabled = true
	lamp.emission = Color(1.0, 0.7, 0.45)
	lamp.emission_energy_multiplier = 3.0
	for x in [-6.4, 6.4]:
		for z in [-7.0, -1.5, 3.0]:
			_box(Vector3(0.08, 0.35, 0.18), Vector3(x, 3.2, z), lamp, root)
			var l := OmniLight3D.new()
			l.position = Vector3(x * 0.95, 3.4, z)
			l.light_color = Color(1.0, 0.72, 0.5)
			l.light_energy = 0.5
			l.omni_range = 3.5
			root.add_child(l)

	for side in [-1.0, 1.0]: # side curtains framing the screen
		var c := _box(Vector3(1.2, 5.6, 0.25), Vector3(side * 5.2, 2.8, -4.3), velvet, root)
		c.rotation.y = side * 0.2
		for k in 5: # soft folds
			_box(Vector3(0.18, 5.6, 0.32), Vector3(side * (4.7 + k * 0.22), 2.8, -4.2 + k * 0.02), velvet, root)

	for x in [-6.45, 6.45]: # LED strips along the side walls (accent coloured)
		var strip := _mat(Color.BLACK, 1.0)
		strip.emission_enabled = true
		strip.emission = accent
		strip.emission_energy_multiplier = 2.5
		_strips.append(strip)
		_box(Vector3(0.04, 0.04, 15.5), Vector3(x, 0.25, -2.5), strip, root)
		_box(Vector3(0.04, 0.04, 15.5), Vector3(x, 5.6, -2.5), strip, root)

	# Seats: your row (either side of you) and one row in front, below eye level.
	for row in [[0.0, [-2.1, -1.4, -0.7, 0.7, 1.4, 2.1]], [-1.3, [-2.1, -1.4, -0.7, 0.0, 0.7, 1.4, 2.1]]]:
		for x in row[1]:
			_box(Vector3(0.6, 0.45, 0.55), Vector3(x, 0.23, row[0]), seat, root)
			_box(Vector3(0.6, 0.75, 0.12), Vector3(x, 0.75, row[0] + 0.3), seat, root)
			_box(Vector3(0.08, 0.25, 0.5), Vector3(x + 0.34, 0.6, row[0]), wall, root)
	return root


static func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


## A quad whose front (+Z of `basis`) faces into the room.
static func _quad(size: Vector2, pos: Vector3, basis: Basis, mat: Material, parent: Node3D) -> void:
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = size
	mi.mesh = qm
	mi.material_override = mat
	mi.transform = Transform3D(basis, pos)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


static func _box(size: Vector3, pos: Vector3, mat: Material, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi
