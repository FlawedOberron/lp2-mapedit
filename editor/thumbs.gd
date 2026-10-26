extends Node
# Thumbnails of meshes, rendered one per frame in an off-screen viewport with its own world.
# request(mesh, materials, done) calls done(ImageTexture) later; request_scene(make, done) does a whole model
# (make() returns it when its turn comes, so models load one per frame; freed after); clear() drops what has not been rendered yet.

const SIZE := 112

var _vp: SubViewport
var _cam: Camera3D
var _mi: MeshInstance3D
var _queue: Array = []
var _busy := false

func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(SIZE, SIZE)
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.75)
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	_vp.add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 40.0
	_vp.add_child(_cam)
	_cam.current = true
	_mi = MeshInstance3D.new()
	_vp.add_child(_mi)

func request(mesh: Mesh, materials: Array, done: Callable) -> void:
	_queue.append([mesh, materials, done])

func request_scene(make: Callable, done: Callable) -> void:
	_queue.append([make, [], done])

func clear() -> void:
	_queue = []

func _process(_dt: float) -> void:
	if not _busy and not _queue.is_empty():
		_render(_queue.pop_front())

func _render(job: Array) -> void:
	_busy = true
	var box: AABB
	var scene: Node3D = null
	if job[0] is Callable:
		scene = job[0].call()
		if scene == null:
			_busy = false
			return
		_vp.add_child(scene)
		box = AABB()
		var first := true
		var mis: Array = scene.find_children("*", "MeshInstance3D", true, false)
		if scene is MeshInstance3D:
			mis.append(scene)
		for mi in mis:
			var b: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			box = b if first else box.merge(b)
			first = false
	else:
		var mesh: Mesh = job[0]
		_mi.mesh = mesh
		for s in mesh.get_surface_count():
			_mi.set_surface_override_material(s, job[1][s] if s < job[1].size() else null)
		box = mesh.get_aabb()
	# a three-quarter view from above that fits the mesh's bounding sphere
	var c := box.get_center()
	var r: float = max(box.size.length() * 0.5, 0.1)
	var dist := r / sin(deg_to_rad(_cam.fov * 0.5))
	_cam.near = max(dist - r * 1.5, 0.05)
	_cam.far = dist + r * 1.5
	_cam.look_at_from_position(c + Vector3(1.0, 0.75, 1.0).normalized() * dist, c)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	_mi.mesh = null
	if scene:
		scene.queue_free()
	_busy = false
	if job[2].is_valid():
		job[2].call(ImageTexture.create_from_image(img))
