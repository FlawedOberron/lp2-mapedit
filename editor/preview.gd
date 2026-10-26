extends Node3D
# Preview (P): walk the map as a soldier-sized capsule with an over-the-shoulder camera, colliding with the stage
# preview's triangles (the visual mesh: close to the game's collision, not the same). Movement numbers are guesses
# to tune against the game: settings.cfg [preview] overrides any of TUNING.
# WASD move, mouse look, Space jump, C / Ctrl crouch, Shift walk, F grapple (to the surface under the crosshair),
# R back to the start, Esc (or P) back to the editor.

const TUNING := {
	"run": 5.0,            # m/s
	"walk": 2.0,           # Shift
	"crouch_speed": 2.0,
	"jump": 1.1,           # jump height (m)
	"gravity": 20.0,       # m/s^2 (games fall faster than 9.8)
	"height": 1.8,
	"crouch_height": 1.1,
	"radius": 0.35,
	"grapple_range": 40.0, # m
	"grapple_speed": 16.0,
	"slope": 50.0,         # steepest walkable slope (deg)
	"step": 0.45,          # highest ledge walked over (m)
	"fov": 70.0,
}

var main: Node
var t := {}
var body: CharacterBody3D
var shape: CapsuleShape3D
var model: MeshInstance3D
var pivot: Node3D      # yaw on the body's position, pitch on this
var arm: SpringArm3D
var cam: Camera3D
var hud: Label
var cross: Label
var start := Vector3.ZERO
var yaw := 0.0
var pitch := -0.15
var crouched := false
var grapple := Vector3.INF   # the point being pulled to
var rope: MeshInstance3D

func setup(m: Node) -> void:
	main = m
	visible = false
	process_mode = Node.PROCESS_MODE_DISABLED

func begin(at: Vector3, facing: float) -> void:
	t = TUNING.duplicate()
	for k in TUNING:
		t[k] = float(main.cfg.get_value("preview", k, TUNING[k]))
	if body == null:
		_build()
	start = at
	yaw = facing
	_reset()
	visible = true
	process_mode = Node.PROCESS_MODE_INHERIT
	cam.fov = t["fov"]
	cam.current = true
	hud.visible = true
	cross.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func end() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_DISABLED
	hud.visible = false
	cross.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.camera.current = true

func active() -> bool:
	return visible

func _build() -> void:
	body = CharacterBody3D.new()
	body.collision_layer = 0
	body.collision_mask = 1 << (main.LAYER_STAGE - 1)
	body.floor_max_angle = deg_to_rad(t["slope"])
	body.floor_snap_length = t["step"]
	var cs := CollisionShape3D.new()
	shape = CapsuleShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	model = MeshInstance3D.new()
	model.mesh = CapsuleMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.55, 0.2)
	mat.emission_enabled = true   # readable in dark corners and in baked mode
	mat.emission = Color(0.85, 0.55, 0.2)
	mat.emission_energy_multiplier = 0.35
	model.material_override = mat
	body.add_child(model)
	add_child(body)
	pivot = Node3D.new()
	body.add_child(pivot)
	arm = SpringArm3D.new()
	arm.collision_mask = 1 << (main.LAYER_STAGE - 1)
	arm.margin = 0.2
	arm.position = Vector3(0.55, 0, 0)   # over the right shoulder
	pivot.add_child(arm)
	cam = Camera3D.new()
	cam.far = 20000.0
	cam.near = 0.05
	arm.add_child(cam)
	rope = MeshInstance3D.new()
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(0.9, 0.9, 0.9)
	rope.material_override = rm
	rope.visible = false
	add_child(rope)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = main._label("Preview: WASD move, mouse look, Space jump, C crouch, Shift walk, F grapple, R restart, Esc back to the editor")
	hud.position = Vector2(12, 12)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	cross = main._label("+")
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.add_theme_font_size_override("font_size", 24)
	cross.add_theme_color_override("font_outline_color", Color.BLACK)
	cross.add_theme_constant_override("outline_size", 6)
	layer.add_child(cross)

func _reset() -> void:
	crouched = false
	_size()
	body.global_position = start + Vector3(0, t["height"] / 2 + 0.05, 0)
	body.velocity = Vector3.ZERO
	grapple = Vector3.INF
	rope.visible = false
	_aim()

func _size() -> void:
	var h: float = t["crouch_height"] if crouched else t["height"]
	shape.radius = t["radius"]
	shape.height = h
	(model.mesh as CapsuleMesh).radius = t["radius"]
	(model.mesh as CapsuleMesh).height = h
	pivot.position.y = h / 2 - 0.25
	arm.spring_length = 2.0 if crouched else 2.6

func _aim() -> void:
	model.rotation.y = yaw
	pivot.rotation = Vector3(pitch, yaw, 0)
	arm.position = pivot.basis.inverse() * Vector3.ZERO + Vector3(0.55, 0, 0)

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= e.relative.x * 0.003
		pitch = clampf(pitch - e.relative.y * 0.003, -1.3, 1.2)
		_aim()
		get_viewport().set_input_as_handled()
	elif e is InputEventMouseButton and e.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED   # back in after the window lost focus
		get_viewport().set_input_as_handled()
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_ESCAPE, KEY_P:
				main.toggle_preview()
			KEY_R:
				_reset()
			KEY_F:
				_fire_grapple()
			KEY_C, KEY_CTRL:
				_crouch(not crouched)
		get_viewport().set_input_as_handled()

func _crouch(on: bool) -> void:
	if not on:   # stand only where there is room
		var space := body.get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(body.global_position, body.global_position + Vector3.UP * (t["height"] - t["crouch_height"] / 2 + 0.1), body.collision_mask)
		if space.intersect_ray(q):
			return
		body.global_position.y += (t["height"] - t["crouch_height"]) / 2
	crouched = on
	_size()

func _fire_grapple() -> void:
	if grapple != Vector3.INF:
		grapple = Vector3.INF
		rope.visible = false
		return
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * (t["grapple_range"] + arm.spring_length), body.collision_mask)
	var hit := body.get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		grapple = hit["position"]
		rope.visible = true

func _physics_process(dt: float) -> void:
	var g: float = t["gravity"]
	var v := body.velocity
	if grapple != Vector3.INF:
		var to := grapple - body.global_position
		if to.length() < 1.2 or Input.is_key_pressed(KEY_SPACE):
			grapple = Vector3.INF   # arrived (or let go): hop up over the edge
			rope.visible = false
			v = Vector3(0, sqrt(2.0 * g * 1.6), 0) + to.normalized() * 2.0 * Vector3(1, 0, 1)
		else:
			v = to.normalized() * t["grapple_speed"]
			_draw_rope()
	else:
		var input := Vector2.ZERO
		if Input.is_key_pressed(KEY_W): input.y -= 1
		if Input.is_key_pressed(KEY_S): input.y += 1
		if Input.is_key_pressed(KEY_A): input.x -= 1
		if Input.is_key_pressed(KEY_D): input.x += 1
		var speed: float = t["crouch_speed"] if crouched else t["walk"] if Input.is_key_pressed(KEY_SHIFT) else t["run"]
		var wish := Basis(Vector3.UP, yaw) * Vector3(input.x, 0, input.y)
		wish = wish.normalized() * speed if input != Vector2.ZERO else Vector3.ZERO
		var accel := 30.0 if body.is_on_floor() else 6.0
		v.x = move_toward(v.x, wish.x, accel * dt)
		v.z = move_toward(v.z, wish.z, accel * dt)
		if body.is_on_floor():
			if Input.is_key_pressed(KEY_SPACE) and not crouched:
				v.y = sqrt(2.0 * g * t["jump"])
		else:
			v.y -= g * dt
	body.velocity = v
	var before := body.global_position
	body.move_and_slide()
	_step_up(before, v, dt)
	var kill: Variant = (main.project.get("environment", {}) as Dictionary).get("kill_floor")
	if body.global_position.y < (float(kill) * main.CM if kill != null else -500.0):
		_reset()
		main.set_status("Preview: fell out (kill floor), back to the start")

func _step_up(before: Vector3, v: Vector3, dt: float) -> void:
	# walk over low ledges: blocked on the floor while moving -> try the move again from step height
	if not body.is_on_floor() or not body.is_on_wall():
		return
	var flat := Vector3(v.x, 0, v.z) * dt
	if flat.length() < 0.001:
		return
	var up: Vector3 = Vector3.UP * float(t["step"])
	var tr := body.global_transform
	tr.origin = before
	if body.test_move(tr, up):
		return
	tr.origin += up
	if body.test_move(tr, flat):
		return
	body.global_position = tr.origin + flat
	body.apply_floor_snap()

func _draw_rope() -> void:
	var a := body.global_position + Vector3(0, 0.3, 0)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(a)
	im.surface_add_vertex(grapple)
	im.surface_end()
	rope.mesh = im
