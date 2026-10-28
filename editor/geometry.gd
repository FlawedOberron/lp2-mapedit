extends Node3D
# Level geometry: the stage split into pieces (lp2-tools/lp2pieces.py, preview data from lp2preview.py).
#
# Atoms (connected bits of the stage) are what the project's geometry.json addresses. A piece is a node of the
# grouping tree: {"name", "members": [member]} or {"name", "children": [node]}; a member is one atom's geometry
# {"atom": int, "copy": bool, "L": Transform3D (piece space)}. A piece is a Node3D (its transform G) holding one
# mesh of its members' geometry and a body for picking, so a member's world transform is G * L.
# geometry.json (cm): xf {atom: 3 x 4 matrix} of moved originals, hidden [atoms], copies [{atom, m}], tree.
# A member with "map": "lp1/s900" is a copy of another map's atom (the asset library's preview of that map).

const CM := 0.01
const LAYER_STAGE := 1

var data := {}          # geo.json
var pos: PackedVector3Array
var nrm: PackedVector3Array
var uv: PackedVector2Array
var col: PackedColorArray
var idx: PackedInt32Array
var bake_ch: Array = []   # lp2bake.py's light components: 4 PackedFloat32Array (CUSTOM0-3, RGBA per vertex), or empty
var atom_blocks := {}   # atom -> [block, ...]; block = [atom, mat, v0, vn, i0, in]
var atom_tris := PackedInt32Array()
var atom_verts := PackedInt32Array()
var materials_lit: Array = []
var materials_baked: Array = []
var hidden := {}        # original atoms left out
var walls_hidden := {}  # collision-only walls left out (lp2pieces.collision_owners ids: LP1's invisible boundaries)
var prefabs: Array = []
var baked := true
var bake_scale := 2.0
var highlight: StandardMaterial3D
var library: Node       # library.gd: members with "map" (pieces of other maps) take their data from there
var _uid := 0

func load_preview(prev: String, geometry_path: String) -> String:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var err := load_data(prev)
	if err != "":
		return err
	_add_pieces(geometry_path)
	return ""

func load_data(prev: String) -> String:
	# the preview's arrays and materials, no pieces (the browser loads other maps this way)
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(prev.path_join("geo.json")))
	if not (j is Dictionary):
		return "no geometry preview (geo.json)"
	data = j
	var bin := FileAccess.get_file_as_bytes(prev.path_join("geo.bin"))
	var a: Dictionary = data["arrays"]
	pos = _slice(bin, a["pos"]).to_vector3_array()
	nrm = _slice(bin, a["nrm"]).to_vector3_array()
	uv = _slice(bin, a["uv"]).to_vector2_array()
	col = _slice(bin, a["col"]).to_color_array()
	idx = _slice(bin, a["idx"]).to_int32_array()
	load_bake(prev)
	var n := int(data["stats"]["atoms"])
	atom_tris.resize(n)
	atom_verts.resize(n)
	atom_tris.fill(0)
	atom_verts.fill(0)
	atom_blocks = {}
	for b in data["blocks"]:
		var at := int(b[0])
		if not atom_blocks.has(at):
			atom_blocks[at] = []
		atom_blocks[at].append([at, int(b[1]), int(b[2]), int(b[3]), int(b[4]), int(b[5])])
		atom_tris[at] += int(b[5]) / 3
		atom_verts[at] += int(b[3])
	_make_materials(prev)
	highlight = StandardMaterial3D.new()
	highlight.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	highlight.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	highlight.albedo_color = Color(1.0, 0.7, 0.15, 0.3)
	highlight.no_depth_test = false
	return ""

func default_trees() -> Array:
	# the preview's own grouping, as trees (members in world space)
	var out: Array = []
	var used := {}
	for node in data["tree"]:
		var t := _load_node(node, {}, [], used)
		if not t.is_empty():
			out.append(t)
	return out

func _add_pieces(geometry_path: String) -> void:
	var n := int(data["stats"]["atoms"])
	# the project's edits, else the default pieces
	var g: Variant = null
	if geometry_path != "" and FileAccess.file_exists(geometry_path):
		g = JSON.parse_string(FileAccess.get_file_as_string(geometry_path))
	if not (g is Dictionary):
		g = {}
	hidden = {}
	for at in g.get("hidden", []):
		hidden[int(at)] = true
	walls_hidden = {}
	for k in g.get("walls_hidden", []):
		walls_hidden[int(k)] = true
	prefabs = g.get("prefabs", [])
	for pf in prefabs:
		for m in pf["members"]:
			m["atom"] = int(m["atom"])
	var xf := {}
	for k in g.get("xf", {}).keys():
		xf[int(k)] = _from_cm(g["xf"][k])
	var copies: Array = g.get("copies", [])
	var tree: Array = g.get("tree", data["tree"])
	var used := {}
	for node in tree:
		var t := _load_node(node, xf, copies, used)
		if not t.is_empty():
			add_piece(t, Transform3D.IDENTITY, true)
	var loose: Array = []  # atoms in no node (the stage changed): one piece
	for at in n:
		if not used.has(at) and not hidden.has(at):
			loose.append({"atom": at, "copy": false, "L": xf.get(at, Transform3D.IDENTITY)})
	if loose.size():
		add_piece({"name": "unsorted", "members": loose}, Transform3D.IDENTITY, true)

func load_bake(prev: String) -> void:
	bake_ch = []
	var f := prev.path_join("bake.bin")
	if not FileAccess.file_exists(f):
		return
	var b := FileAccess.get_file_as_bytes(f)
	var n := pos.size() * 16
	if b.size() != n * 4:
		return   # from an older preview
	for i in 4:
		bake_ch.append(b.slice(i * n, (i + 1) * n).to_float32_array())

func _slice(bin: PackedByteArray, r: Array) -> PackedByteArray:
	return bin.slice(int(r[0]), int(r[0]) + int(r[1]))

func _load_node(node: Dictionary, xf: Dictionary, copies: Array, used: Dictionary) -> Dictionary:
	if node.has("children"):
		var ch: Array = []
		for c in node["children"]:
			var t := _load_node(c, xf, copies, used)
			if not t.is_empty():
				ch.append(t)
		if ch.is_empty():
			return {}
		var g: Dictionary = {"name": node["name"], "children": ch} if ch.size() > 1 else ch[0].merged({"name": node["name"]}, true)
		if node.get("mesh_collision", false):
			g["mesh_collision"] = true
		return g
	var members: Array = []
	for at in node.get("atoms", []):
		at = int(at)
		used[at] = true
		if not hidden.has(at):
			members.append({"atom": at, "copy": false, "L": xf.get(at, Transform3D.IDENTITY)})
	for k in node.get("copies", []):
		if int(k) < copies.size():
			var c: Dictionary = copies[int(k)]
			var mm := {"atom": int(c["atom"]), "copy": true, "L": _from_cm(c["m"])}
			if c.has("map"):
				mm["map"] = c["map"]
			members.append(mm)
	if members.is_empty():
		return {}
	var out := {"name": node["name"], "members": members}
	if node.get("mesh_collision", false):
		out["mesh_collision"] = true
	return out

func _from_cm(m: Array) -> Transform3D:
	# 3 x 4 row-major, cm -> metres
	var b := Basis(Vector3(m[0], m[4], m[8]), Vector3(m[1], m[5], m[9]), Vector3(m[2], m[6], m[10]))
	return Transform3D(b, Vector3(m[3], m[7], m[11]) * CM)

func _to_cm(t: Transform3D) -> Array:
	var b := t.basis
	var o := t.origin / CM
	return [b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z]

func _make_materials(prev: String) -> void:
	materials_lit = []
	materials_baked = []
	for m in data["materials"]:
		var tex: Texture2D = null
		if m["tex"] != null:
			var img := Image.load_from_file(prev.path_join(m["tex"]))
			if img:
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
		var lit := ShaderMaterial.new()
		lit.shader = preload("res://lit.gdshader")
		lit.set_shader_parameter("bake_scale", bake_scale)
		if tex:
			lit.set_shader_parameter("albedo", tex)
			lit.set_shader_parameter("has_texture", true)
		materials_lit.append(lit)
		var sm := ShaderMaterial.new()
		sm.shader = preload("res://baked.gdshader")
		sm.set_shader_parameter("bake_scale", bake_scale)
		if tex:
			sm.set_shader_parameter("albedo", tex)
			sm.set_shader_parameter("has_texture", true)
		materials_baked.append(sm)

func set_bake_params(p: Dictionary) -> void:
	# the live bake settings (lighting.gd) on this map's baked materials
	for m in materials_baked:
		for k in p:
			m.set_shader_parameter(k, p[k])

func set_baked(on: bool) -> void:
	baked = on
	for p in pieces():
		_apply_materials(p)

# ---------------------------------------------------------------- pieces

func pieces() -> Array:
	return get_children()

func members_of(t: Dictionary) -> Array:
	if t.has("members"):
		return t["members"]
	var out: Array = []
	for c in t["children"]:
		out.append_array(members_of(c))
	return out

func world_box(p: Node3D) -> AABB:
	return p.transform * local_box(p.get_meta("tree"))

func local_box(t: Dictionary) -> AABB:
	var box := AABB()
	var first := true
	for m in members_of(t):
		var g: Node = src(m)
		if g == null:
			continue
		var ab: Array = g.data["atom_box"]
		var k: int = m["atom"] * 6
		var b := AABB(Vector3(ab[k], ab[k + 1], ab[k + 2]), Vector3(ab[k + 3] - ab[k], ab[k + 4] - ab[k + 1], ab[k + 5] - ab[k + 2]))
		b = (m["L"] as Transform3D) * b
		box = b if first else box.merge(b)
		first = false
	return box

func _rebase(t: Dictionary, by: Transform3D) -> void:
	# members' L <- by * L
	for m in members_of(t):
		m["L"] = by * (m["L"] as Transform3D)

func add_piece(t: Dictionary, g: Transform3D, recentre: bool) -> Node3D:
	# a piece node for tree t (members in g's space); recentre puts its origin at the bottom centre of its box
	if recentre:
		var box := g * local_box(t)
		var pivot := Vector3(box.get_center().x, box.position.y, box.get_center().z)
		var ng := Transform3D(Basis.IDENTITY, pivot)
		_rebase(t, ng.affine_inverse() * g)
		g = ng
	var p := Node3D.new()
	_uid += 1
	p.name = "piece%d" % _uid
	p.set_meta("tree", t)
	p.set_meta("uid", _uid)
	p.transform = g
	add_child(p)
	rebuild(p)
	return p

func build_mesh(t: Dictionary) -> ArrayMesh:
	# tree t's members as one mesh in its space, a surface per material (meta "mats": surface -> material)
	var by_mat := {}  # mat (int, or "map|mat" for other maps') -> [pos, nrm, uv, col, idx]
	for m in members_of(t):
		var g: Node = src(m)
		if g == null:
			continue
		var L: Transform3D = m["L"]
		var nb := Transform3D(L.basis.inverse().transposed(), Vector3.ZERO)
		var flip := L.basis.determinant() < 0
		for b in g.atom_blocks.get(m["atom"], []):
			var mat: Variant = b[1] if g == self else "%s|%d" % [m["map"], b[1]]
			if not by_mat.has(mat):
				by_mat[mat] = [PackedVector3Array(), PackedVector3Array(), PackedVector2Array(), PackedColorArray(), PackedInt32Array(),
					PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
			var acc: Array = by_mat[mat]
			var base: int = (acc[0] as PackedVector3Array).size()
			var v0: int = b[2]
			var vn: int = b[3]
			acc[0].append_array(L * g.pos.slice(v0, v0 + vn))
			acc[1].append_array(nb * g.nrm.slice(v0, v0 + vn))
			acc[2].append_array(g.uv.slice(v0, v0 + vn))
			acc[3].append_array(g.col.slice(v0, v0 + vn))
			for c in 4:   # the bake's channels (zeros, i.e. not baked: the plain colour)
				if g.bake_ch.is_empty():
					var z := PackedFloat32Array()
					z.resize(vn * 4)
					acc[5 + c].append_array(z)
				else:
					acc[5 + c].append_array(g.bake_ch[c].slice(v0 * 4, (v0 + vn) * 4))
			var ii: PackedInt32Array = g.idx.slice(b[4], b[4] + b[5])
			if flip:
				for i in range(0, ii.size(), 3):
					var s := ii[i]
					ii[i] = ii[i + 1]
					ii[i + 1] = s
			for i in ii.size():
				ii[i] += base
			acc[4].append_array(ii)
	var mesh := ArrayMesh.new()
	var mats: Array = []
	for mat in by_mat.keys():
		var acc: Array = by_mat[mat]
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = acc[0]
		arr[Mesh.ARRAY_NORMAL] = acc[1]
		arr[Mesh.ARRAY_TEX_UV] = acc[2]
		arr[Mesh.ARRAY_COLOR] = acc[3]
		arr[Mesh.ARRAY_INDEX] = acc[4]
		var flags := 0
		if not bake_ch.is_empty():
			for c in 4:
				arr[Mesh.ARRAY_CUSTOM0 + c] = acc[5 + c]
			flags = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
				| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, flags)
		mats.append(mat)
	mesh.set_meta("mats", mats)
	var tris := 0
	for acc in by_mat.values():
		tris += (acc[4] as PackedInt32Array).size() / 3
	mesh.set_meta("tris", tris)
	return mesh

func material(mat: Variant) -> Material:
	if mat is String:   # another map's
		var g: Node = library.map_geometry_rel(mat.get_slice("|", 0)) if library else null
		if g == null:
			return null
		g.baked = baked
		return g.material(int(mat.get_slice("|", 1)))
	return materials_baked[mat] if baked else materials_lit[mat]

func src(m: Dictionary) -> Node:
	# where a member's atom data lives: this map, or another map in the library
	if not m.has("map"):
		return self
	return library.map_geometry_rel(m["map"]) if library else null

func triangles_in_view(cam: Camera3D) -> Vector2i:
	# (stage triangles in pieces the camera sees, all of them): the Wireframe toggle's count
	var planes := cam.get_frustum()
	var seen := 0
	var total := 0
	for p in pieces():
		var mi := p.get_child(0) as MeshInstance3D if p.get_child_count() else null
		if mi == null or mi.mesh == null:
			continue
		var t := int(mi.mesh.get_meta("tris", 0))
		total += t
		if not p.visible:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		var c := box.get_center()
		var r := box.size.length() / 2
		var inside := true
		for pl: Plane in planes:
			if pl.distance_to(c) > r:
				inside = false
				break
		if inside:
			seen += t
	return Vector2i(seen, total)

func rebuild(p: Node3D) -> void:
	for c in p.get_children():
		p.remove_child(c)
		c.queue_free()
	var mesh := build_mesh(p.get_meta("tree"))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_meta("mats", mesh.get_meta("mats"))
	p.add_child(mi)
	_apply_materials(p)
	if mesh.get_surface_count():
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_STAGE
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.shape = mesh.create_trimesh_shape()
		body.add_child(cs)
		p.add_child(body)

func _apply_materials(p: Node3D) -> void:
	var mi := p.get_child(0) as MeshInstance3D
	var mats: Array = mi.get_meta("mats")
	for s in mats.size():
		mi.set_surface_override_material(s, material(mats[s]))

func set_selected(p: Node3D, on: bool) -> void:
	var mi := p.get_child(0) as MeshInstance3D
	mi.material_overlay = highlight if on else null
	for n in ["outline", "outline_xray"]:
		var old := p.get_node_or_null(n)
		if old:
			p.remove_child(old)
			old.queue_free()
	if not on:
		return
	# the piece's feature edges: bright where visible, faint through walls
	if not mi.has_meta("wire"):
		mi.set_meta("wire", wire_mesh(mi.mesh))
	for xray in [false, true]:
		var w := MeshInstance3D.new()
		w.name = "outline_xray" if xray else "outline"
		w.mesh = mi.get_meta("wire")
		w.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.65, 0.1, 0.3 if xray else 1.0)
		if xray:
			m.no_depth_test = true
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.render_priority = 5
		w.material_override = m
		p.add_child(w)

const WIRE_ANGLE := 0.906  # cos 25 degrees: edges between faces bent more than this are drawn, flat ones not

func wire_mesh(mesh: Mesh) -> ArrayMesh:
	# lines along the mesh's feature edges (creases and open borders), welded at 1 mm so material seams vanish
	var ids := {}       # Vector3i -> welded vertex
	var wpos := PackedVector3Array()
	var edges := {}     # Vector2i(lo, hi) -> face normal of its first face, or null once drawn / flat
	var lines := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var ii: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var wid := PackedInt32Array()
		wid.resize(vs.size())
		for v in vs.size():
			var k := Vector3i((vs[v] * 1000.0).round())
			var id: int = ids.get(k, -1)
			if id < 0:
				id = wpos.size()
				ids[k] = id
				wpos.append(vs[v])
			wid[v] = id
		for t in range(0, ii.size(), 3):
			var a := wid[ii[t]]
			var b := wid[ii[t + 1]]
			var c := wid[ii[t + 2]]
			var n := (wpos[b] - wpos[a]).cross(wpos[c] - wpos[a])
			if n.length_squared() < 1e-12:
				continue
			n = n.normalized()
			for e in [Vector2i(mini(a, b), maxi(a, b)), Vector2i(mini(b, c), maxi(b, c)), Vector2i(mini(c, a), maxi(c, a))]:
				if not edges.has(e):
					edges[e] = n
				else:
					var f: Variant = edges[e]
					if f != null and absf((f as Vector3).dot(n)) > WIRE_ANGLE:
						edges[e] = null   # flat (either facing): not drawn
					elif f != null:
						lines.append(wpos[e.x])
						lines.append(wpos[e.y])
						edges[e] = null
	for e in edges:
		if edges[e] != null:      # one face only: an open border
			lines.append(wpos[e.x])
			lines.append(wpos[e.y])
	var out := ArrayMesh.new()
	if lines.size():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = lines
		out.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	return out

func piece_of(collider: Node) -> Node3D:
	var n := collider
	while n and n.get_parent() != self:
		n = n.get_parent()
	return n as Node3D

func label(p: Node3D) -> String:
	var t: Dictionary = p.get_meta("tree")
	var ms := members_of(t)
	var tris := 0
	var copies := 0
	for m in ms:
		var g: Node = src(m)
		tris += g.atom_tris[m["atom"]] if g else 0
		if m["copy"]:
			copies += 1
	var parts := ("%d parts, " % t["children"].size()) if t.has("children") else ""
	return "%s  (%s%d tris%s)" % [t["name"], parts, tris, (", %d copied" % copies) if copies else ""]

# ---------------------------------------------------------------- edits

func _bake_world(p: Node3D) -> Dictionary:
	# the piece's tree with members' L made world transforms
	var t: Dictionary = p.get_meta("tree")
	_rebase(t, p.transform)
	return t

func group(ps: Array, name: String) -> Node3D:
	var ch: Array = []
	for p in ps:
		ch.append(_bake_world(p))
		remove_child(p)
		p.queue_free()
	return add_piece({"name": name, "children": ch}, Transform3D.IDENTITY, true)

func ungroup(p: Node3D) -> Array:
	var t := _bake_world(p)
	remove_child(p)
	p.queue_free()
	var out: Array = []
	if t.has("children"):
		for c in t["children"]:
			if t.get("mesh_collision", false):
				c["mesh_collision"] = true   # the group's setting stays with its parts
			out.append(add_piece(c, Transform3D.IDENTITY, true))
	else:
		var i := 0
		for m in t["members"]:
			i += 1
			var part := {"name": "%s.%d" % [t["name"], i], "members": [m]}
			if t.get("mesh_collision", false):
				part["mesh_collision"] = true
			out.append(add_piece(part, Transform3D.IDENTITY, true))
	return out

func duplicate_piece(p: Node3D, offset: Vector3) -> Node3D:
	var t: Dictionary = _dup_tree(p.get_meta("tree"))
	for m in members_of(t):
		m["copy"] = true
	t["name"] = t["name"] + " copy"
	return add_piece(t, Transform3D(p.transform.basis, p.transform.origin + offset), false)

func _dup_tree(t: Dictionary) -> Dictionary:
	if t.has("children"):
		return {"name": t["name"], "children": t["children"].map(func(c): return _dup_tree(c))}
	return {"name": t["name"], "members": t["members"].map(func(m): return m.duplicate())}

func delete_piece(p: Node3D) -> void:
	for m in members_of(p.get_meta("tree")):
		if not m["copy"]:
			hidden[m["atom"]] = true
	remove_child(p)
	p.queue_free()

func restore_hidden() -> Node3D:
	if hidden.is_empty():
		return null
	var ms: Array = []
	for at in hidden.keys():
		ms.append({"atom": at, "copy": false, "L": Transform3D.IDENTITY})
	hidden = {}
	return add_piece({"name": "restored", "members": ms}, Transform3D.IDENTITY, true)

# ---------------------------------------------------------------- prefabs

func make_prefab(ps: Array, name: String) -> Dictionary:
	# members relative to the selection's bottom centre (metres)
	var box := AABB()
	for i in ps.size():
		box = world_box(ps[i]) if i == 0 else box.merge(world_box(ps[i]))
	var origin := Vector3(box.get_center().x, box.position.y, box.get_center().z)
	var ms: Array = []
	for p in ps:
		for m in members_of(p.get_meta("tree")):
			var w: Transform3D = (p as Node3D).transform * (m["L"] as Transform3D)
			var e := {"atom": m["atom"], "m": _to_cm(Transform3D(w.basis, w.origin - origin))}
			if m.has("map"):
				e["map"] = m["map"]
			ms.append(e)
	var pf := {"name": name, "members": ms}
	prefabs.append(pf)
	return pf

func prefab_tree(pf: Dictionary) -> Dictionary:
	var ms: Array = []
	for m in pf["members"]:
		var e := {"atom": int(m["atom"]), "copy": true, "L": _from_cm(m["m"])}
		if m.has("map"):
			e["map"] = m["map"]
		ms.append(e)
	return {"name": pf["name"], "members": ms}

func place_foreign(rel: String, t: Dictionary, at: Vector3) -> Node3D:
	# a copy of another map's piece (tree t from its default_trees(), world space there), its bottom centre at at
	var ms: Array = []
	for m in members_of(t):
		ms.append({"atom": m["atom"], "copy": true, "map": rel, "L": m["L"]})
	var label: String = t["name"] if rel.begins_with("@project/") else "%s %s" % [rel.get_file(), t["name"]]   # an import: its own name
	var p := add_piece({"name": label, "members": ms}, Transform3D.IDENTITY, true)
	p.position = at
	return p

func placed_from(rel: String) -> Array:
	# pieces holding copies of another map's (or an import's) atoms
	return pieces().filter(func(p): return members_of(p.get_meta("tree")).any(func(m): return m.get("map", "") == rel))

func refresh_import(rel: String) -> void:
	# an imported mesh was rebuilt (its atoms renumbered): every placed copy takes the new piece whole, in the place
	# the old one had
	var g: Node = library.map_geometry_rel(rel) if library else null
	if g == null:
		return
	var ts: Array = g.default_trees()
	if ts.is_empty():
		return
	var fresh: Array = members_of(ts[0])
	for p in placed_from(rel):
		_swap_members(p.get_meta("tree"), rel, fresh)
		rebuild(p)

func _swap_members(t: Dictionary, rel: String, fresh: Array) -> void:
	if t.has("children"):
		for c in t["children"]:
			_swap_members(c, rel, fresh)
		return
	var keep: Array = []
	var L: Variant = null
	for m in t["members"]:
		if m.get("map", "") == rel:
			if L == null:
				L = m["L"]
		else:
			keep.append(m)
	if L == null:
		return
	for f in fresh:
		keep.append({"atom": f["atom"], "copy": true, "map": rel, "L": L})
	t["members"] = keep

func place_prefab(pf: Dictionary, at: Vector3) -> Node3D:
	return add_piece(prefab_tree(pf), Transform3D(Basis.IDENTITY, at), false)

# ---------------------------------------------------------------- save, undo, stats

func _tree_out(t: Dictionary, g: Transform3D, xf: Dictionary, copies: Array) -> Dictionary:
	if t.has("children"):
		var o := {"name": t["name"], "children": t["children"].map(func(c): return _tree_out(c, g, xf, copies))}
		if t.get("mesh_collision", false):
			o["mesh_collision"] = true
		return o
	var atoms: Array = []
	var cps: Array = []
	for m in t["members"]:
		var w: Transform3D = g * (m["L"] as Transform3D)
		if m["copy"]:
			cps.append(copies.size())
			var c := {"atom": m["atom"], "m": _to_cm(w)}
			if m.has("map"):
				c["map"] = m["map"]
			copies.append(c)
		else:
			atoms.append(m["atom"])
			if not w.is_equal_approx(Transform3D.IDENTITY):
				xf[str(m["atom"])] = _to_cm(w)
	var out := {"name": t["name"], "atoms": atoms}
	if cps.size():
		out["copies"] = cps
	if t.get("mesh_collision", false):
		out["mesh_collision"] = true   # lp2pieces.mesh_collision: collision from the visible triangles
	return out

func to_json() -> Dictionary:
	var xf := {}
	var copies: Array = []
	var tree: Array = []
	for p in pieces():
		tree.append(_tree_out(p.get_meta("tree"), p.transform, xf, copies))
	var hid: Array = hidden.keys()
	hid.sort()
	var walls: Array = walls_hidden.keys()
	walls.sort()
	return {"xf": xf, "hidden": hid, "copies": copies, "tree": tree, "prefabs": prefabs, "walls_hidden": walls}

func snapshot() -> Array:
	var out: Array = []
	for p in pieces():
		out.append({"uid": p.get_meta("uid"), "g": p.transform, "tree": _dup_tree(p.get_meta("tree"))})
	return [out, hidden.duplicate(), walls_hidden.duplicate()]

func restore(s: Array) -> void:
	# rebuild only the pieces whose contents changed; the rest just get their transform back
	var keep := {}
	for e in s[0]:
		keep[e["uid"]] = e
	for p in pieces():
		var e: Variant = keep.get(p.get_meta("uid"))
		if e == null or var_to_str(e["tree"]) != var_to_str(p.get_meta("tree")):
			remove_child(p)
			p.queue_free()
	var have := {}
	for p in get_children():
		have[p.get_meta("uid")] = p
	for e in s[0]:
		if have.has(e["uid"]):
			(have[e["uid"]] as Node3D).transform = e["g"]
		else:
			var p := add_piece(_dup_tree(e["tree"]), e["g"], false)
			p.set_meta("uid", e["uid"])
	hidden = s[1].duplicate()
	walls_hidden = s[2].duplicate() if s.size() > 2 else {}

func borrowed_textures() -> Dictionary:
	# {texture name: bytes} that pieces from other maps bring (not this map's own)
	var own := {}
	for m in data["materials"]:
		for n in m.get("textures", {}):
			own[n] = true
	var out := {}
	for p in pieces():
		for m in members_of(p.get_meta("tree")):
			if not m.has("map"):
				continue
			var g: Node = src(m)
			if g == null:
				continue
			for b in g.atom_blocks.get(m["atom"], []):
				var tx: Dictionary = g.data["materials"][b[1]].get("textures", {})
				for n in tx:
					if not own.has(n):
						out[n] = tx[n]
	return out

func stats() -> Dictionary:
	var v := 0
	var t := 0
	var copies := 0
	var atoms := 0
	for p in pieces():
		for m in members_of(p.get_meta("tree")):
			var g: Node = src(m)
			if g:
				v += g.atom_verts[m["atom"]]
				t += g.atom_tris[m["atom"]]
			atoms += 1
			if m["copy"]:
				copies += 1
	return {"vertices": v, "triangles": t, "pieces": get_child_count(), "atoms": atoms, "copies": copies,
		"hidden": hidden.size()}
