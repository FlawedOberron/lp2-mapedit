extends Node
# Hand editing of the navmesh (navmesh.gd's Hand edit). The navmesh is frozen into the project as an OBJ
# (project.json "nav_mesh", metres, Y up, triangles; lp2navmap.py builds from it instead of generating one), which is
# also the export / import (Blender's OBJ settings: forward -Z, up Y, the defaults).
#
# Select: click triangles (Shift adds / removes), or drag a box (Shift adds). Drag a vertex handle onto another
# vertex: the two merge (a weld). Enter: the selection becomes one n-gon (its outline; holes stay holes). In the
# n-gon: drag its vertices (onto the level under the mouse with Snap, else level at their height; dropped onto a
# vertex outside the n-gon they merge), click an outline edge to add a vertex there (a triangle outside on that edge is
# split to match), Delete removes the vertex under the mouse (not one a triangle outside uses). Enter again:
# re-triangulated into the navmesh; Esc: back as it was. Ctrl+Z: undo the last change (Undo edit too).

const HANDLE := 0.14           # m: a vertex handle's size
const PICK_PX := 10.0          # px: a vertex / edge this close to the mouse is under it
const DRAG_PX := 4.0           # px: a press moving this far is a drag
const MERGE_PX := 12.0         # px: a vertex dropped this close to another merges with it
const UNDO_MOST := 40
const COL_TRI := Color(0.15, 0.85, 0.35, 0.40)
const COL_SEL := Color(1.0, 1.0, 1.0, 0.55)
const COL_NGON := Color(1.0, 0.85, 0.2, 0.45)
const COL_EDGE := Color(0.05, 0.1, 0.05, 0.9)
const COL_OUTLINE := Color(1.0, 0.85, 0.1)
const COL_VERT := Color(0.9, 0.95, 1.0)
const COL_LOCKED := Color(1.0, 0.45, 0.15)
const COL_HOT := Color(1.0, 0.2, 1.0)

var main: Node
var win: Control
var verts := PackedVector3Array()   # m
var faces := PackedInt32Array()     # 3 per triangle
var on := false
var dir := ""                       # the project the mesh is from
var snap := true
var sel := {}                       # triangle index -> true
var ngon := false                   # editing an n-gon
var loops: Array = []               # the n-gon's outline loops (vertex indices; 0 the outside, the rest holes)
var _held := PackedInt32Array()     # the n-gon's original triangles (Esc puts them back)
var _wind := 1.0                    # the navmesh's winding seen from above (sign of the area over x / z)
var _undo: Array = []
var _hot := -1                      # the vertex under the mouse
var _press: Variant = null          # where the left button went down (screen)
var _drag_v := -1                   # the vertex being dragged
var _drag_y := 0.0
var _box := false                   # dragging a selection box
var _rect: ReferenceRect
var _layer: CanvasLayer
var tri_mi: MeshInstance3D
var line_mi: MeshInstance3D
var handles: MultiMeshInstance3D
var _pieces := PackedInt32Array()

func setup(m: Node, w: Control) -> void:
	main = m
	win = w
	tri_mi = _mesh_node(true)
	line_mi = _mesh_node(false)
	handles = MultiMeshInstance3D.new()
	handles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hm := StandardMaterial3D.new()
	hm.vertex_color_use_as_albedo = true
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.no_depth_test = true
	handles.material_override = hm
	handles.visible = false
	main.world.add_child(handles)
	_layer = CanvasLayer.new()
	_rect = ReferenceRect.new()
	_rect.border_color = Color(1, 1, 1, 0.9)
	_rect.editor_only = false
	_rect.visible = false
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_rect)
	main.add_child(_layer)

func _mesh_node(tris: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if tris:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	else:
		mat.no_depth_test = true
	mi.material_override = mat
	mi.visible = false
	main.world.add_child(mi)
	return mi

# ---------------------------------------------------------------- the frozen mesh (OBJ)

func obj_path() -> String:
	var rel: Variant = main.project.get("nav_mesh")
	return main.project_dir.path_join(rel) if rel is String and rel != "" and main.project_dir != "" else ""

static func read_obj(path: String) -> Array:
	# -> [verts (m), faces] (polygons triangulated over x / z), [] when unreadable
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return []
	var vs := PackedVector3Array()
	var fs := PackedInt32Array()
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("v "):
			var p := line.split(" ", false)
			if p.size() >= 4:
				vs.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif line.begins_with("f "):
			var p := line.split(" ", false)
			var ids := PackedInt32Array()
			for k in range(1, p.size()):
				var n := int(p[k].split("/")[0])
				ids.append(n - 1 if n > 0 else vs.size() + n)
			if ids.size() == 3:
				fs.append_array(ids)
			elif ids.size() > 3:
				var poly := PackedVector2Array()
				for i in ids:
					poly.append(Vector2(vs[i].x, vs[i].z))
				var t := Geometry2D.triangulate_polygon(poly)
				if t.is_empty():   # not simple: a fan
					for k in range(1, ids.size() - 1):
						fs.append_array([ids[0], ids[k], ids[k + 1]])
				else:
					for k in t:
						fs.append(ids[k])
	return [vs, fs]

func write_obj(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return false
	f.store_line("# LP2 Map Editor navmesh: metres, Y up (Blender OBJ: forward -Z, up Y)")
	var used := PackedInt32Array()
	used.resize(verts.size())
	for i in faces:
		used[i] = 1
	var remap := PackedInt32Array()
	remap.resize(verts.size())
	var n := 0
	for i in verts.size():
		if used[i] == 1:
			n += 1
			remap[i] = n
			f.store_line("v %.4f %.4f %.4f" % [verts[i].x, verts[i].y, verts[i].z])
	for t in faces.size() / 3:
		f.store_line("f %d %d %d" % [remap[faces[t * 3]], remap[faces[t * 3 + 1]], remap[faces[t * 3 + 2]]])
	f.close()
	return true

func freeze(tris: PackedVector3Array) -> bool:
	# the built navmesh (navmesh.bin's triangles, all of them: what was left out can still be added back) as the
	# project's hand-edited mesh
	from_tris(tris)
	return save()

func from_tris(tris: PackedVector3Array) -> void:
	# corners at the same spot (to the mm) become one vertex
	_undo = []
	sel = {}
	ngon = false
	loops = []
	verts = PackedVector3Array()
	faces = PackedInt32Array()
	var at := {}
	for p in tris:
		var k := Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))
		if not at.has(k):
			at[k] = verts.size()
			verts.append(p)
		faces.append(at[k])
	_clean()

func load_mesh() -> bool:
	var r := read_obj(obj_path()) if obj_path() != "" else []
	if r.is_empty():
		return false
	verts = r[0]
	faces = r[1]
	dir = main.project_dir
	_undo = []
	sel = {}
	ngon = false
	return true

func save() -> bool:
	if main.project_dir == "":
		return false
	dir = main.project_dir
	if not main.project.get("nav_mesh") is String:
		main._push_undo("")
		main.project["nav_mesh"] = "assets/nav/edited.obj"
	DirAccess.make_dir_recursive_absolute(obj_path().get_base_dir())
	return write_obj(obj_path())

func _snapshot() -> void:
	_undo.append([verts.duplicate(), faces.duplicate()])
	if _undo.size() > UNDO_MOST:
		_undo.pop_front()

func undo() -> void:
	if ngon:
		cancel_ngon()
		return
	if _undo.is_empty():
		main.set_status("Nothing to undo in the navmesh")
		return
	var s: Array = _undo.pop_back()
	verts = s[0]
	faces = s[1]
	sel = {}
	save()
	redraw()
	main.set_status("Navmesh: undone (rebuild to use it)")

func _clean() -> void:
	# drop triangles with a repeated corner, and repeated triangles
	var out := PackedInt32Array()
	var seen := {}
	for t in faces.size() / 3:
		var a := faces[t * 3]
		var b := faces[t * 3 + 1]
		var c := faces[t * 3 + 2]
		if a == b or b == c or a == c:
			continue
		var k := [mini(a, mini(b, c)), maxi(a, maxi(b, c)), a + b + c]
		if seen.has(k):
			continue
		seen[k] = true
		out.append_array([a, b, c])
	faces = out

# ---------------------------------------------------------------- drawing

func set_on(v: bool) -> void:
	on = v
	if not v:
		if ngon:
			cancel_ngon()
		sel = {}
		_rect.visible = false
	redraw()

func redraw(full := true) -> void:
	tri_mi.visible = on
	line_mi.visible = on
	handles.visible = on
	if not on:
		return
	var nt := faces.size() / 3
	var keep := PackedByteArray()
	keep.resize(nt)
	keep.fill(1)
	var tv := PackedVector3Array()
	tv.resize(nt * 3)
	for i in faces.size():
		tv[i] = verts[faces[i]]
	if full or _pieces.size() != nt:   # not while dragging a vertex (slow on big maps)
		_pieces = win.pieces_of(tv, keep)
	var pos := PackedVector3Array()
	var cols := PackedColorArray()
	var lift := Vector3(0, 0.2, 0)
	for t in nt:
		var col: Color = COL_SEL if sel.has(t) else win.piece_colour(_pieces[t])
		pos.append_array([tv[t * 3] + lift, tv[t * 3 + 2] + lift, tv[t * 3 + 1] + lift])
		cols.append_array([col, col, col])
	var ng := ngon_tris()
	for t in ng.size() / 3:
		pos.append_array([verts[ng[t * 3]] + lift, verts[ng[t * 3 + 2]] + lift, verts[ng[t * 3 + 1]] + lift])
		cols.append_array([COL_NGON, COL_NGON, COL_NGON])
	var m := ArrayMesh.new()
	if pos.size():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = pos
		arr[Mesh.ARRAY_COLOR] = cols
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	tri_mi.mesh = m
	# edges (each once) and the n-gon's outline
	var lp := PackedVector3Array()
	var lc := PackedColorArray()
	var seen := {}
	for t in nt:
		for e in 3:
			var a := faces[t * 3 + e]
			var b := faces[t * 3 + (e + 1) % 3]
			var k := Vector2i(mini(a, b), maxi(a, b))
			if seen.has(k):
				continue
			seen[k] = true
			lp.append_array([verts[a] + lift, verts[b] + lift])
			lc.append_array([COL_EDGE, COL_EDGE])
	for loop in loops:
		for i in loop.size():
			lp.append_array([verts[loop[i]] + lift, verts[loop[(i + 1) % loop.size()]] + lift])
			lc.append_array([COL_OUTLINE, COL_OUTLINE])
	var lm := ArrayMesh.new()
	if lp.size():
		var la := []
		la.resize(Mesh.ARRAY_MAX)
		la[Mesh.ARRAY_VERTEX] = lp
		la[Mesh.ARRAY_COLOR] = lc
		lm.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, la)
	line_mi.mesh = lm
	_draw_handles()

func _draw_handles() -> void:
	var shown := PackedInt32Array()
	if ngon:
		for loop in loops:
			shown.append_array(PackedInt32Array(loop))
	else:
		var used := {}
		for i in faces:
			used[i] = true
		shown = PackedInt32Array(used.keys())
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var bm := BoxMesh.new()
	bm.size = Vector3(HANDLE, HANDLE, HANDLE)
	mm.mesh = bm
	mm.instance_count = shown.size()
	var locked := _outside_used() if ngon else {}
	for k in shown.size():
		var i := shown[k]
		mm.set_instance_transform(k, Transform3D(Basis(), verts[i] + Vector3(0, 0.2, 0)))
		mm.set_instance_color(k, COL_HOT if i == _hot else COL_LOCKED if locked.has(i) else COL_VERT)
	handles.multimesh = mm

# ---------------------------------------------------------------- picking

func _screen(p: Vector3) -> Variant:
	var cam: Camera3D = main.camera
	if cam.is_position_behind(p):
		return null
	return cam.unproject_position(p)

func _vertex_at(at: Vector2, only: Dictionary = {}, skip: int = -1) -> int:
	var best := -1
	var best_d := PICK_PX
	var used := {}
	for i in faces:
		used[i] = true
	for i in used.keys():
		if i == skip or (not only.is_empty() and not only.has(i)):
			continue
		var s: Variant = _screen(verts[i] + Vector3(0, 0.2, 0))
		if s == null:
			continue
		var d := (s as Vector2).distance_to(at)
		if d < best_d:
			best_d = d
			best = i
	return best

func _tri_at(at: Vector2) -> int:
	var cam: Camera3D = main.camera
	var from := cam.project_ray_origin(at)
	var dir := cam.project_ray_normal(at)
	var best := INF
	var hit := -1
	var lift := Vector3(0, 0.2, 0)
	for t in faces.size() / 3:
		var q: Variant = Geometry3D.ray_intersects_triangle(from, dir, verts[faces[t * 3]] + lift, verts[faces[t * 3 + 1]] + lift, verts[faces[t * 3 + 2]] + lift)
		if q != null and from.distance_to(q) < best:
			best = from.distance_to(q)
			hit = t
	return hit

func _outline_edge_at(at: Vector2) -> Array:
	# the n-gon outline edge under the mouse -> [loop, index of its first corner, point on it (m)], [] none
	for li in loops.size():
		var loop: Array = loops[li]
		for i in loop.size():
			var a: Vector3 = verts[loop[i]]
			var b: Vector3 = verts[loop[(i + 1) % loop.size()]]
			var sa: Variant = _screen(a + Vector3(0, 0.2, 0))
			var sb: Variant = _screen(b + Vector3(0, 0.2, 0))
			if sa == null or sb == null:
				continue
			var c := Geometry2D.get_closest_point_to_segment(at, sa, sb)
			if c.distance_to(at) <= PICK_PX * 0.8:
				var len2 := (sb as Vector2).distance_squared_to(sa)
				var t := clampf((c - (sa as Vector2)).dot((sb as Vector2) - (sa as Vector2)) / maxf(len2, 0.001), 0.0, 1.0)
				if t > 0.05 and t < 0.95:
					return [li, i, a.lerp(b, t)]
	return []

# ---------------------------------------------------------------- input

func handle_input(e: InputEvent) -> bool:
	# -> true when used. Called by navmesh.gd while hand editing (the view and the window's own keys)
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				if ngon:
					commit_ngon()
				else:
					start_ngon()
				return true
			KEY_ESCAPE:
				if ngon:
					cancel_ngon()
				else:
					sel = {}
					redraw()
				return true
			KEY_DELETE, KEY_BACKSPACE:
				if ngon and _hot >= 0:
					_remove_vertex(_hot)
				return true
			KEY_Z:
				if e.ctrl_pressed:
					undo()
					return true
		return false
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_press = e.position
			_drag_v = _vertex_at(e.position, _loop_set() if ngon else {})
			if _drag_v >= 0:
				_drag_y = verts[_drag_v].y
				_snapshot_once()
			return true
		# release
		var was_drag := _press != null and (e.position as Vector2).distance_to(_press) > DRAG_PX
		if _drag_v >= 0:
			if was_drag:
				_drop_vertex(_drag_v, e.position)
			_drag_v = -1
			_snapshot_pending = false
		elif _box:
			_box_select(_press, e.position, e.shift_pressed)
			_box = false
			_rect.visible = false
		elif not was_drag:
			_click(e.position, e.shift_pressed)
		_press = null
		return true
	if e is InputEventMouseMotion:
		if _press != null and (e.button_mask & MOUSE_BUTTON_MASK_LEFT):
			if _drag_v >= 0:
				if (e.position as Vector2).distance_to(_press) > DRAG_PX:
					_move_vertex(_drag_v, e.position)
			elif not ngon and (e.position as Vector2).distance_to(_press) > DRAG_PX:
				_box = true
				var r := Rect2(_press, Vector2.ZERO).expand(e.position)
				_rect.position = r.position
				_rect.size = r.size
				_rect.visible = true
			return true
		var h := _vertex_at(e.position, _loop_set() if ngon else {})
		if h != _hot:
			_hot = h
			_draw_handles()
		return false
	return false

var _snapshot_pending := false
func _snapshot_once() -> void:
	# a vertex drag is one undo step, taken when the press lands on a vertex
	if not _snapshot_pending and not ngon:
		_snapshot()
	_snapshot_pending = true

func _loop_set() -> Dictionary:
	var s := {}
	for loop in loops:
		for i in loop:
			s[i] = true
	return s

func _click(at: Vector2, shift: bool) -> void:
	if ngon:
		var ed := _outline_edge_at(at)
		if not ed.is_empty():
			_insert_vertex(ed[0], ed[1], ed[2])
		return
	var t := _tri_at(at)
	if not shift:
		sel = {}
	if t >= 0:
		if shift and sel.has(t):
			sel.erase(t)
		else:
			sel[t] = true
	main.set_status("%d triangle%s selected: Enter makes an n-gon of them" % [sel.size(), "" if sel.size() == 1 else "s"] if sel.size() else "")
	redraw()

func _box_select(a: Vector2, b: Vector2, shift: bool) -> void:
	var r := Rect2(a, Vector2.ZERO).expand(b)
	if not shift:
		sel = {}
	for t in faces.size() / 3:
		var c := (verts[faces[t * 3]] + verts[faces[t * 3 + 1]] + verts[faces[t * 3 + 2]]) / 3.0 + Vector3(0, 0.2, 0)
		var s: Variant = _screen(c)
		if s != null and r.has_point(s):
			sel[t] = true
	main.set_status("%d triangle%s selected: Enter makes an n-gon of them" % [sel.size(), "" if sel.size() == 1 else "s"])
	redraw()

func _move_vertex(i: int, at: Vector2) -> void:
	var cam: Camera3D = main.camera
	var from := cam.project_ray_origin(at)
	var dir := cam.project_ray_normal(at)
	var p: Variant = null
	if snap:
		var hit: Dictionary = main._ray(from, from + dir * 2000.0, (1 << (main.LAYER_STAGE - 1)) | (1 << (main.LAYER_COLLISION - 1)))
		if hit:
			p = hit["position"]
	if p == null:
		p = Plane(Vector3.UP, _drag_y).intersects_ray(from, dir)
	if p != null:
		verts[i] = p
		redraw(false)

func _drop_vertex(i: int, at: Vector2) -> void:
	# dropped onto another vertex (outside the n-gon while editing one): merged into it
	var onto := _vertex_at(at, {}, i)
	if onto >= 0 and (not ngon or not _loop_set().has(onto)):
		_merge(i, onto)
		main.set_status("Vertices merged (rebuild the navmesh to use it)")
	elif not ngon:
		main.set_status("Vertex moved (rebuild the navmesh to use it)")
	if not ngon:
		_clean()
		save()
	redraw()

func _merge(from_i: int, into: int) -> void:
	for k in faces.size():
		if faces[k] == from_i:
			faces[k] = into
	for loop in loops:
		for k in loop.size():
			if loop[k] == from_i:
				loop[k] = into
	for k in _held.size():
		if _held[k] == from_i:
			_held[k] = into
	if ngon:   # a loop that now repeats a corner drops the repeat
		for loop in loops:
			var k := 0
			while k < loop.size() and loop.size() > 3:
				if loop[k] == loop[(k + 1) % loop.size()]:
					loop.remove_at(k)
				else:
					k += 1
	else:
		_clean()

# ---------------------------------------------------------------- the n-gon

func _outside_used() -> Dictionary:
	# vertices a triangle outside the n-gon uses (they can't be removed)
	var s := {}
	for i in faces:
		s[i] = true
	return s

func start_ngon() -> void:
	if sel.is_empty():
		main.set_status("Select triangles first (click, Shift+click, or drag a box)")
		return
	# the selection's outline: directed edges with no reverse among the selection
	var directed := {}
	for t in sel.keys():
		for e in 3:
			directed[Vector2i(faces[t * 3 + e], faces[t * 3 + (e + 1) % 3])] = true
	var nxt := {}
	for k in directed.keys():
		if not directed.has(Vector2i(k.y, k.x)):
			if nxt.has(k.x):
				main.set_status("Can't make one n-gon: the selection touches itself at a corner (select a bit more or less)")
				return
			nxt[k.x] = k.y
	if nxt.is_empty():
		return
	var found: Array = []
	var left := nxt.duplicate()
	while not left.is_empty():
		var start: int = left.keys()[0]
		var loop: Array = []
		var v := start
		while left.has(v):
			loop.append(v)
			var w: int = left[v]
			left.erase(v)
			v = w
		if v != start or loop.size() < 3:
			main.set_status("Can't make one n-gon: the selection's outline doesn't close")
			return
		found.append(loop)
	# the outside: the loop with the largest area (seen from above); one selection piece only
	var best := 0
	var areas: Array = []
	for i in found.size():
		areas.append(_area(found[i]))
		if absf(areas[i]) > absf(areas[best]):
			best = i
	for i in found.size():
		if i != best and signf(areas[i]) == signf(areas[best]):
			main.set_status("Can't make one n-gon: the selection is in separate parts (one at a time)")
			return
	_wind = signf(areas[best]) if areas[best] != 0.0 else 1.0
	loops = [found[best]]
	for i in found.size():
		if i != best:
			loops.append(found[i])
	_snapshot()
	# take the selection out while editing
	var keep := PackedInt32Array()
	_held = PackedInt32Array()
	for t in faces.size() / 3:
		var tri := faces.slice(t * 3, t * 3 + 3)
		if sel.has(t):
			_held.append_array(tri)
		else:
			keep.append_array(tri)
	faces = keep
	sel = {}
	ngon = true
	main.set_status("N-gon: drag its corners, click its outline to add one, Delete removes the one under the mouse; Enter: done, Esc: cancel")
	redraw()

func _area(loop: Array) -> float:
	var a := 0.0
	for i in loop.size():
		var p: Vector3 = verts[loop[i]]
		var q: Vector3 = verts[loop[(i + 1) % loop.size()]]
		a += p.x * q.z - q.x * p.z
	return a * 0.5

func cancel_ngon() -> void:
	if not ngon:
		return
	var s: Array = _undo.pop_back() if _undo.size() else [verts, faces]
	verts = s[0]
	faces = s[1]
	ngon = false
	loops = []
	_held = PackedInt32Array()
	main.set_status("N-gon cancelled")
	redraw()

func _insert_vertex(li: int, i: int, p: Vector3) -> void:
	var loop: Array = loops[li]
	var a: int = loop[i]
	var b: int = loop[(i + 1) % loop.size()]
	if snap:
		var hit: Dictionary = main._ray(p + Vector3(0, 1.5, 0), p - Vector3(0, 3.0, 0), (1 << (main.LAYER_STAGE - 1)) | (1 << (main.LAYER_COLLISION - 1)))
		if hit:
			p = hit["position"]
	var n := verts.size()
	verts.append(p)
	loop.insert(i + 1, n)
	# a triangle outside on that edge (b -> a) is split to match
	for t in faces.size() / 3:
		for e in 3:
			if faces[t * 3 + e] == b and faces[t * 3 + (e + 1) % 3] == a:
				var c := faces[t * 3 + (e + 2) % 3]
				faces[t * 3 + (e + 1) % 3] = n
				faces.append_array([n, a, c])
				redraw()
				return
	redraw()

func _remove_vertex(i: int) -> void:
	if _outside_used().has(i):
		main.set_status("That corner is used by triangles outside the n-gon: it can be moved, not removed")
		return
	for loop in loops:
		var k: int = loop.find(i)
		if k >= 0:
			if loop.size() <= 3:
				main.set_status("An outline needs at least 3 corners")
				return
			loop.remove_at(k)
			_hot = -1
			redraw()
			return

func ngon_tris() -> PackedInt32Array:
	# the n-gon triangulated (holes bridged into the outside), [] when the outline crosses itself
	if not ngon or loops.is_empty():
		return PackedInt32Array()
	var outer: Array = loops[0].duplicate()
	if _area(outer) < 0.0:
		outer.reverse()
	var holes: Array = []
	for k in range(1, loops.size()):
		var h: Array = loops[k].duplicate()
		if _area(h) > 0.0:
			h.reverse()
		holes.append(h)
	# bridge each hole (from its rightmost corner) to the nearest outside corner the bridge doesn't cross an edge to
	holes.sort_custom(func(x, y): return _max_x(x) > _max_x(y))
	for h in holes:
		var hi := 0
		for k in h.size():
			if verts[h[k]].x > verts[h[hi]].x:
				hi = k
		var hp := Vector2(verts[h[hi]].x, verts[h[hi]].z)
		var order: Array = range(outer.size())
		order.sort_custom(func(x, y): return Vector2(verts[outer[x]].x, verts[outer[x]].z).distance_squared_to(hp) < Vector2(verts[outer[y]].x, verts[outer[y]].z).distance_squared_to(hp))
		var oi := -1
		for k in order:
			var op := Vector2(verts[outer[k]].x, verts[outer[k]].z)
			if not _crosses(hp, op, [outer] + holes):
				oi = k
				break
		if oi < 0:
			return PackedInt32Array()
		var spliced: Array = outer.slice(0, oi + 1)
		for k in h.size() + 1:
			spliced.append(h[(hi + k) % h.size()])
		spliced.append_array(outer.slice(oi))
		outer = spliced
	var poly := PackedVector2Array()
	for i in outer:
		poly.append(Vector2(verts[i].x, verts[i].z))
	var t := Geometry2D.triangulate_polygon(poly)
	var out := PackedInt32Array()
	for k in t.size() / 3:
		# wound as the navmesh's own (the selection's outline went round the same way as its triangles)
		var tri := [outer[t[k * 3]], outer[t[k * 3 + 1]], outer[t[k * 3 + 2]]]
		if signf(_area(tri)) != _wind:
			tri = [tri[0], tri[2], tri[1]]
		out.append_array(tri)
	return out

func _max_x(loop: Array) -> float:
	var m := -INF
	for i in loop:
		m = maxf(m, verts[i].x)
	return m

func _crosses(a: Vector2, b: Vector2, all_loops: Array) -> bool:
	for loop in all_loops:
		for k in loop.size():
			var p := Vector2(verts[loop[k]].x, verts[loop[k]].z)
			var q := Vector2(verts[loop[(k + 1) % loop.size()]].x, verts[loop[(k + 1) % loop.size()]].z)
			if p.is_equal_approx(a) or p.is_equal_approx(b) or q.is_equal_approx(a) or q.is_equal_approx(b):
				continue
			if Geometry2D.segment_intersects_segment(a, b, p, q) != null:
				return true
	return false

func commit_ngon() -> void:
	var t := ngon_tris()
	if t.is_empty():
		main.set_status("The n-gon's outline crosses itself: move its corners apart (Esc cancels)")
		return
	faces.append_array(t)
	ngon = false
	loops = []
	_held = PackedInt32Array()
	_clean()
	save()
	main.set_status("N-gon done: %d triangles (rebuild the navmesh to use it)" % (t.size() / 3))
	redraw()
