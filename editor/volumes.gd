extends Node
# Volumes: axis-aligned boxes placed in the level (project "volumes"), shown as translucent markers. A box carries
# any mix of effects:
#   "kill": true      the game's kill surface over the box's top (lp2mapc: a 0x200 quad in the bullet collision);
#                     the game checks it while players fall, so a pit's box kills whoever drops into it
#   "gravity": x      characters inside get their gravity multiplied (map.json "gravity_volumes", xlive mod)
#   "post": {tint, brightness, saturation, contrast, fade}
#                     the screen is colour graded while the camera is inside (map.json "post_volumes", xlive mod);
#                     fade: seconds to fade in on entering / out on leaving (0 = instant)
#   "weather": pct    the map's rain / snow / ash at pct % inside (0 = none: indoors; 5 = a few drips in a shack);
#                     lp2mapc: a weather zone in the scene box, like stock maps' interiors (older: "no_weather": true)
#   "water": true     water up to the box's top: what's inside is underwater (characters lighter, weapons, splashes;
#                     map.json "water_volumes", xlive mod); no visible surface yet
#   "sound": {"reverb": key}  the game's reverb inside (a stock map's preset, REVERBS; lp2sound.py: the game's own
#                     sound zones, no xlive mod); outside, the map's own (environment "sound": {"reverb"}, else the base map's)
# A volume's "pos" is the centre of its floor (cm, like markers), "size" its extent (cm), "yaw" its turn about y
# (degrees, as markers'; the rotate gizmo's ring, the scale gizmo and Ctrl+drag on a face size it in its own axes).
# "boxes": more boxes making one shape (a hangar and its annex): [{"pos": floor centre relative to "pos" in the
# volume's turned frame, "size"}], each grown out of a face with Ctrl+Shift+drag; the effects cover them all
# (lp2mapc expands every box to its own turned box). Selected, its faces and edges also show through the level, dimmed where something is in front.
# Older projects had one "type" (kill / gravity); migrate() turns it into the effect keys, and their no-weather boxes
# (environment.weather.volumes, centred) become volumes (migrate_weather()).

const COLOURS := {"kill": Color(0.95, 0.15, 0.15), "gravity": Color(0.25, 0.55, 1.0), "post": Color(0.75, 0.35, 1.0),
	"weather": Color(0.3, 0.85, 0.8), "water": Color(0.15, 0.4, 0.95), "sound": Color(0.95, 0.7, 0.2),
	"none": Color(0.6, 0.6, 0.6)}
const ADD := [["kill", "Kill volume (pit)"], ["gravity", "Gravity volume"], ["post", "Post-process volume (screen colour)"],
	["weather", "Weather limiter volume (indoors)"], ["water", "Water volume (surface at its top)"],
	["sound", "Sound volume (reverb zone)"]]
# the stock maps' reverb presets (lp2-tools sound_presets.json): key, name (decay time)
const REVERBS := [["15_inside", "Frozen Wasteland, inside (1.5 s)"], ["02_inside", "Kraftwerk, inside: big hall (4.3 s)"],
	["10_inside", "Pirate Fortress, inside (1.2 s)"], ["05_cave", "Thunderpeal Precipice, cave (2.4 s)"],
	["00", "Desecration (1.5 s)"], ["01", "Turbulent Jungle (2.0 s)"], ["02_outside", "Kraftwerk, outside (1.2 s)"],
	["03", "The Great Outdoors (2.0 s)"], ["04", "Dockyard Battle (1.9 s)"], ["05", "Thunderpeal Precipice (2.0 s)"],
	["06", "Dual Complex (2.2 s)"], ["08", "Helix (1.6 s)"], ["09", "Friction (2.1 s)"],
	["10_outside", "Pirate Fortress, outside (1.5 s)"], ["11", "Back to the Island (2.5 s)"], ["12", "Cube (2.5 s)"],
	["15_outside", "Frozen Wasteland, outside (1.9 s)"], ["07", "None: dry (NEOS)"]]
const POST := {"tint": [0.7, 0.85, 1.0], "brightness": 0.9, "saturation": 0.7, "contrast": 1.0, "fade": 0.5}

var main: Node
var box: VBoxContainer       # inspector section (one volume selected)
var kill_on: CheckBox
var gravity_on: CheckBox
var post_on: CheckBox
var weather_on: CheckBox
var water_on: CheckBox
var sound_on: CheckBox
var reverb_pick: OptionButton
var sound_rows: Array = []   # the sound post-process controls, shown while it's on
var size_spins: Array = []
var gravity_spin: SpinBox
var boxes_label: Label
var remove_box: Button
var weather_spin: SpinBox
var post_rows: Array = []    # the post-process controls, shown while it's on
var tint_pick: ColorPickerButton
var post_spins := {}         # brightness / saturation / contrast
var updating := false
var post_overlay: ColorRect   # the post-process preview's tint (multiplies the 3D view, under the panels)
const NEUTRAL := {"tint": Color.WHITE, "brightness": 1.0, "saturation": 1.0, "contrast": 1.0}
var post_now := NEUTRAL.duplicate()   # shown now; fades like the xlive mod's (smoothstep over the volume's fade)
var post_from := NEUTRAL.duplicate()
var post_target: Variant = null       # the volume's data faded towards (null: neutral)
var post_fade := 0.0
var post_t := 1.0                     # 0..1 through the fade

func setup(m: Node, right: VBoxContainer) -> void:
	main = m
	box = VBoxContainer.new()
	box.add_child(main._label("Volume"))
	var g := GridContainer.new()
	g.columns = 2
	for a in ["Width X (cm)", "Height (cm)", "Depth Z (cm)"]:
		g.add_child(main._label(a))
		var s: SpinBox = main._spin(10.0, 1e6, 10.0)
		s.value_changed.connect(func(_v): _on_changed())
		g.add_child(s)
		size_spins.append(s)
	boxes_label = main._label("")
	g.add_child(boxes_label)
	remove_box = Button.new()
	remove_box.text = "Remove last box"
	remove_box.tooltip_text = "Removes the box added last (Ctrl+Shift+drag a face adds one)"
	remove_box.pressed.connect(_remove_box)
	g.add_child(remove_box)
	kill_on = _check(g, "Kill", "Players falling into the box die (its top is a kill surface)")
	g.add_child(Control.new())
	gravity_on = _check(g, "Gravity x", "Characters inside: 1 = normal, 0.3 = NEOS-like, above 1 heavier (xlive mod)")
	gravity_spin = main._spin(0.0, 10.0, 0.05)
	gravity_spin.value_changed.connect(func(_v): _on_changed())
	g.add_child(gravity_spin)
	weather_on = _check(g, "Weather %", "The map's rain / snow / ash inside at this strength (0 = none: indoors, a few % = drips "
		+ "through a leaky roof; the Fog & weather window sets the map's weather)")
	weather_spin = main._spin(0.0, 100.0, 1.0)
	weather_spin.value_changed.connect(func(_v): _on_changed())
	g.add_child(weather_spin)
	water_on = _check(g, "Water", "Water up to the box's top: players inside are underwater (lighter, as on stock water maps; "
		+ "weapons and effects act underwater). No visible surface yet (xlive mod)")
	g.add_child(Control.new())
	sound_on = _check(g, "Sound post-process", "The game's reverb while the player is inside, from a stock map's (outside: the "
		+ "map's own). Combines with the other effects, e.g. a building's weather limiter. The game's own sound zones, no xlive mod")
	g.add_child(Control.new())
	var rl: Label = main._label("  Reverb")
	g.add_child(rl)
	reverb_pick = OptionButton.new()
	for r in REVERBS:
		reverb_pick.add_item(r[1])
	reverb_pick.item_selected.connect(func(_i): _on_changed())
	g.add_child(reverb_pick)
	sound_rows = [rl, reverb_pick]
	post_on = _check(g, "Post-process", "Colour grades the screen while the camera is inside, e.g. murky water (xlive mod)")
	g.add_child(Control.new())
	var tl: Label = main._label("  Tint")
	tint_pick = ColorPickerButton.new()
	tint_pick.edit_alpha = false
	tint_pick.custom_minimum_size = Vector2(150, 24)
	tint_pick.color_changed.connect(func(_c): _on_changed())
	g.add_child(tl)
	g.add_child(tint_pick)
	post_rows = [tl, tint_pick]
	for k in [["brightness", "  Brightness", "1 = unchanged"], ["saturation", "  Saturation", "1 = unchanged, 0 = grey"],
			["contrast", "  Contrast", "1 = unchanged"]]:
		var l: Label = main._label(k[1])
		var s: SpinBox = main._spin(0.0, 3.0, 0.05)
		s.tooltip_text = k[2]
		s.value_changed.connect(func(_v): _on_changed())
		g.add_child(l)
		g.add_child(s)
		post_spins[k[0]] = s
		post_rows += [l, s]
	var fl: Label = main._label("  Fade (s)")
	var fs: SpinBox = main._spin(0.0, 10.0, 0.05)
	fs.tooltip_text = "Seconds to fade in on entering and out on leaving; 0 = instant"
	fs.value_changed.connect(func(_v): _on_changed())
	g.add_child(fl)
	g.add_child(fs)
	post_spins["fade"] = fs
	post_rows += [fl, fs]
	box.add_child(g)
	box.visible = false
	right.add_child(box)

func _process(dt: float) -> void:
	if main == null or not main.view_on("post") or main.project.is_empty():
		return
	# the volume the camera is in (the first, as the xlive mod picks)
	var want := NEUTRAL.duplicate()
	var target: Variant = null
	var cp: Vector3 = main.camera.global_position
	for n in main.markers_root.get_children():
		if not is_volume(n):
			continue
		var inside := contains(n, cp)
		(n.get_child(0) as Node3D).visible = not inside   # its see-through faces would tint the view too
		(n.get_child(3) as Node3D).visible = not inside and main.selection.has(n)
		if target == null and inside and n.get_meta("data").get("post"):
			target = n.get_meta("data")
			var q: Dictionary = target["post"]
			var t: Array = q.get("tint", [1, 1, 1])
			want = {"tint": Color(float(t[0]), float(t[1]), float(t[2])), "brightness": float(q.get("brightness", 1.0)),
				"saturation": float(q.get("saturation", 1.0)), "contrast": float(q.get("contrast", 1.0))}
	if target != post_target:
		# a new fade from what shows now: into a volume over its fade, out of one over the left one's
		var from_d: Variant = target if target != null else post_target
		post_fade = float(from_d["post"].get("fade", 0.5)) if from_d != null and from_d.get("post") else 0.0
		post_from = post_now.duplicate()
		post_target = target
		post_t = 0.0
	if post_t >= 1.0 and post_now == want:
		return   # settled: nothing to redraw
	post_t = 1.0 if post_fade <= 0.0 else minf(1.0, post_t + dt / post_fade)
	var s := post_t * post_t * (3.0 - 2.0 * post_t)
	for k in want:
		post_now[k] = lerp(post_from[k], want[k], s)
	_apply_post()

func _apply_post() -> void:
	if post_overlay == null:
		var layer := CanvasLayer.new()
		layer.layer = -1   # over the 3D view, under the panels
		post_overlay = ColorRect.new()
		post_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		post_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
		post_overlay.material = m
		layer.add_child(post_overlay)
		main.add_child(layer)
	var c: Color = post_now["tint"]
	post_overlay.color = Color(c.r, c.g, c.b, 1.0)
	post_overlay.visible = not c.is_equal_approx(Color.WHITE)
	var we: Environment = main.world_env
	var neutral: bool = is_equal_approx(post_now["brightness"], 1.0) and is_equal_approx(post_now["saturation"], 1.0) \
		and is_equal_approx(post_now["contrast"], 1.0)
	we.adjustment_brightness = post_now["brightness"]
	we.adjustment_saturation = post_now["saturation"]
	we.adjustment_contrast = post_now["contrast"]
	we.adjustment_enabled = not neutral or we.adjustment_color_correction != null   # the map's tone curves keep it on

func preview_post_off() -> void:
	post_now = NEUTRAL.duplicate()
	post_target = null
	post_t = 1.0
	for n in main.markers_root.get_children():
		if is_volume(n):
			(n.get_child(0) as Node3D).visible = true
			(n.get_child(3) as Node3D).visible = main.selection.has(n)
	if post_overlay:
		_apply_post()

func _check(g: GridContainer, t: String, tip: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = t
	c.tooltip_text = tip
	c.toggled.connect(func(_b): _on_changed())
	g.add_child(c)
	return c

func volumes() -> Array:
	if not main.project.has("volumes"):
		main.project["volumes"] = []
	return main.project["volumes"]

static func is_volume(n: Node) -> bool:
	return n.has_meta("volume")

static func migrate(d: Dictionary) -> void:
	if d.has("type"):
		if d["type"] == "kill":
			d["kill"] = true
			d.erase("gravity")
		d.erase("type")
	if d.get("no_weather", false):
		d["weather"] = 0.0
	d.erase("no_weather")

static func effects(d: Dictionary) -> Array:
	var out: Array = []
	if d.get("kill", false):
		out.append("kill")
	if d.has("gravity"):
		out.append("gravity")
	if d.get("post"):
		out.append("post")
	if d.has("weather"):
		out.append("weather")
	if d.get("water", false):
		out.append("water")
	if d.get("sound"):
		out.append("sound")
	return out

static func reverb_name(key: String) -> String:
	for r in REVERBS:
		if r[0] == key:
			return r[1]
	return key

static func label(d: Dictionary) -> String:
	var s: Array = d.get("size", [1000, 1000, 1000])
	var what: Array = []
	for e in effects(d):
		what.append("kill" if e == "kill" else "gravity x%.2f" % float(d["gravity"]) if e == "gravity" else "post" if e == "post" else "water" if e == "water"
			else "reverb: " + reverb_name(str(d["sound"].get("reverb", ""))).get_slice(" (", 0) if e == "sound"
			else "no weather" if float(d["weather"]) <= 0.0 else "weather %d%%" % int(d["weather"]))
	var nb: int = (d.get("boxes", []) as Array).size()
	return "Volume: %s (%d x %d x %d m%s)" % [" + ".join(what) if what else "no effect", int(s[0]) / 100, int(s[1]) / 100,
		int(s[2]) / 100, " + %d box%s" % [nb, "" if nb == 1 else "es"] if nb else ""]

func delete_box(n: Node3D, bi: int) -> void:
	# one of the volume's boxes away (it keeps at least one); the main box's going makes the first other one main
	var d: Dictionary = n.get_meta("data")
	var boxes: Array = d.get("boxes", [])
	if boxes.is_empty() or bi < 0 or bi > boxes.size():
		return
	if bi == 0:
		var off := _v3(boxes[0]["pos"])
		var w: Vector3 = n.global_transform.basis * off   # world cm (no scale)
		d["pos"] = [float(d["pos"][0]) + w.x, float(d["pos"][1]) + w.y, float(d["pos"][2]) + w.z]
		d["size"] = (boxes[0]["size"] as Array).duplicate()
		boxes.remove_at(0)
		for b in boxes:
			b["pos"] = [float(b["pos"][0]) - off.x, float(b["pos"][1]) - off.y, float(b["pos"][2]) - off.z]
	else:
		boxes.remove_at(bi - 1)
	if boxes.is_empty():
		d.erase("boxes")
	main._place(n)
	update_marker(n)
	show_inspector([n])
	var item: Variant = n.get_meta("item") if n.has_meta("item") else null
	if item != null and is_instance_valid(item):
		(item as TreeItem).set_text(0, label(d))

func _remove_box() -> void:
	var vs: Array = main.selection.filter(func(n): return is_instance_valid(n) and is_volume(n))
	if vs.size() != 1 or (vs[0].get_meta("data").get("boxes", []) as Array).is_empty():
		return
	main._push_undo("")
	var n: Node3D = vs[0]
	var d: Dictionary = n.get_meta("data")
	d["boxes"].pop_back()
	if d["boxes"].is_empty():
		d.erase("boxes")
	update_marker(n)
	show_inspector([n])
	var item: Variant = n.get_meta("item") if n.has_meta("item") else null
	if item != null and is_instance_valid(item):
		(item as TreeItem).set_text(0, label(d))

func migrate_weather() -> void:
	var w: Variant = main.lighting.env().get("weather")
	if not (w is Dictionary) or not (w.get("volumes") is Array):
		return
	for b in w["volumes"]:
		var y := float(b["pos"][1]) - float(b["size"][1]) / 2
		volumes().append({"pos": [float(b["pos"][0]), y, float(b["pos"][2])], "yaw": 0.0,
			"size": [float(b["size"][0]), float(b["size"][1]), float(b["size"][2])], "weather": 0.0})
	w.erase("volumes")

func add_markers() -> void:
	migrate_weather()
	for d in volumes():
		migrate(d)
		add_marker(d)

func add_marker(d: Dictionary) -> Node3D:
	var n := Node3D.new()
	n.set_meta("data", d)
	n.set_meta("object", false)
	n.set_meta("volume", true)
	var mi := MeshInstance3D.new()   # child 0: the box (its colour is the outliner's)
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(mi)
	var edges := MeshInstance3D.new()   # child 1: its outline
	edges.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(edges)
	var body := StaticBody3D.new()   # child 2: what clicks pick
	body.collision_layer = main.LAYER_MARKERS
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	n.add_child(body)
	for k in 2:   # children 3 / 4: the faces / edges through the level, while selected
		var x := MeshInstance3D.new()
		x.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		x.visible = false
		n.add_child(x)
	main.markers_root.add_child(n)
	main._place(n)
	update_marker(n)
	return n

func update_marker(n: Node3D) -> void:
	var d: Dictionary = n.get_meta("data")
	var fx := effects(d)
	var c: Color = COLOURS[fx[0] if fx else "none"]
	var bs := _boxes(n)
	# every box's faces in one mesh, its outlines in another (the volume's frame)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lines := PackedVector3Array()
	for b: AABB in bs:
		for q in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
			for k in [0, 1, 2, 0, 2, 3]:
				st.add_vertex(b.get_endpoint(q[k]))
		for e in [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
			lines.append(b.get_endpoint(e[0]))
			lines.append(b.get_endpoint(e[1]))
	var mi := n.get_child(0) as MeshInstance3D
	mi.mesh = st.commit()
	mi.position = Vector3.ZERO
	(mi.material_override as StandardMaterial3D).albedo_color = Color(c, 0.18)
	var am := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = lines
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = c
	am.surface_set_material(0, lm)
	(n.get_child(1) as MeshInstance3D).mesh = am
	# through the level (no depth test), dimmed; drawn first, so the depth-tested box shows full over it where seen
	var xf := StandardMaterial3D.new()
	xf.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	xf.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	xf.cull_mode = BaseMaterial3D.CULL_DISABLED
	xf.no_depth_test = true
	xf.render_priority = -1
	xf.albedo_color = Color(c, 0.07)
	var xm := n.get_child(3) as MeshInstance3D
	xm.mesh = mi.mesh
	xm.position = Vector3.ZERO
	xm.material_override = xf
	var xl := xf.duplicate() as StandardMaterial3D
	xl.albedo_color = Color(c.darkened(0.3), 0.55)
	var xe := n.get_child(4) as MeshInstance3D
	xe.mesh = am
	xe.material_override = xl
	# one pick shape per box
	var body := n.get_child(2) as StaticBody3D
	while body.get_child_count() > bs.size():
		var old := body.get_child(body.get_child_count() - 1)
		body.remove_child(old)
		old.queue_free()
	while body.get_child_count() < bs.size():
		var cs := CollisionShape3D.new()
		cs.shape = BoxShape3D.new()
		body.add_child(cs)
	for i in bs.size():
		var shape := body.get_child(i) as CollisionShape3D
		(shape.shape as BoxShape3D).size = bs[i].size
		shape.position = bs[i].get_center()

func set_selected(n: Node3D, on: bool) -> void:
	# the see-through faces and edges, and a stronger box, while selected
	(n.get_child(3) as Node3D).visible = on
	(n.get_child(4) as Node3D).visible = on
	var m := (n.get_child(0) as MeshInstance3D).material_override as StandardMaterial3D
	m.albedo_color.a = 0.28 if on else 0.18

func add_menu(parent: Control) -> MenuButton:
	var mb := MenuButton.new()
	mb.text = "Add volume"
	mb.flat = false
	mb.tooltip_text = "A box placed where the view points; tick more effects on it in the inspector to combine them"
	for i in ADD.size():
		mb.get_popup().add_item(ADD[i][1], i)
	mb.get_popup().id_pressed.connect(func(i): add_volume(ADD[i][0]))
	parent.add_child(mb)
	return mb

func add_volume(effect: String) -> void:
	if main.project_dir == "":
		return
	var mp: Vector2 = main.get_viewport().get_visible_rect().size / 2
	var hit: Dictionary = main._mouse_ray(mp, 1 << (main.LAYER_STAGE - 1))
	var at: Vector3 = hit["position"] if hit else main.camera.global_position - main.camera.global_transform.basis.z * 10.0
	main._push_undo("")
	var n := place_volume(effect, at)
	main._rebuild_outliner()
	main.select([n])
	main.log_line("Added a volume; move it with the gizmo, size it and add effects in the inspector.")

func place_volume(effect: String, at: Vector3) -> Node3D:
	# a new volume with one effect, its floor centred at `at` (metres); the caller pushes undo
	var d := {"pos": [at.x / main.CM, at.y / main.CM, at.z / main.CM], "yaw": 0.0,
		"size": [1000.0, 300.0 if effect == "kill" else 1000.0, 1000.0]}
	match effect:
		"kill": d["kill"] = true
		"gravity": d["gravity"] = 0.5
		"post": d["post"] = POST.duplicate(true)
		"weather": d["weather"] = 0.0
		"water": d["water"] = true
		"sound": d["sound"] = {"reverb": REVERBS[0][0]}
	volumes().append(d)
	return add_marker(d)

func delete_volumes(ns: Array) -> void:
	for n in ns:
		volumes().erase(n.get_meta("data"))
		main.markers_root.remove_child(n)
		n.queue_free()

func duplicate_volumes(ns: Array) -> Array:
	var out: Array = []
	for n in ns:
		var d: Dictionary = (n.get_meta("data") as Dictionary).duplicate(true)
		d["pos"][0] = float(d["pos"][0]) + float(d["size"][0]) + 100.0
		volumes().append(d)
		out.append(add_marker(d))
	return out

func show_inspector(selection: Array) -> void:
	var vs := selection.filter(func(n): return is_instance_valid(n) and is_volume(n))
	box.visible = vs.size() == 1
	if vs.size() != 1:
		return
	updating = true
	var d: Dictionary = vs[0].get_meta("data")
	var s: Array = d.get("size", [1000, 1000, 1000])
	for a in 3:
		size_spins[a].value = float(s[a])
	kill_on.button_pressed = d.get("kill", false)
	var nb: int = (d.get("boxes", []) as Array).size()
	boxes_label.text = "%d boxes" % (nb + 1) if nb else "1 box"
	remove_box.disabled = nb == 0
	weather_on.button_pressed = d.has("weather")
	water_on.button_pressed = d.get("water", false)
	sound_on.button_pressed = d.get("sound") != null
	var rk: String = str((d.get("sound") if d.get("sound") else {}).get("reverb", REVERBS[0][0]))
	reverb_pick.selected = maxi(0, REVERBS.map(func(r): return r[0]).find(rk))
	for c in sound_rows:
		c.visible = sound_on.button_pressed
	weather_spin.value = float(d.get("weather", 0.0))
	weather_spin.editable = weather_on.button_pressed
	gravity_on.button_pressed = d.has("gravity")
	gravity_spin.value = float(d.get("gravity", 0.5))
	gravity_spin.editable = gravity_on.button_pressed
	var q: Dictionary = d.get("post", {})
	post_on.button_pressed = not q.is_empty()
	var t: Array = q.get("tint", POST["tint"])
	tint_pick.color = Color(float(t[0]), float(t[1]), float(t[2]))
	for k in post_spins:
		post_spins[k].value = float(q.get(k, POST[k] if q.is_empty() or k == "fade" else 1.0))
	for c in post_rows:
		c.visible = post_on.button_pressed
	updating = false

func _on_changed() -> void:
	if updating:
		return
	var vs: Array = main.selection.filter(func(n): return is_instance_valid(n) and is_volume(n))
	if vs.size() != 1:
		return
	main._push_undo("volume")
	var n: Node3D = vs[0]
	var d: Dictionary = n.get_meta("data")
	d["size"] = [size_spins[0].value, size_spins[1].value, size_spins[2].value]
	if kill_on.button_pressed:
		d["kill"] = true
	else:
		d.erase("kill")
	if weather_on.button_pressed:
		d["weather"] = weather_spin.value
	else:
		d.erase("weather")
	if water_on.button_pressed:
		d["water"] = true
	else:
		d.erase("water")
	if sound_on.button_pressed:
		d["sound"] = {"reverb": REVERBS[reverb_pick.selected][0]}
	else:
		d.erase("sound")
	if gravity_on.button_pressed:
		d["gravity"] = gravity_spin.value
	else:
		d.erase("gravity")
	if post_on.button_pressed:
		var c := tint_pick.color
		d["post"] = {"tint": [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001)]}
		for k in post_spins:
			d["post"][k] = post_spins[k].value
	else:
		d.erase("post")
	update_marker(n)
	show_inspector([n])
	var item: Variant = n.get_meta("item") if n.has_meta("item") else null
	if item != null and is_instance_valid(item):
		(item as TreeItem).set_text(0, label(d))

# ---------------------------------------------------------------- Ctrl+drag a face: push / pull it

var face := {}   # the face being dragged: node, axis, sign, start (size, pos), t0 (ray parameter along the normal)

static func sub_boxes(d: Dictionary) -> Array:
	# [pos (floor centre, cm, relative to the volume's pos in its turned frame), size (cm)] per box; the main box first
	var out: Array = [[Vector3.ZERO, _v3(d.get("size", [1000, 1000, 1000]))]]
	for b in d.get("boxes", []):
		out.append([_v3(b["pos"]), _v3(b["size"])])
	return out

static func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

static func _aabb_cm(p: Vector3, sz: Vector3) -> AABB:
	return AABB(p - Vector3(sz.x / 2, 0, sz.z / 2), sz)

func _boxes(n: Node3D) -> Array:
	# the volume's boxes in its own frame (n.to_local), metres
	var out: Array = []
	for b in sub_boxes(n.get_meta("data")):
		var a := _aabb_cm(b[0], b[1])
		out.append(AABB(a.position * main.CM, a.size * main.CM))
	return out

func contains(n: Node3D, p: Vector3) -> bool:
	var l := n.to_local(p)
	return _boxes(n).any(func(b: AABB): return b.has_point(l))

func face_hit(mp: Vector2) -> Dictionary:
	# the nearest volume face under the mouse (from inside a box: the face it looks at)
	var wo: Vector3 = main.camera.project_ray_origin(mp)
	var wdir: Vector3 = main.camera.project_ray_normal(mp)
	var best := {}
	var sel: Array = main.selection.filter(func(x): return is_instance_valid(x) and is_volume(x))
	for n in main.markers_root.get_children():
		if not is_volume(n) or not n.visible:
			continue
		var o: Vector3 = n.to_local(wo)   # the volume's frame (no scale on volumes: t stays metres)
		var dir: Vector3 = n.global_transform.basis.inverse() * wdir
		var bs := _boxes(n)
		for bi in bs.size():
			_face_box(n, bi, bs[bi], o, dir, wo, wdir, sel, best)
	return best

func _face_box(n: Node3D, bi: int, b: AABB, o: Vector3, dir: Vector3, wo: Vector3, wdir: Vector3, sel: Array, best: Dictionary) -> void:
	var t_in := -INF
	var t_out := INF
	var ax_in := -1
	var ax_out := -1
	var ok := true
	for a in 3:
		if absf(dir[a]) < 1e-9:
			if o[a] < b.position[a] or o[a] > b.end[a]:
				ok = false
			continue
		var t1: float = (b.position[a] - o[a]) / dir[a]
		var t2: float = (b.end[a] - o[a]) / dir[a]
		if minf(t1, t2) > t_in:
			t_in = minf(t1, t2)
			ax_in = a
		if maxf(t1, t2) < t_out:
			t_out = maxf(t1, t2)
			ax_out = a
	if not ok or t_in > t_out or t_out < 0:
		return
	var inside := t_in < 0
	var t := t_out if inside else t_in
	var a: int = ax_out if inside else ax_in
	var picked := sel.has(n)   # a selected volume's faces win over others' in front of them
	if best.is_empty() or (picked and not best["sel"]) or (picked == best["sel"] and t < best["t"]):
		var sgn := signf(dir[a]) if inside else -signf(dir[a])
		var nl := Vector3.ZERO
		nl[a] = sgn
		best.clear()
		best.merge({"node": n, "box": bi, "axis": a, "sign": sgn, "t": t, "point": wo + wdir * t, "sel": picked,
			"normal": n.global_transform.basis * nl})

func _along(mp: Vector2) -> float:
	# where the mouse ray passes closest to the face's normal line (metres along it)
	var o: Vector3 = main.camera.project_ray_origin(mp)
	var dir: Vector3 = main.camera.project_ray_normal(mp)
	var n: Vector3 = face["normal"]   # world: the face's outward normal, turned with the box
	var w: Vector3 = face["point"] - o
	var b := n.dot(dir)
	var den := 1.0 - b * b
	if den < 1e-6:
		return face["t0"]
	return (b * dir.dot(w) - n.dot(w)) / den

func begin_face(hit: Dictionary, extrude := false) -> void:
	# extrude (Ctrl+Shift+drag): a new box grows out of the face, the face's size across, dragged out along its normal
	face = hit.duplicate()
	var d: Dictionary = hit["node"].get_meta("data")
	if extrude:
		var bx: Array = sub_boxes(d)[hit["box"]]
		var a: int = hit["axis"]
		var lo: Vector3 = _aabb_cm(bx[0], bx[1]).position
		var hi: Vector3 = lo + (bx[1] as Vector3)
		var at: float = hi[a] if hit["sign"] > 0 else lo[a]
		lo[a] = at
		hi[a] = at
		hi[a] += 10.0 * hit["sign"] if hit["sign"] > 0 else 0.0
		lo[a] += 10.0 * hit["sign"] if hit["sign"] < 0 else 0.0
		if not d.has("boxes"):
			d["boxes"] = []
		d["boxes"].append(_box_dict(lo, hi))
		face["box"] = d["boxes"].size()
	face["start"] = {"pos": (d["pos"] as Array).duplicate(), "size": (d["size"] as Array).duplicate(),
		"boxes": (d.get("boxes", []) as Array).duplicate(true)}
	face["t0"] = 0.0

static func _box_dict(lo: Vector3, hi: Vector3) -> Dictionary:
	return {"pos": [(lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2], "size": [hi.x - lo.x, hi.y - lo.y, hi.z - lo.z]}

func drag_face(mp: Vector2, snap: bool) -> void:
	# the face moves along its normal; its box's other faces stay (the main box's moves keep the sub-boxes in place)
	var n: Node3D = face["node"]
	var d: Dictionary = n.get_meta("data")
	var a: int = face["axis"]
	var delta: float = _along(mp) / main.CM   # cm, outwards
	if snap:
		delta = snappedf(delta, 50.0)
	var st: Dictionary = face["start"]
	var sd := {"size": st["size"], "boxes": st["boxes"]}
	var bx: Array = sub_boxes(sd)[face["box"]]
	var lo: Vector3 = _aabb_cm(bx[0], bx[1]).position
	var hi: Vector3 = lo + (bx[1] as Vector3)
	if face["sign"] > 0:
		hi[a] = maxf(lo[a] + 10.0, hi[a] + delta)
	else:
		lo[a] = minf(hi[a] - 10.0, lo[a] - delta)
	var nb := _box_dict(lo, hi)
	var boxes: Array = (st["boxes"] as Array).duplicate(true)
	if face["box"] == 0:
		# the main box: the volume's origin moves with its floor centre; the sub-boxes keep their place
		var off := _v3(nb["pos"])
		var w: Vector3 = n.global_transform.basis * off   # world cm (no scale)
		d["pos"] = [float(st["pos"][0]) + w.x, float(st["pos"][1]) + w.y, float(st["pos"][2]) + w.z]
		d["size"] = nb["size"]
		for b in boxes:
			b["pos"] = [float(b["pos"][0]) - off.x, float(b["pos"][1]) - off.y, float(b["pos"][2]) - off.z]
	else:
		boxes[face["box"] - 1] = nb
	if boxes.is_empty():
		d.erase("boxes")
	else:
		d["boxes"] = boxes
	main._place(n)
	update_marker(n)
	show_inspector([n])
	var item: Variant = n.get_meta("item") if n.has_meta("item") else null
	if item != null and is_instance_valid(item):
		(item as TreeItem).set_text(0, label(d))

func end_face() -> void:
	face = {}
