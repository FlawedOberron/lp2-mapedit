extends Window
# Floating browser: the project's prefabs and the level's pieces as thumbnails.
# Prefabs: double-click places one where the view points. Level: click selects, double-click frames.
# Game assets: the library's models (VS, weapons, posts) by group; Get assets builds the library from the game installs.

var main: Node      # main.gd
var thumbs: Node    # thumbs.gd
var prefab_list: ItemList
var level_list: ItemList
var filter: LineEdit
var tabs: TabContainer
var asset_list: ItemList
var asset_group: OptionButton
var asset_filter: LineEdit
var asset_info: Label
var _asset_thumbs := {}   # key -> texture
var _gen := 0       # bumped on every refill, so late thumbnails for old lists are dropped
var _prefab_thumbs := {}   # members hash -> texture
var _updating := false

func _init() -> void:
	title = "Browser"
	size = Vector2i(560, 640)
	min_size = Vector2i(300, 240)
	transient = true
	visible = false
	wrap_controls = true
	close_requested.connect(hide)

func setup(m: Node, t: Node) -> void:
	main = m
	thumbs = t
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	tabs = TabContainer.new()
	bg.add_child(tabs)

	var pf := VBoxContainer.new()
	pf.name = "Prefabs"
	prefab_list = _grid()
	prefab_list.select_mode = ItemList.SELECT_SINGLE
	prefab_list.item_activated.connect(func(i): main.place_prefab(i))
	pf.add_child(prefab_list)
	var prow := HBoxContainer.new()
	main._button(prow, "From selection", main.make_prefab).tooltip_text = "Save the selected pieces as a prefab"
	main._button(prow, "Place", func(): main.place_prefab(main._prefab_pick())).tooltip_text = "Place a copy where the view is pointing (or double-click)"
	main._button(prow, "Delete", main.delete_prefab)
	pf.add_child(prow)
	var hint: Label = main._label("A prefab is a reusable copy of level geometry. Placed copies reuse the stage's own geometry and textures.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	pf.add_child(hint)
	tabs.add_child(pf)

	var lv := VBoxContainer.new()
	lv.name = "In the level"
	filter = LineEdit.new()
	filter.placeholder_text = "Filter by name"
	filter.clear_button_enabled = true
	filter.text_changed.connect(func(_t): refresh())
	lv.add_child(filter)
	level_list = _grid()
	level_list.select_mode = ItemList.SELECT_MULTI
	level_list.multi_selected.connect(func(_i, _s): _on_level_selected())
	level_list.item_activated.connect(func(_i): main.frame_selected())
	lv.add_child(level_list)
	tabs.add_child(lv)

	var ga := VBoxContainer.new()
	ga.name = "Game assets"
	var arow := HBoxContainer.new()
	asset_group = OptionButton.new()
	asset_group.item_selected.connect(func(_i): refresh())
	arow.add_child(asset_group)
	asset_filter = LineEdit.new()
	asset_filter.placeholder_text = "Filter"
	asset_filter.clear_button_enabled = true
	asset_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	asset_filter.text_changed.connect(func(_t): refresh())
	arow.add_child(asset_filter)
	main._button(arow, "Get assets", main.get_assets).tooltip_text = "Rip the models from your Lost Planet 2 (and Lost Planet 1) installs into the asset library"
	ga.add_child(arow)
	asset_list = _grid()
	asset_list.select_mode = ItemList.SELECT_SINGLE
	asset_list.item_selected.connect(_on_asset_selected)
	asset_list.item_activated.connect(_on_asset_activated)
	ga.add_child(asset_list)
	asset_info = main._label("")
	asset_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	ga.add_child(asset_info)
	tabs.add_child(ga)
	visibility_changed.connect(_on_shown)
	tabs.tab_changed.connect(func(_t): if visible: refresh())

func _grid() -> ItemList:
	var l := ItemList.new()
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	l.max_columns = 0
	l.icon_mode = ItemList.ICON_MODE_TOP
	l.fixed_icon_size = Vector2i(thumbs.SIZE, thumbs.SIZE)
	l.fixed_column_width = thumbs.SIZE + 12
	l.same_column_width = true
	l.max_text_lines = 2
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l

func _on_shown() -> void:
	if visible:
		if main.geometry.prefabs.is_empty():
			tabs.current_tab = 1
		refresh()

func refresh() -> void:
	# every list again; thumbnails restart (the current tab's first) and stale ones are dropped
	if not visible:
		_fill_prefabs()
		return
	_gen += 1
	thumbs.clear()
	var fills := [_fill_prefabs, _fill_level, _fill_assets]
	fills.push_front(fills.pop_at(tabs.current_tab))
	for f in fills:
		f.call()

func refresh_prefabs() -> void:
	refresh()

func refresh_level() -> void:
	refresh()

func refresh_assets() -> void:
	refresh()

func _fill_assets() -> void:
	var lib: Node = main.library
	var groups: Array = lib.groups()
	var cur := asset_group.get_item_text(asset_group.selected) if asset_group.selected >= 0 else "All"
	asset_group.clear()
	asset_group.add_item("All")
	for g in groups:
		asset_group.add_item(g)
	for i in asset_group.item_count:
		if asset_group.get_item_text(i) == cur:
			asset_group.select(i)
	asset_list.clear()
	if lib.assets.is_empty():
		asset_info.text = "The library is empty: Get assets rips the models from your game installs (a few minutes, once)."
		return
	asset_info.text = "%d assets. Markers in the level show these models." % lib.assets.size()
	var g := asset_group.get_item_text(asset_group.selected)
	var f := asset_filter.text.to_lower()
	if g == lib.IMPORTS:
		_list_imports(f)
		return
	var mk: String = lib.map_key(g)
	if mk != "":
		_list_map_pieces(mk, f)
		return
	for a in lib.assets:
		if g != "All" and lib.group_of(a) != g:
			continue
		if f != "" and not (a["name"] as String).to_lower().contains(f) and not (a["key"] as String).contains(f):
			continue
		var i := asset_list.add_item(a["name"])
		asset_list.set_item_metadata(i, a["key"])
		asset_list.set_item_tooltip(i, "%s  (%s)%s" % [a["name"], a["key"], "\nDouble-click to browse its pieces" if a.has("map") else ""])
		var key: String = a["key"]
		if _asset_thumbs.has(key):
			asset_list.set_item_icon(i, _asset_thumbs[key])
			continue
		var make: Callable
		if a.has("map") and not lib._maps.has(key):
			continue   # a map's thumbnail loads the whole map: only once it has been opened
		if a.has("map"):
			make = func():   # the map's biggest piece (its terrain)
				var mg: Node = lib.map_geometry(key)
				if mg == null:
					return null
				var ts: Array = mg.default_trees()
				return _piece_node(mg, ts[0]) if ts.size() else null
		else:
			make = func(): return lib.instance(key)
		var gen := _gen
		thumbs.request_scene(make, func(tex):
			_asset_thumbs[key] = tex
			if gen == _gen and i < asset_list.item_count and asset_list.get_item_metadata(i) == key:
				asset_list.set_item_icon(i, tex))

func _piece_node(mg: Node, t: Dictionary) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mg.build_mesh(t)
	var mats: Array = mi.mesh.get_meta("mats")
	for s in mats.size():
		mi.set_surface_override_material(s, mg.material(mats[s]))
	return mi

func _list_map_pieces(key: String, f: String) -> void:
	var lib: Node = main.library
	var mg: Node = lib.map_geometry(key)
	if mg == null:
		asset_info.text = "%s has no preview: run Get assets again." % key
		return
	var ts: Array = mg.default_trees()
	var from: String = " (%s install)" % lib.by_key[key]["from"] if lib.by_key[key].has("from") else ""
	asset_info.text = "%s: %d pieces%s. Double-click a piece to place a copy where the view points." % [
		lib.by_key[key]["name"], ts.size(), from]
	var gen := _gen
	var borrowed: Dictionary = main.geometry.borrowed_textures()   # already paid for
	for k in ts.size():
		var t: Dictionary = ts[k]
		if f != "" and not (t["name"] as String).to_lower().contains(f):
			continue
		var i := asset_list.add_item(t["name"])
		var tk := "%s/%d" % [key, k]
		asset_list.set_item_metadata(i, tk)
		var tris := 0
		var tex := {}
		for m in mg.members_of(t):
			tris += mg.atom_tris[m["atom"]]
			for b in mg.atom_blocks.get(m["atom"], []):
				tex.merge(mg.data["materials"][b[1]].get("textures", {}))
		var mb := 0.0
		for n in tex:
			if not borrowed.has(n):
				mb += float(tex[n]) / 1e6
		asset_list.set_item_tooltip(i, "%s  (%d tris, +%.1f MB textures)\nDouble-click to place a copy where the view points." % [t["name"], tris, mb])
		if _asset_thumbs.has(tk):
			asset_list.set_item_icon(i, _asset_thumbs[tk])
			continue
		thumbs.request_scene(func(): return _piece_node(mg, t), func(tex):
			_asset_thumbs[tk] = tex
			if gen == _gen and i < asset_list.item_count and asset_list.get_item_metadata(i) == tk:
				asset_list.set_item_icon(i, tex))

func _list_imports(f: String) -> void:
	# the project's imported meshes (Mesh builder), one piece each
	var lib: Node = main.library
	var gen := _gen
	asset_info.text = "The project's imported meshes (Mesh builder, M). Double-click one to place a copy where the view points."
	for a in lib.imports():
		if f != "" and not (a["name"] as String).to_lower().contains(f):
			continue
		var i := asset_list.add_item(a["name"])
		var tk: String = a["key"] + "/0"
		asset_list.set_item_metadata(i, tk)
		asset_list.set_item_tooltip(i, "%s  (%d tris)\nDouble-click to place a copy where the view points." % [a["name"], int(a["info"].get("triangles", 0))])
		var key: String = a["key"]
		var make := func():
			var mg: Node = lib.map_geometry(key)
			if mg == null:
				return null
			var ts: Array = mg.default_trees()
			return _piece_node(mg, ts[0]) if ts.size() else null
		thumbs.request_scene(make, func(tex):
			if gen == _gen and i < asset_list.item_count and asset_list.get_item_metadata(i) == tk:
				asset_list.set_item_icon(i, tex))

func show_group(g: String) -> void:
	for k in asset_group.item_count:
		if asset_group.get_item_text(k) == g:
			asset_group.select(k)
	refresh()

func _on_asset_activated(i: int) -> void:
	# a map: browse its pieces
	var key: String = asset_list.get_item_metadata(i)
	if key.contains("/"):   # a piece of a library map: place a copy
		main.place_map_piece(key.get_slice("/", 0), int(key.get_slice("/", 1)))
		return
	var a: Dictionary = main.library.by_key.get(key, {})
	if a.has("map"):
		var g: String = main.library.group_of(a)
		for k in asset_group.item_count:
			if asset_group.get_item_text(k) == g:
				asset_group.select(k)
		asset_filter.text = ""
		refresh()

func _on_asset_selected(i: int) -> void:
	if not main.library.by_key.has(asset_list.get_item_metadata(i)):
		return   # a map piece: its tooltip says enough
	var a: Dictionary = main.library.by_key[asset_list.get_item_metadata(i)]
	var sz: Array = a.get("size", [])
	asset_info.text = "%s  [%s, %s]%s" % [a["name"], a["key"], main.library.group_of(a),
		("  %.1f x %.1f x %.1f m" % [sz[0], sz[1], sz[2]]) if sz.size() == 3 else ""]

func _mats(mesh: Mesh) -> Array:
	var out: Array = []
	for m in mesh.get_meta("mats", []):
		out.append(main.geometry.material(m))
	return out

func _fill_prefabs() -> void:
	# kept even while hidden: main.gd's prefab functions use this list
	prefab_list.clear()
	for pf in main.geometry.prefabs:
		var i := prefab_list.add_item("%s (%d)" % [pf["name"], pf["members"].size()])
		prefab_list.set_item_tooltip(i, "%s: %d parts. Double-click to place." % [pf["name"], pf["members"].size()])
		if not visible:
			continue
		var key := str(pf["members"]).hash()
		if _prefab_thumbs.has(key):
			prefab_list.set_item_icon(i, _prefab_thumbs[key])
		else:
			var mesh: ArrayMesh = main.geometry.build_mesh(main.geometry.prefab_tree(pf))
			var gen := _gen
			thumbs.request(mesh, _mats(mesh), func(tex):
				_prefab_thumbs[key] = tex
				if gen == _gen and i < prefab_list.item_count:
					prefab_list.set_item_icon(i, tex))

func _fill_level() -> void:
	level_list.clear()
	var f := filter.text.to_lower()
	var gen := _gen
	for p in main.geometry.pieces():
		var t: Dictionary = p.get_meta("tree")
		if f != "" and not (t["name"] as String).to_lower().contains(f):
			continue
		var i := level_list.add_item(t["name"])
		level_list.set_item_metadata(i, p)
		level_list.set_item_tooltip(i, main.geometry.label(p))
		var mi := p.get_child(0) as MeshInstance3D
		if mi.has_meta("thumb"):
			level_list.set_item_icon(i, mi.get_meta("thumb"))
		elif mi.mesh.get_surface_count():
			thumbs.request(mi.mesh, _mats(mi.mesh), func(tex):
				if is_instance_valid(mi):
					mi.set_meta("thumb", tex)
				if gen == _gen and i < level_list.item_count:
					level_list.set_item_icon(i, tex))
	sync_selection(main.selection)

func sync_selection(sel: Array) -> void:
	if not visible:
		return
	_updating = true
	level_list.deselect_all()
	for i in level_list.item_count:
		var p: Variant = level_list.get_item_metadata(i)
		if is_instance_valid(p) and sel.has(p):
			level_list.select(i, false)
			level_list.ensure_current_is_visible()
	_updating = false

func _on_level_selected() -> void:
	if _updating:
		return
	var out: Array = []
	for i in level_list.get_selected_items():
		var p: Variant = level_list.get_item_metadata(i)
		if is_instance_valid(p):
			out.append(p)
	main.select(out)
