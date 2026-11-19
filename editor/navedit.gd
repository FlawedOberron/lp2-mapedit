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
	if previewing or quick:
		cancel_cleanup()
		cancel_quick()
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
		cancel_cleanup()
		cancel_quick()
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
		var col: Color = COL_SEL if sel.has(t) else COL_NGON if previewing and t >= _preview_from else win.piece_colour(_pieces[t])
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
	var outlines: Array = loops.duplicate()
	if quick and _picks.size() >= 2:
		outlines.append(_sorted_picks())
	for loop in outlines:
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
		mm.set_instance_color(k, COL_HOT if i == _hot else COL_OUTLINE if quick and _picks.has(i) else COL_LOCKED if locked.has(i) else COL_VERT)
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
	if previewing or quick:
		# a clean up preview: Enter applies, Esc / Ctrl+Z cancel, clicks do nothing. Quick simplify: clicks pick corners
		if e is InputEventKey and e.pressed and not e.echo:
			match e.keycode:
				KEY_ENTER, KEY_KP_ENTER:
					if previewing:
						apply_cleanup()
					elif _picks.size() >= 3:
						_apply_quick()
					return true
				KEY_ESCAPE:
					cancel_cleanup()
					cancel_quick()
					return true
				KEY_Z:
					if e.ctrl_pressed:
						cancel_cleanup()
						cancel_quick()
						return true
			return false
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				_press = e.position
			else:
				if quick and _press != null and (e.position as Vector2).distance_to(_press) <= DRAG_PX:
					_pick_quick(e.position)
				_press = null
			return true
		if e is InputEventMouseMotion and quick:
			var hq := _vertex_at(e.position)
			if hq != _hot:
				_hot = hq
				_draw_handles()
		return false
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
	var r: Variant = _outline(sel.keys())
	if r is String:
		main.set_status("Can't make one n-gon: " + r)
		return
	if r == null:
		return
	loops = r[0]
	_wind = r[1]
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

func _outline(tris: Array) -> Variant:
	# the triangles' outline -> [loops (the outside first, then holes), winding seen from above], a String saying
	# why there isn't one, or null when there's no outline at all
	var directed := {}   # directed edges with no reverse among the triangles
	for t in tris:
		for e in 3:
			directed[Vector2i(faces[t * 3 + e], faces[t * 3 + (e + 1) % 3])] = true
	var nxt := {}
	for k in directed.keys():
		if not directed.has(Vector2i(k.y, k.x)):
			if nxt.has(k.x):
				return "the selection touches itself at a corner (select a bit more or less)"
			nxt[k.x] = k.y
	if nxt.is_empty():
		return null
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
			return "the selection's outline doesn't close"
		found.append(loop)
	# the outside: the loop with the largest area (seen from above); one piece only
	var best := 0
	var areas: Array = []
	for i in found.size():
		areas.append(_area(found[i]))
		if absf(areas[i]) > absf(areas[best]):
			best = i
	for i in found.size():
		if i != best and signf(areas[i]) == signf(areas[best]):
			return "the selection is in separate parts (one at a time)"
	var out: Array = [found[best]]
	for i in found.size():
		if i != best:
			out.append(found[i])
	return [out, signf(areas[best]) if areas[best] != 0.0 else 1.0]

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
	return _triangulate(loops, _wind)

func _triangulate(lps: Array, wind: float) -> PackedInt32Array:
	# outline loops (the outside first, then holes) -> triangles wound as `wind` seen from above, [] when it can't
	var outer: Array = lps[0].duplicate()
	if _area(outer) < 0.0:
		outer.reverse()
	var holes: Array = []
	for k in range(1, lps.size()):
		var h: Array = lps[k].duplicate()
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
		if signf(_area(tri)) != wind:
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

# ---------------------------------------------------------------- clean up

const CLEAN_LINE := 0.03     # m: an outline corner this close to the straight line past it can go
const CLEAN_HEIGHT := 0.08   # m: the new triangles may sit this far from a dropped corner, at most

var previewing := false               # showing a Clean up result (faces is the result until applied / cancelled)
var _pre_faces := PackedInt32Array()  # the faces before it
var _pre_sel := {}
var _preview_from := -1               # the first new triangle in the preview

func preview_cleanup(max_deg: float) -> void:
	# shows the Clean up result at max_deg (again at another angle while previewing); Apply keeps it
	if ngon or quick:
		main.set_status("Finish the n-gon / quick simplify first (Enter / Esc)")
		return
	if not previewing:
		_pre_faces = faces.duplicate()
		_pre_sel = sel.duplicate()
		sel = {}
		previewing = true
	faces = _pre_faces.duplicate()
	var r: Variant = _cleanup_result(max_deg, _pre_sel)
	if r == null:
		_preview_from = faces.size() / 3
		main.set_status("Clean up at %.1f°: nothing to simplify%s. Esc / Cancel: back" % [max_deg, " in the selection" if not _pre_sel.is_empty() else ""])
	else:
		faces = r[0]
		_preview_from = r[1]
		main.set_status("Clean up preview at %.1f°: %d triangles -> %d (yellow: new; %d surfaces). Change the angle to compare; Enter / Apply keeps it, Esc / Cancel goes back" % [max_deg, _pre_faces.size() / 3, faces.size() / 3, r[2]])
	win.cleanup_buttons(true)
	redraw()

func apply_cleanup() -> void:
	if not previewing:
		return
	var now := faces
	faces = _pre_faces
	_snapshot()
	faces = now
	previewing = false
	_preview_from = -1
	_clean()
	save()
	win.cleanup_buttons(false)
	redraw()
	main.set_status("Clean up applied: %d triangles -> %d (Ctrl+Z undoes it; rebuild the navmesh to use it)" % [_pre_faces.size() / 3, faces.size() / 3])

func cancel_cleanup() -> void:
	if not previewing:
		return
	faces = _pre_faces
	sel = _pre_sel
	previewing = false
	_preview_from = -1
	win.cleanup_buttons(false)
	redraw()
	main.set_status("Clean up cancelled")

func _cleanup_result(max_deg: float, scope: Dictionary) -> Variant:
	# The triangles in scope (empty: all) in groups of triangles joined by edges, each within max_deg of its
	# group's first triangle's normal; each group is re-triangulated from its outline without its inside corners and
	# the outline corners on a straight line. A corner a triangle outside the groups uses stays (nothing comes apart),
	# and groups that meet drop the same corners; a group whose new triangles would sit off the old ones stays as it was.
	# -> [new faces (the untouched triangles first), the first new triangle, surfaces simplified], null: no change
	var nt := faces.size() / 3
	if nt == 0:
		return null
	var cos_max := cos(deg_to_rad(max_deg))
	var normals: Array = []
	var edge_tri := {}
	for t in nt:
		var a := verts[faces[t * 3]]
		var n := (verts[faces[t * 3 + 1]] - a).cross(verts[faces[t * 3 + 2]] - a)
		normals.append(n.normalized() if n.length() > 1e-9 else Vector3.ZERO)
		for e in 3:
			edge_tri[Vector2i(faces[t * 3 + e], faces[t * 3 + (e + 1) % 3])] = t
	# groups
	var group := PackedInt32Array()
	group.resize(nt)
	group.fill(-1)
	var groups: Array = []
	for t in nt:
		if group[t] >= 0 or normals[t] == Vector3.ZERO or (not scope.is_empty() and not scope.has(t)):
			continue
		var g := groups.size()
		var seed: Vector3 = normals[t]
		var list: Array = [t]
		group[t] = g
		var i := 0
		while i < list.size():
			var u: int = list[i]
			i += 1
			for e in 3:
				var w: int = edge_tri.get(Vector2i(faces[u * 3 + (e + 1) % 3], faces[u * 3 + e]), -1)
				if w >= 0 and group[w] < 0 and normals[w] != Vector3.ZERO and (scope.is_empty() or scope.has(w)) \
						and (normals[w] as Vector3).dot(seed) >= cos_max:
					group[w] = g
					list.append(w)
		groups.append(list)
	# each group's outline (a group that has none, or is one triangle, stays as it is)
	var info: Array = []
	for g in groups.size():
		var r: Variant = _outline(groups[g]) if groups[g].size() >= 2 else null
		info.append({"ok": r is Array, "loops": r[0] if r is Array else [], "wind": r[1] if r is Array else 1.0})
	var keep := {}   # corners that stay
	for t in nt:
		if group[t] < 0 or not info[group[t]]["ok"]:
			for e in 3:
				keep[faces[t * 3 + e]] = true
	var made := {}   # group -> its new triangles
	var settled := false
	while not settled:
		settled = true
		for g in groups.size():
			if info[g]["ok"]:
				for loop in info[g]["loops"]:
					if _keep_corners(loop, keep):
						settled = false
		if not settled:
			continue
		made = {}
		for g in groups.size():
			if not info[g]["ok"]:
				continue
			var dropped: Array = []
			var seen := {}
			for t in groups[g]:
				for e in 3:
					var v := faces[t * 3 + e]
					if not keep.has(v) and not seen.has(v):
						seen[v] = true
						dropped.append(v)
			if dropped.is_empty():
				continue
			var lps: Array = []
			var short := false
			for loop in info[g]["loops"]:
				var lp: Array = loop.filter(func(v): return keep.has(v))
				short = short or lp.size() < 3
				lps.append(lp)
			var tris := PackedInt32Array() if short else _triangulate(lps, info[g]["wind"])
			if tris.is_empty() or not _fits(tris, dropped):
				# this group stays as it was, and so do its corners (its neighbours keep them too)
				info[g]["ok"] = false
				for t in groups[g]:
					for e in 3:
						keep[faces[t * 3 + e]] = true
				settled = false
				break
			made[g] = tris
	if made.is_empty():
		return null
	var out := PackedInt32Array()
	for t in nt:
		if group[t] < 0 or not made.has(group[t]):
			out.append_array(faces.slice(t * 3, t * 3 + 3))
	var first := out.size() / 3
	for g in made:
		out.append_array(made[g])
	return [out, first, made.size()]

func _keep_corners(loop: Array, keep: Dictionary) -> bool:
	# marks the loop's corners needed so every dropped corner is within CLEAN_LINE of the straight line between the
	# kept corners either side of it (the farthest one per stretch at a time); -> true when it marked any
	var idx: Array = []
	for k in loop.size():
		if keep.has(loop[k]):
			idx.append(k)
	if idx.size() < 2:
		var a: int = idx[0] if idx.size() == 1 else 0
		var far := a
		var d := -1.0
		for k in loop.size():
			var dd := verts[loop[k]].distance_to(verts[loop[a]])
			if dd > d:
				d = dd
				far = k
		keep[loop[a]] = true
		keep[loop[far]] = true
		return true
	var more := false
	for j in idx.size():
		var s: int = idx[j]
		var e: int = idx[(j + 1) % idx.size()]
		var p := verts[loop[s]]
		var q := verts[loop[e]]
		var worst := -1
		var wd := CLEAN_LINE
		var k := (s + 1) % loop.size()
		while k != e:
			var c := verts[loop[k]]
			var d := c.distance_to(Geometry3D.get_closest_point_to_segment(c, p, q))
			if d > wd:
				wd = d
				worst = k
			k = (k + 1) % loop.size()
		if worst >= 0:
			keep[loop[worst]] = true
			more = true
	return more

func _fits(tris: PackedInt32Array, dropped: Array) -> bool:
	# every dropped corner within CLEAN_HEIGHT of the new triangles
	for v in dropped:
		var p := verts[v]
		var best := INF
		for k in tris.size() / 3:
			best = minf(best, _tri_dist(p, verts[tris[k * 3]], verts[tris[k * 3 + 1]], verts[tris[k * 3 + 2]]))
			if best <= CLEAN_HEIGHT:
				break
		if best > CLEAN_HEIGHT:
			return false
	return true

static func _tri_dist(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var n := (b - a).cross(c - a)
	if n.length() > 1e-9:
		n = n.normalized()
		var h := (p - a).dot(n)
		var f := p - n * h   # p on the triangle's plane
		if (b - a).cross(f - a).dot(n) >= 0.0 and (c - b).cross(f - b).dot(n) >= 0.0 and (a - c).cross(f - c).dot(n) >= 0.0:
			return absf(h)
	return minf(p.distance_to(Geometry3D.get_closest_point_to_segment(p, a, b)), minf(
		p.distance_to(Geometry3D.get_closest_point_to_segment(p, b, c)),
		p.distance_to(Geometry3D.get_closest_point_to_segment(p, c, a))))

# ---------------------------------------------------------------- quick simplify

var quick := false      # picking corners for a quick simplify
var _picks: Array = []  # the corners picked so far

func start_quick() -> void:
	if ngon or previewing:
		main.set_status("Finish the n-gon / clean up preview first (Enter / Esc)")
		return
	quick = true
	_picks = []
	sel = {}
	main.set_status("Quick simplify: click corner 1 of 4 (Esc cancels)")
	redraw()

func cancel_quick() -> void:
	if not quick:
		return
	quick = false
	_picks = []
	main.set_status("Quick simplify cancelled")
	redraw()

func _pick_quick(at: Vector2) -> void:
	var v := _vertex_at(at)
	if v < 0:
		return
	if _picks.has(v):
		_picks.erase(v)   # clicked again: unpicked
	else:
		_picks.append(v)
	if _picks.size() >= 4:
		_apply_quick()
		return
	main.set_status("Quick simplify: click corner %d of 4 (click one again to unpick; Enter with 3: a triangle; Esc cancels)" % (_picks.size() + 1))
	redraw()

func _sorted_picks() -> Array:
	# the corners in order round their middle (seen from above), so the click order doesn't matter
	var c := Vector2.ZERO
	for v in _picks:
		c += Vector2(verts[v].x, verts[v].z)
	c /= maxf(1.0, _picks.size())
	var out := _picks.duplicate()
	out.sort_custom(func(a, b): return (Vector2(verts[a].x, verts[a].z) - c).angle() < (Vector2(verts[b].x, verts[b].z) - c).angle())
	return out

func _apply_quick() -> void:
	# the triangles inside the corners (seen from above) that join up with them become one piece: its outline is the
	# picked corners plus the corners triangles outside it still use (so nothing comes apart); holes stay
	var pts := _sorted_picks()
	quick = false
	_picks = []
	var poly := PackedVector2Array()
	for v in pts:
		poly.append(Vector2(verts[v].x, verts[v].z))
	var nt := faces.size() / 3
	var inside := func(t: int) -> bool:
		var c := (verts[faces[t * 3]] + verts[faces[t * 3 + 1]] + verts[faces[t * 3 + 2]]) / 3.0
		return Geometry2D.is_point_in_polygon(Vector2(c.x, c.z), poly)
	var edge_tri := {}
	for t in nt:
		for e in 3:
			edge_tri[Vector2i(faces[t * 3 + e], faces[t * 3 + (e + 1) % 3])] = t
	# from the triangles at the corners, through edges, to triangles inside (not other floors above / below)
	var region := {}
	var list: Array = []
	for t in nt:
		for e in 3:
			if pts.has(faces[t * 3 + e]) and not region.has(t) and inside.call(t):
				region[t] = true
				list.append(t)
	var i := 0
	while i < list.size():
		var u: int = list[i]
		i += 1
		for e in 3:
			var w: int = edge_tri.get(Vector2i(faces[u * 3 + (e + 1) % 3], faces[u * 3 + e]), -1)
			if w >= 0 and not region.has(w) and inside.call(w):
				region[w] = true
				list.append(w)
	if region.is_empty():
		main.set_status("Quick simplify: no triangles inside those corners")
		redraw()
		return
	var r: Variant = _outline(region.keys())
	if not r is Array:
		main.set_status("Quick simplify: " + (r if r is String else "no outline") + " - try corners a bit further in or out")
		redraw()
		return
	var used := {}   # corners triangles outside the piece use
	for t in nt:
		if not region.has(t):
			for e in 3:
				used[faces[t * 3 + e]] = true
	var outer: Array = r[0][0]
	for v in pts:
		if not outer.has(v):
			main.set_status("Quick simplify: a picked corner isn't on the piece's edge (the triangles inside the corners don't reach it)")
			redraw()
			return
	var lps: Array = [outer.filter(func(v): return pts.has(v) or used.has(v))]
	lps.append_array(r[0].slice(1))
	var tris := _triangulate(lps, r[1])
	if tris.is_empty():
		main.set_status("Quick simplify: the outline would cross itself - try other corners")
		redraw()
		return
	_snapshot()
	var out := PackedInt32Array()
	for t in nt:
		if not region.has(t):
			out.append_array(faces.slice(t * 3, t * 3 + 3))
	out.append_array(tris)
	faces = out
	_clean()
	save()
	redraw()
	main.set_status("Quick simplify: %d triangles -> %d (Ctrl+Z undoes it; rebuild the navmesh to use it)" % [region.size(), tris.size() / 3])
