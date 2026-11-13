extends PanelContainer
# The Navmesh toolbar (N; main.toggle_toolbar: one toolbar at a time, under the main bars). Generate builds the bots' navigation mesh (lp2navmap.py: from the movement collision as the
# export builds it, limited to the playable area: regions joined to the layout's markers, above the kill floor,
# outside kill volumes) and shows it in the view, coloured by radar floor or by piece; dropped parts faint red.
# Pieces: polygons joined by shared edges (and welds). Bots can only path within a piece, so a floor split into pieces
# (a step over the step height, a slope over the slope limit, a ramp narrower than the edge clearance) strands them.
# Welds join pieces: automatic (open edges within "Weld gaps up to", no wall between) and by hand (two clicks on the
# navmesh: project.json "nav_welds" [{a, b}] in cm). Generation settings: project.json "nav_settings".
# Remove: whole pieces (a click) and brushed areas (a drag), project.json "nav_removed" (lp2navmap.removed), grey here
# until the next build applies them.
# Radar floors: horizontal planes (project.json radar.floors, heights in cm, ascending): each starts a new floor
# above it, up to the next one. No planes = the whole map is one floor; at most MAX_PLANES (9 radar floors,
# as stock ONLINE_08). The radar itself is drawn from the navmesh later (map-editor-plan.md, NEXT).

const MAX_PLANES := 8   # 9 floors: stock ONLINE_08's radar has 9 (one Flash frame + image each; the zones' floor is a byte)
const FLOOR_COLOURS := [Color(0.15, 0.85, 0.35), Color(0.2, 0.6, 1.0), Color(1.0, 0.75, 0.15), Color(0.85, 0.35, 1.0),
	Color(0.2, 0.95, 0.95), Color(1.0, 0.4, 0.3), Color(0.6, 1.0, 0.2), Color(1.0, 0.5, 0.8), Color(0.55, 0.45, 1.0)]
const DROPPED := Color(1.0, 0.2, 0.15, 0.18)
const SETTINGS := [   # project.json "nav_settings": key, label, default, min, max, step, suffix, tooltip
	["climb", "Step height", 55.0, 10.0, 200.0, 5.0, "cm", "The highest step bots walk up. Higher joins stairs and kerbs that split the floor into pieces; too high and they walk up ledges they can't climb in game"],
	["slope", "Steepest slope", 50.0, 10.0, 80.0, 1.0, "°", "Steeper ground isn't walkable"],
	["radius", "Edge clearance", 40.0, 0.0, 100.0, 5.0, "cm", "How far the navmesh keeps from walls and edges. Lower keeps narrow ramps, bridges and doorways (anything under twice this wide is left out)"],
	["weld", "Weld gaps up to", 0.0, 0.0, 300.0, 10.0, "cm", "Joins pieces whose open edges are this close (and no higher apart than the step height), unless a wall is between. 0: off"],
]
const WELD_AUTO := Color(1, 1, 1, 0.9)
const WELD_HAND := Color(1.0, 0.85, 0.1)
const WELD_NEW := Color(1.0, 0.5, 0.1)
const REMOVED := Color(0.25, 0.25, 0.28, 0.55)   # taken out by hand (applied at the next build)
const ADDED := Color(0.35, 0.9, 1.0, 0.55)       # left out but put back by hand (applied at the next build)
const REMOVE_UP := 2.0   # m: a brushed point takes triangles whose middle is within this above or below it (lp2navmap)

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
var weld_lines: MeshInstance3D
var plane_root: Node3D
var colour_by: OptionButton
var setting_spins := {}
var welds_box: VBoxContainer
var mode_btns := {}                # mode -> its toggle button
var info_short: Label
var edit_tools: HBoxContainer       # Snap + Undo, shown while hand editing
var _tris := PackedVector3Array()   # the navmesh view's triangles (m), 3 per triangle
var _kept := PackedByteArray()
var _piece := PackedInt32Array()    # piece per triangle (-1 dropped; empty: built before pieces)
var _welds: Array = []              # the last build's welds: [a (m), b (m), manual]
var _weld_a: Variant = null         # adding a weld: its first end (cm), after the first click
var remove_box: VBoxContainer
var brush_spin: SpinBox
var _mode := ""                     # the toggled tool, which takes the view's clicks: remove / remove_brush / add /
                                    # add_brush / weld / edit (hand edit); "" none (clicks drag the floor planes)
var _stroke: Array = []             # the brush stroke being drawn: points (cm)
var _removed := PackedByteArray()   # per triangle: 1 taken out by hand (nav_removed, as the next build will)
var _added := PackedByteArray()     # per triangle: 1 left out but put back by hand (nav_added)
var _updating := false
var _plane_box := AABB()     # the floor planes' x / z extent (m)
var _drag := -1             # the floor plane being dragged in the view (index into floors()), -1 none
var _drag_y := 0.0          # its height while dragging (m)
var _drag_n := Vector3.ZERO # the upright plane the mouse ray meets while dragging (faces the camera)
var _drag_p := Vector3.ZERO
var _hidden_vols: Array = [] # volumes hidden while the window is open
var edit: Node                # navedit.gd: hand editing (the toolbar at the top)
var snap_box: CheckBox
var _file_dlg: FileDialog
const MODES := {   # mode: [button, cursor, status line, tooltip]
	"remove": ["Remove", Input.CURSOR_POINTING_HAND, "Remove: click the navmesh to take that whole piece out (Esc or Remove again stops)",
		"Click a piece of the navmesh: all of it is taken out at the next build (View: Colour by Piece shows the pieces)"],
	"remove_brush": ["Remove brush", Input.CURSOR_CROSS, "Remove brush: drag over the navmesh to take it out (Esc or the button again stops)",
		"Drag over the navmesh: what's under the brush is taken out at the next build"],
	"add": ["Add", Input.CURSOR_POINTING_HAND, "Add: click a left-out (red) part to put all of it back (Esc or Add again stops)",
		"Click a part left out of the playable area (red): all of it is put back at the next build"],
	"add_brush": ["Add brush", Input.CURSOR_CROSS, "Add brush: drag over left-out (red) parts to put them back (Esc or the button again stops)",
		"Drag over parts left out (red): what's under the brush is put back at the next build"],
	"weld": ["Weld", Input.CURSOR_CROSS, "Weld: click the navmesh on one side of a gap, then the other (Esc stops)",
		"Join two pieces where bots can walk across: click the navmesh each side of the gap (rebuild to use it)"],
	"edit": ["Hand edit", Input.CURSOR_ARROW, "Hand edit: click / Shift+click / drag a box to select; drag a corner onto another to merge. Enter: the selection as one n-gon (drag corners, click its outline to add one, Delete removes one), Enter again: done. Esc: cancel / stop. Ctrl+Z undo. Generate to use it",
		"Edit the navmesh's triangles yourself. The first time, the built navmesh becomes the map's own (assets/nav/edited.obj), which Generate uses from then on (Generate ▾: Discard hand edits goes back)"],
}

func _init() -> void:
	visible = false

func _btn(parent: Control, text: String, cb: Callable, tip := "") -> Button:
	var b: Button = main._button(parent, text, cb)
	b.focus_mode = Control.FOCUS_NONE   # Enter / Esc / Delete stay with the view's tools
	b.tooltip_text = tip
	return b

func _drop(row: Control, text: String, tip: String, width := 360) -> VBoxContainer:
	# a toolbar button opening a panel below it -> the panel's contents
	var pop := PopupPanel.new()
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)
	pop.add_child(sc)
	add_child(pop)
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	row.add_child(b)
	b.pressed.connect(func():   # (b is set by now: lambdas copy locals)
		var h := mini(int(v.get_combined_minimum_size().y) + 8, 600)
		sc.custom_minimum_size = Vector2(width, h)
		pop.popup(Rect2i(Vector2i(b.get_screen_position() + Vector2(0, b.size.y)), Vector2i(width + 8, h + 8))))
	return v

func _wrap(l: Label) -> Label:
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	return l

func setup(m: Node) -> void:
	main = m
	var row := HFlowContainer.new()
	add_child(row)
	var title: Label = main._label("Navmesh")
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	row.add_child(title)
	build_btn = _btn(row, "Generate", build, "Saves the project, then builds the navmesh as the export does (from the movement collision, or the hand-edited mesh), keeping the parts joined to the layout's markers")
	var gen := _drop(row, "▾", "Generation settings")
	gen.add_child(main.lighting._heading("Generation"))
	gen.add_child(_wrap(main._label("Used by the next Generate (not by a hand-edited navmesh).")))
	var grid := GridContainer.new()
	grid.columns = 2
	for d in SETTINGS:
		var l: Label = main._label(d[1])
		l.tooltip_text = d[7]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(l)
		var sp: SpinBox = main._spin(d[3], d[4], d[5])
		sp.suffix = d[6]
		sp.tooltip_text = d[7]
		var key: String = d[0]
		sp.value_changed.connect(func(val):
			if _updating:
				return
			_set_setting(key, val))
		grid.add_child(sp)
		setting_spins[key] = sp
	gen.add_child(grid)
	_btn(gen, "Default settings", func():
		main._push_undo("")
		main.project.erase("nav_settings")
		refresh(), "Back to the standard step height, slope and clearance, welding off")
	gen.add_child(HSeparator.new())
	_btn(gen, "Discard hand edits", _regenerate, "Stop using the hand-edited navmesh and generate one from the collision again (the edited file stays: Ctrl+Z brings it back)")
	_btn(row, "Import", _import_obj, "An OBJ (metres, Y up: Blender's defaults; triangles or polygons) as the map's navmesh, which Generate then uses")
	_btn(row, "Export", _export_obj, "The navmesh (hand-edited, else the last build's, all of it) as an OBJ in metres, Y up")
	row.add_child(VSeparator.new())
	for k in ["edit", "remove", "remove_brush", "add", "add_brush", "weld"]:
		var mode: String = k
		var b := _btn(row, MODES[k][0], func(): _set_mode("" if _mode == mode else mode), MODES[k][3])
		b.toggle_mode = true
		mode_btns[k] = b
		if k == "edit":
			edit_tools = HBoxContainer.new()
			edit_tools.visible = false
			snap_box = CheckBox.new()
			snap_box.text = "Snap"
			snap_box.focus_mode = Control.FOCUS_NONE
			snap_box.button_pressed = true
			snap_box.tooltip_text = "Dragged and added corners sit on the level under the mouse; off, they stay level at their height"
			snap_box.toggled.connect(func(on): edit.snap = on)
			edit_tools.add_child(snap_box)
			_btn(edit_tools, "Undo", func(): edit.undo(), "Undo the last hand edit (Ctrl+Z)")
			row.add_child(edit_tools)
			row.add_child(VSeparator.new())
		if k == "add_brush":
			brush_spin = main._spin(0.5, 20.0, 0.5)
			brush_spin.suffix = "m"
			brush_spin.value = 2.0
			brush_spin.tooltip_text = "Brush radius"
			brush_spin.custom_minimum_size.x = 76
			brush_spin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			row.add_child(brush_spin)
	row.add_child(VSeparator.new())

	var fl := _drop(row, "Floors ▾", "Radar floors: the planes splitting the navmesh into the cockpit radar's floors, and the radar preview", 380)
	fl.add_child(main.lighting._heading("Radar floors"))
	fl.add_child(_wrap(main._label("Each plane starts a new radar floor above it, up to the next plane (drag them in the view). No planes: the whole map is one floor. Up to %d planes (%d floors)." % [MAX_PLANES, MAX_PLANES + 1])))
	planes_box = VBoxContainer.new()
	fl.add_child(planes_box)
	add_btn = _btn(fl, "Add floor plane", add_plane, "A plane at the view's height (move it with the spin box or drag it in the view); the navmesh above it is the next floor")
	radar_btn = _btn(fl, "Preview radar", preview_radar, "Draws the cockpit radar's floor images from the navmesh and these planes, as the export does (the export also adds the zones that switch floors in game)")
	radar_box = HFlowContainer.new()
	fl.add_child(radar_box)

	var ed := _drop(row, "Edits ▾", "The welds and the parts taken out / put back by hand, each with Show and Undo")
	ed.add_child(main.lighting._heading("Welds"))
	welds_box = VBoxContainer.new()
	ed.add_child(welds_box)
	ed.add_child(main.lighting._heading("Taken out / put back"))
	remove_box = VBoxContainer.new()
	ed.add_child(remove_box)

	var vw := _drop(row, "View ▾", "What the view shows, and the last build's numbers")
	info = _wrap(main._label(""))
	vw.add_child(info)
	show_box = CheckBox.new()
	show_box.text = "Show in the view"
	show_box.tooltip_text = "The navmesh over the level (stays on with the toolbar closed)"
	show_box.toggled.connect(func(_on): _update_view())
	vw.add_child(show_box)
	dropped_box = CheckBox.new()
	dropped_box.text = "Show what was left out (red)"
	dropped_box.tooltip_text = "Walkable surface outside the playable area: not connected to any marker, below the kill floor or in a kill volume"
	dropped_box.toggled.connect(func(_on): _rebuild_overlay())
	vw.add_child(dropped_box)
	var crow := HBoxContainer.new()
	crow.add_child(main._label("Colour by"))
	colour_by = OptionButton.new()
	colour_by.add_item("Radar floor")
	colour_by.add_item("Piece")
	colour_by.selected = 1
	colour_by.tooltip_text = "Piece: each part bots can walk around without a jump has its own colour. Two colours meeting where you can walk across is a split: weld it"
	colour_by.item_selected.connect(func(_i): _rebuild_overlay())
	crow.add_child(colour_by)
	vw.add_child(crow)
	info_short = main._label("")
	info_short.modulate = Color(1, 1, 1, 0.75)
	row.add_child(info_short)

	edit = Node.new()
	edit.set_script(load("res://navedit.gd"))
	add_child(edit)
	edit.setup(main, self)

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
	weld_lines = MeshInstance3D.new()
	weld_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lm := StandardMaterial3D.new()
	lm.vertex_color_use_as_albedo = true
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.no_depth_test = true
	weld_lines.material_override = lm
	weld_lines.visible = false
	main.world.add_child(weld_lines)
	plane_root = Node3D.new()
	main.world.add_child(plane_root)

func _start_editing() -> bool:
	# hand editing needs the mesh: the project's own, else the built navmesh frozen into it
	if main.project_dir == "":
		return false
	if edit.load_mesh():
		return true
	if _tris.is_empty():
		main.set_status("Generate the navmesh first (or Import one)")
		return false
	if not edit.freeze(_tris):
		main.set_status("Couldn't write the navmesh file")
		return false
	main.save_project()
	main.log_line("The navmesh is now hand-edited (%s): Generate uses it instead of generating one." % main.project["nav_mesh"])
	return true

func _dialog(save: bool, done: Callable) -> void:
	if _file_dlg:
		_file_dlg.queue_free()
	_file_dlg = FileDialog.new()
	_file_dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE if save else FileDialog.FILE_MODE_OPEN_FILE
	_file_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_file_dlg.filters = PackedStringArray(["*.obj ; Wavefront OBJ"])
	_file_dlg.use_native_dialog = true
	_file_dlg.file_selected.connect(done)
	add_child(_file_dlg)
	_file_dlg.popup_centered_ratio(0.6)

func _export_obj() -> void:
	if _mode != "edit" and not edit.load_mesh():
		if _tris.is_empty():
			main.set_status("Build the navmesh first")
			return
		edit.from_tris(_tris)
	_dialog(true, func(path: String):
		if path.get_extension().to_lower() != "obj":
			path += ".obj"
		main.set_status("Navmesh written to " + path if edit.write_obj(path) else "Couldn't write " + path))

func _import_obj() -> void:
	if main.project_dir == "":
		return
	_dialog(false, func(path: String):
		var r: Array = edit.read_obj(path)
		if r.is_empty() or (r[1] as PackedInt32Array).is_empty():
			main.set_status("No triangles in " + path)
			return
		edit.verts = r[0]
		edit.faces = r[1]
		edit._undo = []
		edit.sel = {}
		if not edit.save():
			main.set_status("Couldn't write the navmesh file")
			return
		main.save_project()
		_set_mode("edit")
		main.log_line("Imported %d navmesh triangles: Generate uses them (and shows the playable area)" % ((r[1] as PackedInt32Array).size() / 3)))

func _regenerate() -> void:
	if not main.project.get("nav_mesh") is String:
		main.set_status("The navmesh is generated already")
		return
	if _mode == "edit":
		_set_mode("")
	main._push_undo("")
	main.project.erase("nav_mesh")
	main.save_project()
	build()

func toggle() -> void:
	main.toggle_toolbar(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and plane_root:
		# open: nothing selected, volumes hidden, the view's clicks drag the floor planes (handle_input)
		if visible:
			refresh()
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
			if _mode != "":
				_set_mode("")
		_update_view()

func handle_input(e: InputEvent) -> bool:
	# while the toolbar is open (main._unhandled_input): a toggled tool takes the left clicks (right drag still looks
	# round), Esc stops it; with none, left click / drag moves a floor plane up and down and no other clicks reach the
	# level. -> true when the event is used
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_ESCAPE and _mode != "":
		if _mode == "edit" and (edit.ngon or not edit.sel.is_empty()):
			return edit.handle_input(e)   # cancel the n-gon / the selection first
		if _mode == "weld" and _weld_a != null:
			_weld_a = null
			main.set_status(MODES["weld"][2])
			_rebuild_welds()
			return true
		_set_mode("")
		main.set_status("")
		return true
	if _mode == "edit":
		return edit.handle_input(e)
	var left: bool = e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT
	if _mode == "weld":
		if left and e.pressed:
			_weld_click(e.position)
		return left
	if _mode != "":   # remove / add: a piece per click, or brushing
		var brush := _mode.ends_with("brush")
		if left:
			if e.pressed and not brush:
				_remove_piece(e.position)
			elif e.pressed:
				_stroke = []
				_brush_at(e.position)
			elif brush and _stroke.size():
				var items := marks(_key())
				items.append({"brush": _stroke, "r": snappedf(brush_spin.value * 100.0, 1.0)})
				_stroke = []
				_set_marks(_key(), items)
			return true
		if e is InputEventMouseMotion and brush and (e.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_brush_at(e.position)
			return true
		return false
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

func settings() -> Dictionary:
	var st: Variant = main.project.get("nav_settings")
	return st if st is Dictionary else {}

func _set_setting(key: String, val: float) -> void:
	main._push_undo("nav_settings")
	var st := settings().duplicate()
	for d in SETTINGS:
		if d[0] == key and is_equal_approx(val, d[2]):
			st.erase(key)
			break
		if d[0] == key:
			st[key] = val
	if st.is_empty():
		main.project.erase("nav_settings")
	else:
		main.project["nav_settings"] = st

func hand_welds() -> Array:
	var w: Variant = main.project.get("nav_welds")
	return (w as Array).filter(func(x): return x is Dictionary) if w is Array else []

func _key() -> String:
	return "nav_added" if _adding() else "nav_removed"

func _adding() -> bool:
	return _mode.begins_with("add")

func marks(key: String) -> Array:
	# project.json "nav_removed" (taken out) / "nav_added" (put back): [{brush: [[x, y, z], ...], r} or {piece: [x, y, z]}]
	var r: Variant = main.project.get(key)
	return (r as Array).filter(func(x): return x is Dictionary) if r is Array else []

func _set_marks(key: String, items: Array) -> void:
	main._push_undo("")
	if items.is_empty():
		main.project.erase(key)
	else:
		main.project[key] = items
	refresh()

func _set_mode(m: String) -> void:
	# one tool at a time; it takes the view's clicks until toggled off, Esc, or the toolbar closes
	var was := _mode
	_stroke = []
	_weld_a = null
	if was == "edit" and m != "edit":
		edit.set_on(false)
	if m == "edit" and was != "edit" and not _start_editing():
		m = ""
	_mode = m
	for k in mode_btns:
		(mode_btns[k] as Button).set_pressed_no_signal(k == m)
	edit_tools.visible = m == "edit"
	if m != "" and m != "edit":
		show_box.button_pressed = true
	if m.begins_with("add"):
		dropped_box.button_pressed = true
	Input.set_default_cursor_shape(MODES[m][1] if m != "" else Input.CURSOR_ARROW)
	if m != "":
		main.get_viewport().gui_release_focus()   # Enter / Delete go to the tool, not a focused control
		main.set_status(MODES[m][2])
	elif was != "":
		main.set_status("")
	if m == "edit" and was != "edit":
		edit.set_on(true)
	_rebuild_overlay()

func _cm(q: Vector3) -> Array:
	var c: Vector3 = q / main.CM
	return [snappedf(c.x, 1.0), snappedf(c.y, 1.0), snappedf(c.z, 1.0)]

func _remove_piece(at: Vector2) -> void:
	var q: Variant = _pick_navmesh(at, not _adding())
	if q == null:
		main.set_status("Click on the navmesh" if not _adding() else "Click on a part left out (red)")
		return
	var items := marks(_key())
	items.append({"piece": _cm(q)})
	main.set_status("Piece %s (applied at the next Generate; Edits ▾ lists it, with Undo)" % ("taken out" if not _adding() else "put back"))
	_set_marks(_key(), items)

func _brush_at(at: Vector2) -> void:
	var q: Variant = _pick_navmesh(at, not _adding())
	if q == null:
		return
	var pt := _cm(q)
	if _stroke.size():
		var last: Array = _stroke[-1]
		if Vector3(last[0], last[1], last[2]).distance_to(Vector3(pt[0], pt[1], pt[2])) < brush_spin.value * 40.0:
			return
	_stroke.append(pt)
	_rebuild_overlay()

func _unbuilt(key: String) -> Array:
	# the marks the last build didn't apply yet (it lists the ones it did: navmesh "marks"). An applied piece mark must not
	# be matched again: its piece is gone, so it would pick the piece next to it (the main one went grey)
	var nm: Variant = main.project.get("navmesh")
	var done: Variant = (nm as Dictionary).get("marks") if nm is Dictionary else null
	if not done is Dictionary or not (done as Dictionary).get(key, []) is Array:
		return marks(key)   # built before the list: all count as new
	var seen := {}
	for x in (done as Dictionary)[key]:
		seen[JSON.stringify(x)] = int(seen.get(JSON.stringify(x), 0)) + 1
	var out: Array = []
	for x in marks(key):
		var k := JSON.stringify(x)
		if int(seen.get(k, 0)) > 0:
			seen[k] = int(seen[k]) - 1
		else:
			out.append(x)
	return out

func _mask(key: String, among: PackedByteArray, stroke: bool) -> PackedByteArray:
	# what a "nav_removed" / "nav_added" list (and the brush stroke being drawn, when stroke) picks among the triangles
	# marked 1 in among, as lp2navmap.marked does: brushes first, then whole pieces of what's left (over shared edges)
	var n := _kept.size()
	var out := PackedByteArray()
	out.resize(n)
	var items := _unbuilt(key)
	if stroke and _stroke.size():
		items.append({"brush": _stroke, "r": brush_spin.value * 100.0})
	if items.is_empty() or n == 0 or among.size() != n:
		return out
	var cen := PackedVector3Array()
	cen.resize(n)
	for t in n:
		cen[t] = (_tris[t * 3] + _tris[t * 3 + 1] + _tris[t * 3 + 2]) / 3.0
	var any_piece := false
	for it in items:
		if it.get("brush") is Array:
			var r: float = float(it.get("r", 300.0)) * main.CM
			for p in it["brush"]:
				var c: Vector3 = Vector3(p[0], p[1], p[2]) * main.CM
				for t in n:
					if out[t] == 0 and among[t] == 1 and absf(cen[t].y - c.y) <= REMOVE_UP and Vector2(cen[t].x - c.x, cen[t].z - c.z).length() <= r:
						out[t] = 1
		elif it.get("piece") is Array:
			any_piece = true
	if any_piece:
		var left := among.duplicate()
		for t in n:
			if out[t] == 1:
				left[t] = 0
		var pc := pieces_of(_tris, left)
		for it in items:
			if not it.get("piece") is Array:
				continue
			var p: Array = it["piece"]
			var c: Vector3 = Vector3(p[0], p[1], p[2]) * main.CM
			var best := -1
			var best_d := INF
			for t in n:
				if pc[t] < 0:
					continue
				var d := cen[t].distance_to(c)
				if d < best_d:
					best_d = d
					best = t
			if best >= 0 and best_d < 3.0:
				var k := pc[best]
				for t in n:
					if pc[t] == k:
						out[t] = 1
	return out

func _set_welds(w: Array) -> void:
	main._push_undo("")
	if w.is_empty():
		main.project.erase("nav_welds")
	else:
		main.project["nav_welds"] = w
	refresh()

func _pick_navmesh(at: Vector2, kept := true) -> Variant:
	# the navmesh point under the mouse (m), kept triangles only, nearest along the ray; null when none
	var from: Vector3 = main.camera.project_ray_origin(at)
	var dir: Vector3 = main.camera.project_ray_normal(at)
	var best := INF
	var hit: Variant = null
	for t in _kept.size():
		var live := (_kept[t] == 1 or (_added.size() == _kept.size() and _added[t] == 1)) \
			and not (_removed.size() == _kept.size() and _removed[t] == 1)
		if live != kept:
			continue
		var q: Variant = Geometry3D.ray_intersects_triangle(from, dir, _tris[t * 3], _tris[t * 3 + 1], _tris[t * 3 + 2])
		if q != null and from.distance_to(q) < best:
			best = from.distance_to(q)
			hit = q
	return hit

func _weld_click(at: Vector2) -> void:
	var q: Variant = _pick_navmesh(at)
	if q == null:
		main.set_status("Weld: click on the navmesh (build it first, and show it)")
		return
	var cm: Vector3 = (q as Vector3) / main.CM
	var pt := [snappedf(cm.x, 1.0), snappedf(cm.y, 1.0), snappedf(cm.z, 1.0)]
	if _weld_a == null:
		_weld_a = pt
		main.set_status("Weld: now click the navmesh on the other side (Esc drops this one)")
		_rebuild_welds()
		return
	var w := hand_welds()
	w.append({"a": _weld_a, "b": pt})
	_weld_a = null
	main.set_status("Weld added (Generate to use it). Click the next gap, or Esc to stop")
	_set_welds(w)

# ---------------------------------------------------------------- window

func refresh() -> void:
	_updating = true
	var nm: Dictionary = main.project.get("navmesh", {}) if main.project.get("navmesh") is Dictionary else {}
	if nm.is_empty():
		info.text = "No navmesh yet: build one for bots to play this map."
	else:
		info.text = "%d polygons in the playable area, %d left out.\n%s" % [int(nm.get("polygons", 0)), int(nm.get("dropped", 0)), nm.get("lnv", "")]
		if nm.has("pieces"):
			var sizes: Array = nm.get("piece_sizes", [])
			var share := 100.0 * float(sizes[0]) / maxf(1.0, float(nm.get("polygons", 1))) if sizes.size() else 0.0
			info.text += "\n%d piece%s (the largest %.0f%% of it); %d weld%s (%d by hand)." % [int(nm["pieces"]),
				"" if int(nm["pieces"]) == 1 else "s", share, int(nm.get("welds", 0)), "" if int(nm.get("welds", 0)) == 1 else "s",
				int(nm.get("welds_manual", 0))]
	if main.project.get("nav_mesh") is String:
		info.text += "\nHand-edited: Generate uses %s instead of generating one (the Generation settings don't apply; Generate ▾ Discard hand edits goes back)." % main.project["nav_mesh"]
	info_short.text = "not built" if nm.is_empty() else "%d polygons, %d piece%s%s" % [int(nm.get("polygons", 0)),
		int(nm.get("pieces", 1)), "" if int(nm.get("pieces", 1)) == 1 else "s", ", hand-edited" if main.project.get("nav_mesh") is String else ""]
	if _mode == "edit" and (edit.obj_path() == "" or edit.dir != main.project_dir):
		_set_mode("")
	var st := settings()
	for d in SETTINGS:
		(setting_spins[d[0]] as SpinBox).value = float(st.get(d[0], d[2]))
	for c in welds_box.get_children():
		welds_box.remove_child(c)
		c.queue_free()
	var hw := hand_welds()
	for i in hw.size():
		var row := HBoxContainer.new()
		var a: Array = hw[i].get("a", [0, 0, 0])
		var b: Array = hw[i].get("b", [0, 0, 0])
		var gap := Vector3(a[0], a[1], a[2]).distance_to(Vector3(b[0], b[1], b[2])) / 100.0
		var l: Label = main._label("Weld %d: %.1f m" % [i + 1, gap])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var idx := i
		main._button(row, "Show", func():
			var mid: Vector3 = (Vector3(a[0], a[1], a[2]) + Vector3(b[0], b[1], b[2])) * 0.5 * main.CM
			main.camera.look_at_point(mid, mid + Vector3(5, 4, 5)))
		main._button(row, "Remove", func():
			var w := hand_welds()
			w.remove_at(idx)
			_set_welds(w))
		welds_box.add_child(row)
	for c in remove_box.get_children():
		remove_box.remove_child(c)
		c.queue_free()
	for key in ["nav_added", "nav_removed"]:
		_list_marks(key)
	for c in planes_box.get_children():
		planes_box.remove_child(c)
		c.queue_free()
	var f := floors()
	for i in f.size():
		_floor_row(f, i)
	add_btn.disabled = f.size() >= MAX_PLANES or main.project_dir == ""
	build_btn.disabled = main.project_dir == ""
	radar_btn.disabled = main.project_dir == "" or nm.is_empty()
	_updating = false
	load_view()

func _list_marks(key: String) -> void:
	var items := marks(key)
	for i in items.size():
		var it: Dictionary = items[i]
		var row := HBoxContainer.new()
		var at: Array = it["piece"] if it.get("piece") is Array else (it["brush"][0] if it.get("brush") is Array and it["brush"].size() else [0, 0, 0])
		var verb := "Added back" if key == "nav_added" else "Taken out"
		var what := verb + (": piece" if it.get("piece") is Array else ": area (%d m brush)" % roundi(float(it.get("r", 0)) / 100.0))
		var l: Label = main._label("%s at %.0f, %.0f, %.0f m" % [what, at[0] / 100.0, at[1] / 100.0, at[2] / 100.0])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		row.add_child(l)
		var idx := i
		main._button(row, "Show", func():
			var pnt: Vector3 = Vector3(at[0], at[1], at[2]) * main.CM
			main.camera.look_at_point(pnt, pnt + Vector3(6, 5, 6)))
		main._button(row, "Undo", func():
			var r := marks(key)
			r.remove_at(idx)
			_set_marks(key, r))
		remove_box.add_child(row)

func _floor_row(f: Array, i: int) -> void:
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

# the export builds the navmesh itself when the map changed: show that one
func after_export() -> void:
	var res: Variant = JSON.parse_string(FileAccess.get_file_as_string(main.project_dir.path_join(".preview/navmesh.json")))
	if res is Dictionary:
		main.project["navmesh"] = res
		refresh()
		_update_view()

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
		_piece = PackedInt32Array()
		_welds = []
		if f.get_length() - f.get_position() >= n * 2 + 4:   # pieces and welds (since 2026-11-13)
			var pc := PackedInt32Array()
			var raw16 := f.get_buffer(n * 2)
			pc.resize(n)
			for i in n:
				var x := raw16.decode_u16(i * 2)
				pc[i] = -1 if x == 0xFFFF else x
			_piece = pc
			var nw := f.get_32()
			for i in nw:
				var w := f.get_buffer(24).to_float32_array()
				var manual := f.get_8() == 1
				_welds.append([Vector3(w[0], w[1], w[2]) * main.CM, Vector3(w[3], w[4], w[5]) * main.CM, manual])
		f.close()
		if _piece.size() != _kept.size():   # built before pieces: worked out here (no welds known)
			_piece = _pieces_here()
		_tris.resize(n * 3)
		for i in n * 3:
			_tris[i] = Vector3(raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2]) * main.CM
	_rebuild_overlay()

func _rebuild_overlay() -> void:
	var pos := PackedVector3Array()
	var cols := PackedColorArray()
	var fl := floors()
	var dropped := PackedByteArray()
	dropped.resize(_kept.size())
	for t in _kept.size():
		dropped[t] = 1 - _kept[t]
	_added = _mask("nav_added", dropped, _mode == "add_brush")
	var live := _kept.duplicate()
	for t in _kept.size():
		if _added[t] == 1:
			live[t] = 1
	_removed = _mask("nav_removed", live, _mode == "remove_brush")
	for t in _kept.size():
		var keep := _kept[t] == 1
		if not keep and not dropped_box.button_pressed and _added[t] == 0:
			continue
		var a := _tris[t * 3]
		var b := _tris[t * 3 + 1]
		var c := _tris[t * 3 + 2]
		var col: Color = DROPPED
		if keep and colour_by.selected == 1 and _piece.size() == _kept.size():
			col = piece_colour(_piece[t])
		elif keep:
			var y: float = (a.y + b.y + c.y) / 3.0 / main.CM
			var k := 0
			for h in fl:
				if y >= h:
					k += 1
			col = FLOOR_COLOURS[k % FLOOR_COLOURS.size()]
			col.a = 0.45
		if _added[t] == 1:
			col = ADDED
		if (keep or _added[t] == 1) and _removed[t] == 1:
			col = REMOVED
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
	_rebuild_welds()
	_update_view()

static func _root(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

static func _corner(q: Vector3) -> Vector3i:
	return Vector3i(roundi(q.x * 1000.0), roundi(q.y * 1000.0), roundi(q.z * 1000.0))

func _pieces_here() -> PackedInt32Array:
	# kept triangles joined across shared edges (corners matched by position, to the mm), 0 the largest, -1 dropped
	return pieces_of(_tris, _kept)

static func pieces_of(tris: PackedVector3Array, kept: PackedByteArray) -> PackedInt32Array:
	var n := kept.size()
	var parent: Array = range(n)
	var first := {}   # edge -> the first triangle on it
	for t in n:
		if kept[t] != 1:
			continue
		for e in 3:
			var a := _corner(tris[t * 3 + e])
			var b := _corner(tris[t * 3 + (e + 1) % 3])
			var k := [a, b] if (a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z)))) else [b, a]
			if first.has(k):
				var ra := _root(parent, first[k])
				var rb := _root(parent, t)
				if ra != rb:
					parent[rb] = ra
			else:
				first[k] = t
	var count := {}
	for t in n:
		if kept[t] == 1:
			var r := _root(parent, t)
			count[r] = int(count.get(r, 0)) + 1
	var roots := count.keys()
	roots.sort_custom(func(x, y): return count[x] > count[y])
	var num := {}
	for i in roots.size():
		num[roots[i]] = i
	var out := PackedInt32Array()
	out.resize(n)
	for t in n:
		out[t] = num[_root(parent, t)] if kept[t] == 1 else -1
	return out

static func piece_colour(k: int) -> Color:
	# piece 0 (the largest) green; the rest spread round the colour wheel, strong so small islands stand out
	if k <= 0:
		return Color(0.15, 0.85, 0.35, 0.45)
	var c := Color.from_hsv(fmod(0.33 + k * 0.618034, 1.0), 0.85, 1.0)
	c.a = 0.6
	return c

func _rebuild_welds() -> void:
	# the last build's welds (white automatic, yellow by hand) and hand welds not built yet (orange), 25 cm up
	var im := ImmediateMesh.new()
	var lift := Vector3(0, 0.25, 0)
	if _welds.is_empty() and hand_welds().is_empty() and _weld_a == null:
		weld_lines.mesh = null
		return
	var any := false
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for w in _welds:
		im.surface_set_color(WELD_HAND if w[2] else WELD_AUTO)
		im.surface_add_vertex(w[0] + lift)
		im.surface_set_color(WELD_HAND if w[2] else WELD_AUTO)
		im.surface_add_vertex(w[1] + lift)
		any = true
	for hw in hand_welds():
		var a: Array = hw.get("a", [0, 0, 0])
		var b: Array = hw.get("b", [0, 0, 0])
		var pa: Vector3 = Vector3(a[0], a[1], a[2]) * main.CM
		var pb: Vector3 = Vector3(b[0], b[1], b[2]) * main.CM
		for k in 3:   # a cross at each end and the line between
			var d := [Vector3(0.3, 0, 0), Vector3(0, 0.3, 0), Vector3(0, 0, 0.3)][k] as Vector3
			for p in [pa, pb]:
				im.surface_set_color(WELD_NEW)
				im.surface_add_vertex(p + lift - d)
				im.surface_set_color(WELD_NEW)
				im.surface_add_vertex(p + lift + d)
		im.surface_set_color(WELD_NEW)
		im.surface_add_vertex(pa + lift)
		im.surface_set_color(WELD_NEW)
		im.surface_add_vertex(pb + lift)
		any = true
	if _weld_a != null:
		var p: Vector3 = Vector3(_weld_a[0], _weld_a[1], _weld_a[2]) * main.CM + lift
		for d in [Vector3(0.4, 0, 0), Vector3(0, 0.4, 0), Vector3(0, 0, 0.4)]:
			im.surface_set_color(WELD_NEW)
			im.surface_add_vertex(p - d)
			im.surface_set_color(WELD_NEW)
			im.surface_add_vertex(p + d)
		any = true
	im.surface_end()
	weld_lines.mesh = im if any else null

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
	overlay.visible = show_box.button_pressed and _mode != "edit"
	weld_lines.visible = show_box.button_pressed and _mode != "edit"
	plane_root.visible = visible
