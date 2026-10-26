extends Node
# The asset library (lp2-tools/lp2library.py): game models as GLB with index.json. Models load on first use
# and are copied from a cached instance after that.

var dir := ""
var assets: Array = []      # index.json entries
var by_key := {}
var _scenes := {}           # key -> loaded Node3D (kept out of the tree, duplicated for use)
var _maps := {}             # key -> geometry.gd node with a library map's preview data (LP1 maps, LP2 props; no pieces)
var project_dir := ""       # the open project: its imported meshes (lp2mesh.py) are maps "@project/imports/<name>"
const IMPORTS := "Imported meshes"

func load_index(lib_dir: String) -> int:
	dir = lib_dir
	assets = []
	by_key = {}
	_scenes = {}
	for g in _maps.values():
		g.queue_free()
	_maps = {}
	var f := FileAccess.open(dir.path_join("index.json"), FileAccess.READ)
	if f == null:
		return 0
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		assets = d.get("assets", [])
	for a in assets:
		by_key[a["key"]] = a
	var n := assets.size()
	load_imports(project_dir)
	return n

func load_imports(proj: String) -> void:
	# the project's imported meshes as assets {key imp_<name>, group IMPORTS, map "@project/imports/<name>"}
	project_dir = proj
	for a in assets.duplicate():
		if a.get("import", false):
			assets.erase(a)
			by_key.erase(a["key"])
			forget_map(a["key"])
	if proj == "":
		return
	var root := proj.path_join("imports")
	for n in DirAccess.get_directories_at(root) if DirAccess.dir_exists_absolute(root) else PackedStringArray():
		var f := FileAccess.open(root.path_join(n).path_join("import.json"), FileAccess.READ)
		if f == null or not FileAccess.file_exists(root.path_join(n).path_join(".preview/geo.json")):
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		if not (d is Dictionary):
			continue
		var a := {"key": "imp_" + n, "name": n, "source": "Project", "group": IMPORTS, "map": "@project/imports/" + n,
			"import": true, "info": d}
		assets.append(a)
		by_key[a["key"]] = a

func imports() -> Array:
	return assets.filter(func(a): return a.get("import", false))

func map_path(rel: String) -> String:
	# a library map's folder: LIB/<rel>, or the project's own (lp2pieces.map_folder)
	if rel.begins_with("@project/"):
		return project_dir.path_join(rel.trim_prefix("@project/"))
	return dir.path_join(rel)

func forget_map(key: String) -> void:
	# drop a loaded map (rebuilt on disk: the next use reloads it)
	if _maps.has(key):
		if _maps[key]:
			_maps[key].queue_free()
		_maps.erase(key)

func group_of(a: Dictionary) -> String:
	# "LP2 Vehicles", ...; each LP1 map is its own group ("LP1 map s900"), the LP2 props map is "LP2 objects"
	if a.get("import", false):
		return IMPORTS
	if a.has("map"):
		var k: String = a["key"]
		return "LP1 map %s" % k.trim_prefix("lp1_") if k.begins_with("lp1_") else a["name"]
	return "%s %s" % [a["source"], a["group"]]

func groups() -> Array:
	var out: Array = []
	for a in assets:
		var g := group_of(a)
		if not out.has(g):
			out.append(g)
	return out

func map_key(group: String) -> String:
	# a map's group -> its key ("" for model groups)
	for a in assets:
		if a.has("map") and group_of(a) == group:
			return a["key"]
	return ""

func map_geometry_rel(rel: String) -> Node:
	# by library path ("lp1/s900", "lp2/props")
	for a in assets:
		if a.get("map", "") == rel:
			return map_geometry(a["key"])
	return null

func map_geometry(key: String) -> Node:
	# an LP1 map's pieces source (geometry.gd: build_mesh / material / default_trees), loaded once
	if not _maps.has(key):
		var g := Node3D.new()
		g.set_script(load("res://geometry.gd"))
		add_child(g)
		if g.load_data(map_path(by_key[key]["map"]).path_join(".preview")) != "":
			g.queue_free()
			g = null
		_maps[key] = g
	return _maps[key]

func marker_key(model: String) -> String:
	# a layout object's model (vs50, wp0d, om7101) -> library key (vs_50, ...), or "" when there is none
	if model.length() < 3:
		return ""
	var key := model.substr(0, 2) + "_" + model.substr(2)
	if by_key.has(key):
		return key
	if key.begins_with("om_71") and by_key.has("om_7100"):   # data post variants
		return "om_7100"
	return ""

func instance(key: String) -> Node3D:
	if not by_key.has(key):
		return null
	if not _scenes.has(key):
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file(dir.path_join(by_key[key]["glb"]), st) != OK:
			_scenes[key] = null
		else:
			_scenes[key] = doc.generate_scene(st)
	var s: Node3D = _scenes[key]
	return s.duplicate() if s else null

static func meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(meshes(c))
	return out

static func box(n: Node3D) -> AABB:
	# the meshes' box in n's space
	var b := AABB()
	var first := true
	for mi in meshes(n):
		var t: Transform3D = n.global_transform.affine_inverse() * (mi as MeshInstance3D).global_transform if n.is_inside_tree() else _rel(n, mi)
		var mb: AABB = t * (mi as MeshInstance3D).get_aabb()
		b = mb if first else b.merge(mb)
		first = false
	return b

static func _rel(root: Node3D, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur and cur != root:
		t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

static func set_overlay(n: Node, m: Material) -> void:
	for mi in meshes(n):
		(mi as MeshInstance3D).material_overlay = m

func _exit_tree() -> void:
	for s in _scenes.values():
		if s:
			s.free()
	_scenes = {}
