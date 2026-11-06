extends Window
# Floating placement window (T): pick a spawn point, weapon pickup or VS, then click the map to put one there
# (a ray against the stage) and drag to aim it (the mouse on the level plane through that point). Placed markers
# go into the shown marker set with "placed": true (lp2layout.py: VS / weapons beyond the stock count are copies
# of the stock records; spawns fill the stock rInitPosSet counts by role, so extra ones are not exported yet).

const KINDS := ["Spawn point", "Weapon pickup", "VS", "Volume", "Data post"]
const SPAWNS := [["start", 1, "Free-for-all start"], ["team_a", 20, "Team A (red)"], ["team_b", 21, "Team B (blue)"],
	["team_c", 22, "Team C"], ["team_d", 23, "Team D"], ["k30", 30, "Team A base (red sphere; VS mode)"],
	["k31", 31, "Team B base (blue sphere; VS mode)"], ["k40", 40, "Free-for-all / Fugitive point (green sphere)"]]
const AIM_PX := 6.0        # drag this far before the mouse aims the marker
const SNAP_DEG := 15.0
const SNAP_CM := 50.0
const HINT := "Click the map to place, drag to aim\n(Ctrl or Snap: 15° steps). Esc stops placing."
const HINT_VOLUME := "Click the map for a 10 m box, or drag out its floor\n(Ctrl or Snap: 50 cm steps). Esc stops placing."

var main: Node
var kind_pick: OptionButton
var item_pick: OptionButton
var vs_list: ItemList      # VS: thumbnails (the library's vs_XX models) instead of the dropdown
var _vs_thumbs := {}       # library key -> texture
var _shown: Array = []     # the vs_types rows in vs_list
var hint: Label
var all_layouts: CheckBox  # also put a copy in the other layouts' matching sets
var vs_types: Array = []   # per family: [type id placed, tooltip, short label, family's types]
var _node: Node3D = null   # the marker being placed
var _press := Vector2.ZERO
var _origin := Vector3.ZERO
var _copies: Array = []    # the placed marker's data and its copies in the other layouts
var _quick: Node3D = null  # Quick place (Q): the item following the mouse; the next click puts it down (then drag to aim)
var _quick_copy: Node3D = null   # Ctrl+Q: the original of the copy in _quick (Esc takes the copy away and selects this again)
var _quick_copy_data: Variant = null   # its data: a marker's node is rebuilt when a copy goes
var _quick_at := Vector3.ZERO    # from the point under the mouse to the item's origin
var _quick_skip: Array = []      # the item's own collision: the mouse's ray goes through it
var _quick_done := false         # the click was a Quick place: _end finishes it, whatever the item

func _twin_sets(i: int) -> Array:
	# the other layouts' sets with the same LP1 mode digits (ids 00 10 30 40 -> 01 11 31 41 ...)
	var sets: Array = main.layout["sets"]
	var key := func(k: int) -> Array:
		var m: Array = sets[k].get("ids", []).map(func(x): return str(x).substr(0, 1))
		m.sort()
		return m
	var mine: Array = key.call(i)
	var v: String = main._set_variant_digit(i)
	var out := []
	for j in sets.size():
		if j != i and main._set_variant_digit(j) != v and key.call(j) == mine:
			out.append(j)
	return out

func _init() -> void:
	title = "Place"
	size = Vector2i(360, 170)
	min_size = Vector2i(300, 150)
	transient = true
	visible = false
	wrap_controls = true
	close_requested.connect(hide)

func setup(m: Node) -> void:
	main = m
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var v := VBoxContainer.new()
	bg.add_child(v)
	kind_pick = OptionButton.new()
	for k in KINDS:
		kind_pick.add_item(k)
	kind_pick.item_selected.connect(func(_i): _fill_items())
	v.add_child(kind_pick)
	item_pick = OptionButton.new()
	item_pick.fit_to_longest_item = false
	item_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(item_pick)
	vs_list = ItemList.new()
	vs_list.max_columns = 0
	vs_list.icon_mode = ItemList.ICON_MODE_TOP
	vs_list.fixed_icon_size = Vector2i(main.thumbs.SIZE, main.thumbs.SIZE)
	vs_list.fixed_column_width = main.thumbs.SIZE + 12
	vs_list.same_column_width = true
	vs_list.max_text_lines = 2
	vs_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vs_list.visible = false
	v.add_child(vs_list)
	all_layouts = CheckBox.new()
	all_layouts.text = "Place on all 4 layouts"
	all_layouts.button_pressed = true
	all_layouts.tooltip_text = "The game picks one of the map's 4 layouts per match: also put a copy in the other layouts' matching set (the copies don't follow later moves)"
	v.add_child(all_layouts)
	hint = main._label(HINT)
	v.add_child(hint)
	_load_vs_types()
	_fill_items()

func _load_vs_types() -> void:
	# one entry per VS family (the tools' vs_families.json, lp2vsfamilies.py): [type placed (the family's default),
	# tooltip, label, every type of the family]; the variant and arm weapons are set in the inspector (vsprops.gd)
	vs_types = []
	var f := FileAccess.open(main.tools.path_join("vs_families.json"), FileAccess.READ)
	if f == null:
		return
	var j = JSON.parse_string(f.get_as_text())
	if typeof(j) != TYPE_DICTIONARY:
		return
	for fam in j.get("families", []):
		var t := int(fam["default"])
		var info: Dictionary = j["types"].get("%02x" % t, {})
		var sz: Array = info.get("size", [])
		var arms: Array = info.get("editable", [])
		var tip := "%s: %d variant(s), %s%s" % [fam["name"], fam["types"].size(),
			("weapon mounts " + ", ".join(arms)) if not arms.is_empty() else "no weapon mounts",
			("  %s x %s x %s m" % sz) if sz.size() == 3 else ""]
		vs_types.append([t, tip, "%s\n%d variant%s" % [fam["name"], fam["types"].size(), "" if fam["types"].size() == 1 else "s"],
			fam["types"].map(func(x): return int(x))])

func _fill_items() -> void:
	item_pick.clear()
	var vs := kind_pick.selected == 2
	item_pick.visible = not vs
	all_layouts.visible = kind_pick.selected != 3   # volumes are the map's, not a layout's
	hint.text = HINT_VOLUME if kind_pick.selected == 3 else HINT
	vs_list.visible = vs
	size = Vector2i(maxi(size.x, 560), 560) if vs else Vector2i(size.x, 170)
	if vs:
		_fill_vs()
		return
	match kind_pick.selected:
		0:
			for s in SPAWNS:
				item_pick.add_item(s[2])
		1:
			for w in main.PICKUP_ITEMS:
				item_pick.add_item(w[1])
		3:
			for a in main.volumes.ADD:
				item_pick.add_item(a[1])
		4:   # lp2layout.patch_objset: a copy of the base map's post record (Data Post layouts) at each one
			item_pick.add_item("Data post (Data Post game type)")
	item_pick.select(0)

func _fill_vs() -> void:
	vs_list.clear()
	_shown = vs_types   # no library yet (Browser: Get assets): no pictures
	for t in _shown:
		var key := _thumb_key(t)
		var i := vs_list.add_item(t[2])
		vs_list.set_item_tooltip(i, t[1])
		if _vs_thumbs.has(key):
			vs_list.set_item_icon(i, _vs_thumbs[key])
		elif main.library.by_key.has(key):
			main.thumbs.request_scene(func(): return main.library.instance(key), func(tex):
				_vs_thumbs[key] = tex
				if i < vs_list.item_count and vs_list.get_item_tooltip(i) == t[1]:
					vs_list.set_item_icon(i, tex))
	if vs_list.item_count:
		vs_list.select(0)

func _thumb_key(t: Array) -> String:
	# the family's default type's library model, else any of its types'
	for x in [t[0]] + t[3]:
		if main.library.by_key.has("vs_%02x" % x):
			return "vs_%02x" % x
	return "vs_%02x" % t[0]

func placing() -> bool:
	return visible or _node != null or _quick != null

func quick(n: Node3D, copy_of: Node3D = null) -> void:
	# Quick place: this item follows the mouse, the next click puts it there, a drag aims it (about the up axis), Esc cancels.
	# Only the node moves until the click, so an item's data (and the undo taken then) still has where it was.
	_quick = n
	_quick_copy = copy_of
	_quick_copy_data = copy_of.get_meta("data") if copy_of and copy_of.has_meta("data") else null
	_quick_at = _anchor(n)
	_quick_skip = []
	_bodies(n, _quick_skip)
	_follow(main.get_viewport().get_mouse_position())
	var what := "Quick duplicate" if copy_of else "Quick place"
	main.set_status("%s: click where it goes%s. Esc cancels." % [what, ", drag to aim (Ctrl or Snap: 15° steps)" if _aims(n) else ""])

func _aims(n: Node3D) -> bool:
	# a drag aims spawns, pickups, VS, posts and spot lights; the rest have no front
	if not main._is_marker(n) or n.has_meta("volume") or n.has_meta("terrain"):
		return false
	return not n.has_meta("light") or (n.get_meta("data") as Dictionary).get("type") == "spot"

func _anchor(n: Node3D) -> Vector3:
	if n.has_meta("light"):   # stays as high above the ground as it was
		var from: Vector3 = n.global_position + Vector3.UP * 0.5
		var hit: Dictionary = main._ray(from, from + Vector3.DOWN * 2000.0, 1 << (main.LAYER_STAGE - 1))
		return Vector3(0, maxf(0.3, n.global_position.y - hit["position"].y) if hit else 2.0, 0)
	if main._is_marker(n) and not n.has_meta("terrain"):
		return Vector3(0, 5.0 * main.CM, 0) if not n.has_meta("volume") else Vector3.ZERO   # 5 cm up, as placed markers
	# a piece or terrain: the middle of its underside goes to the mouse
	var box := _bounds(n, AABB(), false)
	if box.size == Vector3.ZERO:
		return Vector3.ZERO
	return n.global_position - (box.get_center() - Vector3(0, box.size.y / 2.0, 0))

func _bounds(n: Node, box: AABB, have: bool) -> AABB:
	for c in n.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh and (c as MeshInstance3D).visible:
			var b: AABB = (c as MeshInstance3D).global_transform * (c as MeshInstance3D).get_aabb()
			box = box.merge(b) if have else b
			have = true
		var sub := _bounds(c, box, have)
		if sub != box:
			box = sub
			have = true
	return box

func _bodies(n: Node, out: Array) -> void:
	if n is CollisionObject3D:
		out.append((n as CollisionObject3D).get_rid())
	for c in n.get_children():
		_bodies(c, out)

func _under_mouse(mp: Vector2) -> Dictionary:
	var from: Vector3 = main.camera.project_ray_origin(mp)
	return main._ray(from, from + main.camera.project_ray_normal(mp) * 5000.0, 1 << (main.LAYER_STAGE - 1), _quick_skip)

func _follow(mp: Vector2) -> void:
	if not is_instance_valid(_quick):
		return
	var hit := _under_mouse(mp)
	if hit:
		_quick.global_position = hit["position"] + _quick_at
		main._place_gizmo()

func cancel_quick() -> bool:
	if _quick == null:
		return false
	var n: Node3D = _quick if is_instance_valid(_quick) else null
	var copy_of: Node3D = _quick_copy
	var data: Variant = _quick_copy_data
	_quick = null
	_quick_copy = null
	_quick_copy_data = null
	if n and copy_of:   # the copy goes, and so does the undo step that made it
		main.cancel_copy(n, copy_of if is_instance_valid(copy_of) else null, data, _copies)
		_copies = []
		main.set_status("Quick duplicate cancelled")
		return true
	if n and n.has_meta("data"):
		main._place(n)   # back where its data says
		main._place_gizmo()
	main.set_status("Quick place cancelled")
	return true

func duplicate_marker(n: Node3D) -> Node3D:
	# a copy of a spawn, pickup, VS or post in the shown set, and in the other layouts' as a placed one is
	var src: Dictionary = n.get_meta("data")
	var d: Dictionary = src.duplicate(true)
	d.erase("id")   # scripts point at the original
	d["placed"] = true
	var is_object: bool = n.get_meta("object")
	var key := "objects" if is_object else "points"
	var s: Dictionary = main.layout["sets"][main.set_index]
	if d.get("role") == "object":
		d["post"] = main.next_post_number(s)
	s[key].append(d)
	main._add_marker(d, is_object)
	_copies = [d]
	if all_layouts.button_pressed:
		for j in _twin_sets(main.set_index):
			var c: Dictionary = d.duplicate(true)
			if d.get("role") == "object":
				c["post"] = main.next_post_number(main.layout["sets"][j])
			main.layout["sets"][j][key].append(c)
			_copies.append(c)
	return main.markers_root.get_child(main.markers_root.get_child_count() - 1)

func _marker_data() -> Variant:
	var i := item_pick.selected
	match kind_pick.selected:
		0:
			return {"kind": SPAWNS[i][1], "role": SPAWNS[i][0], "placed": true}
		1:
			var id: int = main.PICKUP_ITEMS[i][0]
			var d := {"kind": 4, "role": "weapon", "placed": true}
			if id >= 0:
				d["item"] = id
				if id < 0x30:
					d["model"] = "wp%02x" % id
			return d
		2:
			var sel := vs_list.get_selected_items()
			if sel.is_empty():
				main.set_status("Pick a VS in the Place window first.")
				return null
			return {"kind": 1, "role": "vs", "model": "vs%02x" % _shown[sel[0]][0], "placed": true}
		4:
			return {"kind": 3, "role": "object", "model": "om7100", "placed": true}
	return null

# main._unhandled_input hands mouse events here first while placing; true = used
func handle(e: InputEvent) -> bool:
	if _quick and not is_instance_valid(_quick):   # an undo or a layout change rebuilt it
		_quick = null
		_quick_copy = null
	if e is InputEventMouseMotion and _quick and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_follow(e.position)
		return false   # the view still sees the mouse
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and _quick:
			_begin_quick(e.position)
			return true
		if e.pressed and visible:
			if Time.get_ticks_msec() - _last_place < CLICK_GAP_MS:   # a twitch / bounce right after a placement
				return true
			var at := _existing(e.position)
			if at:   # a marker already there (or the second click of a double click): select it, don't stack another
				main.select([at])
				main.set_status("Selected %s (click empty ground to place)" % main._marker_label(at.get_meta("data"), at.get_meta("object")) if at.has_meta("data") and not at.has_meta("light") else "Selected")
				return true
			_begin(e.position)
			return true
		if not e.pressed and _node:
			_end()
			return true
	elif e is InputEventMouseMotion and _node:
		_aim(e.position)
		return true
	return false

const CLICK_GAP_MS := 200   # clicks this soon after a placement are ignored (no accidental second copy)
var _last_place := 0
const POST_GAP := 1.5   # m: placing a post this close to another selects that one instead (they'd overlap)

func _existing(mp: Vector2) -> Node3D:
	# the marker under the mouse (spawns, pickups, VS, posts, lights; not volumes or terrain, which are placed into),
	# or, placing a post, the post nearest where it would go if one is within POST_GAP
	var n: Node3D = main._pick(mp)
	if n and main._is_marker(n) and not n.has_meta("volume") and not n.has_meta("terrain"):
		return n
	if kind_pick.selected != 4:
		return null
	var hit: Dictionary = main._mouse_ray(mp, 1 << (main.LAYER_STAGE - 1))
	if not hit:
		return null
	var best: Node3D = null
	var best_d := POST_GAP
	for m in main.markers_root.get_children():
		if m.has_meta("data") and m.get_meta("object") and (m.get_meta("data") as Dictionary).get("role", "") == "object":
			var d: float = m.global_position.distance_to(hit["position"])
			if d < best_d:
				best_d = d
				best = m
	return best

func _unhandled_key_input(e: InputEvent) -> void:
	# keys pressed while this window has the focus (W / E / R, Q, F, Delete...) work as in the view
	main._unhandled_input(e)

func _begin(mp: Vector2) -> void:
	if main.set_index < 0 and kind_pick.selected != 3:
		main.log_line("This layout has no marker set to place into.")
		return
	var hit: Dictionary = main._mouse_ray(mp, 1 << (main.LAYER_STAGE - 1))
	if not hit:   # nothing of the level under the mouse (sky, a gap): 20 m along the view instead of nothing
		hit = {"position": main.camera.project_ray_origin(mp) + main.camera.project_ray_normal(mp) * 20.0}
		main.set_status("Nothing under the mouse: placed 20 m out.")
	if kind_pick.selected == 3:
		main._push_undo("")
		_origin = hit["position"]
		_node = main.volumes.place_volume(main.volumes.ADD[item_pick.selected][0], _origin)
		_copies = []
		_press = mp
		return
	var d: Variant = _marker_data()
	if d == null:
		return
	main._push_undo("")
	_origin = hit["position"]
	# facing away from the camera until dragged
	var fwd: Vector3 = -main.camera.global_transform.basis.z
	d["pos"] = [_origin.x / main.CM, _origin.y / main.CM + 5.0, _origin.z / main.CM]
	d["yaw"] = snappedf(rad_to_deg(atan2(fwd.x, fwd.z)), 0.01)   # the game faces +Z
	var s: Dictionary = main.layout["sets"][main.set_index]
	if d["role"] == "object":
		d["post"] = main.next_post_number(s)
	s["objects" if d["role"] in main.OBJECT_ROLES else "points"].append(d)
	main._add_marker(d, d["role"] in main.OBJECT_ROLES)
	_copies = [d]
	if all_layouts.button_pressed:
		for j in _twin_sets(main.set_index):
			var c: Dictionary = d.duplicate(true)
			if d["role"] == "object":
				c["post"] = main.next_post_number(main.layout["sets"][j])
			main.layout["sets"][j]["objects" if d["role"] in main.OBJECT_ROLES else "points"].append(c)
			_copies.append(c)
	_node = main.markers_root.get_child(main.markers_root.get_child_count() - 1)
	_press = mp

func _begin_quick(mp: Vector2) -> void:
	var hit := _under_mouse(mp)
	if not hit:
		main.set_status("Nothing of the level under the mouse: click on the map (Esc cancels)")
		return
	if _quick_copy == null:
		main._push_undo("")   # a copy took its undo step when it was made
	else:
		_quick_copy = null
		_quick_copy_data = null
	_node = _quick
	_quick = null
	_quick_done = true
	_origin = hit["position"]
	_node.global_position = _origin + _quick_at
	if main._is_marker(_node):
		main._store_marker(_node)
	if _copies.is_empty() or not _node.has_meta("data") or not is_same(_copies[0], _node.get_meta("data")):
		_copies = []
	_press = mp

func _aim(mp: Vector2) -> void:
	if mp.distance_to(_press) < AIM_PX or (_quick_done and not _aims(_node)):
		return
	var from: Vector3 = main.camera.project_ray_origin(mp)
	var at: Variant = Plane(Vector3.UP, _origin.y).intersects_ray(from, main.camera.project_ray_normal(mp))
	if at == null:
		return
	var dir: Vector3 = at - _origin
	dir.y = 0
	if _node.has_meta("volume"):
		_drag_floor(at)
		return
	if dir.length() < 0.05:
		return
	var yaw := rad_to_deg(atan2(dir.x, dir.z))   # +Z (the game's front) towards the mouse
	if main.snap_toggle.button_pressed or Input.is_key_pressed(KEY_CTRL):
		yaw = snappedf(yaw, SNAP_DEG)
	_node.rotation_degrees.y = yaw
	main._store_marker(_node)
	_sync_copies()

func _drag_floor(at: Vector3) -> void:
	# the volume's floor spans the press point to the mouse (at least 1 m a side)
	var snap: bool = main.snap_toggle.button_pressed or Input.is_key_pressed(KEY_CTRL)
	var d: Dictionary = _node.get_meta("data")
	var a: Vector2 = Vector2(_origin.x, _origin.z) / main.CM
	var b: Vector2 = Vector2(at.x, at.z) / main.CM
	if snap:
		a = a.snapped(Vector2(SNAP_CM, SNAP_CM))
		b = b.snapped(Vector2(SNAP_CM, SNAP_CM))
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	var size := (hi - lo).max(Vector2(100, 100))
	d["size"] = [size.x, d["size"][1], size.y]
	d["pos"] = [(lo.x + hi.x) / 2, _origin.y / main.CM, (lo.y + hi.y) / 2]
	main._place(_node)
	main.volumes.update_marker(_node)

func _sync_copies() -> void:
	if _copies.is_empty():
		return
	var d: Dictionary = _node.get_meta("data")
	for c in _copies.slice(1):
		c["pos"] = d["pos"].duplicate()
		c["yaw"] = d["yaw"]

func _end() -> void:
	if _quick_done:
		_quick_done = false
		var q := _node
		if main._is_marker(q):
			main._store_marker(q)
			_sync_copies()
		_node = null
		_copies = []
		_last_place = Time.get_ticks_msec()
		main._rebuild_outliner()
		main.select([q])
		main._update_stats()
		main.set_status("Placed")
		return
	if _node.has_meta("volume"):
		var v := _node
		_node = null
		_last_place = Time.get_ticks_msec()
		main._rebuild_outliner()
		main.select([v])
		main.log_line("Placed %s." % main.volumes.label(v.get_meta("data")))
		return
	main._store_marker(_node)
	_sync_copies()
	_last_place = Time.get_ticks_msec()
	var n := _node
	_node = null
	main._rebuild_outliner()
	main.select([n])
	main._update_stats()
	main.log_line("Placed %s (yaw %.0f°)%s." % [main._marker_label(n.get_meta("data"), n.get_meta("object")), n.rotation_degrees.y,
		" on %d layouts" % _copies.size() if _copies.size() > 1 else ""])
	if not visible:   # a Quick place (the Place window is closed)
		main.set_status("Placed")
