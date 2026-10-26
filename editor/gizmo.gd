extends Node3D
# Move / rotate / scale gizmo in world axes, drawn on top and kept the same size on screen.
# main.gd asks hit() on a click, then begin() / drag() / end(); drag() returns the transform to apply to
# everything selected (about the gizmo's origin): new = delta * start.

enum Mode { MOVE, ROTATE, SCALE }
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const COLOURS := [Color(0.95, 0.25, 0.25), Color(0.35, 0.9, 0.3), Color(0.3, 0.5, 1.0)]
const SCREEN := 0.12   # gizmo size as a fraction of the distance to the camera
const PICK_PX := 10.0

var mode := Mode.MOVE
var camera: Camera3D
var allow_scale := true
var allow_tilt := true   # markers only turn about Y
var snap := false
var _handle := -1        # 0..2 axis, 3 = centre (move on the camera plane / uniform scale)
var _start_hit := Vector3.ZERO
var _start_mouse := Vector2.ZERO
var _origin := Vector3.ZERO
var _parts: Array = []

func _ready() -> void:
	_build()

func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.albedo_color = c
	m.render_priority = 10
	return m

func _build() -> void:
	for c in get_children():
		c.queue_free()
	_parts = []
	for a in 3:
		var root := Node3D.new()
		add_child(root)
		var m := _mat(COLOURS[a])
		if mode == Mode.ROTATE:
			var ring := MeshInstance3D.new()
			var tor := TorusMesh.new()
			tor.inner_radius = 0.97
			tor.outer_radius = 1.0
			tor.rings = 48
			ring.mesh = tor
			ring.material_override = m
			root.add_child(ring)
			# the torus lies in XZ (axis Y): turn it to face its axis
			if a == 0:
				root.rotation_degrees.z = 90
			elif a == 2:
				root.rotation_degrees.x = 90
		else:
			var shaft := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.015
			cyl.bottom_radius = 0.015
			cyl.height = 0.8
			shaft.mesh = cyl
			shaft.position.y = 0.4
			shaft.material_override = m
			root.add_child(shaft)
			var tip := MeshInstance3D.new()
			if mode == Mode.MOVE:
				var cone := CylinderMesh.new()
				cone.top_radius = 0.0
				cone.bottom_radius = 0.06
				cone.height = 0.2
				tip.mesh = cone
			else:
				var box := BoxMesh.new()
				box.size = Vector3(0.1, 0.1, 0.1)
				tip.mesh = box
			tip.position.y = 0.9
			tip.material_override = m
			root.add_child(tip)
			if a == 0:
				root.rotation_degrees.z = -90
			elif a == 2:
				root.rotation_degrees.x = 90
		_parts.append(root)
	var centre := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.06
	s.height = 0.12
	centre.mesh = s
	centre.material_override = _mat(Color(0.95, 0.95, 0.95))
	add_child(centre)
	_style()

func set_mode(m: int) -> void:
	mode = m
	_build()

func set_limits(scale_ok: bool, tilt_ok: bool) -> void:
	allow_scale = scale_ok
	allow_tilt = tilt_ok
	_style()

func _style() -> void:
	for a in _parts.size():
		var off := (mode == Mode.SCALE and not allow_scale) or (mode == Mode.ROTATE and not allow_tilt and a != 1)
		_parts[a].visible = not off

func _size() -> float:
	return max(camera.global_position.distance_to(global_position) * SCREEN, 0.05) if camera else 1.0

func _process(_dt: float) -> void:
	if visible and camera:
		scale = Vector3.ONE * _size()

func _screen(p: Vector3) -> Vector2:
	return camera.unproject_position(p)

func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t: float = clamp((p - a).dot(ab) / max(ab.length_squared(), 1e-6), 0.0, 1.0)
	return p.distance_to(a + ab * t)

func hit(mp: Vector2) -> int:
	# the handle under the mouse, or -1
	if not visible or camera.is_position_behind(global_position):
		return -1
	var o := global_position
	var s := _size()
	if _screen(o).distance_to(mp) < PICK_PX + 4 and mode != Mode.ROTATE:
		return 3
	var best := -1
	var best_d := PICK_PX
	for a in 3:
		if not _parts[a].visible:
			continue
		var d := INF
		if mode == Mode.ROTATE:
			var u: Vector3 = AXES[(a + 1) % 3]
			var v: Vector3 = AXES[(a + 2) % 3]
			var prev := _screen(o + u * s)
			for k in range(1, 49):
				var ang := TAU * k / 48.0
				var q := _screen(o + (u * cos(ang) + v * sin(ang)) * s)
				d = min(d, _seg_dist(mp, prev, q))
				prev = q
		else:
			d = _seg_dist(mp, _screen(o), _screen(o + AXES[a] * s))
		if d < best_d:
			best_d = d
			best = a
	return best

func _ray(mp: Vector2) -> Array:
	return [camera.project_ray_origin(mp), camera.project_ray_normal(mp)]

func _axis_param(mp: Vector2, axis: Vector3) -> float:
	# position along the axis line (through the origin) closest to the mouse ray
	var r := _ray(mp)
	var w0: Vector3 = _origin - r[0]
	var b := axis.dot(r[1])
	var d := axis.dot(w0)
	var e: float = (r[1] as Vector3).dot(w0)
	var den := 1.0 - b * b
	if abs(den) < 1e-5:
		return 0.0
	return (b * e - d) / den

func _plane_hit(mp: Vector2, normal: Vector3) -> Variant:
	var r := _ray(mp)
	return Plane(normal, _origin).intersects_ray(r[0], r[1])

func begin(handle: int, mp: Vector2) -> void:
	_handle = handle
	_origin = global_position
	_start_mouse = mp
	if handle == 3:
		var h: Variant = _plane_hit(mp, -camera.global_transform.basis.z)
		_start_hit = h if h != null else _origin
	elif mode == Mode.ROTATE:
		var h2: Variant = _plane_hit(mp, AXES[handle])
		_start_hit = h2 if h2 != null else _origin
	else:
		_start_hit = AXES[handle] * _axis_param(mp, AXES[handle])

func dragging() -> bool:
	return _handle >= 0

func drag(mp: Vector2) -> Transform3D:
	# the change since begin(), about the origin at begin()
	var o := _origin
	if _handle == 3:
		if mode == Mode.SCALE:
			var f := 1.0 + (mp.x - _start_mouse.x) / 200.0
			f = _snap_scale(max(f, 0.01))
			return _about(o, Basis.from_scale(Vector3.ONE * f))
		var h: Variant = _plane_hit(mp, -camera.global_transform.basis.z)
		var d: Vector3 = (h - _start_hit) if h != null else Vector3.ZERO
		return Transform3D(Basis.IDENTITY, _snap_move(d))
	var axis: Vector3 = AXES[_handle]
	if mode == Mode.MOVE:
		var t := _axis_param(mp, axis)
		return Transform3D(Basis.IDENTITY, axis * _snap_len(t - _start_hit.dot(axis)))
	if mode == Mode.ROTATE:
		var h2: Variant = _plane_hit(mp, axis)
		var ang := 0.0
		if h2 != null:
			var a0: Vector3 = (_start_hit - o)
			var a1: Vector3 = (h2 - o)
			ang = a0.signed_angle_to(a1, axis)
		else:
			ang = (mp.x - _start_mouse.x) * 0.01
		if snap:
			ang = snapped(ang, deg_to_rad(15.0))
		return _about(o, Basis(axis, ang))
	var t0: float = _start_hit.dot(axis)
	var t1 := _axis_param(mp, axis)
	var f2: float = t1 / t0 if abs(t0) > 1e-4 else 1.0
	f2 = _snap_scale(max(f2, 0.01))
	var sv := Vector3.ONE
	sv[_handle] = f2
	return _about(o, Basis.from_scale(sv))

func scale_axis() -> int:
	return _handle if mode == Mode.SCALE else -1

func end() -> void:
	_handle = -1

func _about(o: Vector3, b: Basis) -> Transform3D:
	return Transform3D(Basis.IDENTITY, o) * Transform3D(b, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -o)

func _snap_len(x: float) -> float:
	return snapped(x, 0.5) if snap else x

func _snap_move(d: Vector3) -> Vector3:
	return d.snapped(Vector3.ONE * 0.5) if snap else d

func _snap_scale(f: float) -> float:
	return max(snapped(f, 0.1), 0.1) if snap else f
