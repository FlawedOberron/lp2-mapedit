extends Window
# Floating placement window (T): pick a spawn point, weapon pickup or VS, then click the map to put one there
# (a ray against the stage) and drag to aim it (the mouse on the level plane through that point). Placed markers
# go into the shown marker set with "placed": true (lp2layout.py: VS / weapons beyond the stock count are copies
# of the stock records; spawns fill the stock rInitPosSet counts by role, so extra ones are not exported yet).

const KINDS := ["Spawn point", "Weapon pickup", "VS", "Volume"]
const SPAWNS := [["start", 1, "Free-for-all start"], ["team_a", 20, "Team A (red)"], ["team_b", 21, "Team B (blue)"],
	["team_c", 22, "Team C"], ["team_d", 23, "Team D"], ["k40", 40, "Spare point (k40: weapons fill these)"]]
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
	return visible or _node != null

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
	return null

# main._unhandled_input hands mouse events here first while placing; true = used
func handle(e: InputEvent) -> bool:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and visible:
			_begin(e.position)
			return true
		if not e.pressed and _node:
			_end()
			return true
	elif e is InputEventMouseMotion and _node:
		_aim(e.position)
		return true
	return false

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
	d["yaw"] = snappedf(rad_to_deg(atan2(-fwd.x, -fwd.z)), 0.01)
	var s: Dictionary = main.layout["sets"][main.set_index]
	s["objects" if d["role"] in ["weapon", "vs"] else "points"].append(d)
	main._add_marker(d, d["role"] in ["weapon", "vs"])
	_copies = [d]
	if all_layouts.button_pressed:
		for j in _twin_sets(main.set_index):
			var c: Dictionary = d.duplicate(true)
			main.layout["sets"][j]["objects" if d["role"] in ["weapon", "vs"] else "points"].append(c)
			_copies.append(c)
	_node = main.markers_root.get_child(main.markers_root.get_child_count() - 1)
	_press = mp

func _aim(mp: Vector2) -> void:
	if mp.distance_to(_press) < AIM_PX:
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
	var yaw := rad_to_deg(atan2(-dir.x, -dir.z))
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
	var d: Dictionary = _node.get_meta("data")
	for c in _copies.slice(1):
		c["pos"] = d["pos"].duplicate()
		c["yaw"] = d["yaw"]

func _end() -> void:
	if _node.has_meta("volume"):
		var v := _node
		_node = null
		main._rebuild_outliner()
		main.select([v])
		main.log_line("Placed %s." % main.volumes.label(v.get_meta("data")))
		return
	main._store_marker(_node)
	_sync_copies()
	var n := _node
	_node = null
	main._rebuild_outliner()
	main.select([n])
	main._update_stats()
	main.log_line("Placed %s (yaw %.0f°)%s." % [main._marker_label(n.get_meta("data"), n.get_meta("object")), n.rotation_degrees.y,
		" on %d layouts" % _copies.size() if _copies.size() > 1 else ""])
