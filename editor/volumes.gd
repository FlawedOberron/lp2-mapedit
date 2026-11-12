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
#   "damage": {"player": pct, "vs": pct, "player_kill": bool, "vs_kill": bool}
#                     damage over time inside: % of full health per second, separately for players and VS, or a kill at
#                     once (lava); the game's own burning damage (map.json "damage_volumes", xlive mod damage.cpp)
#   "marker": name    a script marker: a named point for scripts (its floor centre, facing its yaw: the arrow), found by
#                     name or wildcard (outpost_*); its box is the area for "anywhere inside" (map.json "script_markers")
#   "oneway": {"players": bool, "vs": bool, "bullets": bool, "grenades": bool, "akrid": bool}
#                     a one-way wall: those ticked may cross the box along its arrow only (its yaw, as markers'); going
#                     back through it, characters are held, bullets and grenades vanish (map.json "oneway_volumes", xlive
#                     mod oneway.cpp)
#   "force": {"mode": "continuous" | "impulse" | "velocity", "vector": [x, y, z], "local": bool,
#             "players": bool, "vs": bool, "bullets": bool, "grenades": bool, "akrid": bool}
#                     pushes what's ticked: continuous = an acceleration while inside (m/s per second: wind, currents),
#                     impulse = m/s added once on entering (again after leaving), velocity = the velocity set to m/s on
#                     entering (grav lifts, man cannons); "local": the vector turns with the box's yaw (z along -arrow)
#                     (map.json "force_volumes", xlive mod force.cpp)
#   "limits": true    map limits: marks the playable space, no effect in the game. Several (or one with extra boxes) make
#                     an odd shape: inside any of them counts. With any limits volume, the navmesh keeps only what's
#                     inside (lp2navmap.py); later also the radar's extent
#   "barrier": true   an invisible wall / roof: the box goes into the movement collision only (lp2mapc.py), so players
#                     and VS are stopped while bullets (and, it's expected, the grapple, which aims with them) pass
#   "spawn": {"team": 0 | 1 | -1, "order": n}
#                     a spawn zone for team games' Spawning > Spawn Area: Zones (map.json "spawn_volumes", xlive mod
#                     respawn.cpp): a team respawns at the free-for-all and team points inside the zones it owns. "team":
#                     who owns it at the start (-1 nobody); "order": its place on the line from team A's side (low) to
#                     team B's (high). Zones: Dynamic hands a zone to a team that holds it alone for 10 s, next (by order)
#                     to one that team owns already
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
	"damage": Color(1.0, 0.45, 0.05), "marker": Color(1.0, 0.9, 0.2),
	"oneway": Color(0.3, 1.0, 0.45), "limits": Color(0.85, 0.85, 0.95),
	"barrier": Color(0.55, 0.75, 1.0), "force": Color(0.2, 0.95, 0.95), "spawn": Color(1.0, 0.4, 0.7), "none": Color(0.6, 0.6, 0.6)}
const ADD := [["kill", "Kill volume (pit)"], ["gravity", "Gravity volume"], ["post", "Post-process volume (screen colour)"],
	["weather", "Weather limiter volume (indoors)"], ["water", "Water volume (surface at its top)"],
	["sound", "Sound volume (reverb zone)"], ["damage", "Damage volume (lava, fire)"],
	["marker", "Script marker (a named point for scripts)"], ["oneway", "One-way wall (pass along its arrow only)"],
	["force", "Force volume (lift, man cannon, wind)"], ["limits", "Map limits (marks the level's bounds)"], ["barrier", "Barrier (invisible wall / roof, no grapple)"],
	["spawn", "Spawn zone (team games: Spawning > Zones)"]]
const SPAWN := {"team": 0, "order": 0}   # a new one
const SPAWN_TEAMS := [[0, "Team A"], [1, "Team B"], [-1, "Nobody (taken in Zones: Dynamic)"]]
const ONEWAY := {"players": true, "vs": true, "bullets": false, "grenades": false, "akrid": false}   # a new one
const ONEWAY_NAMES := [["players", "Players"], ["vs", "VS"], ["bullets", "Bullets"], ["grenades", "Grenades"], ["akrid", "Akrid"]]
const FORCE := {"mode": "velocity", "vector": [0.0, 15.0, 0.0], "local": true, "players": true, "vs": true,
	"bullets": false, "grenades": false, "akrid": false}   # a new one: a grav lift
const FORCE_MODES := [["continuous", "Continuous force (m/s per second, while inside)"],
	["impulse", "Immediate force (m/s added on entering)"], ["velocity", "Immediate velocity (m/s set on entering)"]]
const DAMAGE := {"player": 0.0, "vs": 10.0, "player_kill": true, "vs_kill": false}   # a new one: lava
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
var limits_on: CheckBox
var barrier_on: CheckBox
var damage_on: CheckBox
var damage_rows: Array = []  # the damage controls, shown while it's on
var damage_spins := {}       # player / vs: % per second
var damage_kills := {}       # player / vs: kill at once
var marker_on: CheckBox
var spawn_on: CheckBox
var spawn_team: OptionButton
var spawn_order: SpinBox
var spawn_rows: Array = []   # the spawn zone controls, shown while it's on
var oneway_on: CheckBox
var oneway_flags := {}       # players / vs / bullets / grenades / akrid
var oneway_rows: Array = []
var marker_name: LineEdit
var force_on: CheckBox
var force_mode: OptionButton
var force_spins: Array = []   # x / y / z
var force_local: CheckBox
var force_flags := {}         # players / vs / bullets / grenades / akrid
var force_rows: Array = []
var force_note: Label
var force_target_rows: Array = []   # shown for impulse / velocity
var force_arc_spin: SpinBox
var force_target_btn: Button
var target_picking: Node3D = null   # the volume whose landing point the next click sets
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
	limits_on = _check(g, "Map limits", "Marks the level's bounds (no effect in the game). Several, or one with extra boxes "
		+ "(Ctrl+Shift+drag a face), make an odd shape: inside any counts. The navmesh keeps only what's inside them")
	g.add_child(Control.new())
	barrier_on = _check(g, "Barrier", "An invisible wall or roof: players and VS can't pass it; bullets fly through and the grapple "
		+ "can't hook onto it. Thin boxes work best; Ctrl+drag a face to size it")
	g.add_child(Control.new())
	damage_on = _check(g, "Damage", "Damage over time inside, separately for players and VS: % of full health per second, or Kill "
		+ "at once (e.g. lava: kills players, burns VS). Uses the game's burning damage (xlive mod)")
	g.add_child(Control.new())
	for k in [["player", "  Players %/s"], ["vs", "  VS %/s"]]:
		var l: Label = main._label(k[1])
		var h := HBoxContainer.new()
		var sp: SpinBox = main._spin(0.0, 100.0, 1.0)
		sp.tooltip_text = "Percent of full health lost per second inside (hits every quarter second)"
		sp.value_changed.connect(func(_v): _on_changed())
		h.add_child(sp)
		var kc := CheckBox.new()
		kc.text = "Kill"
		kc.tooltip_text = "Killed at once on entering"
		kc.toggled.connect(func(_b): _on_changed())
		h.add_child(kc)
		g.add_child(l)
		g.add_child(h)
		damage_spins[k[0]] = sp
		damage_kills[k[0]] = kc
		damage_rows += [l, h]
	marker_on = _check(g, "Script name (marker)", "A named point scripts can find (by name, or many at once with a wildcard: "
		+ "spawn_* finds spawn_1, spawn_2...): its floor centre facing the arrow, or anywhere in its box")
	marker_name = LineEdit.new()
	marker_name.placeholder_text = "name"
	marker_name.tooltip_text = "Letters, digits and _ (not case sensitive); several markers may share a prefix"
	marker_name.text_changed.connect(func(_t): _on_changed())
	g.add_child(marker_name)
	spawn_on = _check(g, "Spawn zone", "Team games with Spawning > Spawn Area: Zones: the owning team respawns at the "
		+ "free-for-all and team spawn points inside (xlive mod). Zones: Dynamic hands a zone to the other team once it "
		+ "holds it alone for 10 s, next to a zone it owns already (by order)")
	g.add_child(Control.new())
	var stl: Label = main._label("  Owner")
	spawn_team = OptionButton.new()
	for t in SPAWN_TEAMS:
		spawn_team.add_item(t[1])
	spawn_team.tooltip_text = "Who spawns here at the start"
	spawn_team.item_selected.connect(func(_i): _on_changed())
	g.add_child(stl)
	g.add_child(spawn_team)
	var sol: Label = main._label("  Order")
	spawn_order = main._spin(0.0, 99.0, 1.0)
	spawn_order.tooltip_text = "Its place on the line from team A's side (low) to team B's (high); all the same = no line"
	spawn_order.value_changed.connect(func(_v): _on_changed())
	g.add_child(sol)
	g.add_child(spawn_order)
	spawn_rows += [stl, spawn_team, sol, spawn_order]
	oneway_on = _check(g, "One-way wall", "What's ticked may cross the box only along its arrow (turn it with the yaw); "
		+ "going back through, players, VS and akrid are held and bullets and grenades vanish (xlive mod)")
	g.add_child(Control.new())
	var ol: Label = main._label("  Holds back")
	var of := HFlowContainer.new()
	for k in ONEWAY_NAMES:
		var oc := CheckBox.new()
		oc.text = k[1]
		oc.toggled.connect(func(_b): _on_changed())
		of.add_child(oc)
		oneway_flags[k[0]] = oc
	g.add_child(ol)
	g.add_child(of)
	oneway_rows += [ol, of]
	force_on = _check(g, "Force", "Pushes what's ticked: a steady push while inside (wind, currents), a kick on entering, or a "
		+ "new velocity on entering (grav lifts, man cannons). Players and VS keep what they're given in the air and stop on "
		+ "the ground; grenades get it as their own velocity (xlive mod)")
	g.add_child(Control.new())
	var fml: Label = main._label("  Mode")
	force_mode = OptionButton.new()
	for fm in FORCE_MODES:
		force_mode.add_item(fm[1])
	force_mode.item_selected.connect(func(_i): _on_changed())
	g.add_child(fml)
	g.add_child(force_mode)
	force_rows += [fml, force_mode]
	for a in [["X", "Sideways (local: the box's own x)"], ["Y", "Up"], ["Z", "Local: back from the arrow; the arrow is -Z"]]:
		var l: Label = main._label("  " + a[0] + " (m/s)")
		var sp: SpinBox = main._spin(-500.0, 500.0, 0.5)
		sp.tooltip_text = a[1]
		sp.value_changed.connect(func(_v): _on_changed())
		g.add_child(l)
		g.add_child(sp)
		force_spins.append(sp)
		force_rows += [l, sp]
	var fll: Label = main._label("")
	force_local = CheckBox.new()
	force_local.text = "Turns with the box (local)"
	force_local.tooltip_text = "On: the vector follows the box's yaw (Z along its arrow is -Z), so turning the box aims it"
	force_local.toggled.connect(func(_b): _on_changed())
	g.add_child(fll)
	g.add_child(force_local)
	force_rows += [fll, force_local]
	var ffl: Label = main._label("  Affects")
	var ff := HFlowContainer.new()
	for k in ONEWAY_NAMES:
		var fc := CheckBox.new()
		fc.text = k[1]
		fc.toggled.connect(func(_b): _on_changed())
		ff.add_child(fc)
		force_flags[k[0]] = fc
	g.add_child(ffl)
	g.add_child(ff)
	force_rows += [ffl, ff]
	var tgl: Label = main._label("  Target")
	var th := HBoxContainer.new()
	force_target_btn = Button.new()
	force_target_btn.text = "Pick target…"
	force_target_btn.tooltip_text = ("Click it, then click where things launched from the box should land: X / Y / Z are worked out "
		+ "for that (the arc's peak this high above the higher end; the mod's air drag allowed for). Moving or turning the box "
		+ "works them out again; typing X / Y / Z drops the target")
	force_target_btn.pressed.connect(_start_target_pick)
	th.add_child(force_target_btn)
	th.add_child(main._label(" Arc (m)"))
	force_arc_spin = main._spin(0.0, 200.0, 0.5)
	force_arc_spin.tooltip_text = "How high the path's peak is above the higher of the launch and the target"
	force_arc_spin.value_changed.connect(func(_v): _on_changed())
	th.add_child(force_arc_spin)
	g.add_child(tgl)
	g.add_child(th)
	force_target_rows = [tgl, th]
	force_rows += force_target_rows
	g.add_child(main._label(""))
	force_note = main._label("")
	force_note.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	g.add_child(force_note)
	force_rows.append(force_note)
	force_rows.append(g.get_child(g.get_child_count() - 2))
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

func ensure_id(d: Dictionary) -> String:
	# a volume's id for scripts (scripts.gd), given on first use
	if str(d.get("id", "")) == "":
		var used := {}
		for x in volumes():
			used[str(x.get("id", ""))] = true
		var k := 1
		while used.has("vol%d" % k):
			k += 1
		d["id"] = "vol%d" % k
	return d["id"]

func select_id(id: String) -> void:
	for n in main.markers_root.get_children():
		if is_volume(n) and str(n.get_meta("data").get("id", "")) == id and id != "":
			main.select([n])
			main.frame_selected()
			return

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
	if d.has("marker"):
		out.append("marker")
	if d.get("damage"):
		out.append("damage")
	if d.get("oneway"):
		out.append("oneway")
	if d.get("spawn"):
		out.append("spawn")
	if d.get("force"):
		out.append("force")
	if d.get("limits", false):
		out.append("limits")
	if d.get("barrier", false):
		out.append("barrier")
	return out

static func spawn_team_name(team: int) -> String:
	return "team A" if team == 0 else "team B" if team == 1 else "nobody"

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
			else "damage" if e == "damage"
			else "one-way" if e == "oneway"
			else "spawn zone (%s, order %d)" % [spawn_team_name(int(d["spawn"].get("team", -1))), int(d["spawn"].get("order", 0))] if e == "spawn"
			else "force (%s)" % str(d["force"].get("mode", "continuous")) if e == "force"
			else "map limits" if e == "limits"
			else "barrier" if e == "barrier"
			else "marker " + str(d["marker"]) if e == "marker"
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
	if d.get("force") and bs:   # the force's direction: an arrow from the box's centre, longer for more
		var vec := force_world(d, false)
		if vec.length() > 0.001:
			var b0: AABB = bs[0]
			var from := b0.get_center()
			var dir := vec.normalized()
			var tip := from + dir * clampf(vec.length() * 0.1, 0.5, 4.0)
			var side := dir.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT).normalized() * 0.25
			for q in [[from, tip], [tip, tip - dir * 0.4 + side], [tip, tip - dir * 0.4 - side]]:
				lines.append(q[0])
				lines.append(q[1])
	if d.get("force") and bs:
		if d["force"].has("target") and str(d["force"].get("mode", "")) != "continuous":
			solve_target(n, d)
			var tl: Vector3 = n.to_local(_v3(d["force"]["target"]) * main.CM) if n.is_inside_tree() else Vector3.ZERO
			for ax in [Vector3(0.4, 0, 0), Vector3(0, 0.4, 0), Vector3(0, 0, 0.4)]:   # the target: a cross
				lines.append(tl - ax)
				lines.append(tl + ax)
		lines.append_array(force_arc(n, d, bs))
	if (d.has("marker") or d.get("oneway")) and bs:   # facing: an arrow along -z at half height, like the spawn markers' cone
		var b0: AABB = bs[0]
		var h := b0.position.y + b0.size.y / 2
		var tip := Vector3(0, h, b0.position.z - 0.6)
		for q in [[Vector3(0, h, 0), tip], [tip, tip + Vector3(0.25, 0, 0.3)], [tip, tip + Vector3(-0.25, 0, 0.3)]]:
			lines.append(q[0])
			lines.append(q[1])
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
		"damage": d["damage"] = DAMAGE.duplicate()
		"marker":
			d["marker"] = unique_marker("marker_1")
			d["size"] = [100.0, 200.0, 100.0]
		"limits":
			d["limits"] = true
			d["size"] = [10000.0, 5000.0, 10000.0]
		"barrier":
			d["barrier"] = true
			d["size"] = [1000.0, 600.0, 20.0]   # a thin wall
		"force":
			d["force"] = FORCE.duplicate(true)
			d["size"] = [300.0, 600.0, 300.0]   # a lift shaft
		"spawn":
			d["spawn"] = SPAWN.duplicate()
			d["size"] = [3000.0, 1000.0, 3000.0]
		"oneway":
			d["oneway"] = ONEWAY.duplicate()
			d["size"] = [1000.0, 600.0, 100.0]   # a thin wall
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
		d.erase("id")   # scripts point at the original
		if d.has("marker"):
			d["marker"] = unique_marker(str(d["marker"]))   # spawn_1 -> spawn_2
		d["pos"][0] = float(d["pos"][0]) + float(d["size"][0]) + 100.0
		volumes().append(d)
		out.append(add_marker(d))
	return out

func unique_marker(want: String) -> String:
	# want, or with its trailing number counted up until no marker has the name
	var used := {}
	for x in volumes():
		if x.has("marker"):
			used[str(x["marker"]).to_lower()] = true
	if not used.has(want.to_lower()):
		return want
	var stem := want
	var k := 1
	var r := RegEx.create_from_string("^(.*?)(\\d+)$")
	var m := r.search(want)
	if m:
		stem = m.get_string(1)
		k = int(m.get_string(2))
	else:
		stem += "_"
	while used.has((stem + str(k)).to_lower()):
		k += 1
	return stem + str(k)

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
	marker_on.button_pressed = d.has("marker")
	if marker_name.text != str(d.get("marker", "")):
		marker_name.text = str(d.get("marker", ""))
	marker_name.editable = marker_on.button_pressed
	var nb: int = (d.get("boxes", []) as Array).size()
	boxes_label.text = "%d boxes" % (nb + 1) if nb else "1 box"
	remove_box.disabled = nb == 0
	weather_on.button_pressed = d.has("weather")
	water_on.button_pressed = d.get("water", false)
	limits_on.button_pressed = d.get("limits", false)
	barrier_on.button_pressed = d.get("barrier", false)
	sound_on.button_pressed = d.get("sound") != null
	var rk: String = str((d.get("sound") if d.get("sound") else {}).get("reverb", REVERBS[0][0]))
	reverb_pick.selected = maxi(0, REVERBS.map(func(r): return r[0]).find(rk))
	for c in sound_rows:
		c.visible = sound_on.button_pressed
	var dm: Dictionary = d.get("damage") if d.get("damage") else {}
	damage_on.button_pressed = not dm.is_empty()
	for k in damage_spins:
		damage_spins[k].value = float(dm.get(k, DAMAGE[k]))
		damage_kills[k].button_pressed = dm.get(k + "_kill", DAMAGE[k + "_kill"] if dm.is_empty() else false)
		damage_spins[k].editable = not damage_kills[k].button_pressed
	for c in damage_rows:
		c.visible = damage_on.button_pressed
	var sz: Dictionary = d.get("spawn") if d.get("spawn") else {}
	spawn_on.button_pressed = not sz.is_empty()
	spawn_team.selected = maxi(0, SPAWN_TEAMS.map(func(t): return t[0]).find(int(sz.get("team", SPAWN["team"]))))
	spawn_order.value = float(sz.get("order", SPAWN["order"]))
	for c in spawn_rows:
		c.visible = spawn_on.button_pressed
	var ow: Dictionary = d.get("oneway") if d.get("oneway") else {}
	oneway_on.button_pressed = not ow.is_empty()
	for k in oneway_flags:
		oneway_flags[k].button_pressed = ow.get(k, ONEWAY[k] if ow.is_empty() else false)
	for c in oneway_rows:
		c.visible = oneway_on.button_pressed
	var fo: Dictionary = d.get("force") if d.get("force") else {}
	force_on.button_pressed = not fo.is_empty()
	var fq: Dictionary = fo if not fo.is_empty() else FORCE
	force_mode.selected = maxi(0, FORCE_MODES.map(func(m): return m[0]).find(str(fq.get("mode", "continuous"))))
	var fv: Array = fq.get("vector", [0, 0, 0])
	for a in 3:
		force_spins[a].value = float(fv[a])
	force_local.button_pressed = fq.get("local", true)
	for k in force_flags:
		force_flags[k].button_pressed = fq.get(k, false)
	force_note.text = force_hint(fq)
	if fq.has("target"):
		var t: Array = fq["target"]
		force_note.text += "\nTarget: %.0f, %.0f, %.0f m" % [float(t[0]) / 100.0, float(t[1]) / 100.0, float(t[2]) / 100.0]
	force_arc_spin.value = float(fq.get("arc", 3.0))
	force_target_btn.text = "Picking… (Esc)" if target_picking == vs[0] else ("Re-pick target…" if fq.has("target") else "Pick target…")
	for c in force_rows:
		c.visible = force_on.button_pressed
	for c in force_target_rows:
		c.visible = force_on.button_pressed and fq.get("mode", "continuous") != "continuous"
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
	if marker_on.button_pressed:
		var nm := marker_name.text.strip_edges().replace(" ", "_")
		d["marker"] = nm if nm != "" else (str(d["marker"]) if d.has("marker") else unique_marker("marker_1"))
	else:
		d.erase("marker")
	if water_on.button_pressed:
		d["water"] = true
	else:
		d.erase("water")
	if limits_on.button_pressed:
		d["limits"] = true
	else:
		d.erase("limits")
	if barrier_on.button_pressed:
		d["barrier"] = true
	else:
		d.erase("barrier")
	if sound_on.button_pressed:
		d["sound"] = {"reverb": REVERBS[reverb_pick.selected][0]}
	else:
		d.erase("sound")
	if damage_on.button_pressed:
		var dm := {}
		for k in damage_spins:
			dm[k] = damage_spins[k].value
			if damage_kills[k].button_pressed:
				dm[k + "_kill"] = true
		d["damage"] = dm
	else:
		d.erase("damage")
	if spawn_on.button_pressed:
		d["spawn"] = {"team": SPAWN_TEAMS[spawn_team.selected][0], "order": int(spawn_order.value)}
	else:
		d.erase("spawn")
	if oneway_on.button_pressed:
		var ow := {}
		for k in oneway_flags:
			ow[k] = oneway_flags[k].button_pressed
		d["oneway"] = ow
	else:
		d.erase("oneway")
	if force_on.button_pressed:
		var fo := {"mode": FORCE_MODES[force_mode.selected][0],
			"vector": [force_spins[0].value, force_spins[1].value, force_spins[2].value], "local": force_local.button_pressed}
		var was_off: bool = not d.get("force")
		for k in force_flags:
			fo[k] = FORCE[k] if was_off else force_flags[k].button_pressed
		if was_off:
			fo = FORCE.duplicate(true)
		else:
			var old: Dictionary = d["force"]
			fo["arc"] = force_arc_spin.value
			var ov: Array = old.get("vector", [0, 0, 0])
			var typed := false
			for a in 3:
				typed = typed or absf(float(ov[a]) - force_spins[a].value) > 0.001
			# the target stays unless X / Y / Z were typed or the mode went continuous
			if old.has("target") and not typed and fo["mode"] != "continuous":
				fo["target"] = old["target"]
				if fo["local"] != old.get("local", true):
					fo["vector"] = ov   # re-solved below in the new frame
		d["force"] = fo
	else:
		d.erase("force")
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

static func force_world(d: Dictionary, world: bool) -> Vector3:
	# the force's vector (m/s or m/s per second) in the volume's frame (world false) or the map's (world true)
	var f: Dictionary = d.get("force", {})
	var a: Array = f.get("vector", [0, 0, 0])
	var v := Vector3(float(a[0]), float(a[1]), float(a[2]))
	var local: bool = f.get("local", true)
	var turn := Basis(Vector3.UP, deg_to_rad(float(d.get("yaw", 0.0))))
	if world:
		return turn * v if local else v
	return v if local else turn.inverse() * v

func _start_target_pick() -> void:
	var vs: Array = main.selection.filter(func(n): return is_instance_valid(n) and is_volume(n))
	if vs.size() != 1:
		return
	target_picking = vs[0]
	main.set_status("Click where it should land (Esc cancels)")
	show_inspector(vs)

func stop_target_pick() -> void:
	var n := target_picking
	target_picking = null
	if n and is_instance_valid(n):
		show_inspector([n])

func picked_target(at: Vector3) -> void:
	# the click's point (metres) as the volume's target: X / Y / Z solved for it
	var n := target_picking
	target_picking = null
	if n == null or not is_instance_valid(n):
		return
	main._push_undo("")
	var f: Dictionary = n.get_meta("data")["force"]
	f["target"] = [snappedf(at.x / main.CM, 1.0), snappedf(at.y / main.CM, 1.0), snappedf(at.z / main.CM, 1.0)]
	f["arc"] = float(f.get("arc", 3.0))   # the spin sets it through _on_changed
	update_marker(n)
	show_inspector([n])
	main.log_line("Force volume aimed: " + force_hint(f))

func solve_target(n: Node3D, d: Dictionary) -> void:
	# launch velocity from the box's floor centre to its target: the peak "arc" m above the higher end, gravity the
	# map's, horizontal speed allowing for the mod's air drag (0.15/s, none vertically)
	var f: Dictionary = d["force"]
	var bs := _boxes(n)
	if bs.is_empty() or not n.is_inside_tree():
		return
	var b0: AABB = bs[0]
	var p0: Vector3 = n.to_global(Vector3(b0.get_center().x, b0.position.y + 0.05, b0.get_center().z))
	var t: Vector3 = _v3(f["target"]) * main.CM
	var g := 9.8 * float(main.lighting.env().get("gravity", 1.0))
	if g <= 0.0:
		return
	var top := maxf(p0.y, t.y) + maxf(0.0, float(f.get("arc", 3.0)))
	var vy := sqrt(2.0 * g * (top - p0.y))
	var time := vy / g + sqrt(2.0 * (top - t.y) / g)
	var flat := Vector2(t.x - p0.x, t.z - p0.z)
	var k := 0.15
	var speed := flat.length() * k / (1.0 - exp(-k * time)) if time > 0.001 else 0.0
	var hv := flat.normalized() * speed if flat.length() > 0.001 else Vector2.ZERO
	var w := Vector3(hv.x, vy, hv.y)
	if f.get("local", true):
		w = Basis(Vector3.UP, deg_to_rad(float(d.get("yaw", 0.0)))).inverse() * w
	f["vector"] = [snappedf(w.x, 0.01), snappedf(w.y, 0.01), snappedf(w.z, 0.01)]

func force_arc(n: Node3D, d: Dictionary, bs: Array) -> PackedVector3Array:
	# the predicted path of something standing at the box's floor centre: pushed as the xlive mod pushes it (the force
	# while inside for continuous, the kick / new velocity at once otherwise), falling with the map's gravity, the mod's
	# air drag; ends where it hits the level (or after 8 s). Line pairs in the volume's frame, metres.
	var out := PackedVector3Array()
	var f: Dictionary = d["force"]
	var mode := str(f.get("mode", "continuous"))
	var acc := force_world(d, false)
	var g := 9.8 * float(main.lighting.env().get("gravity", 1.0))
	var b0: AABB = bs[0]
	var p := Vector3(b0.get_center().x, b0.position.y + 0.05, b0.get_center().z)
	var v := Vector3.ZERO if mode == "continuous" else acc
	var air := mode != "continuous" and v.y > 0.0
	var dt := 1.0 / 30.0
	var mask: int = 1 << (main.LAYER_STAGE - 1)
	for i in 240:
		var inside: bool = bs.any(func(b: AABB): return b.has_point(p))
		if mode == "continuous" and inside:
			v += acc * dt
			if not air and v.y > g * dt:
				air = true
		if air:
			v.y -= g * dt
			v.x *= 1.0 - 0.15 * dt
			v.z *= 1.0 - 0.15 * dt
		else:
			v.y = 0.0
			v.x *= maxf(0.0, 1.0 - 10.0 * dt)
			v.z *= maxf(0.0, 1.0 - 10.0 * dt)
			if v.length() < 0.02 and not (mode == "continuous" and inside):
				break
		var q := p + v * dt
		if n.is_inside_tree():
			var hit: Dictionary = main._ray(n.to_global(p), n.to_global(q), mask)
			if hit:
				out.append(p)
				out.append(n.to_local(hit["position"]))
				break
		out.append(p)
		out.append(q)
		p = q
		if p.y < b0.position.y - 100.0:
			break
	return out

static func force_hint(f: Dictionary) -> String:
	# what the numbers do, roughly (earth gravity; the map's own gravity scales it)
	if f.has("target") and str(f.get("mode", "")) != "continuous":
		var vv: Array = f.get("vector", [0, 0, 0])
		return "Aimed at the target: %.1f m/s, peak %.1f m above the higher end" % [
			Vector3(float(vv[0]), float(vv[1]), float(vv[2])).length(), float(f.get("arc", 3.0))]
	var a: Array = f.get("vector", [0, 0, 0])
	var up := float(a[1])
	var v := Vector3(float(a[0]), up, float(a[2]))
	match str(f.get("mode", "continuous")):
		"continuous":
			if up > 9.8:
				return "Lifts: %.1f m/s² net upward (gravity is 9.8)" % (up - 9.8)
			return "Steady push of %.1f m/s²; on the ground it levels off near %.1f m/s" % [v.length(), Vector2(a[0], a[2]).length() / 10.0]
		_:
			if up > 0.0:
				var flat := Vector2(float(a[0]), float(a[2])).length()
				var t := 2.0 * up / 9.8
				return "Rises about %.1f m, lands about %.1f m away (no drag)" % [up * up / 19.6, flat * t]
			return "%.1f m/s" % v.length()

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
