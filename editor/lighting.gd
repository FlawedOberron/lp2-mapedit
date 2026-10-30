extends Window
# Floating lighting window (L): the sun, the sky light (hemisphere from above / below) and ambient, the sky dome and
# atmosphere, colour grading (tone curves, curves.gd; bloom colour), and placed point / spot lights. Settings go to
# project.json's environment (lp2light.py / lp2sky.py at export); placed lights to project.json "lights" and show as
# markers (Lights in the outliner) with a Godot light each.
# Colours are stored as the game takes them: colour x brightness.

const STOCK_SUN := [2.43, 2.43, 2.43]   # online00's sun as the export greys it (x environment.tint)
const STOCK_SKY := [0.152, 0.152, 0.152]
const STOCK_GROUND := [0.106, 0.106, 0.106]
const STOCK_AMBIENT := [0.152, 0.152, 0.152]
const CLEAR_SCATTER := {"mRaylieghScattering": [17.0, 14.8, 13.9], "mMeiScattering": [2.94, 2.95, 3.0], "mMeiDirective": -0.1, "mDensity": 0.53}
const MAP_NAMES := {"00": "Desecration", "01": "Turbulent Jungle", "02": "Kraftwerk", "03": "The Great Outdoors",
	"04": "Dockyard Battle", "05": "Thunderpeal Precipice", "06": "Dual Complex", "07": "NEOS", "08": "Helix",
	"09": "Friction", "10": "Pirate Fortress", "11": "Back to the Island", "12": "Cube", "15": "Frozen Wasteland"}
const SKY_MAPS := ["03", "06", "07", "10", "12", "15"]   # stock maps with a sky model (lp2sky.py list)
const LIGHT_SIZE := 0.35
# the ray-traced bake (lp2bake.py; project stage.light): defaults as its DEFAULTS. Live ones show at once (the
# baked shader combines the stored light components); the rest need "Bake lighting"
const BAKE_DEFAULTS := {"source": "lp1", "sun": 0.4, "sky": 1.0, "lights": 1.0, "glow": 1.0, "exposure": 0.0,
	"min_light": 0.01, "bounce": 1.0, "bounces": 2, "samples": 64, "detail": 0}
const BAKE_CALIBRATION := 0.48   # lp2bake.py CALIBRATION
const BAKE_FIELDS := [
	["sun", "Sun in bake", 0.0, 5.0, 0.05, "Strength of the sun's direct light in the bake (x the Sun colour above). Live"],
	["sky", "Sky in bake", 0.0, 5.0, 0.05, "Strength of the sky and ground light in the bake (x their colours above). Live"],
	["lights", "Placed lights", 0.0, 5.0, 0.05, "Strength of the point and spot lights in the bake. Live"],
	["glow", "Glow", 0.0, 10.0, 0.05, "Strength of glowing materials. Live"],
	["exposure", "Exposure (EV)", -4.0, 4.0, 0.1, "The whole bake brighter or darker: +1 doubles it. Live"],
	["min_light", "Min light", 0.0, 0.5, 0.005, "The darkest the bake goes (a soft floor), so nothing is pitch black. Live"],
	["bounces", "Bounces", 0.0, 4.0, 1.0, "How many times light bounces between surfaces. Needs a re-bake"],
	["bounce", "Bounce strength", 0.0, 1.5, 0.05, "How much light surfaces pass on (x their colour). Needs a re-bake"],
	["samples", "Quality (rays)", 8.0, 256.0, 8.0, "Sky rays per vertex: more is smoother and slower. Needs a re-bake"],
	["detail", "Detail (+% vertices)", 0.0, 400.0, 5.0, "Puts vertices along the sun's shadow lines and splits triangles where the other light changes sharply (doorways, wall feet), up to this many more vertices: sharper light, bigger stage model, slower bake (the cost shows below). Needs a re-bake"]]
# detail cost (lp2bake.py), measured on Battlegrounds: the built stage model is about STAGE_VERTEX_BYTES per vertex
# (the preview has more vertices than the stage: count from the model's bytes) and each split vertex adds
# DETAIL_VERTEX_BYTES (28 B + its triangles' 16-bit indices). The bake's RAM, from the preview bake (271k
# vertices: 2.8 GB at +162k, 3.6 GB at +401k, 64 rays; the stage's bake needs less)
const STAGE_VERTEX_BYTES := 39.0
const DETAIL_VERTEX_BYTES := 33.0
const BAKE_RAM_BASE := 1.4e9
const BAKE_RAM_PER_RAY := 40.0   # bytes per vertex per sky ray, plus BAKE_RAM_VERTEX
const BAKE_RAM_VERTEX := 600.0
const NEUTRAL_CURVE := [[0.0, 0.333, 0.667, 1.0], [0.0, 0.333, 0.667, 1.0]]

var main: Node
var presets := {}            # lp2light.py presets: map number -> day values
var preset_pick: OptionButton
var sun_az: SpinBox
var sun_el: SpinBox
var rows := {}               # env key -> [ColorPickerButton, SpinBox brightness]
var sky_pick: OptionButton
var sky_file: Button
var sky_bright: SpinBox
var haze_pick: OptionButton
var haze_density: SpinBox
var grade_pick: OptionButton
var curve_ed: Control        # curves.gd
var light_ed := {}           # the window's light editor: {box, title, rows: field -> control, node: the light shown}
var popup_ed := {}           # the same in the right-click popup
var light_popup: PopupPanel
var bake_source: OptionButton
var bake_rows := {}          # stage.light key -> SpinBox
var bake_btn: Button
var detail_info: Label
var _unsplit := {}           # the unsplit preview's stats (geo_base.json once a detail bake split geo.json): {time, stats}
var _updating := false

func _init() -> void:
	title = "Lighting"
	size = Vector2i(460, 780)
	min_size = Vector2i(360, 400)
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

	v.add_child(_heading("Sun and sky light"))
	var pr := HBoxContainer.new()
	preset_pick = OptionButton.new()
	preset_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_pick.tooltip_text = "A stock map's daytime light: sun direction and colour, sky light, ambient and atmosphere"
	pr.add_child(preset_pick)
	main._button(pr, "Use", apply_preset)
	main._button(pr, "Reset", reset_light).tooltip_text = "Back to the export's defaults (Desecration's light, grey)"
	v.add_child(pr)
	var g := GridContainer.new()
	g.columns = 2
	g.add_child(main._label("Sun azimuth"))
	sun_az = _num(g, -360, 360, 1, "Compass direction the sunlight comes from (degrees; 0 = from +Z, 90 = from +X)")
	g.add_child(main._label("Sun elevation"))
	sun_el = _num(g, 1, 90, 1, "Height of the sun above the horizon (degrees)")
	v.add_child(g)
	main._button(v, "Sun from behind the view", sun_from_view).tooltip_text = "Put the sun behind the camera, at the elevation set above"
	var cg := GridContainer.new()
	cg.columns = 3
	for row in [["sun_colour", "Sun", "The sun's colour and brightness (stock maps: 2 to 5)"],
			["sky_colour", "Sky light", "Light from above, on every surface facing up (stock: 0.03 to 0.3)"],
			["ground_colour", "Ground light", "Light bounced from below (stock: 0.03 to 0.3)"],
			["ambient", "Ambient", "Light from every side (stock: 0.04 to 0.5)"]]:
		cg.add_child(main._label(row[1]))
		var cp := ColorPickerButton.new()
		cp.custom_minimum_size = Vector2(70, 0)
		cp.edit_alpha = false
		cp.tooltip_text = row[2]
		cp.color_changed.connect(func(_c): _on_changed())
		cg.add_child(cp)
		var b := _num(cg, 0.0, 20.0, 0.01, "Brightness")
		rows[row[0]] = [cp, b]
	v.add_child(cg)

	v.add_child(HSeparator.new())
	v.add_child(_heading("Sky"))
	var sg := GridContainer.new()
	sg.columns = 2
	sg.add_child(main._label("Dome"))
	sky_pick = OptionButton.new()
	sky_pick.add_item("The map's own")
	for n in SKY_MAPS:
		sky_pick.add_item("%s's sky" % MAP_NAMES[n])
	sky_pick.add_item("Panorama image")
	sky_pick.tooltip_text = "The map's own: whatever the stage has (LP1 ports bring their dome). A stock sky or a panorama image (equirectangular, 2:1) replaces it"
	sky_pick.item_selected.connect(func(_i): _on_changed())
	sg.add_child(sky_pick)
	sg.add_child(main._label("Image"))
	sky_file = Button.new()
	sky_file.text = "(none)"
	sky_file.clip_text = true
	sky_file.pressed.connect(func(): main.lighting_dialog.popup_centered_ratio(0.6))
	sg.add_child(sky_file)
	sg.add_child(main._label("Dome brightness"))
	sky_bright = _num(sg, 0.1, 1.9, 0.05, "The panorama dome's brightness (1 = as stock skies)")
	sg.add_child(main._label("Atmosphere"))
	haze_pick = OptionButton.new()
	haze_pick.tooltip_text = "Scattering: the haze over distance and the sky's tint (Turbulent Jungle's clear air is the default)"
	haze_pick.item_selected.connect(func(_i): _on_haze_pick())
	sg.add_child(haze_pick)
	sg.add_child(main._label("Haze density"))
	haze_density = _num(sg, 0.0, 2.0, 0.01, "How thick the air is (stock 0.48 to 0.91)")
	v.add_child(sg)
	var tg := GridContainer.new()
	tg.columns = 3
	tg.add_child(main._label("Sky tint"))
	var tcp := ColorPickerButton.new()
	tcp.custom_minimum_size = Vector2(70, 0)
	tcp.edit_alpha = false
	tcp.tooltip_text = "The scattered sunlight's colour (the sky and distant haze)"
	tcp.color_changed.connect(func(_c): _on_changed())
	tg.add_child(tcp)
	rows["sky"] = [tcp, _num(tg, 0.0, 40.0, 0.1, "Brightness (stock 3 to 30)")]
	v.add_child(tg)

	v.add_child(HSeparator.new())
	v.add_child(_heading("Baked lighting"))
	var bk := GridContainer.new()
	bk.columns = 2
	bk.add_child(main._label("Source"))
	bake_source = OptionButton.new()
	bake_source.add_item("LP1 lightmap")
	bake_source.add_item("Ray-traced bake")
	bake_source.tooltip_text = "The level's light: the original LP1 lightmap, or our own bake (sun, sky, placed lights, glow and bounces)"
	bake_source.item_selected.connect(func(_i): _on_bake_changed())
	bk.add_child(bake_source)
	for f in BAKE_FIELDS:
		bk.add_child(main._label(f[1]))
		bake_rows[f[0]] = _num(bk, f[2], f[3], f[4], f[5], _on_bake_changed)
	v.add_child(bk)
	detail_info = Label.new()
	detail_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_info.custom_minimum_size.x = 300
	detail_info.visible = false
	v.add_child(detail_info)
	bake_btn = main._button(v, "Bake lighting", bake_now)
	bake_btn.tooltip_text = "Ray trace the level's light (about half a minute; a minute or more with detail). Saves the project first"

	v.add_child(HSeparator.new())
	v.add_child(_heading("Colour grading"))
	var gr := HBoxContainer.new()
	grade_pick = OptionButton.new()
	grade_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grade_pick.tooltip_text = "Tone curves: neutral, or a stock map's grade"
	gr.add_child(grade_pick)
	main._button(gr, "Use", apply_grade)
	v.add_child(gr)
	var chs := HBoxContainer.new()
	var group := ButtonGroup.new()
	for ch in ["All", "R", "G", "B"]:
		var b := Button.new()
		b.text = ch
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = ch == "All"
		b.tooltip_text = "Edit every channel together" if ch == "All" else "Edit the %s curve" % {"R": "red", "G": "green", "B": "blue"}[ch]
		b.pressed.connect(func(): curve_ed.set_channel(ch))
		chs.add_child(b)
	v.add_child(chs)
	curve_ed = preload("res://curves.gd").new()
	curve_ed.tooltip_text = "Drag a point: across = the input brightness, up = what it becomes. Diagonal = no change"
	curve_ed.changed.connect(_on_curves)
	curve_ed.edited.connect(func(): _preview_grade(curve_ed.curves))
	v.add_child(curve_ed)
	var bg2 := GridContainer.new()
	bg2.columns = 3
	bg2.add_child(main._label("Bloom"))
	var bcp := ColorPickerButton.new()
	bcp.custom_minimum_size = Vector2(70, 0)
	bcp.edit_alpha = false
	bcp.tooltip_text = "The glow's colour around bright areas"
	bcp.color_changed.connect(func(_c): _on_changed())
	bg2.add_child(bcp)
	rows["bloom"] = [bcp, _num(bg2, 0.0, 2.0, 0.01, "Bloom strength (stock 0.3 to 0.6)")]
	v.add_child(bg2)

	v.add_child(HSeparator.new())
	v.add_child(_heading("Placed lights"))
	var lr := HBoxContainer.new()
	main._button(lr, "Add point light", func(): add_light("point")).tooltip_text = "A light shining every way, where the view points"
	main._button(lr, "Add spot light", func(): add_light("spot")).tooltip_text = "A cone of light, pointing down; turn it with the gizmo (yaw) and Pitch"
	v.add_child(lr)
	var hint: Label = main._label("Lights show in the outliner under Lights: move them with the gizmo, Delete removes, Ctrl+D copies. The game lights characters and objects with them (and, most likely, the level).")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(hint)
	light_ed = _light_editor()
	v.add_child(light_ed["box"])
	# the same editor as a popup: right-click a light in the view
	light_popup = PopupPanel.new()
	var pv := VBoxContainer.new()
	pv.custom_minimum_size = Vector2(330, 0)
	light_popup.add_child(pv)
	popup_ed = _light_editor()
	pv.add_child(popup_ed["box"])
	var pb := HBoxContainer.new()
	main._button(pb, "Duplicate", func(): _popup_act(main.duplicate_selected))
	main._button(pb, "Delete", func(): _popup_act(main.delete_selected))
	main._button(pb, "Lighting window", func(): light_popup.hide(); popup())
	pv.add_child(pb)
	main.add_child(light_popup)
	visibility_changed.connect(func(): if visible: refresh())

func _heading(t: String) -> Label:
	var l: Label = main._label(t)
	l.add_theme_font_size_override("font_size", 16)
	return l

func _num(parent: Control, lo: float, hi: float, step: float, tip: String, cb: Callable = Callable()) -> SpinBox:
	var s: SpinBox = main._spin(lo, hi, step)
	s.tooltip_text = tip
	s.value_changed.connect(func(_v): (cb if cb.is_valid() else _on_changed).call())
	parent.add_child(s)
	return s

# ---------------------------------------------------------------- environment <-> controls

func env() -> Dictionary:
	if not main.project.has("environment"):
		main.project["environment"] = {}
	return main.project["environment"]

static func curves_of(e: Dictionary) -> Dictionary:
	# environment.curves -> R / G / B: [[x0..x3], [y0..y3]]; missing or the old flat form (x only) -> neutral
	var c: Dictionary = e.get("curves") if e.get("curves") is Dictionary else {}
	var out := {}
	for ch in ["R", "G", "B"]:
		var v: Variant = c.get(ch)
		var ok: bool = v is Array and v.size() == 2 and v[0] is Array and v[1] is Array and v[0].size() == 4 and v[1].size() == 4
		out[ch] = (v as Array).duplicate(true) if ok else NEUTRAL_CURVE.duplicate(true)
	return out

static func split(c: Variant, fallback: Array) -> Array:
	# stored colour x brightness -> [Color, brightness]
	var v: Array = c if c is Array else fallback
	var b: float = maxf(maxf(float(v[0]), float(v[1])), maxf(float(v[2]), 0.0001))
	return [Color(float(v[0]) / b, float(v[1]) / b, float(v[2]) / b), b]

func refresh() -> void:
	_load_presets()
	_updating = true
	var e := env()
	var s: Array = e.get("sun", [0.472, 0.848, 0.241])
	var d := Vector3(s[0], s[1], s[2]).normalized()
	sun_el.value = rad_to_deg(asin(clampf(d.y, -1, 1)))
	sun_az.value = rad_to_deg(atan2(d.x, d.z))
	var tint: Array = e.get("tint", [1, 1, 1])
	var stock_sun := [STOCK_SUN[0] * tint[0], STOCK_SUN[1] * tint[1], STOCK_SUN[2] * tint[2]]
	for k in rows:
		var fb: Array = {"sun_colour": stock_sun, "sky_colour": STOCK_SKY, "ground_colour": STOCK_GROUND,
			"ambient": STOCK_AMBIENT, "sky": [8.5, 9.2, 10], "bloom": [0.42, 0.45, 0.5]}[k]
		var cb := split(e.get(k), fb)
		rows[k][0].color = cb[0]
		rows[k][1].value = cb[1]
	var sky: Dictionary = e.get("skybox", {"type": "map"}) if e.get("skybox") is Dictionary else {"type": "map"}
	match sky.get("type", "map"):
		"stock":
			sky_pick.select(1 + maxi(0, SKY_MAPS.find(String(sky.get("map", "06")))))
		"panorama":
			sky_pick.select(SKY_MAPS.size() + 1)
		_:
			sky_pick.select(0)
	sky_file.text = String(sky.get("image", "(none)")).get_file() if sky.has("image") else "(none)"
	sky_bright.value = float(sky.get("brightness", 1.0))
	var sc: Dictionary = e.get("scatter", {}) if e.get("scatter") is Dictionary else {}
	haze_density.value = float(sc.get("mDensity", CLEAR_SCATTER["mDensity"]))
	haze_pick.select(0)
	for i in haze_pick.item_count:
		if haze_pick.get_item_metadata(i) == sc.get("from", "01"):
			haze_pick.select(i)
	curve_ed.set_curves(curves_of(e))
	grade_pick.select(_grade_index(curves_of(e)))
	bake_source.select(1 if _bake("source") == "bake" else 0)
	for k in bake_rows:
		bake_rows[k].value = float(_bake(k))
	_updating = false
	main._stats_later()   # detail_info
	_show_light()
	apply_preview()

func _load_presets() -> void:
	if not presets.is_empty():
		return
	var p: String = main.library_dir.path_join("light_presets.json")
	if not FileAccess.file_exists(p):
		main.run_tool("lp2light.py", ["presets", "--game", main.game, p], func():
			presets = {}
			if FileAccess.file_exists(p):
				refresh())
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	presets = d if d is Dictionary else {}
	if not presets.is_empty() and not (presets.values()[0] as Dictionary).has("curves"):   # made before curves: redo
		presets = {}
		DirAccess.remove_absolute(p)
		_load_presets()
		return
	preset_pick.clear()
	haze_pick.clear()
	grade_pick.clear()
	grade_pick.add_item("Neutral")
	grade_pick.set_item_metadata(0, "")
	for k in presets:
		preset_pick.add_item("%s (%s)" % [MAP_NAMES.get(k, k), k])
		preset_pick.set_item_metadata(preset_pick.item_count - 1, k)
		if (presets[k] as Dictionary).has("scatter"):
			haze_pick.add_item(MAP_NAMES.get(k, k) + ("  (default: clear)" if k == "01" else ""))
			haze_pick.set_item_metadata(haze_pick.item_count - 1, k)
		if (presets[k] as Dictionary).has("curves"):
			grade_pick.add_item("%s's grade" % MAP_NAMES.get(k, k))
			grade_pick.set_item_metadata(grade_pick.item_count - 1, k)

func _store_rgb(k: String) -> void:
	var c: Color = rows[k][0].color
	var b: float = rows[k][1].value
	env()[k] = [snappedf(c.r * b, 0.0001), snappedf(c.g * b, 0.0001), snappedf(c.b * b, 0.0001)]

func _on_changed() -> void:
	if _updating or main.project_dir == "":
		return
	main._push_undo("lighting")
	var e := env()
	var az := deg_to_rad(sun_az.value)
	var el := deg_to_rad(sun_el.value)
	e["sun"] = [snappedf(cos(el) * sin(az), 0.0001), snappedf(sin(el), 0.0001), snappedf(cos(el) * cos(az), 0.0001)]
	for k in rows:
		_store_rgb(k)
	var i := sky_pick.selected
	if i == 0:
		e["skybox"] = {"type": "map"}
	elif i <= SKY_MAPS.size():
		e["skybox"] = {"type": "stock", "map": SKY_MAPS[i - 1]}
	else:
		var old: Dictionary = e.get("skybox", {}) if e.get("skybox") is Dictionary else {}
		e["skybox"] = {"type": "panorama", "image": old.get("image", ""), "brightness": sky_bright.value}
	var sc: Dictionary = (e.get("scatter") as Dictionary).duplicate() if e.get("scatter") is Dictionary else CLEAR_SCATTER.duplicate()
	sc["mDensity"] = haze_density.value
	e["scatter"] = sc
	apply_preview()

func _on_haze_pick() -> void:
	if _updating or haze_pick.selected < 0:
		return
	var k: String = haze_pick.get_item_metadata(haze_pick.selected)
	var sc: Dictionary = (presets[k]["scatter"] as Dictionary).duplicate()
	sc.erase("mSunColor")
	sc["from"] = k
	env()["scatter"] = sc
	if presets[k]["scatter"].has("mSunColor"):
		env()["sky"] = presets[k]["scatter"]["mSunColor"]
	refresh()

func apply_preset() -> void:
	if preset_pick.selected < 0 or main.project_dir == "":
		return
	var k: String = preset_pick.get_item_metadata(preset_pick.selected)
	var p: Dictionary = presets[k]
	main._push_undo("")
	var e := env()
	for key in ["sun", "sun_colour", "sky_colour", "ground_colour", "ambient", "bloom"]:
		if p.has(key):
			e[key] = p[key]
	if p.has("scatter"):
		var sc: Dictionary = (p["scatter"] as Dictionary).duplicate()
		if sc.has("mSunColor"):
			e["sky"] = sc["mSunColor"]
			sc.erase("mSunColor")
		sc["from"] = k
		e["scatter"] = sc
	main.log_line("Lighting from %s's day." % MAP_NAMES.get(k, k))
	refresh()

func _grade_index(c: Dictionary) -> int:
	# the grade item whose curves these are (0 Neutral), or -1 (edited by hand: none shown)
	for i in grade_pick.item_count:
		var k: String = grade_pick.get_item_metadata(i)
		var g: Dictionary = curves_of({}) if k == "" else curves_of({"curves": presets[k]["curves"]})
		if _same_curves(g, c):
			return i
	return -1

static func _same_curves(a: Dictionary, b: Dictionary) -> bool:
	for ch in ["R", "G", "B"]:
		var pa: Array = a.get(ch, [[], []])
		var pb: Array = b.get(ch, [[], []])
		for j in 2:
			if (pa[j] as Array).size() != (pb[j] as Array).size():
				return false
			for i in (pa[j] as Array).size():
				if absf(float(pa[j][i]) - float(pb[j][i])) > 0.002:
					return false
	return true

func apply_grade() -> void:
	if grade_pick.selected < 0 or main.project_dir == "":
		return
	var k: String = grade_pick.get_item_metadata(grade_pick.selected)
	main._push_undo("")
	env()["curves"] = curves_of({"curves": presets[k]["curves"]}) if k != "" else curves_of({})
	main.log_line("Colour grading: %s." % ("neutral" if k == "" else MAP_NAMES.get(k, k) + "'s"))
	refresh()

func _on_curves() -> void:
	if _updating or main.project_dir == "":
		return
	main._push_undo("lighting")
	env()["curves"] = curve_ed.curves.duplicate(true)

func reset_light() -> void:
	main._push_undo("")
	var e := env()
	for key in ["sun_colour", "sky_colour", "ground_colour", "ambient", "scatter"]:
		e.erase(key)
	e["sun"] = [0.472, 0.848, 0.241]
	e["sky"] = [8.5, 9.2, 10]
	refresh()

func sun_from_view() -> void:
	var f: Vector3 = -main.camera.global_transform.basis.z
	sun_az.value = rad_to_deg(atan2(-f.x, -f.z))   # behind the camera: the light travels along the view

func set_panorama(path: String) -> void:
	# the image goes into the project (assets/), so the project carries it
	var dst: String = "assets/sky_" + path.get_file()
	DirAccess.make_dir_recursive_absolute(main.project_dir.path_join("assets"))
	DirAccess.copy_absolute(path, main.project_dir.path_join(dst))
	main._push_undo("")
	env()["skybox"] = {"type": "panorama", "image": dst, "brightness": sky_bright.value}
	refresh()

# ---------------------------------------------------------------- the editor's preview of it

func apply_preview() -> void:
	var e := env()
	var s: Array = e.get("sun", [0.472, 0.848, 0.241])
	main._set_sun(Vector3(s[0], s[1], s[2]))
	var sun: Array = split(e.get("sun_colour"), STOCK_SUN)
	main.sun.light_color = sun[0]
	main.sun.light_energy = sun[1] / 2.0
	var we: Environment = main.world_env
	var sky: Array = split(e.get("sky_colour"), STOCK_SKY)
	var amb: Array = split(e.get("ambient"), STOCK_AMBIENT)
	we.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	we.ambient_light_color = (sky[0] * sky[1] + amb[0] * amb[1]).clamp()
	we.ambient_light_energy = 2.0 * (sky[1] + amb[1])
	_preview_grade(curves_of(e))
	_preview_sky()
	preview_bake()

# ---------------------------------------------------------------- the ray-traced bake

func bake_settings() -> Dictionary:
	if not main.project.has("stage"):
		main.project["stage"] = {}
	if not (main.project["stage"].get("light") is Dictionary):
		main.project["stage"]["light"] = {}
	return main.project["stage"]["light"]

func _bake(k: String) -> Variant:
	return bake_settings().get(k, BAKE_DEFAULTS[k])

func _on_bake_changed() -> void:
	if _updating or main.project_dir == "":
		return
	var b := bake_settings()
	b["source"] = "bake" if bake_source.selected == 1 else "lp1"
	for k in bake_rows:
		b[k] = int(bake_rows[k].value) if k in ["bounces", "samples", "detail"] else bake_rows[k].value
	preview_bake()
	main._stats_later()   # the memory meter counts the detail (detail_estimate), and fills detail_info

func _unsplit_stats() -> Dictionary:
	var f: String = main.project_dir.path_join(".preview/geo_base.json")
	if FileAccess.file_exists(f):
		var t := FileAccess.get_modified_time(f)
		if _unsplit.get("time", -1) != t:
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(f))
			_unsplit = {"time": t, "stats": j["stats"] if j is Dictionary and j.get("stats") is Dictionary else {}}
		return _unsplit["stats"]
	return main.geometry.data.get("stats", {}) if main.geometry != null else {}

func detail_estimate() -> Dictionary:
	# what the detail setting will add when the stage is baked (lp2bake.py splits up to its vertices x detail %):
	# {} with the LP1 lightmap or no detail; else vertices / added (the stage's, at most), bytes (stage model), ram (bake)
	if main.project_dir == "" or _bake("source") != "bake" or float(_bake("detail")) <= 0:
		return {}
	var st := _unsplit_stats()
	if st.is_empty():
		return {}
	var d := float(_bake("detail")) / 100.0
	var pv := float(st.get("vertices", 0))
	var v := float(st.get("model_bytes", 0)) / STAGE_VERTEX_BYTES
	if v <= 0:
		v = pv
	return {"vertices": v, "added": v * d, "bytes": v * d * DETAIL_VERTEX_BYTES,
		"ram": BAKE_RAM_BASE + pv * (1.0 + d) * (float(_bake("samples")) * BAKE_RAM_PER_RAY + BAKE_RAM_VERTEX)}

func show_detail(model: float, total: float, target: float) -> void:
	# main._update_stats: model / total (with textures) include the detail; target the stock map's model + textures
	var e := detail_estimate()
	detail_info.visible = not e.is_empty()
	if e.is_empty():
		return
	var base_model: float = model - float(e["bytes"])
	var phys := float(OS.get_memory_info().get("physical", 0))
	var ram := float(e["ram"])
	var lines := [
		"Detail: up to +%dk stage vertices (%dk -> %dk); %d detail passes" % [int(e["added"] / 1000), int(e["vertices"] / 1000),
			int((e["vertices"] + e["added"]) / 1000), 3 + int(float(_bake("detail")) / 50)],
		"Stage model: %.1f -> %.1f MB (%.1fx the base geometry)" % [base_model / 1e6, model / 1e6, model / maxf(base_model, 1.0)],
		"Map memory: %.1f of %.1f MB (%d%% of the stock map)" % [total / 1e6, target / 1e6, int(100 * total / maxf(target, 1.0))],
		"Bake: about %.1f GB RAM%s" % [ram / 1e9, " of %.0f GB" % (phys / 1e9) if phys > 0 else ""]]
	var warn := []
	if target > 0 and total > target * 1.15:
		warn.append("over the stock map's memory: the game may run short")
	if phys > 0 and ram > phys * 0.7:
		warn.append("the bake may run out of RAM")
	if not warn.is_empty():
		lines.append("Warning: " + "; ".join(warn))
	detail_info.text = "\n".join(lines)
	detail_info.modulate = Color(1.0, 0.45, 0.35) if not warn.is_empty() else Color(1, 1, 1, 0.8)

func preview_bake() -> void:
	# the live settings on the baked materials, as lp2bake.py combine()
	if main.project_dir == "" or main.geometry == null:
		return
	var e := env()
	var raw := func(k: String, fallback: Array) -> Vector3:
		var c: Array = e.get(k) if e.get(k) is Array else fallback
		return Vector3(c[0], c[1], c[2])
	var sky := float(_bake("sky"))
	main.geometry.set_bake_params({
		"use_bake": _bake("source") == "bake" and not main.geometry.bake_ch.is_empty(),
		"sun_k": raw.call("sun_colour", STOCK_SUN) * float(_bake("sun")),
		"sky_k": raw.call("sky_colour", STOCK_SKY) * sky,
		"ground_k": raw.call("ground_colour", STOCK_GROUND) * sky,
		"lights_k": float(_bake("lights")),
		"glow_k": float(_bake("glow")),
		"gain": BAKE_CALIBRATION * pow(2.0, float(_bake("exposure"))),
		"min_light": float(_bake("min_light"))})

func bake_now() -> void:
	if main.project_dir == "":
		return
	var b := bake_settings()
	b["source"] = "bake"
	bake_source.select(1)
	main.save_project()   # the bake reads the project from disk
	bake_btn.disabled = true
	main.set_status("Baking the lighting...")
	main.run_tool("lp2bake.py", [main.project_dir], func():
		bake_btn.disabled = false
		main.load_stage(false)
		main.set_status("Lighting baked"))

func _preview_grade(c: Dictionary) -> void:
	# the tone curves as the viewport's colour correction (neutral curves: off)
	var we: Environment = main.world_env
	var neutral := true
	for ch in c:
		neutral = neutral and c[ch] == NEUTRAL_CURVE
	we.adjustment_enabled = not neutral
	we.adjustment_color_correction = null if neutral else preload("res://curves.gd").lut(c)

func _preview_sky() -> void:
	var we: Environment = main.world_env
	var e := env()
	var sky: Dictionary = e.get("skybox", {"type": "map"}) if e.get("skybox") is Dictionary else {"type": "map"}
	var png := ""
	if sky.get("type") == "panorama" and String(sky.get("image", "")) != "":
		png = main.project_dir.path_join(sky["image"])
	elif sky.get("type") == "stock":
		png = main.library_dir.path_join("skies/%s.png" % sky.get("map", "06"))
		if not FileAccess.file_exists(png):
			var tmp: String = main.library_dir.path_join("skies/tmp")
			main.run_tool("lp2sky.py", ["--game", main.game, "stock", sky.get("map", "06"), tmp, "--preview", png], _preview_sky)
			png = ""
	if png != "" and FileAccess.file_exists(png):
		var img := Image.load_from_file(png)
		if img and not img.is_empty():
			var m := PanoramaSkyMaterial.new()
			m.panorama = ImageTexture.create_from_image(img)
			m.energy_multiplier = float(sky.get("brightness", 1.0))
			we.sky.sky_material = m
			return
	var t: Array = split(e.get("sky"), [8.5, 9.2, 10])
	var ps := ProceduralSkyMaterial.new()
	ps.sky_top_color = (t[0] as Color).darkened(0.35)
	ps.sky_horizon_color = (t[0] as Color).lerp(Color.WHITE, 0.4)
	we.sky.sky_material = ps

# ---------------------------------------------------------------- placed lights

func lights() -> Array:
	if not main.project.has("lights"):
		main.project["lights"] = []
	return main.project["lights"]

static func is_light(n: Node) -> bool:
	return n.has_meta("light")

func add_markers() -> void:
	# every placed light as a marker (main.show_set calls this after the layout's markers)
	for d in lights():
		add_marker(d)

func add_marker(d: Dictionary) -> Node3D:
	var n := Node3D.new()
	n.set_meta("data", d)
	n.set_meta("object", false)
	n.set_meta("light", true)
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	if d.get("type") == "spot":
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = LIGHT_SIZE
		cone.height = LIGHT_SIZE * 2
		mi.mesh = cone
	else:
		var sp := SphereMesh.new()
		sp.radius = LIGHT_SIZE
		sp.height = LIGHT_SIZE * 2
		mi.mesh = sp
	n.add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = main.LAYER_MARKERS
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var ss := SphereShape3D.new()
	ss.radius = LIGHT_SIZE * 1.4
	shape.shape = ss
	body.add_child(shape)
	n.add_child(body)
	var dot := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.012, 0.012)
	dot.mesh = q
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dmat.fixed_size = true
	dmat.render_priority = 1
	dot.material_override = dmat
	dot.position.y = LIGHT_SIZE * 2.5
	n.add_child(dot)
	main.markers_root.add_child(n)
	main._place(n)
	update_marker(n)
	return n

func update_marker(n: Node3D) -> void:
	# the marker's colour, its spot pitch, its Godot light, and the stored direction (from yaw and pitch)
	var d: Dictionary = n.get_meta("data")
	var c := _colour(d)
	var mi := n.get_child(0) as MeshInstance3D
	(mi.material_override as StandardMaterial3D).albedo_color = c
	(n.get_child(2) as MeshInstance3D).material_override.albedo_color = c
	var old := n.get_node_or_null("light")
	if old:
		n.remove_child(old)
		old.queue_free()
	var l: Light3D
	var pitch := float(d.get("pitch", -90.0))
	if d.get("type") == "spot":
		var sl := SpotLight3D.new()
		sl.spot_range = float(d.get("end", 2000.0)) * main.CM
		sl.spot_angle = float(d.get("cone", 60.0)) / 2.0
		sl.spot_angle_attenuation = 1.0 + float(d.get("spread", 10.0)) / 20.0
		sl.rotation_degrees.x = pitch
		mi.rotation_degrees.x = pitch + 90.0   # the cone's tip at the light, opening along the beam
		l = sl
		var yaw := deg_to_rad(float(d.get("yaw", 0.0)))
		var p := deg_to_rad(pitch)
		var dir := Vector3(-sin(yaw) * cos(p), sin(p), -cos(yaw) * cos(p))
		d["dir"] = [snappedf(dir.x, 0.0001), snappedf(dir.y, 0.0001), snappedf(dir.z, 0.0001)]
	else:
		var ol := OmniLight3D.new()
		ol.omni_range = float(d.get("end", 1000.0)) * main.CM
		l = ol
	l.name = "light"
	l.light_color = c
	l.light_energy = float(d.get("brightness", 2.0))
	l.shadow_enabled = false
	n.add_child(l)

func _colour(d: Dictionary) -> Color:
	var c: Array = d.get("colour", [1, 1, 1])
	return Color(c[0], c[1], c[2])

static func label(d: Dictionary) -> String:
	return "%s light (%.1f, to %d cm)" % ["Spot" if d.get("type") == "spot" else "Point", float(d.get("brightness", 2.0)), int(d.get("end", 1000))]

func add_light(type: String) -> void:
	if main.project_dir == "":
		return
	var mp: Vector2 = main.get_viewport().get_visible_rect().size / 2
	var hit: Dictionary = main._mouse_ray(mp, 1 << (main.LAYER_STAGE - 1))
	var at: Vector3 = hit["position"] if hit else main.camera.global_position - main.camera.global_transform.basis.z * 10.0
	at.y += 3.0 if type == "spot" else 2.0
	var d := {"type": type, "pos": [at.x / main.CM, at.y / main.CM, at.z / main.CM], "yaw": 0.0, "colour": [1.0, 0.9, 0.75],
		"brightness": 2.5, "start": 100.0, "end": 1500.0 if type == "point" else 2500.0}
	if type == "spot":
		d.merge({"pitch": -90.0, "cone": 60.0, "spread": 10.0})
	main._push_undo("")
	lights().append(d)
	var n := add_marker(d)
	main._rebuild_outliner()
	main.select([n])
	main.log_line("Added a %s light; move it with the gizmo, set it up in Lighting (L)." % type)

func delete_lights(ns: Array) -> void:
	for n in ns:
		lights().erase(n.get_meta("data"))
		main.markers_root.remove_child(n)
		n.queue_free()

func duplicate_lights(ns: Array) -> Array:
	var out: Array = []
	for n in ns:
		var d: Dictionary = (n.get_meta("data") as Dictionary).duplicate(true)
		d["pos"][0] = float(d["pos"][0]) + 200.0
		lights().append(d)
		out.append(add_marker(d))
	return out

func _selected_lights() -> Array:
	return main.selection.filter(func(n): return is_instance_valid(n) and is_light(n))

func _light_editor() -> Dictionary:
	var ed := {"box": VBoxContainer.new(), "title": main._label(""), "rows": {}, "node": null}
	ed["box"].add_child(ed["title"])
	var lg := GridContainer.new()
	lg.columns = 2
	lg.add_child(main._label("Colour"))
	var lcp := ColorPickerButton.new()
	lcp.edit_alpha = false
	lcp.custom_minimum_size = Vector2(120, 0)
	lcp.color_changed.connect(func(_c): _on_light_changed(ed))
	lg.add_child(lcp)
	ed["rows"]["colour"] = lcp
	for f in [["brightness", "Brightness", 0.0, 20.0, 0.05, "Stock lights: 2 to 3"],
			["start", "Full light to (cm)", 0.0, 100000.0, 10.0, "The light is at full strength up to this distance"],
			["end", "Fades out at (cm)", 10.0, 100000.0, 10.0, "No light past this distance (stock: 1000 to 3000)"],
			["cone", "Cone (deg)", 1.0, 179.0, 1.0, "The spot's full angle"],
			["spread", "Soft edge (deg)", 0.0, 90.0, 1.0, "How far the edge fades"],
			["pitch", "Pitch (deg)", -90.0, 90.0, 1.0, "Up / down: -90 points straight down"]]:
		lg.add_child(main._label(f[1]))
		ed["rows"][f[0]] = _num(lg, f[2], f[3], f[4], f[5], func(): _on_light_changed(ed))
	ed["box"].add_child(lg)
	return ed

func _show_light() -> void:
	var ls := _selected_lights()
	light_ed["box"].visible = ls.size() == 1
	if ls.size() == 1:
		_fill(light_ed, ls[0])

func _fill(ed: Dictionary, n: Node3D) -> void:
	_updating = true
	ed["node"] = n
	var rows: Dictionary = ed["rows"]
	var d: Dictionary = n.get_meta("data")
	var spot: bool = d.get("type") == "spot"
	ed["title"].text = label(d)
	rows["colour"].color = _colour(d)
	for f in ["brightness", "start", "end", "cone", "spread", "pitch"]:
		rows[f].value = float(d.get(f, {"brightness": 2.0, "start": 100.0, "end": 1000.0, "cone": 60.0, "spread": 10.0, "pitch": -90.0}[f]))
		if f in ["cone", "spread", "pitch"]:
			rows[f].get_parent().get_child(rows[f].get_index() - 1).visible = spot
			rows[f].visible = spot
	_updating = false

func _on_light_changed(ed: Dictionary) -> void:
	var n: Variant = ed["node"]
	if _updating or n == null or not is_instance_valid(n):
		return
	main._push_undo("light")
	var rows: Dictionary = ed["rows"]
	var d: Dictionary = n.get_meta("data")
	var c: Color = rows["colour"].color
	d["colour"] = [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001)]
	for f in ["brightness", "start", "end"]:
		d[f] = rows[f].value
	if d.get("type") == "spot":
		for f in ["cone", "spread", "pitch"]:
			d[f] = rows[f].value
	update_marker(n)
	var ref: Variant = n.get_meta("item") if n.has_meta("item") else null
	if ref != null and is_instance_valid(ref):
		(ref as TreeItem).set_text(0, label(d))
	ed["title"].text = label(d)
	if ed == popup_ed and visible:
		_show_light()

func light_menu(n: Node3D, at: Vector2) -> void:
	# right-click on a light: select it and edit it in a popup by the mouse
	main.select([n])
	_fill(popup_ed, n)
	light_popup.reset_size()
	var win: Vector2 = main.get_viewport().get_visible_rect().size
	var sz := Vector2(light_popup.size)
	light_popup.popup(Rect2i(Vector2i(at.clamp(Vector2.ZERO, (win - sz).max(Vector2.ZERO))), Vector2i(sz)))

func _popup_act(f: Callable) -> void:
	light_popup.hide()
	f.call()

func selection_changed() -> void:
	if visible:
		_show_light()
