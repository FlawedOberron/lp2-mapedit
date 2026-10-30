extends Window
# Floating fog and weather window (H): the map's distance fog and height fog, and its weather (rain / snow / ash,
# lp2weather.py: environment.weather {type, amount 0..100, layouts [4 x on], volumes [{pos, size} cm]}; the
# no-weather boxes show in the view as blue boxes).
# Fog: Settings go to project.json's environment.fog
# (heights and distances in cm, like the layout; the window shows metres); lp2scenebox.py writes them into every
# zone of the SceneBox at export (the game's fog records, with the stock maps' curves). Colour alpha is the fog's
# strength: 0 = none, 1 = solid colour at the far end. The view's fog (Godot depth fog) is an approximation.

# the stock maps' whole-map zone (priority 15): [on, start, end, colour + alpha, height top, bottom, colour + alpha]
const PRESETS := {
	"00": [true, -1000, 30000, [0.506, 0.641, 0.703, 1.0], -32000, -124000, [0.213, 0.181, 0.165, 0.476]],
	"02": [true, 2000, 40000, [0.0, 0.8, 0.166, 0.0], -1350, -2500, [0.106, 0.628, 0.774, 0.2]],
	"03": [true, 4000, 40000, [0.48, 0.6, 0.72, 0.5], 100, 0, [0.0, 0.0, 0.0, 0.0]],
	"05": [true, 1500, 50000, [0.077, 0.098, 0.101, 0.597], 250, -300, [0.084, 0.111, 0.111, 0.85]],
	"06": [true, 100, 6000, [0.217, 0.249, 0.283, 0.9], 0, -500, [0.0, 0.479, 0.584, 0.9]],
	"07": [true, 0, 11000, [0.075, 0.07, 0.064, 0.512], 100, 0, [0.0, 0.0, 0.0, 0.0]],
	"08": [true, -3000, 7000, [0.116, 0.259, 0.324, 0.656], 89000, 198000, [0.913, 0.911, 1.0, 0.417]],
	"10": [true, 1000, 20000, [0.885, 0.986, 0.997, 1.0], 100, 0, [0.0, 0.0, 0.0, 0.0]],
	"11": [true, 0, 10000, [0.0, 0.458, 1.0, 1.0], -1500, -5500, [0.0, 0.814, 0.799, 0.721]],
	"15": [true, 2000, 12000, [0.555, 0.705, 1.0, 0.919], 100, 0, [0.0, 0.0, 0.0, 0.0]],
}
const DEFAULT := {"on": false, "start": 2000.0, "end": 30000.0, "colour": [0.6, 0.65, 0.7], "density": 0.5,
	"height_on": false, "height_top": 0.0, "height_bottom": -1000.0, "height_colour": [0.6, 0.65, 0.7], "height_density": 0.5}

var main: Node
var preset_pick: OptionButton
var on: CheckBox
var colour: ColorPickerButton
var density: SpinBox
var start: SpinBox
var end: SpinBox
var h_on: CheckBox
var h_colour: ColorPickerButton
var h_density: SpinBox
var h_top: SpinBox
var h_bottom: SpinBox
var w_type: OptionButton
var w_amount: SpinBox
var w_layouts: Array = []
var _updating := false

const WEATHER := [["", "None"], ["rain", "Rain (Turbulent Jungle)"], ["rain_heavy", "Rain (The Great Outdoors)"],
	["snow", "Snow (Frozen Wasteland)"], ["ash", "Falling ash (Desecration)"]]

func _init() -> void:
	title = "Fog and weather"
	size = Vector2i(420, 760)
	min_size = Vector2i(340, 300)
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
	var pr := HBoxContainer.new()
	preset_pick = OptionButton.new()
	preset_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_pick.tooltip_text = "A stock map's fog (its whole-map zone)"
	for k in PRESETS:
		preset_pick.add_item("%s (%s)" % [main.lighting.MAP_NAMES.get(k, k), k])
		preset_pick.set_item_metadata(preset_pick.item_count - 1, k)
	pr.add_child(preset_pick)
	main._button(pr, "Use", apply_preset)
	main._button(pr, "Clear", clear).tooltip_text = "No fog (the export's default)"
	v.add_child(pr)

	v.add_child(main.lighting._heading("Distance fog"))
	var g := GridContainer.new()
	g.columns = 2
	on = _check(g, "On", "Fog that thickens with distance from the camera")
	colour = _colour(g, "Colour", "The fog's colour")
	density = _num(g, "Strength", 0, 1, 0.01, "How solid the fog gets at its far end (stock 0.5 to 1)")
	start = _num(g, "Starts at (m)", -500, 2000, 1, "Distance where the fog begins (stock -50 to 40 m; below 0 = some fog right at the camera)")
	end = _num(g, "Full at (m)", 1, 5000, 1, "Distance where it reaches full strength (stock 60 to 500 m)")
	v.add_child(g)

	v.add_child(HSeparator.new())
	v.add_child(main.lighting._heading("Height fog"))
	var hg := GridContainer.new()
	hg.columns = 2
	h_on = _check(hg, "On", "Fog lying low: thin at the top height, full at the bottom height (mist in a valley, haze over water)")
	h_colour = _colour(hg, "Colour", "The low fog's colour")
	h_density = _num(hg, "Strength", 0, 1, 0.01, "How solid it gets at the bottom height (stock 0.2 to 0.9)")
	h_top = _num(hg, "Top (m)", -2000, 2000, 0.5, "Height where it begins (the map's units: the layout's Y)")
	h_bottom = _num(hg, "Bottom (m)", -2000, 2000, 0.5, "Height where it is full strength (below the top)")
	v.add_child(hg)
	var hint: Label = main._label("Covers the whole map. The view shows an approximation;\nthe game's fog can look stronger or softer.")
	v.add_child(hint)

	v.add_child(HSeparator.new())
	v.add_child(main.lighting._heading("Weather"))
	var wg := GridContainer.new()
	wg.columns = 2
	wg.add_child(main._label("Type"))
	w_type = OptionButton.new()
	for w in WEATHER:
		w_type.add_item(w[1])
	w_type.tooltip_text = "The falling effect, taken from the stock map that has it (the one thing a custom map borrows)"
	w_type.item_selected.connect(func(_i): _on_changed())
	wg.add_child(w_type)
	w_amount = _num(wg, "Strength", 0, 100, 1, "How heavy (the game's weather rate; stock 35 to 50). The match's Weather rule may override it")
	v.add_child(wg)
	var lr := HBoxContainer.new()
	lr.add_child(main._label("On layouts"))
	for i in 4:
		var c := CheckBox.new()
		c.text = str(i + 1)
		c.tooltip_text = "Weather on layout %d. Untested: the map has 4 weather schedulers, which may be the 4 layouts; if not, the first one counts" % (i + 1)
		c.toggled.connect(func(_b): _on_changed())
		lr.add_child(c)
		w_layouts.append(c)
	v.add_child(lr)
	var br := HBoxContainer.new()
	main._button(br, "Add weather limiter volume", func(): main.volumes.add_volume("weather")).tooltip_text = \
		"Less or no weather inside (indoors, under cover; its Weather % in the inspector): a volume where the view points"
	v.add_child(br)
	visibility_changed.connect(func(): if visible: refresh())

func _check(g: GridContainer, t: String, tip: String) -> CheckBox:
	g.add_child(main._label(t))
	var c := CheckBox.new()
	c.tooltip_text = tip
	c.toggled.connect(func(_b): _on_changed())
	g.add_child(c)
	return c

func _colour(g: GridContainer, t: String, tip: String) -> ColorPickerButton:
	g.add_child(main._label(t))
	var c := ColorPickerButton.new()
	c.custom_minimum_size = Vector2(70, 0)
	c.edit_alpha = false
	c.tooltip_text = tip
	c.color_changed.connect(func(_c): _on_changed())
	g.add_child(c)
	return c

func _num(g: GridContainer, t: String, lo: float, hi: float, step: float, tip: String) -> SpinBox:
	g.add_child(main._label(t))
	var s: SpinBox = main._spin(lo, hi, step)
	s.tooltip_text = tip
	s.value_changed.connect(func(_v): _on_changed())
	g.add_child(s)
	return s

# ---------------------------------------------------------------- environment.fog <-> controls

func fog() -> Dictionary:
	var e: Dictionary = main.lighting.env()
	var f: Dictionary = DEFAULT.duplicate(true)
	if e.get("fog") is Dictionary:
		f.merge(e["fog"], true)
	return f

static func _rgb(c: Variant) -> Color:
	var a: Array = c
	return Color(float(a[0]), float(a[1]), float(a[2]))

func refresh() -> void:
	_updating = true
	var f := fog()
	on.button_pressed = bool(f["on"])
	colour.color = _rgb(f["colour"])
	density.value = float(f["density"])
	start.value = float(f["start"]) * main.CM
	end.value = float(f["end"]) * main.CM
	h_on.button_pressed = bool(f["height_on"])
	h_colour.color = _rgb(f["height_colour"])
	h_density.value = float(f["height_density"])
	h_top.value = float(f["height_top"]) * main.CM
	h_bottom.value = float(f["height_bottom"]) * main.CM
	var w := weather()
	w_type.select(maxi(0, WEATHER.map(func(x): return x[0]).find(String(w.get("type", "")))))
	w_amount.value = float(w.get("amount", 50))
	var lay: Array = w.get("layouts", [true, true, true, true])
	for i in 4:
		w_layouts[i].button_pressed = bool(lay[i]) if i < lay.size() else true
	_updating = false
	apply_preview()

func weather() -> Dictionary:
	var e: Dictionary = main.lighting.env()
	return e["weather"] if e.get("weather") is Dictionary else {}

func _on_changed() -> void:
	if _updating or main.project_dir == "":
		return
	main._push_undo("fog")
	var w := weather().duplicate(true)
	w["type"] = WEATHER[w_type.selected][0]
	w["amount"] = w_amount.value
	w["layouts"] = w_layouts.map(func(c): return c.button_pressed)
	if w["type"] == "" and (w.get("volumes", []) as Array).is_empty():
		main.lighting.env().erase("weather")
	else:
		main.lighting.env()["weather"] = w
	var c := colour.color
	var hc := h_colour.color
	main.lighting.env()["fog"] = {"on": on.button_pressed, "colour": [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001)],
		"density": density.value, "start": start.value / main.CM, "end": maxf(end.value, start.value + 1) / main.CM,
		"height_on": h_on.button_pressed, "height_colour": [snappedf(hc.r, 0.001), snappedf(hc.g, 0.001), snappedf(hc.b, 0.001)],
		"height_density": h_density.value, "height_top": h_top.value / main.CM, "height_bottom": h_bottom.value / main.CM}
	apply_preview()

func apply_preset() -> void:
	if preset_pick.selected < 0 or main.project_dir == "":
		return
	var k: String = preset_pick.get_item_metadata(preset_pick.selected)
	var p: Array = PRESETS[k]
	main._push_undo("")
	main.lighting.env()["fog"] = {"on": p[0] and p[3][3] > 0, "start": float(p[1]), "end": float(p[2]),
		"colour": p[3].slice(0, 3), "density": p[3][3],
		"height_on": p[6][3] > 0, "height_top": float(p[4]), "height_bottom": float(p[5]),
		"height_colour": p[6].slice(0, 3), "height_density": p[6][3]}
	main.log_line("Fog from %s." % main.lighting.MAP_NAMES.get(k, k))
	refresh()

func clear() -> void:
	main._push_undo("")
	main.lighting.env().erase("fog")
	refresh()

# ---------------------------------------------------------------- no-weather boxes
# They are volumes now ("weather", volumes.gd); volumes.migrate_weather() moves an older project's boxes over.

# ---------------------------------------------------------------- the editor's view of it

func apply_preview() -> void:
	# distance fog: Godot's depth fog; height fog: our own overlay (heightfog.gdshader), so each has its colour
	var we: Environment = main.world_env
	var f := fog()
	var dist: bool = f["on"] and float(f["density"]) > 0 and main.view_on("fog")
	var low: bool = f["height_on"] and float(f["height_density"]) > 0 and main.view_on("fog")
	_height_overlay(f, low)
	we.fog_enabled = dist
	if not dist:
		return
	we.fog_mode = Environment.FOG_MODE_DEPTH
	we.fog_light_color = _rgb(f["colour"])
	we.fog_light_energy = 1.0
	we.fog_sun_scatter = 0.0
	we.fog_sky_affect = 0.0
	we.fog_density = float(f["density"])
	we.fog_depth_begin = maxf(0.0, float(f["start"]) * main.CM)
	we.fog_depth_end = maxf(we.fog_depth_begin + 1.0, float(f["end"]) * main.CM)
	we.fog_depth_curve = 1.0
	we.fog_height_density = 0.0   # the height fog is the overlay's

var _overlay: MeshInstance3D

func _height_overlay(f: Dictionary, on: bool) -> void:
	if _overlay == null:
		if not on:
			return
		_overlay = MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(2, 2)
		_overlay.mesh = q
		var mat := ShaderMaterial.new()
		mat.shader = load("res://heightfog.gdshader")
		_overlay.material_override = mat
		_overlay.extra_cull_margin = 16384.0   # never culled: it covers the screen wherever the camera looks
		_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		main.camera.add_child(_overlay)
	_overlay.visible = on
	if not on:
		return
	var m: ShaderMaterial = _overlay.material_override
	m.set_shader_parameter("colour", _rgb(f["height_colour"]))
	m.set_shader_parameter("strength", float(f["height_density"]))
	m.set_shader_parameter("top", float(f["height_top"]) * main.CM)
	m.set_shader_parameter("bottom", float(f["height_bottom"]) * main.CM)
