extends Node
# Terrain areas (project "terrains"): height grids placed in the level; lp2terrain.py builds each into a piece of the
# map (its own triangles as collision) at export. A terrain's "pos" is the grid's corner, cell (0, 0) (cm), "cell" the
# cell size (cm), "cells" [nx, nz]. Per terrain, beside the project (edits that change a grid in place _detach it first,
# so the undo snapshots keep theirs):
#   terrain/<id>.r32   heights: (nx + 1) * (nz + 1) float32, cm above pos y, rows along x, one per z
#   terrain/<id>.w8    paint: 4 bytes per height point, the weights of paint layers 1-4 (the base layer has the rest)
#   terrain/<id>.hole  holes: 1 byte per cell (1 = no ground: caves, tunnel mouths)
# "material" / "tile": the base layer's project material ("" = the blockout grid) and metres per texture repeat;
# "layers": up to 4 paint layers [{material, tile}]. Each cell shows (and exports as) its strongest layer (cell_layer):
# the materials' own tiled textures, edged along the cells.
# Selected, its outline and see-through sides show; Ctrl+drag a side grows / shrinks it by whole cells (the grid stays
# put in the world: growing adds cells with the edge's heights, shrinking crops). Edit (inspector) locks the rest of
# the level and shows the terrain toolbar: height (Shift lowers, Ctrl flattens), smooth, paint (Shift erases), fill
# (click: the touching cells of that layer; or by slope), holes (cut, or add ground: past the edge the grid grows to
# the brush, the new cells holes but the brushed ones, heights carried from the edge; Shift swaps). Brush size / strength / falloff,
# each of size and strength optionally from pen pressure. Esc or Done leaves.

const COLOUR := Color(0.45, 0.75, 0.35)
const CELLS := [50.0, 100.0, 200.0, 400.0]   # cell sizes offered (cm)
const SUN := Vector3(0.35, 0.85, 0.4)          # editor shading
const MAX_CELLS := 512                       # per side
const CHUNK := 32                            # cells per side of one editor mesh (a stroke rebuilds only its chunks)
const LAYERS := 5                            # base + 4 paint layers
# a layer without a material: the blockout grid in its own colour (lp2terrain.BLOCKOUT_COLOURS, same order)
const LAYER_COLOURS := [Color(0.42, 0.55, 0.3), Color(0.76, 0.66, 0.45), Color(0.5, 0.5, 0.52), Color(0.92, 0.94, 0.97), Color(0.45, 0.32, 0.22)]
const TOOLS := [["height", "Height", "Raise; Shift lowers; Ctrl flattens to the height where the stroke began"],
	["smooth", "Smooth", "Evens out bumps and steps"], ["paint", "Paint", "Paints the chosen layer; Shift erases back to the base"],
	["fill", "Fill", "Click: fills the touching cells of the same layer with the chosen one. Or fill by slope below"],
	["holes", "Holes", "Cut: holes (no ground or collision: cave and tunnel mouths). Add ground: paints ground back, and past the edge grows the terrain (joined to the edge's height). Shift swaps the two"]]
const HEIGHT_RATE := 600.0   # cm per second at full strength
const PAINT_RATE := 3.0      # blend per second at full strength

var main: Node
var heights := {}    # id -> PackedFloat32Array
var weights := {}    # id -> PackedByteArray (4 per point)
var holes := {}      # id -> PackedByteArray (1 per cell)
var rev := 0         # bumped on every change (unsaved-changes check)
var dirty := {}      # ids whose files are out of date
var box: VBoxContainer
var size_spins: Array = []
var cell_pick: OptionButton
var mat_pick: OptionButton
var tile_spin: SpinBox
var blend_pick: OptionButton
var bake_spin: SpinBox
var info: Label
var updating := false
var _grid_tex: ImageTexture
var _tex_cache := {}   # material name -> [texture, tint]
var _shader: Shader

func setup(m: Node, right: VBoxContainer) -> void:
	main = m
	box = VBoxContainer.new()
	box.add_child(main._label("Terrain"))
	var g := GridContainer.new()
	g.columns = 2
	for a in ["Size X (m)", "Size Z (m)"]:
		g.add_child(main._label(a))
		var s: SpinBox = main._spin(0.5, 2048.0, 0.5)
		s.tooltip_text = "Grows or shrinks the far side by whole cells (Ctrl+drag a side to change either side)"
		s.value_changed.connect(func(_v): _on_size())
		g.add_child(s)
		size_spins.append(s)
	g.add_child(main._label("Cell size"))
	cell_pick = OptionButton.new()
	for c in CELLS:
		cell_pick.add_item("%s m" % _m(c / 100.0))
	cell_pick.tooltip_text = "Distance between height points. Smaller = finer shapes and paint edges, more triangles (resampled)"
	cell_pick.item_selected.connect(func(_i): _on_cell())
	g.add_child(cell_pick)
	g.add_child(main._label("Base material"))
	mat_pick = OptionButton.new()
	mat_pick.tooltip_text = "A project material (Mesh builder, M), or the blockout grid; paint layers go over it (Edit)"
	mat_pick.item_selected.connect(func(_i): _on_changed())
	g.add_child(mat_pick)
	g.add_child(main._label("Texture tile (m)"))
	tile_spin = main._spin(0.25, 256.0, 0.25)
	tile_spin.tooltip_text = "Metres per texture repeat (the blockout grid is always 1 m)"
	tile_spin.value_changed.connect(func(_v): _on_changed())
	g.add_child(tile_spin)
	g.add_child(main._label("Paint"))
	blend_pick = OptionButton.new()
	blend_pick.add_item("Sharp (per cell)")
	blend_pick.add_item("Smooth blend (baked)")
	blend_pick.tooltip_text = "Sharp: each cell uses its strongest layer's own tiled textures (crisp, no extra memory, edges follow the cells). Smooth: layers blend; the export bakes the blend into textures per 64 m-ish chunk (softer close up, costs memory)"
	blend_pick.item_selected.connect(func(_i): _on_changed())
	g.add_child(blend_pick)
	g.add_child(main._label("Bake detail (px/m)"))
	bake_spin = main._spin(4.0, 64.0, 1.0)
	bake_spin.tooltip_text = "Smooth blend: texture pixels per metre baked (16 = 6 cm pixels). Memory grows with its square"
	bake_spin.value_changed.connect(func(_v): _on_changed())
	g.add_child(bake_spin)
	box.add_child(g)
	var eb := Button.new()
	eb.text = "Edit terrain (sculpt, paint, holes)"
	eb.tooltip_text = "Locks the rest of the level and shows the terrain tools; Esc or Done leaves"
	eb.pressed.connect(_edit_selected)
	box.add_child(eb)
	info = main._label("")
	box.add_child(info)
	box.visible = false
	right.add_child(box)

func _edit_selected() -> void:
	var n := _one()
	if n:
		start_edit(n)

func add_button(parent: Control) -> Button:
	var b := Button.new()
	b.text = "Add terrain"
	b.tooltip_text = "A flat terrain area where the view points; Ctrl+drag its sides to size it, Edit to sculpt and paint"
	b.pressed.connect(add_terrain)
	parent.add_child(b)
	return b

# ---------------------------------------------------------------- data

func terrains() -> Array:
	if not main.project.has("terrains"):
		main.project["terrains"] = []
	return main.project["terrains"]

static func is_terrain(n: Node) -> bool:
	return n.has_meta("terrain")

static func dims(d: Dictionary) -> Vector2i:
	return Vector2i(int(d["cells"][0]), int(d["cells"][1]))

func _file(d: Dictionary, key: String, ext: String) -> String:
	return main.project_dir.path_join(str(d.get(key, "terrain/%s.%s" % [d["id"], ext])))

static func _blank(d: Dictionary) -> Array:
	# flat heights, no paint, no holes for the terrain's size
	var g := dims(d)
	var h := PackedFloat32Array()
	h.resize((g.x + 1) * (g.y + 1))
	var w := PackedByteArray()
	w.resize(h.size() * 4)
	var o := PackedByteArray()
	o.resize(g.x * g.y)
	return [h, w, o]

func load_all() -> void:
	# the open project's grids (a missing or mis-sized file: flat / unpainted / no holes)
	heights = {}
	weights = {}
	holes = {}
	dirty = {}
	for d in terrains():
		_paths(d)
		var b := _blank(d)
		var hb := FileAccess.get_file_as_bytes(_file(d, "heights", "r32"))
		var wb := FileAccess.get_file_as_bytes(_file(d, "weights", "w8"))
		var ob := FileAccess.get_file_as_bytes(_file(d, "holes", "hole"))
		heights[d["id"]] = hb.to_float32_array() if hb.size() == (b[0] as PackedFloat32Array).size() * 4 else b[0]
		weights[d["id"]] = wb if wb.size() == (b[1] as PackedByteArray).size() else b[1]
		holes[d["id"]] = ob if ob.size() == (b[2] as PackedByteArray).size() else b[2]

static func _paths(d: Dictionary) -> void:
	d["heights"] = "terrain/%s.r32" % d["id"]
	d["weights"] = "terrain/%s.w8" % d["id"]
	d["holes"] = "terrain/%s.hole" % d["id"]

func save_all() -> void:
	# the changed terrains' files; files of deleted terrains go
	DirAccess.make_dir_recursive_absolute(main.project_dir.path_join("terrain"))
	var keep := {}
	for d in terrains():
		_paths(d)
		for k in [["heights", "r32"], ["weights", "w8"], ["holes", "hole"]]:
			var path := _file(d, k[0], k[1])
			keep[path.get_file()] = true
			if not dirty.has(d["id"]) and FileAccess.file_exists(path):
				continue
			var data: PackedByteArray = (heights[d["id"]] as PackedFloat32Array).to_byte_array() if k[0] == "heights" \
				else weights[d["id"]] if k[0] == "weights" else holes[d["id"]]
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f == null:
				main.log_line("SAVE FAILED: can't write %s" % path)
				continue
			f.store_buffer(data)
			f.close()
	dirty = {}
	var dir := DirAccess.open(main.project_dir.path_join("terrain"))
	if dir:
		for f in dir.get_files():
			if f.get_extension() in ["r32", "w8", "hole"] and not keep.has(f):
				dir.remove(f)

func snapshot() -> Array:
	return [terrains().duplicate(true), heights.duplicate(), weights.duplicate(), holes.duplicate()]

func restore(s: Array) -> void:
	main.project["terrains"] = s[0]
	heights = (s[1] as Dictionary).duplicate()
	weights = (s[2] as Dictionary).duplicate() if s.size() > 2 else {}
	holes = (s[3] as Dictionary).duplicate() if s.size() > 3 else {}
	for d in terrains():
		var b := _blank(d)
		for k in 3:
			var store: Dictionary = [heights, weights, holes][k]
			if not store.has(d["id"]):
				store[d["id"]] = b[k]
		dirty[d["id"]] = true
	rev += 1

func _detach(d: Dictionary) -> void:
	# own copies of the terrain's grids before editing them in place: packed arrays are shared by reference, so the
	# undo snapshot just taken would change with them
	var id: String = d["id"]
	heights[id] = (heights[id] as PackedFloat32Array).duplicate()
	weights[id] = (weights[id] as PackedByteArray).duplicate()
	holes[id] = (holes[id] as PackedByteArray).duplicate()

func _set_heights(d: Dictionary, h: PackedFloat32Array) -> void:
	heights[d["id"]] = h
	_changed(d)

func _changed(d: Dictionary) -> void:
	dirty[d["id"]] = true
	rev += 1

func _new_id() -> String:
	var used := {}
	for d in terrains():
		used[d["id"]] = true
	var i := 1
	while used.has("t%d" % i):
		i += 1
	return "t%d" % i

static func _m(x: float) -> String:
	# metres for labels: 64, 0.5 (no trailing zeros)
	var t := "%.2f" % x
	return t.rstrip("0").rstrip(".")

static func label(d: Dictionary) -> String:
	var n := dims(d)
	var c := float(d["cell"])
	return "Terrain: %s (%s x %s m, %s m cells)" % [d.get("name", d["id"]), _m(n.x * c / 100.0), _m(n.y * c / 100.0), _m(c / 100.0)]

static func layer_info(d: Dictionary, k: int) -> Dictionary:
	# layer k (0 = base): {material, tile, slope?, damage?}
	if k == 0:
		var b := {"material": str(d.get("material", "")), "tile": float(d.get("tile", 4.0))}
		if d.get("damage") is Dictionary:
			b["damage"] = d["damage"]
		return b
	var ls: Array = d.get("layers", [])
	return ls[k - 1] if k - 1 < ls.size() else {"material": "", "tile": 4.0}

static func cell_layer(w: PackedByteArray, g: Vector2i, ix: int, iz: int) -> int:
	# the cell's strongest layer from its four corners' weights (base = what the paint layers leave); ties: the lower
	# layer. lp2terrain.cell_layers does the same.
	var a := iz * (g.x + 1) + ix
	var s := [0, 0, 0, 0, 0]
	for p in [a, a + 1, a + g.x + 1, a + g.x + 2]:
		var rest := 255
		for k in 4:
			var v: int = w[p * 4 + k]
			s[k + 1] += v
			rest -= v
		s[0] += maxi(rest, 0)
	var best := 0
	for k in range(1, LAYERS):
		if s[k] > s[best]:
			best = k
	return best

# ---------------------------------------------------------------- level nodes

func add_markers() -> void:
	for d in terrains():
		if not heights.has(d["id"]):
			var b := _blank(d)
			heights[d["id"]] = b[0]
			weights[d["id"]] = b[1]
			holes[d["id"]] = b[2]
		add_marker(d)
	if _resume_id != "":
		var id := _resume_id
		_resume_id = ""
		var back: Array = main.markers_root.get_children().filter(func(n): return is_terrain(n) and n.get_meta("data")["id"] == id)
		if back.is_empty():
			stop_edit.call_deferred()   # undone away: unlock the level
		else:
			start_edit.call_deferred(back[0])

func add_marker(d: Dictionary) -> Node3D:
	_paths(d)
	var n := Node3D.new()
	n.set_meta("data", d)
	n.set_meta("object", false)
	n.set_meta("terrain", true)
	var mi := MeshInstance3D.new()   # child 0: holds the chunks; its material's colour is the outliner's
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOUR
	mi.material_override = mat
	n.add_child(mi)
	var edges := MeshInstance3D.new()   # child 1: its outline, while selected
	edges.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	edges.visible = false
	n.add_child(edges)
	var body := StaticBody3D.new()   # child 2: picking, and ground for placing / dropping things on it
	body.collision_layer = (1 << (main.LAYER_MARKERS - 1)) | (1 << (main.LAYER_STAGE - 1))
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.shape = ConcavePolygonShape3D.new()
	(shape.shape as ConcavePolygonShape3D).backface_collision = true
	body.add_child(shape)
	n.add_child(body)
	var sides := MeshInstance3D.new()   # child 3: the see-through sides (where Ctrl+drag grabs), while selected
	sides.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sides.visible = false
	n.add_child(sides)
	var sm := ShaderMaterial.new()
	sm.shader = _get_shader()
	n.set_meta("shader", sm)
	main.markers_root.add_child(n)
	main._place(n)
	update_marker(n)
	return n

func _bounds(n: Node3D) -> AABB:
	# the terrain's box in its own frame (metres): the grid, from below its lowest point to above its highest
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	if not n.has_meta("y_range"):   # cached: brushes ask every frame (update_marker clears it, strokes widen it)
		var lo0 := INF
		var hi0 := -INF
		for v in (heights[d["id"]] as PackedFloat32Array):
			lo0 = minf(lo0, v)
			hi0 = maxf(hi0, v)
		n.set_meta("y_range", Vector2(lo0, hi0))
	var yr: Vector2 = n.get_meta("y_range")
	var lo := yr.x
	var hi := yr.y
	var c: float = float(d["cell"]) * main.CM
	return AABB(Vector3(0, lo * main.CM - 1.0, 0), Vector3(g.x * c, (hi - lo) * main.CM + 3.0, g.y * c))

func update_marker(n: Node3D) -> void:
	# everything: the chunks, the layer map, the materials, the pick shape, the outline
	n.remove_meta("y_range")
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var holder := n.get_child(0) as MeshInstance3D
	for c in holder.get_children():
		holder.remove_child(c)
		c.queue_free()
	var nc := Vector2i(ceili(g.x / float(CHUNK)), ceili(g.y / float(CHUNK)))
	for cz in nc.y:
		for cx in nc.x:
			var ch := MeshInstance3D.new()
			ch.material_override = n.get_meta("shader")
			ch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(ch)
	_rebuild_chunks(n, Rect2i(0, 0, g.x, g.y))
	_layer_map(n, Rect2i(0, 0, g.x, g.y), true)
	_materials_to_shader(n)
	update_shape(n)
	_update_box(n)

func _rebuild_chunks(n: Node3D, cells: Rect2i) -> void:
	# the chunks touching these cells (one more round: normals reach the next points)
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var nc := ceili(g.x / float(CHUNK))
	var r := cells.grow(1).intersection(Rect2i(0, 0, g.x, g.y))
	var holder := n.get_child(0)
	for cz in range(r.position.y / CHUNK, (r.end.y - 1) / CHUNK + 1):
		for cx in range(r.position.x / CHUNK, (r.end.x - 1) / CHUNK + 1):
			var k := cz * nc + cx
			if k < holder.get_child_count():
				(holder.get_child(k) as MeshInstance3D).mesh = _chunk_mesh(d, cx, cz)

func _chunk_mesh(d: Dictionary, cx: int, cz: int) -> ArrayMesh:
	var g := dims(d)
	var h: PackedFloat32Array = heights[d["id"]]
	var c: float = float(d["cell"]) * main.CM
	var w := g.x + 1
	var x0 := cx * CHUNK
	var z0 := cz * CHUNK
	var x1 := mini(x0 + CHUNK, g.x)
	var z1 := mini(z0 + CHUNK, g.y)
	var cw := x1 - x0 + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var shade := PackedColorArray()   # a fixed sun's light, like the level's baked light (the shader is unshaded)
	var sun := SUN.normalized()
	for iz in range(z0, z1 + 1):
		for ix in range(x0, x1 + 1):
			var i := iz * w + ix
			verts.append(Vector3(ix * c, h[i] * main.CM, iz * c))
			var xa := maxi(ix - 1, 0)
			var xb := mini(ix + 1, g.x)
			var za := maxi(iz - 1, 0)
			var zb := mini(iz + 1, g.y)
			var dx: float = (h[iz * w + xb] - h[iz * w + xa]) * main.CM / ((xb - xa) * c)
			var dz: float = (h[zb * w + ix] - h[za * w + ix]) * main.CM / ((zb - za) * c)
			var nv := Vector3(-dx, 1.0, -dz).normalized()
			norms.append(nv)
			var l := 0.45 + 0.6 * maxf(0.0, nv.dot(sun))
			shade.append(Color(l, l, l))
	var idx := PackedInt32Array()
	for iz in z1 - z0:
		for ix in x1 - x0:
			var a := iz * cw + ix
			idx.append_array([a, a + 1, a + cw, a + 1, a + cw + 1, a + cw])   # Godot's front faces: clockwise from above
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = shade
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

func update_shape(n: Node3D) -> void:
	# the pick / ground shape (after a stroke: rebuilding it per frame would be slow on big terrains)
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var h: PackedFloat32Array = heights[d["id"]]
	var c: float = float(d["cell"]) * main.CM
	var w := g.x + 1
	var o: PackedByteArray = holes[d["id"]]
	var faces := PackedVector3Array()
	for iz in g.y:
		for ix in g.x:
			if o[iz * g.x + ix]:
				continue
			var a := iz * w + ix
			var p := [Vector3(ix * c, h[a] * main.CM, iz * c), Vector3((ix + 1) * c, h[a + 1] * main.CM, iz * c),
				Vector3(ix * c, h[a + w] * main.CM, (iz + 1) * c), Vector3((ix + 1) * c, h[a + w + 1] * main.CM, (iz + 1) * c)]
			faces.append_array([p[0], p[1], p[2], p[1], p[3], p[2]])
	var shape := (n.get_child(2) as StaticBody3D).get_child(0) as CollisionShape3D
	(shape.shape as ConcavePolygonShape3D).set_faces(faces)

func _layer_map(n: Node3D, cells: Rect2i, full := false) -> void:
	# for these cells: the effective weights (paint + slope rules) of their points and the shader's per-cell layer
	# index (255 = hole)
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var img: Image = n.get_meta("layer_img") if n.has_meta("layer_img") and not full else null
	if img == null or img.get_width() != g.x or img.get_height() != g.y:
		img = Image.create(g.x, g.y, false, Image.FORMAT_R8)
		n.set_meta("layer_img", img)
		n.set_meta("weight_img", Image.create(g.x + 1, g.y + 1, false, Image.FORMAT_RGBA8))
		n.remove_meta("eff")
		cells = Rect2i(0, 0, g.x, g.y)
	var r := cells.intersection(Rect2i(0, 0, g.x, g.y))
	var eff := _effective(n, Rect2i(r.position, r.size + Vector2i.ONE))
	var o: PackedByteArray = holes[d["id"]]
	for iz in range(r.position.y, r.end.y):
		for ix in range(r.position.x, r.end.x):
			var v := 255 if o[iz * g.x + ix] else cell_layer(eff, g, ix, iz)
			img.set_pixel(ix, iz, Color8(v, 0, 0))
	var sm: ShaderMaterial = n.get_meta("shader")
	for k in [["layer_tex", img, "layer_map"], ["weight_tex", n.get_meta("weight_img"), "weight_map"]]:
		var im: Image = k[1]
		var tex: Variant = n.get_meta(k[0]) if n.has_meta(k[0]) else null
		if tex == null or (tex as ImageTexture).get_width() != im.get_width() or (tex as ImageTexture).get_height() != im.get_height():
			tex = ImageTexture.create_from_image(im)
			n.set_meta(k[0], tex)
		else:
			(tex as ImageTexture).update(im)
		sm.set_shader_parameter(k[2], tex)
	sm.set_shader_parameter("cells", Vector2(g.x, g.y))
	sm.set_shader_parameter("cell", float(d["cell"]) * main.CM)
	sm.set_shader_parameter("blend", bool(d.get("blend", false)))

static func bake_mb(d: Dictionary) -> float:
	# the smooth blend's baked textures (lp2terrain.bake_chunks): colour (DXT1, 0.5 B/px) + normal and mask (DXT5,
	# 1 B/px each), mips +1/3, per chunk of up to 1024 px
	var g := dims(d)
	var px: float = float(d.get("bake_px", 16.0))
	var m := Vector2(g.x, g.y) * float(d["cell"]) / 100.0 * px
	return m.x * m.y * 2.5 * 4.0 / 3.0 / 1e6

static func slope_rules(d: Dictionary) -> Array:
	# [layer, from deg, to deg, soft deg] for the paint layers with "Auto by slope" on
	var out: Array = []
	for k in range(1, LAYERS):
		var sl: Variant = layer_info(d, k).get("slope")
		if sl is Dictionary and sl.get("on", false):
			out.append([k, float(sl.get("min", 35.0)), float(sl.get("max", 90.0)), float(sl.get("soft", 5.0))])
	return out

static func rule_weight(deg: float, lo: float, hi: float, soft: float) -> float:
	# 1 inside lo..hi, ramping to 0 over `soft` degrees outside it (lp2terrain.rule_weight alike)
	if soft <= 0.0:
		return 1.0 if deg >= lo and deg <= hi else 0.0
	return clampf((deg - (lo - soft)) / soft, 0.0, 1.0) * clampf(((hi + soft) - deg) / soft, 0.0, 1.0)

func _effective(n: Node3D, pts: Rect2i) -> PackedByteArray:
	# the points' weights as shown and exported: the paint, each slope rule's layer raised to its rule weight (the
	# higher layers on top), scaled back to 255 in all; kept in the node (meta "eff") and its weight image
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var w := g.x + 1
	var src: PackedByteArray = weights[d["id"]]
	var eff: PackedByteArray = n.get_meta("eff") if n.has_meta("eff") else PackedByteArray()
	if eff.size() != src.size():
		eff = src.duplicate()
		n.set_meta("eff", eff)
		pts = Rect2i(0, 0, w, g.y + 1)
	var wimg: Image = n.get_meta("weight_img")
	var rules := slope_rules(d)
	var h: PackedFloat32Array = heights[d["id"]]
	var c: float = float(d["cell"])
	var r := pts.intersection(Rect2i(0, 0, w, g.y + 1))
	for iz in range(r.position.y, r.end.y):
		for ix in range(r.position.x, r.end.x):
			var i := iz * w + ix
			var v := [float(src[i * 4]), float(src[i * 4 + 1]), float(src[i * 4 + 2]), float(src[i * 4 + 3])]
			if not rules.is_empty():
				var xa := maxi(ix - 1, 0)
				var xb := mini(ix + 1, g.x)
				var za := maxi(iz - 1, 0)
				var zb := mini(iz + 1, g.y)
				var dx: float = (h[iz * w + xb] - h[iz * w + xa]) / ((xb - xa) * c)
				var dz: float = (h[zb * w + ix] - h[za * w + ix]) / ((zb - za) * c)
				var deg := rad_to_deg(atan(Vector2(dx, dz).length()))
				for rule in rules:
					var k: int = rule[0] - 1
					v[k] = maxf(v[k], rule_weight(deg, rule[1], rule[2], rule[3]) * 255.0)
				var sum: float = v[0] + v[1] + v[2] + v[3]
				if sum > 255.0:
					for k in 4:
						v[k] *= 255.0 / sum
			for k in 4:
				eff[i * 4 + k] = clampi(floori(v[k] + 0.5), 0, 255)
			wimg.set_pixel(ix, iz, Color8(eff[i * 4], eff[i * 4 + 1], eff[i * 4 + 2], eff[i * 4 + 3]))
	return eff

func _materials_to_shader(n: Node3D) -> void:
	var d: Dictionary = n.get_meta("data")
	var sm: ShaderMaterial = n.get_meta("shader")
	for k in LAYERS:
		var li := layer_info(d, k)
		var t: Array = _layer_tex(str(li["material"]), k)
		sm.set_shader_parameter("tex%d" % k, t[0])
		sm.set_shader_parameter("tint%d" % k, t[1])
		sm.set_shader_parameter("tile%d" % k, float(t[2]) if t[2] > 0 else float(li["tile"]))
	sm.set_shader_parameter("show_holes", editing() and edit_node == n and tool == "holes")

func _layer_tex(mname: String, k: int) -> Array:
	# [texture, tint, fixed tile (0: the layer's own)] for a layer's material ("": the blockout grid in its colour)
	if mname != "":
		if not _tex_cache.has(mname):
			var md: Variant = main._read_json(main.project_dir.path_join("materials/%s/material.json" % mname))
			var out: Array = []
			if md is Dictionary and md.get("bm"):
				var img := Image.load_from_file(main.project_dir.path_join("materials/%s/%s" % [mname, md["bm"]]))
				if img:
					img.generate_mipmaps()
					out = [ImageTexture.create_from_image(img), Color.WHITE, 0.0]
			if out.is_empty():
				var col: Array = md.get("colour", [0.8, 0.8, 0.8]) if md is Dictionary else [0.8, 0.8, 0.8]
				out = [_grid(), Color(float(col[0]), float(col[1]), float(col[2])), 0.0]
			_tex_cache[mname] = out
		return _tex_cache[mname]
	return [_grid(), LAYER_COLOURS[k], 1.0]

func _get_shader() -> Shader:
	if _shader == null:
		_shader = Shader.new()
		var code := """shader_type spatial;
render_mode unshaded, cull_disabled;
// the terrain: each cell shows its strongest layer's texture, tiled in world space; holes are cut out
"""
		for k in LAYERS:
			code += "uniform sampler2D tex%d : source_color, filter_linear_mipmap, repeat_enable;\nuniform vec3 tint%d = vec3(1.0);\nuniform float tile%d = 4.0;\n" % [k, k, k]
		code += """uniform sampler2D layer_map : filter_nearest;
uniform sampler2D weight_map : filter_linear;
uniform bool blend = false;
uniform vec2 cells = vec2(1.0);
uniform float cell = 1.0;
uniform bool show_holes = false;
varying vec3 lp;
varying vec3 wp;
void vertex() {
	lp = VERTEX;
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	ivec2 c = ivec2(clamp(floor(lp.xz / cell), vec2(0.0), cells - 1.0));
	int k = int(texelFetch(layer_map, c, 0).r * 255.0 + 0.5);
	vec3 col;
	if (k == 255) {
		if (!show_holes) { discard; }
		col = mix(vec3(0.5, 0.05, 0.05), vec3(0.9, 0.2, 0.2), step(0.5, fract((wp.x + wp.z) * 0.5)));
	}
	else if (blend) {
		vec4 w = texture(weight_map, (lp.xz / cell + 0.5) / (cells + 1.0));
		float w0 = max(1.0 - (w.r + w.g + w.b + w.a), 0.0);
		col = (texture(tex0, wp.xz / tile0).rgb * tint0 * w0 + texture(tex1, wp.xz / tile1).rgb * tint1 * w.r
			+ texture(tex2, wp.xz / tile2).rgb * tint2 * w.g + texture(tex3, wp.xz / tile3).rgb * tint3 * w.b
			+ texture(tex4, wp.xz / tile4).rgb * tint4 * w.a) / max(w0 + w.r + w.g + w.b + w.a, 0.001);
	}
	else if (k == 1) { col = texture(tex1, wp.xz / tile1).rgb * tint1; }
	else if (k == 2) { col = texture(tex2, wp.xz / tile2).rgb * tint2; }
	else if (k == 3) { col = texture(tex3, wp.xz / tile3).rgb * tint3; }
	else if (k == 4) { col = texture(tex4, wp.xz / tile4).rgb * tint4; }
	else { col = texture(tex0, wp.xz / tile0).rgb * tint0; }
	ALBEDO = col * COLOR.rgb;
}
"""
		_shader.code = code
	return _shader

func _update_box(n: Node3D) -> void:
	var b := _bounds(n)
	var lines := PackedVector3Array()
	for e in [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		lines.append(b.get_endpoint(e[0]))
		lines.append(b.get_endpoint(e[1]))
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = COLOUR.lightened(0.3)
	var la := []
	la.resize(Mesh.ARRAY_MAX)
	la[Mesh.ARRAY_VERTEX] = lines
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, la)
	am.surface_set_material(0, lm)
	(n.get_child(1) as MeshInstance3D).mesh = am
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for q in [[0, 4, 5, 1], [2, 3, 7, 6], [0, 1, 3, 2], [4, 6, 7, 5]]:   # the four sides (x and z faces)
		for j in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(b.get_endpoint(q[j]))
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_color = Color(COLOUR, 0.12)
	var sides := n.get_child(3) as MeshInstance3D
	sides.mesh = st.commit()
	sides.material_override = sm

func _grid() -> ImageTexture:
	# 1 m: light with a darker line round the edge (tinted per layer)
	if _grid_tex == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.85, 0.85, 0.85))
		for i in 64:
			for j in [0, 1, 62, 63]:
				img.set_pixel(i, j, Color(0.55, 0.55, 0.55))
				img.set_pixel(j, i, Color(0.55, 0.55, 0.55))
		img.generate_mipmaps()
		_grid_tex = ImageTexture.create_from_image(img)
	return _grid_tex

func set_selected(n: Node3D, on: bool) -> void:
	var show := on and not (editing() and edit_node == n)
	(n.get_child(1) as Node3D).visible = show
	(n.get_child(3) as Node3D).visible = show

# ---------------------------------------------------------------- add, delete, duplicate

func add_terrain() -> void:
	if main.project_dir == "":
		return
	var mp: Vector2 = main.get_viewport().get_visible_rect().size / 2
	var hit: Dictionary = main._mouse_ray(mp, 1 << (main.LAYER_STAGE - 1))
	var at: Vector3 = hit["position"] if hit else main.camera.global_position - main.camera.global_transform.basis.z * 30.0
	main._push_undo("")
	var id := _new_id()
	var d := {"id": id, "name": "Terrain %s" % id.substr(1), "cell": 200.0, "cells": [32, 32], "material": "",
		"tile": 4.0, "yaw": 0.0, "layers": []}
	_paths(d)
	d["pos"] = [snappedf(at.x / main.CM - 3200.0, 1.0), snappedf(at.y / main.CM, 1.0), snappedf(at.z / main.CM - 3200.0, 1.0)]
	var b := _blank(d)
	heights[id] = b[0]
	weights[id] = b[1]
	holes[id] = b[2]
	_changed(d)
	terrains().append(d)
	var n := add_marker(d)
	main._rebuild_outliner()
	main.select([n])
	main.log_line("Added a 64 x 64 m terrain; Ctrl+drag its sides to size it, Edit terrain to sculpt and paint.")

func delete_terrains(ns: Array) -> void:
	for n in ns:
		if editing() and edit_node == n:
			stop_edit()
		var d: Dictionary = n.get_meta("data")
		terrains().erase(d)
		for s in [heights, weights, holes]:
			s.erase(d["id"])
		rev += 1
		main.markers_root.remove_child(n)
		n.queue_free()

func duplicate_terrains(ns: Array) -> Array:
	var out: Array = []
	for n in ns:
		var src: Dictionary = n.get_meta("data")
		var d: Dictionary = src.duplicate(true)
		d["id"] = _new_id()
		d["name"] = str(src.get("name", "Terrain")) + " copy"
		_paths(d)
		d["pos"][0] = float(d["pos"][0]) + dims(d).x * float(d["cell"]) + 200.0
		terrains().append(d)
		heights[d["id"]] = heights[src["id"]]
		weights[d["id"]] = weights[src["id"]]
		holes[d["id"]] = holes[src["id"]]
		_changed(d)
		out.append(add_marker(d))
	return out

# ---------------------------------------------------------------- inspector

func show_inspector(selection: Array) -> void:
	var ts := selection.filter(func(n): return is_instance_valid(n) and is_terrain(n))
	box.visible = ts.size() == 1
	if ts.size() != 1:
		return
	updating = true
	var d: Dictionary = ts[0].get_meta("data")
	var g := dims(d)
	var c := float(d["cell"])
	for a in 2:
		size_spins[a].step = c / 100.0
		size_spins[a].value = (g.x if a == 0 else g.y) * c / 100.0
	cell_pick.selected = maxi(0, CELLS.find(c))
	_fill_materials(mat_pick, str(d.get("material", "")))
	tile_spin.value = float(d.get("tile", 4.0))
	tile_spin.editable = str(d.get("material", "")) != ""
	blend_pick.selected = 1 if d.get("blend", false) else 0
	bake_spin.value = float(d.get("bake_px", 16.0))
	bake_spin.editable = d.get("blend", false)
	var nh := 0
	for v in (holes[d["id"]] as PackedByteArray):
		nh += v
	info.text = "%d x %d cells, %d triangles%s" % [g.x, g.y, (g.x * g.y - nh) * 2, ", %d hole cells" % nh if nh else ""]
	if d.get("blend", false):
		info.text += "\nBaked paint: about %.1f MB of textures" % bake_mb(d)
	updating = false

func _fill_materials(pick: OptionButton, current: String) -> void:
	pick.clear()
	pick.add_item("Blockout grid")
	var mats := _materials()
	for m in mats:
		pick.add_item(m)
	pick.selected = maxi(0, mats.find(current) + 1)

func _materials() -> Array:
	var out: Array = []
	var dir := DirAccess.open(main.project_dir.path_join("materials"))
	if dir:
		for m in dir.get_directories():
			if not m.begins_with("terrain_blockout") and not m.begins_with("terrain_bake_") and FileAccess.file_exists(main.project_dir.path_join("materials/%s/material.json" % m)):
				out.append(m)
	out.sort()
	return out

func _one() -> Node3D:
	var ts: Array = main.selection.filter(func(n): return is_instance_valid(n) and is_terrain(n))
	return ts[0] if ts.size() == 1 else null

func _refresh(n: Node3D) -> void:
	update_marker(n)
	show_inspector([n])
	var item: Variant = n.get_meta("item") if n.has_meta("item") else null
	if item != null and is_instance_valid(item):
		(item as TreeItem).set_text(0, label(n.get_meta("data")))

func _on_changed() -> void:
	var n := _one()
	if updating or n == null:
		return
	main._push_undo("terrain")
	var d: Dictionary = n.get_meta("data")
	d["material"] = "" if mat_pick.selected <= 0 else mat_pick.get_item_text(mat_pick.selected)
	d["tile"] = tile_spin.value
	if blend_pick.selected == 1:
		d["blend"] = true
	else:
		d.erase("blend")
	d["bake_px"] = bake_spin.value
	_refresh(n)
	if editing():
		_show_layer()

func _on_size() -> void:
	var n := _one()
	if updating or n == null:
		return
	main._push_undo("terrain")
	var d: Dictionary = n.get_meta("data")
	var c := float(d["cell"])
	var g := dims(d)
	var want := Vector2i(clampi(roundi(size_spins[0].value * 100.0 / c), 1, MAX_CELLS),
		clampi(roundi(size_spins[1].value * 100.0 / c), 1, MAX_CELLS))
	_resize(d, [heights[d["id"]], weights[d["id"]], holes[d["id"]]], g, Vector2i.ZERO, want)
	_refresh(n)

func _on_cell() -> void:
	# a new cell size: the same ground and paint resampled (bilinear; holes: nearest), the area kept (whole cells)
	var n := _one()
	if updating or n == null:
		return
	main._push_undo("")
	var d: Dictionary = n.get_meta("data")
	var old_c := float(d["cell"])
	var c: float = CELLS[cell_pick.selected]
	var g := dims(d)
	var ng := Vector2i(clampi(roundi(g.x * old_c / c), 1, MAX_CELLS), clampi(roundi(g.y * old_c / c), 1, MAX_CELLS))
	var h: PackedFloat32Array = heights[d["id"]]
	var w: PackedByteArray = weights[d["id"]]
	var o: PackedByteArray = holes[d["id"]]
	var oh := PackedFloat32Array()
	oh.resize((ng.x + 1) * (ng.y + 1))
	var ow := PackedByteArray()
	ow.resize(oh.size() * 4)
	var oo := PackedByteArray()
	oo.resize(ng.x * ng.y)
	var gw := g.x + 1
	for iz in ng.y + 1:
		for ix in ng.x + 1:
			var fx := clampf(ix * c / old_c, 0.0, g.x)
			var fz := clampf(iz * c / old_c, 0.0, g.y)
			var x0 := mini(int(fx), g.x - 1)
			var z0 := mini(int(fz), g.y - 1)
			var tx := fx - x0
			var tz := fz - z0
			var q := [z0 * gw + x0, z0 * gw + x0 + 1, (z0 + 1) * gw + x0, (z0 + 1) * gw + x0 + 1]
			var o_i := iz * (ng.x + 1) + ix
			oh[o_i] = lerpf(lerpf(h[q[0]], h[q[1]], tx), lerpf(h[q[2]], h[q[3]], tx), tz)
			for k in 4:
				ow[o_i * 4 + k] = roundi(lerpf(lerpf(w[q[0] * 4 + k], w[q[1] * 4 + k], tx), lerpf(w[q[2] * 4 + k], w[q[3] * 4 + k], tx), tz))
			if ix < ng.x and iz < ng.y:
				oo[iz * ng.x + ix] = o[mini(int((iz + 0.5) * c / old_c), g.y - 1) * g.x + mini(int((ix + 0.5) * c / old_c), g.x - 1)]
	d["cell"] = c
	d["cells"] = [ng.x, ng.y]
	heights[d["id"]] = oh
	weights[d["id"]] = ow
	holes[d["id"]] = oo
	_changed(d)
	_refresh(n)

func _resize(d: Dictionary, src: Array, g: Vector2i, shift: Vector2i, ng: Vector2i, new_holes := false) -> void:
	# the grids [heights, weights, holes] as ng cells, `shift` cells added before the old ones (negative: cropped);
	# new points take the nearest old edge point's height and paint, new cells no hole (new_holes: holes); the caller
	# moves pos so the old cells stay
	var h: PackedFloat32Array = src[0]
	var w: PackedByteArray = src[1]
	var o: PackedByteArray = src[2]
	var oh := PackedFloat32Array()
	oh.resize((ng.x + 1) * (ng.y + 1))
	var ow := PackedByteArray()
	ow.resize(oh.size() * 4)
	var oo := PackedByteArray()
	oo.resize(ng.x * ng.y)
	for iz in ng.y + 1:
		var sz := clampi(iz - shift.y, 0, g.y)
		for ix in ng.x + 1:
			var s := sz * (g.x + 1) + clampi(ix - shift.x, 0, g.x)
			var t := iz * (ng.x + 1) + ix
			oh[t] = h[s]
			for k in 4:
				ow[t * 4 + k] = w[s * 4 + k]
			var ox := ix - shift.x
			var oz := iz - shift.y
			if ix < ng.x and iz < ng.y:
				if ox >= 0 and oz >= 0 and ox < g.x and oz < g.y:
					oo[iz * ng.x + ix] = o[oz * g.x + ox]
				elif new_holes:
					oo[iz * ng.x + ix] = 1
	d["cells"] = [ng.x, ng.y]
	heights[d["id"]] = oh
	weights[d["id"]] = ow
	holes[d["id"]] = oo
	_changed(d)

# ---------------------------------------------------------------- Ctrl+drag a side: grow / shrink

var face := {}   # the side being dragged: node, axis (0 x / 2 z), sign, point, normal, start {pos, cells, grids}, last

func face_hit(mp: Vector2) -> Dictionary:
	# the nearest side of a selected terrain's box under the mouse (from inside: the side it looks at)
	if editing():
		return {}
	var wo: Vector3 = main.camera.project_ray_origin(mp)
	var wdir: Vector3 = main.camera.project_ray_normal(mp)
	var best := {}
	for n in main.selection:
		if not is_instance_valid(n) or not is_terrain(n):
			continue
		var b := _bounds(n)
		var o: Vector3 = n.to_local(wo)
		var t_in := -INF
		var t_out := INF
		var ax_in := -1
		var ax_out := -1
		var ok := true
		for a in 3:
			if absf(wdir[a]) < 1e-9:
				if o[a] < b.position[a] or o[a] > b.end[a]:
					ok = false
				continue
			var t1: float = (b.position[a] - o[a]) / wdir[a]
			var t2: float = (b.end[a] - o[a]) / wdir[a]
			if minf(t1, t2) > t_in:
				t_in = minf(t1, t2)
				ax_in = a
			if maxf(t1, t2) < t_out:
				t_out = maxf(t1, t2)
				ax_out = a
		if not ok or t_in > t_out or t_out < 0:
			continue
		var inside := t_in < 0
		var t := t_out if inside else t_in
		var a: int = ax_out if inside else ax_in
		var sgn := signf(wdir[a]) if inside else -signf(wdir[a])
		if a == 1:
			# through the top / bottom (looking down on it): a side, when the ground under the mouse is near an edge,
			# inside or just outside (within ~3 % of the view distance: about the same few pixels near or far)
			var p: Variant = _ground_point(n, wo, wdir)
			if p == null:
				continue
			t = wo.distance_to(n.to_global(p))
			var margin := maxf(0.5, t * 0.03)
			var gaps := [absf(p.x - b.position.x), absf(b.end.x - p.x), absf(p.z - b.position.z), absf(b.end.z - p.z)]
			var along_ok := [p.z > b.position.z - margin and p.z < b.end.z + margin, p.x > b.position.x - margin and p.x < b.end.x + margin]
			var k := -1
			for j in 4:
				if along_ok[j / 2] and gaps[j] <= margin and (k < 0 or gaps[j] < gaps[k]):
					k = j
			if k < 0:
				continue
			a = 0 if k < 2 else 2
			sgn = -1.0 if k % 2 == 0 else 1.0
		if not best.is_empty() and t >= best["t"]:
			continue
		var nl := Vector3.ZERO
		nl[a] = sgn
		best = {"node": n, "axis": a, "sign": sgn, "t": t, "point": wo + wdir * t, "normal": nl, "sel": true}
	return best

func _ground_point(n: Node3D, wo: Vector3, wdir: Vector3) -> Variant:
	# where the ray meets the terrain's ground (its own frame), else its mean height's plane (just off its edge); null: neither
	var p: Variant = ray_ground(n, wo, wdir)
	if p != null:
		return p
	var o := n.to_local(wo)
	if absf(wdir.y) < 1e-6:
		return null
	var h: PackedFloat32Array = heights[(n.get_meta("data") as Dictionary)["id"]]
	var mean := 0.0
	for v in h:
		mean += v
	var y: float = mean / h.size() * main.CM
	var t := (y - o.y) / wdir.y
	return o + wdir * t if t > 0 else null

func ray_ground(n: Node3D, wo: Vector3, wdir: Vector3) -> Variant:
	# the first point where the ray meets the height grid (its frame, metres; holes count as ground, so they can be
	# filled back), marching through its box and refining by halves; null: it misses
	var b := _bounds(n)
	var o: Vector3 = n.to_local(wo)
	var t0 := 0.0
	var t1 := INF
	for a in 3:
		if absf(wdir[a]) < 1e-9:
			if o[a] < b.position[a] or o[a] > b.end[a]:
				return null
			continue
		var ta: float = (b.position[a] - o[a]) / wdir[a]
		var tb: float = (b.end[a] - o[a]) / wdir[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t0 > t1:
		return null
	var d: Dictionary = n.get_meta("data")
	var step: float = float(d["cell"]) * main.CM * 0.4
	var prev := t0
	var above := _above(n, o + wdir * t0)
	var t := t0
	while t < t1:
		t = minf(t + step, t1)
		var now := _above(n, o + wdir * t)
		if above > 0.0 and now <= 0.0:
			var lo := prev
			var hi := t
			for _i in 12:
				var mid := (lo + hi) / 2
				if _above(n, o + wdir * mid) > 0.0:
					lo = mid
				else:
					hi = mid
			return o + wdir * hi
		prev = t
		above = now
	return null

func _above(n: Node3D, p: Vector3) -> float:
	return p.y - height_at(n, p.x, p.z)

func height_at(n: Node3D, x: float, z: float) -> float:
	# the ground's height (metres, its frame) at x, z: the cell's two triangles, as drawn
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var c: float = float(d["cell"]) * main.CM
	var fx := clampf(x / c, 0.0, g.x - 0.0001)
	var fz := clampf(z / c, 0.0, g.y - 0.0001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var h: PackedFloat32Array = heights[d["id"]]
	var w := g.x + 1
	var a := h[iz * w + ix]
	var b := h[iz * w + ix + 1]
	var cc := h[(iz + 1) * w + ix]
	var dd := h[(iz + 1) * w + ix + 1]
	var y := a + (b - a) * tx + (cc - a) * tz if tx + tz <= 1.0 else dd + (cc - dd) * (1.0 - tx) + (b - dd) * (1.0 - tz)
	return y * main.CM

func begin_face(hit: Dictionary, _extrude := false) -> void:
	face = hit.duplicate()
	var d: Dictionary = hit["node"].get_meta("data")
	face["start"] = {"pos": (d["pos"] as Array).duplicate(), "cells": dims(d),
		"grids": [heights[d["id"]], weights[d["id"]], holes[d["id"]]]}
	face["t0"] = 0.0
	face["last"] = 0

func _along(mp: Vector2) -> float:
	var o: Vector3 = main.camera.project_ray_origin(mp)
	var dir: Vector3 = main.camera.project_ray_normal(mp)
	var n: Vector3 = face["normal"]
	var w: Vector3 = face["point"] - o
	var b := n.dot(dir)
	var den := 1.0 - b * b
	if den < 1e-6:
		return 0.0
	return (b * dir.dot(w) - n.dot(w)) / den

func drag_face(mp: Vector2, _snap: bool) -> void:
	# whole cells out (or in) along the side's normal; the other sides stay put
	var n: Node3D = face["node"]
	var d: Dictionary = n.get_meta("data")
	var c := float(d["cell"])
	var k := roundi(_along(mp) / main.CM / c)
	if k == face["last"]:
		return
	var st: Dictionary = face["start"]
	var g: Vector2i = st["cells"]
	var i := 0 if face["axis"] == 0 else 1
	var ng := g
	ng[i] = clampi(g[i] + k, 1, MAX_CELLS)
	k = ng[i] - g[i]
	face["last"] = k
	var shift := Vector2i.ZERO
	var pos: Array = (st["pos"] as Array).duplicate()
	if face["sign"] < 0:   # the near side: cells added before the old ones, the corner moves out
		shift[i] = k
		pos[face["axis"]] = float(pos[face["axis"]]) - k * c
	d["pos"] = pos
	_resize(d, st["grids"], g, shift, ng)
	main._place(n)
	_refresh(n)

func end_face() -> void:
	face = {}

# ---------------------------------------------------------------- edit mode: tools and brushes

var edit_node: Node3D = null
var tool := "height"
var brush_size := 8.0       # radius, metres
var brush_strength := 0.5
var brush_falloff := 0.5    # 0 = hard edge, 1 = soft all the way in
var pen_size := false
var pen_strength := false
var layer := 1              # the paint / fill layer (0 = base)
var hole_add := false       # the holes tool adds ground (and grows the terrain past its edge) instead of cutting
var hole_row: HBoxContainer
var hole_mode: OptionButton
var bar: PanelContainer
var bar_layer: CanvasLayer
var tool_buttons := {}
var size_slider: HSlider
var strength_slider: HSlider
var falloff_slider: HSlider
var pen_size_check: CheckBox
var pen_strength_check: CheckBox
var layer_pick: OptionButton
var layer_mat: OptionButton
var layer_tile: SpinBox
var paint_row: HBoxContainer
var rule_row: HBoxContainer
var rule_on: CheckBox
var rule_spins: Array = []
var fill_row: HBoxContainer
var dmg_row: HBoxContainer
var dmg_on: CheckBox
var dmg_spins := {}     # player / vs: % per second
var dmg_kills := {}     # player / vs: kill at once
var slope_lo: SpinBox
var slope_hi: SpinBox
var hint: Label
var cursor: MeshInstance3D
var _stroke := false
var _mouse := Vector2.ZERO
var _pressure := 1.0
var _tablet := false        # a pen has reported pressure (a mouse reports none: full strength)
var _flatten_to := NAN      # Ctrl+height: the height where the stroke began (cm)
var _stroke_rect := Rect2i()  # the cells a stroke touched (its pick shape is rebuilt at the end)
var _resume_id := ""
var _hidden: Array = []     # [node, was visible] hidden by edit mode
var _grey: StandardMaterial3D

func editing() -> bool:
	return edit_node != null and is_instance_valid(edit_node)

func edit_id() -> String:
	return str(edit_node.get_meta("data")["id"]) if editing() else ""

func resume_after_restore(id: String) -> void:
	# undo / redo rebuild the level's nodes: edit mode picks the terrain up again once its node is back
	_hidden = []
	edit_node = null
	_resume_id = id

func start_edit(n: Node3D) -> void:
	if editing():
		stop_edit()
	edit_node = n
	main.select([n])
	set_selected(n, true)
	if _grey == null:
		_grey = StandardMaterial3D.new()
		_grey.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_grey.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_grey.albedo_color = Color(0.3, 0.3, 0.33, 0.8)
	_hidden = []
	for m in main.markers_root.get_children():
		if m == n:
			continue
		if is_terrain(m):   # other terrains: greyed like the level (edges to match), not hidden
			_grey_geometry(m.get_child(0), true)
			set_selected(m, false)
		else:
			_hidden.append([m, m.visible])
			m.visible = false
	_grey_geometry(main.geometry, true)
	main.gizmo.visible = false
	_make_bar()
	bar_layer.visible = true
	_show_layer()
	_set_tool(tool)
	if cursor == null or not is_instance_valid(cursor):
		cursor = MeshInstance3D.new()
		cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cm := StandardMaterial3D.new()
		cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cm.no_depth_test = true
		cm.albedo_color = Color(1, 1, 1, 0.9)
		cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		cursor.material_override = cm
		cursor.mesh = ImmediateMesh.new()
	if cursor.get_parent():
		cursor.get_parent().remove_child(cursor)
	n.add_child(cursor)
	cursor.visible = false
	main.log_line("Editing %s: the level is locked; Esc or Done when finished." % n.get_meta("data").get("name", "the terrain"))

func stop_edit() -> void:
	if not editing():   # its node is gone (undo, a layout switch): just undo the locking
		edit_node = null
		_resume_id = ""
		if bar_layer:
			bar_layer.visible = false
		_grey_geometry(main.geometry, false)
		for m in main.markers_root.get_children():
			if is_terrain(m):
				_grey_geometry(m.get_child(0), false)
		main.apply_marker_visibility()
		return
	if _stroke:
		_end_stroke()
	var n := edit_node
	edit_node = null
	for h in _hidden:
		if is_instance_valid(h[0]):
			h[0].visible = h[1]
	_hidden = []
	main.apply_marker_visibility()   # the view toggles' own hiding
	_grey_geometry(main.geometry, false)
	for m in main.markers_root.get_children():
		if is_terrain(m):
			_grey_geometry(m.get_child(0), false)
	if cursor and is_instance_valid(cursor):
		cursor.visible = false
	bar_layer.visible = false
	if is_instance_valid(n):
		_materials_to_shader(n)
		set_selected(n, main.selection.has(n))
		show_inspector(main.selection)
	main._place_gizmo()

func _grey_geometry(root: Node, on: bool) -> void:
	for c in root.get_children():
		if c is GeometryInstance3D:
			(c as GeometryInstance3D).material_overlay = _grey if on else null
		_grey_geometry(c, on)

func handle_input(e: InputEvent) -> bool:
	# edit mode's input (true: used); the camera's buttons and the wheel pass through
	if e is InputEventKey and e.pressed and not e.echo:
		var k: Key = e.keycode
		if k == KEY_ESCAPE:
			stop_edit()
			return true
		if not e.ctrl_pressed and k >= KEY_1 and k <= KEY_5:
			_set_tool(TOOLS[k - KEY_1][0])
			return true
		if k == KEY_BRACKETLEFT or k == KEY_BRACKETRIGHT:
			size_slider.value *= 0.8 if k == KEY_BRACKETLEFT else 1.25
			return true
		if k in [KEY_DELETE, KEY_BACKSPACE, KEY_END] or (e.ctrl_pressed and k in [KEY_D, KEY_G]):
			return true   # no deleting, duplicating or grouping while the level is locked
		return false
	if e is InputEventMouseMotion:
		_mouse = e.position
		if e.pressure > 0.0 and e.pressure < 1.0:
			_tablet = true
		_pressure = e.pressure if _tablet else 1.0
		_update_cursor()
		return _stroke
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_mouse = e.position
		if e.pressed:
			var p: Variant = _brush_point()
			if p == null:
				return true
			main._push_undo("")
			_detach(edit_node.get_meta("data"))
			if tool == "fill":
				_bucket(p)
				return true
			_stroke = true
			_stroke_rect = Rect2i()
			_flatten_to = height_at(edit_node, p.x, p.z) / main.CM
			_apply(1.0 / 60.0)
		elif _stroke:
			_end_stroke()
		return true
	return false

func _process(dt: float) -> void:
	if not editing():
		if edit_node != null:   # its node went (undo rebuilt the level and it was not found): leave
			stop_edit()
		return
	if _stroke:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_end_stroke()
		else:
			_apply(minf(dt, 0.1))

func _end_stroke() -> void:
	_stroke = false
	if editing():
		edit_node.remove_meta("y_range")   # exact again (smoothing may have lowered the top)
		update_shape(edit_node)
		_update_box(edit_node)
		show_inspector(main.selection)

func _brush() -> Array:
	# [radius m, strength] now (pen pressure scales whichever is ticked)
	var r := brush_size * (lerpf(0.15, 1.0, _pressure) if pen_size else 1.0)
	var s := brush_strength * (_pressure if pen_strength else 1.0)
	return [r, s]

func _fall(dist: float, r: float) -> float:
	# 1 inside the hard core, easing to 0 at the edge
	var core := r * (1.0 - brush_falloff)
	if dist <= core:
		return 1.0
	if dist >= r:
		return 0.0
	var t := (dist - core) / maxf(r - core, 1e-6)
	return 1.0 - t * t * (3.0 - 2.0 * t)

func _apply(dt: float) -> void:
	var n := edit_node
	var p: Variant = _brush_point()
	if p == null:
		return
	var bs := _brush()
	var r: float = bs[0]
	var s: float = bs[1]
	var adding := _adding()
	if adding:
		p = _grow_to(n, p, r)
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var c: float = float(d["cell"]) * main.CM
	var x0 := clampi(floori((p.x - r) / c), 0, g.x)
	var x1 := clampi(ceili((p.x + r) / c), 0, g.x)
	var z0 := clampi(floori((p.z - r) / c), 0, g.y)
	var z1 := clampi(ceili((p.z + r) / c), 0, g.y)
	var w := g.x + 1
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var cells := Rect2i(maxi(x0 - 1, 0), maxi(z0 - 1, 0), mini(x1 + 1, g.x) - maxi(x0 - 1, 0), mini(z1 + 1, g.y) - maxi(z0 - 1, 0))
	match tool:
		"height", "smooth":
			var h: PackedFloat32Array = heights[d["id"]]
			var src := h.duplicate() if tool == "smooth" else h
			var flat := tool == "height" and Input.is_key_pressed(KEY_CTRL)
			for iz in range(z0, z1 + 1):
				for ix in range(x0, x1 + 1):
					var f := _fall(Vector2(ix * c - p.x, iz * c - p.z).length(), r) * s
					if f <= 0.0:
						continue
					var i := iz * w + ix
					if tool == "smooth":
						var avg := (src[iz * w + maxi(ix - 1, 0)] + src[iz * w + mini(ix + 1, g.x)] + src[maxi(iz - 1, 0) * w + ix] + src[mini(iz + 1, g.y) * w + ix]) / 4.0
						h[i] = lerpf(h[i], avg, clampf(f * dt * 12.0, 0.0, 1.0))
					elif flat:
						h[i] = lerpf(h[i], _flatten_to, clampf(f * dt * 8.0, 0.0, 1.0))
					else:
						h[i] += (-1.0 if shift else 1.0) * f * HEIGHT_RATE * dt
			heights[d["id"]] = h
			var yr: Vector2 = n.get_meta("y_range") if n.has_meta("y_range") else Vector2(INF, -INF)
			for iz in range(z0, z1 + 1):
				for ix in range(x0, x1 + 1):
					yr = Vector2(minf(yr.x, h[iz * w + ix]), maxf(yr.y, h[iz * w + ix]))
			n.set_meta("y_range", yr)
			_rebuild_chunks(n, cells)
			if not slope_rules(d).is_empty():
				_layer_map(n, cells.grow(1))
		"paint":
			var pts := PackedInt32Array()
			var amounts := PackedFloat32Array()
			for iz in range(z0, z1 + 1):
				for ix in range(x0, x1 + 1):
					var f := _fall(Vector2(ix * c - p.x, iz * c - p.z).length(), r) * s
					if f > 0.0:
						pts.append(iz * w + ix)
						amounts.append(clampf(f * PAINT_RATE * dt, 0.0, 1.0))
			weights[d["id"]] = _blend(weights[d["id"]], pts, amounts, 0 if shift else layer)
			_layer_map(n, cells)
		"holes":
			var o: PackedByteArray = holes[d["id"]]
			for iz in range(maxi(z0 - 1, 0), mini(z1 + 1, g.y)):
				for ix in range(maxi(x0 - 1, 0), mini(x1 + 1, g.x)):
					if _fall(Vector2((ix + 0.5) * c - p.x, (iz + 0.5) * c - p.z).length(), r) >= 0.5:
						o[iz * g.x + ix] = 0 if adding else 1
			holes[d["id"]] = o
			_layer_map(n, cells)
	_stroke_rect = cells if _stroke_rect.size == Vector2i.ZERO else _stroke_rect.merge(cells)
	_changed(d)
	_update_cursor()

static func _blend(wt: PackedByteArray, pts: PackedInt32Array, amounts: PackedFloat32Array, to: int) -> PackedByteArray:
	# each point's five weights its amount of the way towards all-`to` (0 = the base: every paint layer fades);
	# -> the array (edited in place; callers detach first)
	for j in pts.size():
		var i := pts[j]
		for k in 4:
			var v: float = wt[i * 4 + k]
			var target := 255.0 if k + 1 == to else 0.0
			wt[i * 4 + k] = clampi(roundi(lerpf(v, target, amounts[j])), 0, 255)
	return wt

func _bucket(p: Vector3) -> void:
	# the cells touching the clicked one with the same layer (or all holes) take the chosen layer
	var n := edit_node
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var c: float = float(d["cell"]) * main.CM
	var start := Vector2i(clampi(int(p.x / c), 0, g.x - 1), clampi(int(p.z / c), 0, g.y - 1))
	var wt: PackedByteArray = weights[d["id"]]
	var o: PackedByteArray = holes[d["id"]]
	var eff: PackedByteArray = n.get_meta("eff")   # as shown (paint + slope rules)
	var kind := func(v: Vector2i) -> int: return -1 if o[v.y * g.x + v.x] else cell_layer(eff, g, v.x, v.y)
	var want: int = kind.call(start)
	var seen := {start: true}
	var todo := [start]
	var region: Array = []
	while not todo.is_empty():
		var v: Vector2i = todo.pop_back()
		region.append(v)
		for dv in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = v + dv
			if q.x >= 0 and q.y >= 0 and q.x < g.x and q.y < g.y and not seen.has(q) and kind.call(q) == want:
				seen[q] = true
				todo.append(q)
	var w := g.x + 1
	var pts := PackedInt32Array()
	for v in region:
		pts.append_array([v.y * w + v.x, v.y * w + v.x + 1, (v.y + 1) * w + v.x, (v.y + 1) * w + v.x + 1])
	var ones := PackedFloat32Array()
	ones.resize(pts.size())
	ones.fill(1.0)
	weights[d["id"]] = _blend(wt, pts, ones, layer)
	_changed(d)
	_layer_map(n, Rect2i(0, 0, g.x, g.y))
	main.log_line("Filled %d cells with layer %d." % [region.size(), layer])

func fill_slope(lo_deg: float, hi_deg: float) -> void:
	# every point whose slope is within lo..hi degrees takes the chosen layer (e.g. rock on 35-90: the cliffs)
	if not editing():
		return
	var n := edit_node
	main._push_undo("")
	var d: Dictionary = n.get_meta("data")
	_detach(d)
	var g := dims(d)
	var c: float = float(d["cell"])
	var h: PackedFloat32Array = heights[d["id"]]
	var w := g.x + 1
	var pts := PackedInt32Array()
	for iz in g.y + 1:
		for ix in w:
			var dx := (h[iz * w + mini(ix + 1, g.x)] - h[iz * w + maxi(ix - 1, 0)]) / (float(mini(ix + 1, g.x) - maxi(ix - 1, 0)) * c)
			var dz := (h[mini(iz + 1, g.y) * w + ix] - h[maxi(iz - 1, 0) * w + ix]) / (float(mini(iz + 1, g.y) - maxi(iz - 1, 0)) * c)
			var deg := rad_to_deg(atan(Vector2(dx, dz).length()))
			if deg >= lo_deg and deg <= hi_deg:
				pts.append(iz * w + ix)
	var ones := PackedFloat32Array()
	ones.resize(pts.size())
	ones.fill(1.0)
	weights[d["id"]] = _blend(weights[d["id"]], pts, ones, layer)
	var count := pts.size()
	_changed(d)
	_layer_map(n, Rect2i(0, 0, g.x, g.y))
	main.log_line("Slope fill: %d points at %d-%d degrees took layer %d." % [count, int(lo_deg), int(hi_deg), layer])

func _adding() -> bool:
	return tool == "holes" and hole_add != Input.is_key_pressed(KEY_SHIFT)

func _brush_point() -> Variant:
	# the brush's centre under the mouse (the terrain's frame): on the ground; adding ground, also past the edge (on
	# the level of the edge nearest the mouse)
	var wo: Vector3 = main.camera.project_ray_origin(_mouse)
	var wdir: Vector3 = main.camera.project_ray_normal(_mouse)
	var p: Variant = ray_ground(edit_node, wo, wdir)
	if p != null or not _adding():
		return p
	var o := edit_node.to_local(wo)
	if absf(wdir.y) < 1e-6:
		return null
	var y: float = _bounds(edit_node).get_center().y
	for _i in 3:   # settle on the height of the edge below where the ray meets that level
		var t := (y - o.y) / wdir.y
		if t <= 0:
			return null
		var q := o + wdir * t
		y = height_at(edit_node, q.x, q.z)
	var t2 := (y - o.y) / wdir.y
	return o + wdir * t2 if t2 > 0 else null

func _grow_to(n: Node3D, p: Vector3, r: float) -> Vector3:
	# adding ground past the edge: the grid grows (whole cells, a few spare) to take the brush; new cells start as
	# holes, new points take the nearest edge's height and paint -> p in the moved frame
	var d: Dictionary = n.get_meta("data")
	var g := dims(d)
	var c: float = float(d["cell"]) * main.CM
	var lo := Vector2i(floori((p.x - r) / c), floori((p.z - r) / c))
	var hi := Vector2i(ceili((p.x + r) / c), ceili((p.z + r) / c))
	if lo.x >= 0 and lo.y >= 0 and hi.x <= g.x and hi.y <= g.y:
		return p
	var shift := Vector2i(maxi(0, -lo.x + 4) if lo.x < 0 else 0, maxi(0, -lo.y + 4) if lo.y < 0 else 0)
	var ng := Vector2i(g.x + shift.x + (hi.x - g.x + 4 if hi.x > g.x else 0), g.y + shift.y + (hi.y - g.y + 4 if hi.y > g.y else 0))
	ng = Vector2i(mini(ng.x, MAX_CELLS), mini(ng.y, MAX_CELLS))
	shift = Vector2i(mini(shift.x, ng.x - g.x), mini(shift.y, ng.y - g.y))
	if ng == g:
		return p   # at the size limit
	_resize(d, [heights[d["id"]], weights[d["id"]], holes[d["id"]]], g, shift, ng, true)
	var pos: Array = d["pos"]
	d["pos"] = [float(pos[0]) - shift.x * float(d["cell"]), float(pos[1]), float(pos[2]) - shift.y * float(d["cell"])]
	main._place(n)
	update_marker(n)
	return p + Vector3(shift.x * c, 0, shift.y * c)

func _update_cursor() -> void:
	if not editing() or cursor == null:
		return
	var p: Variant = _brush_point()
	cursor.visible = p != null and tool != "fill"
	if p == null:
		return
	var bs := _brush()
	var im := cursor.mesh as ImmediateMesh
	im.clear_surfaces()
	for ring in [bs[0], bs[0] * (1.0 - brush_falloff)]:
		if ring < 0.05:
			continue
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for i in 49:
			var a := TAU * i / 48.0
			var q := Vector3(p.x + cos(a) * ring, 0, p.z + sin(a) * ring)
			q.y = height_at(edit_node, q.x, q.z) + 0.08
			im.surface_add_vertex(q)
		im.surface_end()

# ---------------------------------------------------------------- the toolbar

func _make_bar() -> void:
	if bar_layer:
		return
	bar_layer = CanvasLayer.new()
	bar_layer.layer = 1
	main.add_child(bar_layer)
	bar = PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.offset_top = 76.0   # under the editor's two top bars
	bar_layer.add_child(bar)
	var v := VBoxContainer.new()
	bar.add_child(v)
	var row := HBoxContainer.new()
	v.add_child(row)
	var grp := ButtonGroup.new()
	for i in TOOLS.size():
		var t: Array = TOOLS[i]
		var b := Button.new()
		b.text = "%d %s" % [i + 1, t[1]]
		b.tooltip_text = t[2]
		b.toggle_mode = true
		b.button_group = grp
		b.pressed.connect(_set_tool.bind(t[0]))
		row.add_child(b)
		tool_buttons[t[0]] = b
	row.add_child(VSeparator.new())
	size_slider = _slider(row, "Size", 0.5, 100.0, brush_size, _on_brush.bind("size"), "Brush radius in metres ([ and ] change it)", true)
	pen_size_check = _check(row, "Pen", "Pen pressure sets the size", _on_pen.bind("size"))
	strength_slider = _slider(row, "Strength", 0.02, 1.0, brush_strength, _on_brush.bind("strength"), "How fast it works")
	pen_strength_check = _check(row, "Pen", "Pen pressure sets the strength", _on_pen.bind("strength"))
	falloff_slider = _slider(row, "Falloff", 0.0, 1.0, brush_falloff, _on_brush.bind("falloff"), "0: hard edge; 1: soft from the middle (the inner ring)")
	row.add_child(VSeparator.new())
	var done := Button.new()
	done.text = "Done"
	done.tooltip_text = "Leave terrain editing (Esc)"
	done.pressed.connect(stop_edit)
	row.add_child(done)
	paint_row = HBoxContainer.new()
	v.add_child(paint_row)
	paint_row.add_child(main._label("Layer"))
	layer_pick = OptionButton.new()
	layer_pick.tooltip_text = "What paint and fill lay down (the base is under everything; Shift+paint erases back to it)"
	layer_pick.item_selected.connect(func(i): layer = i; _show_layer())
	paint_row.add_child(layer_pick)
	paint_row.add_child(main._label("Material"))
	layer_mat = OptionButton.new()
	layer_mat.item_selected.connect(func(_i): _on_layer_changed())
	paint_row.add_child(layer_mat)
	paint_row.add_child(main._label("Tile (m)"))
	layer_tile = main._spin(0.25, 256.0, 0.25)
	layer_tile.value_changed.connect(func(_v): _on_layer_changed())
	paint_row.add_child(layer_tile)
	rule_row = HBoxContainer.new()
	v.add_child(rule_row)
	rule_on = CheckBox.new()
	rule_on.text = "Auto by slope"
	rule_on.tooltip_text = "This layer also covers every slope in the range, live: re-sculpting re-paints it (e.g. rock 35-90 with a 5 degree soft edge). Brush paint still adds to it"
	rule_on.toggled.connect(func(_b): _on_layer_changed())
	rule_row.add_child(rule_on)
	for x in [["from", 35.0], ["to", 90.0], ["soft", 5.0]]:
		rule_row.add_child(main._label(x[0]))
		var sp: SpinBox = main._spin(0.0, 90.0, 1.0)
		sp.value = x[1]
		sp.suffix = "deg"
		sp.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		sp.custom_minimum_size.x = 90
		sp.value_changed.connect(func(_v): _on_layer_changed())
		rule_row.add_child(sp)
		rule_spins.append(sp)
	dmg_row = HBoxContainer.new()
	v.add_child(dmg_row)
	dmg_on = CheckBox.new()
	dmg_on.text = "Damage"
	dmg_on.tooltip_text = "Where this layer is the strongest, the ground hurts (lava, acid): % of full health per second for players and VS, or Kill at once (xlive mod; boxes over its cells when the map is built)"
	dmg_on.toggled.connect(func(_b): _on_layer_changed())
	dmg_row.add_child(dmg_on)
	for x in [["player", "players %/s", 0.0, true], ["vs", "VS %/s", 10.0, false]]:
		dmg_row.add_child(main._label(x[1]))
		var sp: SpinBox = main._spin(0.0, 100.0, 1.0)
		sp.value = x[2]
		sp.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		sp.custom_minimum_size.x = 80
		sp.value_changed.connect(func(_v): _on_layer_changed())
		dmg_row.add_child(sp)
		var kc := CheckBox.new()
		kc.text = "Kill"
		kc.button_pressed = x[3]
		kc.toggled.connect(func(_b): _on_layer_changed())
		dmg_row.add_child(kc)
		dmg_spins[x[0]] = sp
		dmg_kills[x[0]] = kc
	fill_row = HBoxContainer.new()
	paint_row.add_child(fill_row)
	fill_row.add_child(VSeparator.new())
	fill_row.add_child(main._label("Slope"))
	slope_lo = main._spin(0.0, 90.0, 1.0)
	slope_lo.value = 35.0
	fill_row.add_child(slope_lo)
	fill_row.add_child(main._label("to"))
	slope_hi = main._spin(0.0, 90.0, 1.0)
	slope_hi.value = 90.0
	fill_row.add_child(slope_hi)
	var sb := Button.new()
	sb.text = "Fill by slope"
	sb.tooltip_text = "Every point this steep (degrees) takes the layer: e.g. rock on 35-90 for cliffs"
	sb.pressed.connect(func(): fill_slope(slope_lo.value, slope_hi.value))
	fill_row.add_child(sb)
	hole_row = HBoxContainer.new()
	v.add_child(hole_row)
	hole_row.add_child(main._label("Brush"))
	hole_mode = OptionButton.new()
	hole_mode.add_item("Cut holes")
	hole_mode.add_item("Add ground (grows past the edge)")
	hole_mode.tooltip_text = "Shift swaps them while painting"
	hole_mode.item_selected.connect(func(i): hole_add = i == 1; _update_cursor())
	hole_row.add_child(hole_mode)
	hint = main._label("")
	v.add_child(hint)

func _on_brush(x: float, what: String) -> void:
	match what:
		"size": brush_size = x
		"strength": brush_strength = x
		"falloff": brush_falloff = x
	_update_cursor()

func _on_pen(on: bool, what: String) -> void:
	if what == "size":
		pen_size = on
	else:
		pen_strength = on

func _slider(row: HBoxContainer, text: String, lo: float, hi: float, value: float, on: Callable, tip: String, exp := false) -> HSlider:
	row.add_child(main._label(text))
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.01
	s.exp_edit = exp
	s.value = value
	s.custom_minimum_size = Vector2(80, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.tooltip_text = tip
	s.value_changed.connect(on)
	row.add_child(s)
	return s

func _check(row: HBoxContainer, text: String, tip: String, on: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.toggled.connect(on)
	row.add_child(c)
	return c

func _set_tool(t: String) -> void:
	tool = t
	if tool_buttons.has(t):
		(tool_buttons[t] as Button).button_pressed = true
	paint_row.visible = t in ["paint", "fill"]
	rule_row.visible = t in ["paint", "fill"] and layer > 0
	dmg_row.visible = t in ["paint", "fill"]
	fill_row.visible = t == "fill"
	hole_row.visible = t == "holes"
	for x in TOOLS:
		if x[0] == t:
			hint.text = x[2]
	if editing():
		_materials_to_shader(edit_node)   # holes show as red while the holes tool is on
		_update_cursor()

func _show_layer() -> void:
	if not editing() or layer_pick == null:
		return
	var d: Dictionary = edit_node.get_meta("data")
	updating = true
	layer_pick.clear()
	for k in LAYERS:
		var li := layer_info(d, k)
		layer_pick.add_item(("Base" if k == 0 else "Layer %d" % k) + ": " + (str(li["material"]) if li["material"] != "" else "blockout"))
	layer = clampi(layer, 0, LAYERS - 1)
	layer_pick.selected = layer
	var li := layer_info(d, layer)
	_fill_materials(layer_mat, str(li["material"]))
	layer_tile.value = float(li["tile"])
	layer_tile.editable = str(li["material"]) != ""
	var sl: Dictionary = li.get("slope", {}) if li.get("slope") is Dictionary else {}
	rule_on.button_pressed = sl.get("on", false)
	rule_spins[0].value = float(sl.get("min", 35.0))
	rule_spins[1].value = float(sl.get("max", 90.0))
	rule_spins[2].value = float(sl.get("soft", 5.0))
	rule_row.visible = tool in ["paint", "fill"] and layer > 0
	var dm: Dictionary = li.get("damage", {}) if li.get("damage") is Dictionary else {}
	dmg_on.button_pressed = not dm.is_empty()
	if not dm.is_empty():
		for k in dmg_spins:
			dmg_spins[k].value = float(dm.get(k, 0.0))
			dmg_kills[k].button_pressed = dm.get(k + "_kill", false)
	for k in dmg_spins:
		dmg_spins[k].editable = dmg_on.button_pressed and not dmg_kills[k].button_pressed
		dmg_kills[k].disabled = not dmg_on.button_pressed
	updating = false

func _on_layer_changed() -> void:
	if updating or not editing():
		return
	main._push_undo("terrain-layer")
	var d: Dictionary = edit_node.get_meta("data")
	var mname := "" if layer_mat.selected <= 0 else layer_mat.get_item_text(layer_mat.selected)
	var dm := {}
	if dmg_on.button_pressed:
		for k in dmg_spins:
			dm[k] = dmg_spins[k].value
			if dmg_kills[k].button_pressed:
				dm[k + "_kill"] = true
	if layer == 0:
		d["material"] = mname
		d["tile"] = layer_tile.value
		if dm.is_empty():
			d.erase("damage")
		else:
			d["damage"] = dm
	else:
		var ls: Array = d.get("layers", [])
		while ls.size() < layer:
			ls.append({"material": "", "tile": 4.0})
		ls[layer - 1] = {"material": mname, "tile": layer_tile.value}
		if rule_on.button_pressed:
			ls[layer - 1]["slope"] = {"on": true, "min": rule_spins[0].value, "max": rule_spins[1].value, "soft": rule_spins[2].value}
		if not dm.is_empty():
			ls[layer - 1]["damage"] = dm
		d["layers"] = ls
	_changed(d)
	_materials_to_shader(edit_node)
	var g := dims(d)
	_layer_map(edit_node, Rect2i(0, 0, g.x, g.y), true)   # the rules changed: every point
	_show_layer()
