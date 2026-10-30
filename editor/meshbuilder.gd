extends Window
# Floating mesh builder (lp2-tools/lp2mesh.py): OBJ / glTF files become the project's imported meshes, placed like
# library pieces; the project's materials (colour / normal / specular mask -> game textures) are shared between
# them, so a trim sheet loads once per map.

const COLLISION := ["mesh", "box", "none"]
const COLLISION_NAMES := ["Own mesh", "Box", "None"]
const SIZES := [256, 512, 1024, 2048]

var main: Node      # main.gd
var thumbs: Node    # thumbs.gd
var import_list: ItemList
var imp_info: Label
var imp_collision: OptionButton
var imp_scale: SpinBox
var imp_slots: GridContainer
var mat_list: ItemList
var mat_name: LineEdit
var mat_files := {}        # kind -> Button showing the file
var mat_colour: ColorPickerButton
var mat_size: OptionButton
var mat_grid: SpinBox
var mat_preview: TextureRect
var mat_info: Label
var file_dialog: FileDialog
var image_dialog: FileDialog
var _image_kind := ""
var _pending := {}          # kind -> chosen image path (applied on Apply)
var _thumbs := {}           # import key + build time -> texture
var new_folder := ""          # the browser's folder for the next import (My assets)
var _materials: Array = []  # [{name, bm, nm, mm, colour, size, users}]

func _init() -> void:
	title = "Mesh builder"
	size = Vector2i(560, 760)
	min_size = Vector2i(380, 420)
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
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bg.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	v.add_child(_heading("Imported meshes"))
	var note: Label = main._label("Experimental (work in progress). From Blender: File > Export > glTF 2.0 (.glb) or Wavefront (.obj), "
		+ "Y up, metres. A file is one mesh, its materials mapped below. Collision: an object named COL_<name> is the collision "
		+ "for <name> (e.g. COL_Girder, a few boxes, for Girder) and is never drawn; objects without one collide with their own "
		+ "triangles. Re-import after editing the file in Blender.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	note.modulate = Color(1, 0.85, 0.55)
	v.add_child(note)
	var row := HBoxContainer.new()
	main._button(row, "Import file...", func(): file_dialog.popup_centered_ratio(0.6)).tooltip_text = "An OBJ or glTF (.glb / .gltf) file: Y up, metres (Blender's default export)"
	main._button(row, "Place", place_selected).tooltip_text = "Place a copy where the view points (or double-click)"
	main._button(row, "Re-import", reimport_selected).tooltip_text = "Read the file again from where it was imported (placed copies update)"
	main._button(row, "Delete", delete_selected)
	v.add_child(row)
	import_list = ItemList.new()
	import_list.custom_minimum_size = Vector2(0, 170)
	import_list.max_columns = 0
	import_list.icon_mode = ItemList.ICON_MODE_TOP
	import_list.fixed_icon_size = Vector2i(thumbs.SIZE, thumbs.SIZE)
	import_list.fixed_column_width = thumbs.SIZE + 12
	import_list.same_column_width = true
	import_list.max_text_lines = 2
	import_list.item_selected.connect(func(_i): _show_import())
	import_list.item_activated.connect(func(_i): place_selected())
	v.add_child(import_list)
	imp_info = main._label("")
	imp_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(imp_info)
	var g := GridContainer.new()
	g.columns = 2
	g.add_child(main._label("Collision"))
	imp_collision = OptionButton.new()
	for n in COLLISION_NAMES:
		imp_collision.add_item(n)
	imp_collision.tooltip_text = "Own mesh: its triangles (or its COL_ objects' where the file has them). Box: its bounding box (cheap, for crates and blocks). None: walk and shoot through it"
	g.add_child(imp_collision)
	g.add_child(main._label("Scale"))
	imp_scale = main._spin(0.01, 100000.0, 0.01)
	imp_scale.value = 100.0
	imp_scale.tooltip_text = "Game centimetres per file unit (100: the file is in metres)"
	g.add_child(imp_scale)
	v.add_child(g)
	v.add_child(main._label("Materials (the file's material -> a project material):"))
	imp_slots = GridContainer.new()
	imp_slots.columns = 2
	v.add_child(imp_slots)
	main._button(v, "Apply to the mesh", apply_import).tooltip_text = "Rebuild it with these settings (placed copies update)"

	v.add_child(HSeparator.new())
	v.add_child(_heading("Materials"))
	var hint: Label = main._label("Shared by every mesh that uses them: a trim sheet's textures load once per map, however many meshes use it.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(hint)
	mat_list = ItemList.new()
	mat_list.custom_minimum_size = Vector2(0, 120)
	mat_list.max_columns = 0
	mat_list.icon_mode = ItemList.ICON_MODE_TOP
	mat_list.fixed_icon_size = Vector2i(64, 64)
	mat_list.fixed_column_width = 84
	mat_list.same_column_width = true
	mat_list.max_text_lines = 2
	mat_list.item_selected.connect(func(_i): _show_material())
	v.add_child(mat_list)
	var mrow := HBoxContainer.new()
	var mg := GridContainer.new()
	mg.columns = 3
	mg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mg.add_child(main._label("Name"))
	mat_name = LineEdit.new()
	mat_name.placeholder_text = "trim_metal"
	mat_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mg.add_child(mat_name)
	mg.add_child(Control.new())
	for kind in ["bm", "nm", "mm"]:
		mg.add_child(main._label({"bm": "Colour map", "nm": "Normal map", "mm": "Specular mask"}[kind]))
		var b := Button.new()
		b.text = "(none)"
		b.clip_text = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = {"bm": "The colour (alpha: see-through parts)", "nm": "Tangent-space normal map, OpenGL style (Y up, Blender's)",
			"mm": "Greyscale: white = full shine, black = matte"}[kind]
		b.pressed.connect(func():
			_image_kind = kind
			image_dialog.popup_centered_ratio(0.6))
		mg.add_child(b)
		mat_files[kind] = b
		main._button(mg, "Clear", func():
			_pending[kind] = ""
			b.text = "(none)"
			_preview())
	mg.add_child(main._label("Colour"))
	mat_colour = ColorPickerButton.new()
	mat_colour.color = Color(0.8, 0.8, 0.8)
	mat_colour.tooltip_text = "The colour when there is no colour map"
	mat_colour.color_changed.connect(func(_c): _preview())
	mg.add_child(mat_colour)
	mg.add_child(Control.new())
	mg.add_child(main._label("Largest side"))
	mat_size = OptionButton.new()
	for s in SIZES:
		mat_size.add_item("%d px" % s)
	mat_size.select(SIZES.size() - 1)
	mat_size.tooltip_text = "Bigger images are scaled down to this (powers of two). Memory: 1024 px = about 1.3 MB for its three maps"
	mg.add_child(mat_size)
	mg.add_child(Control.new())
	mg.add_child(main._label("Grid UVs (m)"))
	mat_grid = main._spin(0.0, 64.0, 0.25)
	mat_grid.tooltip_text = "Metres per texture tile, projected onto each face from the nearest axis (ignores the mesh's own UVs). 0 = the mesh's UVs"
	mg.add_child(mat_grid)
	mrow.add_child(mg)
	mat_preview = TextureRect.new()
	mat_preview.custom_minimum_size = Vector2(thumbs.SIZE, thumbs.SIZE)
	mat_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mat_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mrow.add_child(mat_preview)
	v.add_child(mrow)
	var brow := HBoxContainer.new()
	main._button(brow, "New", new_material).tooltip_text = "Clear the fields for a new material"
	main._button(brow, "Apply", apply_material).tooltip_text = "Build the game textures (the meshes using it are rebuilt)"
	main._button(brow, "Blockout", make_blockout).tooltip_text = "A dev-style grid colour map in the material's colour (orange for a new one): 1 m tiles, white lines every 1 m / 25 cm / 12.5 cm, Grid UVs 1 m"
	v.add_child(brow)
	mat_info = main._label("")
	mat_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(mat_info)

	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.glb, *.gltf, *.obj ; 3D models"])
	file_dialog.use_native_dialog = true
	file_dialog.file_selected.connect(import_file)
	add_child(file_dialog)
	image_dialog = FileDialog.new()
	image_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	image_dialog.access = FileDialog.ACCESS_FILESYSTEM
	image_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.tga, *.bmp, *.webp ; Images"])
	image_dialog.use_native_dialog = true
	image_dialog.file_selected.connect(func(p):
		_pending[_image_kind] = p
		mat_files[_image_kind].text = p.get_file()
		_preview())
	add_child(image_dialog)
	visibility_changed.connect(func(): if visible: refresh())

func _heading(t: String) -> Label:
	var l: Label = main._label(t)
	l.add_theme_font_size_override("font_size", 16)
	return l

# ---------------------------------------------------------------- lists

func refresh() -> void:
	_fill_imports()
	_fill_materials()

func _proj() -> String:
	return main.project_dir

func _fill_imports() -> void:
	var sel := _selected_key()
	import_list.clear()
	if _proj() == "":
		imp_info.text = "Open a project first."
		return
	for a in main.library.imports():
		var i := import_list.add_item(a["name"])
		import_list.set_item_metadata(i, a["key"])
		var info: Dictionary = a["info"]
		import_list.set_item_tooltip(i, "%s: %d triangles. Double-click to place." % [a["name"], int(info.get("triangles", 0))])
		if a["key"] == sel:
			import_list.select(i)
		var tk := "%s@%d" % [a["key"], FileAccess.get_modified_time(_proj().path_join("imports").path_join(a["name"]).path_join("import.json"))]
		if _thumbs.has(tk):
			import_list.set_item_icon(i, _thumbs[tk])
			continue
		var key: String = a["key"]
		var make := func():
			var mg: Node = main.library.map_geometry(key)
			if mg == null:
				return null
			var ts: Array = mg.default_trees()
			return main.browser._piece_node(mg, ts[0]) if ts.size() else null
		thumbs.request_scene(make, func(tex):
			_thumbs[tk] = tex
			if i < import_list.item_count and import_list.get_item_metadata(i) == key:
				import_list.set_item_icon(i, tex))
	if import_list.item_count == 0:
		imp_info.text = "No imported meshes yet: Import file... takes an OBJ or glTF (Y up, metres)."
	_show_import()

func _fill_materials() -> void:
	var sel := mat_name.text
	_materials = []
	mat_list.clear()
	var root := _proj().path_join("materials")
	if _proj() == "" or not DirAccess.dir_exists_absolute(root):
		return
	var users := {}
	for a in main.library.imports():
		for s in (a["info"] as Dictionary).get("slots", {}).values():
			users[s] = users.get(s, []) + [a["name"]]
	for n in DirAccess.get_directories_at(root):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(root.path_join(n).path_join("material.json")))
		if not (d is Dictionary):
			continue
		d["name"] = n
		d["users"] = users.get(n, [])
		_materials.append(d)
		var i := mat_list.add_item(n)
		mat_list.set_item_metadata(i, _materials.size() - 1)
		mat_list.set_item_tooltip(i, "%s: used by %s" % [n, ", ".join(d["users"]) if d["users"].size() else "nothing yet"])
		mat_list.set_item_icon(i, _swatch(d))
		if n == sel:
			mat_list.select(i)

func _swatch(d: Dictionary) -> Texture2D:
	var img: Image = null
	if d.get("bm", "") != "":
		img = Image.load_from_file(_proj().path_join("materials").path_join(d["name"]).path_join(d["bm"]))
	if img == null or img.is_empty():
		var c: Array = d.get("colour", [0.8, 0.8, 0.8])
		img = Image.create(8, 8, false, Image.FORMAT_RGB8)
		img.fill(Color(c[0], c[1], c[2]))
	img.resize(64, 64)
	return ImageTexture.create_from_image(img)

func _selected_key() -> String:
	var s := import_list.get_selected_items()
	return import_list.get_item_metadata(s[0]) if s.size() else ""

func _selected_import() -> Dictionary:
	var k := _selected_key()
	return main.library.by_key.get(k, {})

# ---------------------------------------------------------------- imports

func _show_import() -> void:
	for c in imp_slots.get_children():
		imp_slots.remove_child(c)
		c.queue_free()
	var a := _selected_import()
	if a.is_empty():
		if import_list.item_count:
			imp_info.text = "Select a mesh to see its settings."
		return
	var info: Dictionary = a["info"]
	var sz: Array = info.get("size", [0, 0, 0])
	var placed: int = main.geometry.placed_from(a["map"]).size()
	imp_info.text = "%s (from %s): %d triangles, %.2f x %.2f x %.2f m, placed %d times." % [a["name"],
		info.get("from", info.get("source", "?")), int(info.get("triangles", 0)), sz[0], sz[1], sz[2], placed]
	imp_collision.select(maxi(0, COLLISION.find(info.get("collision", "mesh"))))
	imp_scale.value = float(info.get("scale", 100.0))
	var slots: Dictionary = info.get("slots", {})
	for s in slots:
		imp_slots.add_child(main._label(s if s != "" else "(no material)"))
		var o := OptionButton.new()
		o.set_meta("slot", s)
		for m in _materials:
			o.add_item(m["name"])
			if m["name"] == slots[s]:
				o.select(o.item_count - 1)
		imp_slots.add_child(o)

func _tool(args: Array, then: Callable) -> void:
	main.run_tool("lp2mesh.py", args, func():
		main.library.load_imports(_proj())
		then.call()
		refresh()
		main.browser.refresh_assets())

func import_file(path: String) -> void:
	if _proj() == "":
		return
	var name := path.get_file().get_basename().to_lower()
	var n := name
	var k := 2
	while main.library.by_key.has("imp_" + _slug(n)):
		n = "%s_%d" % [name, k]
		k += 1
	main.set_status("Importing %s..." % path.get_file())
	_tool(["import", "--game", main.game, _proj(), path, "--name", n,
		"--collision", COLLISION[imp_collision.selected] if import_list.item_count else "mesh"], func():
		main.log_line("Imported %s as %s. Double-click it (or Place) to put a copy in the level." % [path.get_file(), _slug(n)])
		if new_folder != "":
			main.browser._browser_data()["meshes"]["imp_" + _slug(n)] = new_folder
			new_folder = ""
			main.browser.refresh_prefabs()
		for i in import_list.item_count:
			if import_list.get_item_metadata(i) == "imp_" + _slug(n):
				import_list.select(i))

func _slug(s: String) -> String:
	# lp2mesh.py slug(): lower case, a-z 0-9 _, 32 characters
	var out := ""
	for ch in s.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" else "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.strip_edges().trim_prefix("_").trim_suffix("_")
	return (out if out != "" else "mesh").substr(0, 32)

func apply_import() -> void:
	var a := _selected_import()
	if a.is_empty():
		return
	var args := ["rebuild", "--game", main.game, _proj(), a["name"], "--collision", COLLISION[imp_collision.selected],
		"--scale", str(imp_scale.value)]
	for o in imp_slots.get_children():
		if o is OptionButton and o.selected >= 0:
			args += ["--mat", "%s=%s" % [o.get_meta("slot"), o.get_item_text(o.selected)]]
	_rebuild(a, args)

func reimport_selected() -> void:
	var a := _selected_import()
	if a.is_empty():
		return
	var from: String = (a["info"] as Dictionary).get("from", "")
	if from == "" or not FileAccess.file_exists(from):
		main.log_line("%s's file is gone (%s): use Import file... with its new place." % [a["name"], from])
		return
	var args := ["import", "--replace", "--game", main.game, _proj(), from, "--name", a["name"],
		"--collision", COLLISION[imp_collision.selected], "--scale", str(imp_scale.value)]
	for s in (a["info"] as Dictionary).get("slots", {}):
		args += ["--mat", "%s=%s" % [s, a["info"]["slots"][s]]]
	_rebuild(a, args)

func _rebuild(a: Dictionary, args: Array) -> void:
	var rel: String = a["map"]
	main.set_status("Rebuilding %s..." % a["name"])
	_tool(args, func():
		main.geometry.refresh_import(rel)
		main._stats_later()
		main.log_line("Rebuilt %s; its placed copies follow." % a["name"]))

func place_selected() -> void:
	var k := _selected_key()
	if k != "":
		main.place_map_piece(k, 0)

func select_key(key: String) -> void:
	for i in import_list.item_count:
		if import_list.get_item_metadata(i) == key:
			import_list.select(i)
			_show_import()

func delete_key(key: String) -> void:
	select_key(key)
	if _selected_key() == key:
		delete_selected()

func delete_selected() -> void:
	var a := _selected_import()
	if a.is_empty():
		return
	if main.geometry.placed_from(a["map"]).size():
		main.log_line("%s is placed in the level: delete its copies first." % a["name"])
		return
	_tool(["delete", _proj(), a["name"]], func(): main.log_line("Deleted %s." % a["name"]))

# ---------------------------------------------------------------- materials

func _show_material() -> void:
	var s := mat_list.get_selected_items()
	if s.is_empty():
		return
	var d: Dictionary = _materials[mat_list.get_item_metadata(s[0])]
	mat_name.text = d["name"]
	_pending = {}
	for kind in mat_files:
		mat_files[kind].text = d.get(kind, "(none)") if d.get(kind, "") != "" else "(none)"
	var c: Array = d.get("colour", [0.8, 0.8, 0.8])
	mat_colour.color = Color(c[0], c[1], c[2])
	mat_size.select(maxi(0, SIZES.find(int(d.get("size", 2048)))))
	mat_grid.value = float(d.get("grid", 0.0))
	mat_info.text = "Used by %s." % (", ".join(d["users"]) if d["users"].size() else "no mesh yet")
	_preview()

func new_material() -> void:
	mat_list.deselect_all()
	mat_name.text = ""
	_pending = {}
	for kind in mat_files:
		mat_files[kind].text = "(none)"
	mat_colour.color = Color(0.8, 0.8, 0.8)
	mat_grid.value = 0.0
	mat_info.text = "Name it, pick its maps, then Apply. Then pick it for a mesh's material above."
	_preview()

func _image_path(kind: String) -> String:
	# the chosen (not yet applied) file, else the material's own
	if _pending.has(kind):
		return _pending[kind]
	var b: String = mat_files[kind].text
	if b == "(none)" or mat_name.text == "":
		return ""
	return _proj().path_join("materials").path_join(_slug_mat(mat_name.text)).path_join(b)

func _slug_mat(s: String) -> String:
	return _slug(s).substr(0, 24)

func _preview() -> void:
	# a lit sphere with the colour and normal maps (the specular mask as Godot's specular)
	var m := StandardMaterial3D.new()
	m.albedo_color = mat_colour.color
	var bm := _load_tex(_image_path("bm"))
	if bm:
		m.albedo_texture = bm
		m.albedo_color = Color.WHITE
	var nm := _load_tex(_image_path("nm"))
	if nm:
		m.normal_enabled = true
		m.normal_texture = nm
	m.roughness = 0.6
	var mm := _load_tex(_image_path("mm"))
	if mm:
		m.metallic_specular = 1.0
		m.roughness_texture = mm
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	thumbs.request(sphere, [m], func(tex): mat_preview.texture = tex)

func _load_tex(p: String) -> Texture2D:
	if p == "" or not FileAccess.file_exists(p):
		return null
	var img := Image.load_from_file(p)
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func make_blockout() -> void:
	# a new material (no name yet) becomes "blockout" in orange; an existing one keeps its name and colour
	if mat_name.text.strip_edges() == "":
		mat_name.text = "blockout"
		mat_colour.color = Color(0.93, 0.47, 0.16)
	if mat_grid.value <= 0.0:
		mat_grid.value = 1.0
	_pending.erase("bm")
	apply_material(["--blockout"])

func apply_material(extra: Array = []) -> void:
	if _proj() == "":
		return
	var n := _slug_mat(mat_name.text)
	if mat_name.text.strip_edges() == "":
		mat_info.text = "Give it a name first."
		return
	var c := mat_colour.color
	var args := ["material", "--game", main.game, _proj(), n, "--colour", "%.4f,%.4f,%.4f" % [c.r, c.g, c.b],
		"--size", str(SIZES[mat_size.selected]), "--grid", str(mat_grid.value)] + extra
	for kind in _pending:
		args += ["--" + kind, _pending[kind]]
	var users: Array = []
	for a in main.library.imports():
		if (a["info"] as Dictionary).get("slots", {}).values().has(n):
			users.append(a["map"])
	main.set_status("Building material %s..." % n)
	mat_name.text = n
	_tool(args, func():
		_pending = {}
		for rel in users:
			main.geometry.refresh_import(rel)
		main.log_line("Material %s built%s." % [n, (" (%d meshes rebuilt)" % users.size()) if users.size() else ""]))
