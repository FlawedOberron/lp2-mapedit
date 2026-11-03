extends Window
# Floating navmesh window (N): builds the bots' navigation mesh (lp2navmap.py: from the movement collision as the
# export builds it, limited to the playable area: regions joined to the layout's markers, above the kill floor,
# outside kill volumes) and shows it in the view, coloured by radar floor; dropped parts faint red.
# Radar floors: horizontal planes (project.json radar.floors, heights in cm, ascending): each starts a new floor
# above it, up to the next one. No planes = the whole map is one floor; at most MAX_PLANES (9 radar floors,
# as stock ONLINE_08). The radar itself is drawn from the navmesh later (map-editor-plan.md, NEXT).

const MAX_PLANES := 8   # 9 floors: stock ONLINE_08's radar has 9 (one Flash frame + image each; the zones' floor is a byte)
const FLOOR_COLOURS := [Color(0.15, 0.85, 0.35), Color(0.2, 0.6, 1.0), Color(1.0, 0.75, 0.15), Color(0.85, 0.35, 1.0),
	Color(0.2, 0.95, 0.95), Color(1.0, 0.4, 0.3), Color(0.6, 1.0, 0.2), Color(1.0, 0.5, 0.8), Color(0.55, 0.45, 1.0)]
const DROPPED := Color(1.0, 0.2, 0.15, 0.18)

var main: Node
var info: Label
var show_box: CheckBox
var dropped_box: CheckBox
var planes_box: VBoxContainer
var add_btn: Button
var build_btn: Button
var radar_btn: Button
var radar_box: HFlowContainer   # the radar preview: one image per floor (lp2radar.py)
var overlay: MeshInstance3D
var plane_root: Node3D
var _tris := PackedVector3Array()   # the navmesh view's triangles (m), 3 per triangle
var _kept := PackedByteArray()
var _updating := false
var _plane_box := AABB()     # the floor planes' x / z extent (m)
var _drag := -1             # the floor plane being dragged in the view (index into floors()), -1 none
var _drag_y := 0.0          # its height while dragging (m)
var _drag_n := Vector3.ZERO # the upright plane the mouse ray meets while dragging (faces the camera)
var _drag_p := Vector3.ZERO
var _hidden_vols: Array = [] # volumes hidden while the window is open

func _init() -> void:
	title = "Navmesh"
	size = Vector2i(380, 460)
	min_size = Vector2i(320, 300)
	transient = true
	visible = false
	wrap_controls = true
	close_requested.connect(hide)

func setup(m: Node) -> void:
	main = m
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bg.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)
	v.add_child(main.lighting._heading("Bot navigation"))
	info = main._label("")
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(info)
	build_btn = main._button(v, "Build navmesh", build)
	build_btn.tooltip_text = "Saves the project, then builds the navmesh from the movement collision as the export makes it (moved, hidden and placed pieces included), keeping the parts connected to the layout's markers"
	show_box = CheckBox.new()
	show_box.text = "Show in the view"
	show_box.tooltip_text = "The navmesh over the level, coloured by radar floor (stays on with the window closed)"
	show_box.toggled.connect(func(_on): _update_view())
	v.add_child(show_box)
	dropped_box = CheckBox.new()
	dropped_box.text = "Show what was left out (red)"
	dropped_box.tooltip_text = "Walkable surface outside the playable area: not connected to any marker, below the kill floor or in a kill volume"
	dropped_box.toggled.connect(func(_on): _rebuild_overlay())
	v.add_child(dropped_box)

	v.add_child(HSeparator.new())
	v.add_child(main.lighting._heading("Radar floors"))
	var hint: Label = main._label("Each plane starts a new radar floor above it, up to the next plane. No planes: the whole map is one floor. Up to %d planes (%d floors)." % [MAX_PLANES, MAX_PLANES + 1])
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(hint)
	planes_box = VBoxContainer.new()
	v.add_child(planes_box)
	add_btn = main._button(v, "Add floor plane", add_plane)
	add_btn.tooltip_text = "A plane at the view's height (move it with the spin box); the navmesh above it is the next floor"
	radar_btn = main._button(v, "Preview radar", preview_radar)
	radar_btn.tooltip_text = "Draws the cockpit radar's floor images from the navmesh and these planes, as the export does (the export also adds the zones that switch floors in game)"
	radar_box = HFlowContainer.new()
	v.add_child(radar_box)

	overlay = MeshInstance3D.new()
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	overlay.material_override = mat
	overlay.visible = false
	main.world.add_child(overlay)
	plane_root = Node3D.new()
	main.world.add_child(plane_root)

func toggle() -> void:
	if visible:
		hide()
	else:
		refresh()
		popup()
	_update_view()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and plane_root:
		# open: nothing selected, volumes hidden, the view's clicks drag the floor planes (handle_input)
		if visible:
			main.select([])
			for n in main.markers_root.get_children():
				if n.has_meta("volume") and n.visible:
					n.visible = false
					_hidden_vols.append(n)
		else:
			for n in _hidden_vols:
				if is_instance_valid(n):
					n.visible = true
			_hidden_vols = []
			_drag = -1
		_update_view()

func handle_input(e: InputEvent) -> bool:
	# while the window is open (main._unhandled_input): left click / drag moves a floor plane up and down; no other
	# clicks reach the level. -> true when the event is used
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_begin_drag(e.position)
		elif _drag >= 0:
			var f := floors()
			f[_drag] = snappedf(_drag_y / main.CM, 10.0)
			_drag = -1
			_set_floors(f)
		return true
	if e is InputEventMouseMotion and _drag >= 0:
		var from: Vector3 = main.camera.project_ray_origin(e.position)
		var hit: Variant = Plane(_drag_n, _drag_p).intersects_ray(from, main.camera.project_ray_normal(e.position))
		if hit != null:
			_drag_y = snappedf((hit as Vector3).y, 0.1)
			_preview_plane(_drag, _drag_y)
		return true
	return false

func _begin_drag(at: Vector2) -> void:
	# the nearest floor plane under the mouse (inside its drawn extent)
	var from: Vector3 = main.camera.project_ray_origin(at)
	var dir: Vector3 = main.camera.project_ray_normal(at)
	var best := INF
	var fl := floors()
	for i in fl.size():
		var hit: Variant = Plane(Vector3.UP, fl[i] * main.CM).intersects_ray(from, dir)
		if hit == null:
			continue
		var q := hit as Vector3
		var t := from.distance_to(q)
		if t < best and absf(q.x - _plane_box.get_center().x) <= _plane_box.size.x / 2 \
				and absf(q.z - _plane_box.get_center().z) <= _plane_box.size.z / 2:
			best = t
			_drag = i
			_drag_p = q
	if _drag >= 0:
		_drag_y = fl[_drag] * main.CM
		var fwd: Vector3 = -main.camera.global_transform.basis.z
		fwd.y = 0.0
		_drag_n = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD

func _preview_plane(i: int, y: float) -> void:
	# a plane at y (m) while dragging (the plane and its spin box; committed on release)
	if i < plane_root.get_child_count():
		plane_root.get_child(i).position.y = y
	var row := planes_box.get_child(i) if i < planes_box.get_child_count() else null
	if row:
		_updating = true
		(row.get_child(2) as SpinBox).value = y
		_updating = false

func _drag_spin(s: SpinBox, idx: int) -> void:
	# click and drag on the height field (sideways or up / down, 5 cm a pixel); a plain click still edits the text
	var le := s.get_line_edit()
	le.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	var st := {"press": null, "drag": false, "v": 0.0}
	le.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			if ev.pressed:
				st["press"] = ev.position
				st["drag"] = false
			else:
				if st["drag"]:
					le.accept_event()
					var f := floors()
					f[idx] = snappedf(s.value / main.CM, 10.0)
					_set_floors.call_deferred(f)
				st["press"] = null
		elif ev is InputEventMouseMotion and st["press"] != null and (ev.button_mask & MOUSE_BUTTON_MASK_LEFT):
			if not st["drag"] and (ev.position as Vector2).distance_to(st["press"]) > 4.0:
				st["drag"] = true
				st["v"] = s.value
				le.release_focus()
			if st["drag"]:
				le.accept_event()
				st["v"] += (ev.relative.x - ev.relative.y) * 0.05
				_preview_plane(idx, snappedf(st["v"], 0.1)))

# ---------------------------------------------------------------- project data

func floors() -> Array:
	# the planes' heights (cm), ascending
	var r: Variant = main.project.get("radar", {})
	var f: Array = (r as Dictionary).get("floors", []) if r is Dictionary else []
	var out := f.map(func(x): return float(x))
	out.sort()
	return out

func _set_floors(f: Array) -> void:
	main._push_undo("")
	f.sort()
	if f.is_empty():
		main.project.erase("radar")
	else:
		main.project["radar"] = {"floors": f}
	refresh()

func floor_of(y_cm: float) -> int:
	var k := 0
	for h in floors():
		if y_cm >= h:
			k += 1
	return k

# ---------------------------------------------------------------- window

func refresh() -> void:
	_updating = true
	var nm: Dictionary = main.project.get("navmesh", {}) if main.project.get("navmesh") is Dictionary else {}
	if nm.is_empty():
		info.text = "No navmesh yet: build one for bots to play this map."
	else:
		info.text = "%d polygons in the playable area, %d left out.\n%s" % [int(nm.get("polygons", 0)), int(nm.get("dropped", 0)), nm.get("lnv", "")]
	for c in planes_box.get_children():
		planes_box.remove_child(c)
		c.queue_free()
	var f := floors()
	for i in f.size():
		var row := HBoxContainer.new()
		var sw := ColorRect.new()
		sw.color = FLOOR_COLOURS[(i + 1) % FLOOR_COLOURS.size()]
		sw.custom_minimum_size = Vector2(14, 14)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(sw)
		row.add_child(main._label("Floor %d from" % (i + 2)))
		var s: SpinBox = main._spin(-100000.0, 100000.0, 0.1)
		s.suffix = "m"
		s.value = f[i] * main.CM
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var idx := i
		s.value_changed.connect(func(val):
			if _updating:
				return
			var g := floors()
			g[idx] = val / main.CM
			_set_floors(g))
		_drag_spin(s, idx)
		row.add_child(s)
		main._button(row, "Remove", func():
			var g := floors()
			g.remove_at(idx)
			_set_floors(g))
		planes_box.add_child(row)
	add_btn.disabled = f.size() >= MAX_PLANES or main.project_dir == ""
	build_btn.disabled = main.project_dir == ""
	radar_btn.disabled = main.project_dir == "" or nm.is_empty()
	_updating = false
	load_view()

func add_plane() -> void:
	var f := floors()
	if f.size() >= MAX_PLANES:
		return
	# at the height the view looks at (the level under the screen centre), else the camera's
	var y: float = main.camera.global_position.y
	var vs: Vector2 = main.get_viewport().get_visible_rect().size
	var hit: Dictionary = main._mouse_ray(vs * 0.5, 1 << (main.LAYER_STAGE - 1))
	if hit:
		y = hit["position"].y + 1.0
	f.append(snappedf(y / main.CM, 10.0))
	_set_floors(f)

func build() -> void:
	if main.project_dir == "":
		return
	main.save_project()   # the tool reads the project (layout, geometry, volumes) from disk
	build_btn.disabled = true
	main.set_status("Building the navmesh...")
	main.run_tool("lp2navmap.py", [main.project_dir, "--library", main.library_dir], func():
		build_btn.disabled = false
		var res: Variant = JSON.parse_string(FileAccess.get_file_as_string(main.project_dir.path_join(".preview/navmesh.json")))
		if res is Dictionary:
			main.project["navmesh"] = res
			main.save_project()
			main.set_status("Navmesh built: %d polygons" % int(res.get("polygons", 0)))
		refresh()
		show_box.button_pressed = true
		_update_view())

func preview_radar() -> void:
	if main.project_dir == "":
		return
	main.save_project()
	radar_btn.disabled = true
	main.set_status("Drawing the radar...")
	main.run_tool("lp2radar.py", [main.project_dir], func():
		radar_btn.disabled = false
		for c in radar_box.get_children():
			radar_box.remove_child(c)
			c.queue_free()
		var n := 0
		while FileAccess.file_exists(main.project_dir.path_join(".preview/radar_%d.png" % n)):
			if n > floors().size():   # left from an earlier preview with more floors
				break
			var img := Image.load_from_file(main.project_dir.path_join(".preview/radar_%d.png" % n))
			var col := VBoxContainer.new()
			var bg := ColorRect.new()   # the cockpit's dark backing
			bg.color = Color(0.05, 0.08, 0.06)
			bg.custom_minimum_size = Vector2(150, 150)
			var tr := TextureRect.new()
			tr.texture = ImageTexture.create_from_image(img)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.set_anchors_preset(Control.PRESET_FULL_RECT)
			bg.add_child(tr)
			col.add_child(bg)
			col.add_child(main._label("Floor %d" % (n + 1)))
			radar_box.add_child(col)
			n += 1
		main.set_status("Radar: %d floor%s" % [n, "" if n == 1 else "s"]))

# ---------------------------------------------------------------- view

func load_view() -> void:
	_tris = PackedVector3Array()
	_kept = PackedByteArray()
	var f := FileAccess.open(main.project_dir.path_join(".preview/navmesh.bin"), FileAccess.READ) if main.project_dir != "" else null
	if f:
		var n := f.get_32()
		var raw := f.get_buffer(n * 36).to_float32_array()
		_kept = f.get_buffer(n)
		f.close()
		_tris.resize(n * 3)
		for i in n * 3:
			_tris[i] = Vector3(raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2]) * main.CM
	_rebuild_overlay()

func _rebuild_overlay() -> void:
	var pos := PackedVector3Array()
	var cols := PackedColorArray()
	var fl := floors()
	for t in _kept.size():
		var keep := _kept[t] == 1
		if not keep and not dropped_box.button_pressed:
			continue
		var a := _tris[t * 3]
		var b := _tris[t * 3 + 1]
		var c := _tris[t * 3 + 2]
		var col: Color = DROPPED
		if keep:
			var y: float = (a.y + b.y + c.y) / 3.0 / main.CM
			var k := 0
			for h in fl:
				if y >= h:
					k += 1
			col = FLOOR_COLOURS[k % FLOOR_COLOURS.size()]
			col.a = 0.45
		var lift := Vector3(0, 0.2, 0)   # 20 cm off the floor it lies on, clear of the stage (and its slopes)
		pos.append_array([a + lift, c + lift, b + lift])
		cols.append_array([col, col, col])
	var m := ArrayMesh.new()
	if pos.size():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = pos
		arr[Mesh.ARRAY_COLOR] = cols
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	overlay.mesh = m
	_rebuild_planes()
	_update_view()

func _rebuild_planes() -> void:
	for c in plane_root.get_children():
		plane_root.remove_child(c)
		c.queue_free()
	# across the navmesh (or 100 m around the view without one)
	var box := AABB(main.camera.global_position - Vector3(50, 0, 50), Vector3(100, 0, 100))
	if _tris.size():
		box = AABB(_tris[0], Vector3.ZERO)
		for p in _tris:
			box = box.expand(p)
	_plane_box = AABB(box.position - Vector3(5, 0, 5), box.size + Vector3(10, 0, 10))
	var fl := floors()
	for i in fl.size():
		var mi := MeshInstance3D.new()
		var q := PlaneMesh.new()
		q.size = Vector2(box.size.x + 10.0, box.size.z + 10.0)
		mi.mesh = q
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var col: Color = FLOOR_COLOURS[(i + 1) % FLOOR_COLOURS.size()]
		col.a = 0.12
		mat.albedo_color = col
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(box.get_center().x, fl[i] * main.CM, box.get_center().z)
		plane_root.add_child(mi)

func _update_view() -> void:
	# the navmesh shows while its box is ticked; the floor planes while the window is open
	overlay.visible = show_box.button_pressed
	plane_root.visible = visible
