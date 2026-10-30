extends Camera3D
# Free-fly camera: hold the right mouse button to look, WASD to move, Q / E or Ctrl / Space down / up,
# Shift faster (keys go to the camera only while looking: never typed into a focused field), mouse wheel (while looking) changes the speed. A quick right click (no turn) is a click: right_clicked.
# Middle drag pans: the point grabbed under the mouse follows it (sideways and up / down).

signal right_clicked(at: Vector2)

var speed := 20.0
var _look := false
var _yaw := 0.0
var _pitch := -0.3
var _press_at := Vector2.ZERO
var _press_time := 0
var _turned := 0.0
var _pan := false
var _pan_scale := 0.0   # metres per pixel at the grabbed point's depth

func _ready() -> void:
	far = 20000.0
	near = 0.05
	_apply()

func look_at_point(target: Vector3, from: Vector3) -> void:
	position = from
	var d := (target - from).normalized()
	_yaw = atan2(-d.x, -d.z)
	_pitch = asin(clamp(d.y, -1.0, 1.0))
	_apply()

func _apply() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)

func is_looking() -> bool:
	return _look

func stop_look() -> void:
	_look = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

const MOVE_KEYS := [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_SPACE, KEY_CTRL, KEY_SHIFT]

func _input(e: InputEvent) -> void:
	# before the GUI sees them: while looking, the camera keys are the camera's (no typing, no shortcuts)
	if _look and e is InputEventKey and e.keycode in MOVE_KEYS:
		get_viewport().set_input_as_handled()

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_RIGHT and e.ctrl_pressed and e.shift_pressed:
			return   # Ctrl+Shift+right click: the editor's (deletes a volume's box)
		if e.button_index == MOUSE_BUTTON_RIGHT:
			_look = e.pressed
			if e.pressed:
				get_viewport().gui_release_focus()   # a field focused before must not get WASD after
				_press_at = e.position
				_press_time = Time.get_ticks_msec()
				_turned = 0.0
			elif _turned < 6.0 and Time.get_ticks_msec() - _press_time < 400:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				Input.warp_mouse(_press_at)
				right_clicked.emit(_press_at)
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _look else Input.MOUSE_MODE_VISIBLE
			get_viewport().set_input_as_handled()
		elif e.button_index == MOUSE_BUTTON_MIDDLE:
			_pan = e.pressed and not _look
			if _pan:
				_pan_scale = _depth_at(e.position) * 2.0 * tan(deg_to_rad(fov) / 2.0) / get_viewport().get_visible_rect().size.y
			get_viewport().set_input_as_handled()
		elif _look and e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = min(speed * 1.25, 2000.0)
		elif _look and e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = max(speed / 1.25, 1.0)
	elif e is InputEventMouseMotion and _look:
		_turned += e.relative.length()
		_yaw -= e.relative.x * 0.0035
		_pitch = clamp(_pitch - e.relative.y * 0.0035, -1.55, 1.55)
		_apply()
		get_viewport().set_input_as_handled()
	elif e is InputEventMouseMotion and _pan:
		var b := global_transform.basis
		position += (-b.x * e.relative.x + b.y * e.relative.y) * _pan_scale * (4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		get_viewport().set_input_as_handled()

func _depth_at(mp: Vector2) -> float:
	# distance along the view to whatever is under the mouse (else 20 m)
	var from := project_ray_origin(mp)
	var q := PhysicsRayQueryParameters3D.create(from, from + project_ray_normal(mp) * far)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return 20.0
	return maxf(0.5, (hit["position"] - from).dot(-global_transform.basis.z))

func _process(dt: float) -> void:
	if not _look:
		return
	var v := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): v.z -= 1
	if Input.is_key_pressed(KEY_S): v.z += 1
	if Input.is_key_pressed(KEY_A): v.x -= 1
	if Input.is_key_pressed(KEY_D): v.x += 1
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE): v.y += 1
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_CTRL): v.y -= 1
	if v == Vector3.ZERO:
		return
	var s := speed * (4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	position += global_transform.basis * v.normalized() * s * dt
