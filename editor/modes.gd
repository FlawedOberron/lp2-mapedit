extends "res://scripts.gd"
# Game Mode window (G): the visual scripting graph of scripts.gd for a game mode, its own file instead of the map's
# script. A mode file (<game>/Modes/<name>.lp2mode, JSON) = {format, name, description, base, settings, requires, script}.
# The xlive mod runs it during the match (the host decides, as with map scripts) on any map that has what it requires.
# - Settings: the mode's own lobby rows; each is a variable of the same name in the graph, set from the lobby.
# - Requirements: script markers / volumes the map must have (by name or wildcard, at least N). Scan fills them from the
#   graph; Check against map counts what the open map has.
# Mode nodes: events (Match start, Round start / end, World update, On kill, On death, Player joined / left, Player
# spawned, Zone entered) and actions (Spawn player at a marker, Hold, Eliminate, Respawn rules, Queue, Score, End round,
# End match, Show text). Map-only nodes that point at one map's volume (by id) are left out: modes go by names.
# Planned in the mod (xlive lives.cpp / scripts.cpp): running these nodes; until then a mode file is design only.

const MODE_FORMAT := 1
const MODE_TYPES := {
	"matchstart": {"title": "Match start", "ins": [], "outs": ["then"], "hint": "Fires once when the match starts, before anyone spawns (players are held until spawned, unless the mode's base spawns them)"},
	"roundstart": {"title": "Round start", "ins": [], "outs": ["then"], "props": {"var": "round"},
		"hint": "Fires at the start of every round (the first too); stores the round number (from 1) in the variable"},
	"roundend": {"title": "Round end", "ins": [], "outs": ["then"], "props": {"var": "round"},
		"hint": "Fires when a round ends (time up, End round), before the next starts"},
	"worldupdate": {"title": "World update", "ins": [], "outs": ["tick"], "props": {"var": "dt"},
		"hint": "Fires every frame of the match (about 60 a second); stores the seconds since the last one in the variable. Keep what hangs off it small"},
	"onkill": {"title": "On kill", "ins": [], "outs": ["then"], "props": {"killer": "killer", "victim": "victim"},
		"hint": "Fires when a player kills another (or a bot); stores both in player variables"},
	"ondeath": {"title": "On death", "ins": [], "outs": ["then"], "props": {"victim": "victim"},
		"hint": "Fires on any player's death (killed, fall, self); stores who died"},
	"onjoin": {"title": "Player joined / left", "ins": [], "outs": ["joined", "left"], "props": {"player": "who"},
		"hint": "Fires when a player joins the match (or is in it at the start) and when one leaves"},
	"onspawn": {"title": "Player spawned", "ins": [], "outs": ["then"], "props": {"player": "who"},
		"hint": "Fires each time a player's character appears (spawn, respawn, Spawn player)"},
	"zoneenter": {"title": "Zone entered", "ins": [], "outs": ["entered", "left"], "props": {"text": "zone_*", "who": "any", "player": "who"},
		"hint": "Fires when a character goes into or out of a script volume whose name matches (wildcards * and ?): a zone the map must have"},
	"spawnplayer": {"title": "Spawn player", "ins": ["in"], "outs": ["spawned", "skipped"], "props": {"player": "who", "marker": "spot", "face": true},
		"hint": "Puts the player in play at the marker (a marker variable: Get marker / For each over Find markers), facing its arrow; respawns a dead or held one. skipped: nobody, gone or no marker"},
	"holdplayer": {"title": "Hold player", "ins": ["in"], "outs": ["then"], "props": {"player": "who"},
		"hint": "Takes the player out of play without eliminating them (no character, spectating) until Spawn player"},
	"eliminate": {"title": "Eliminate player", "ins": ["in"], "outs": ["then"], "props": {"player": "who"},
		"hint": "Out of the match: no more respawns, spectating"},
	"respawnrules": {"title": "Respawn rules", "ins": ["in"], "outs": ["then"], "props": {"respawn": "auto", "a": "5", "b": "0"},
		"hint": "How players come back: automatically after the delay (with Lives: at most that many deaths; 0 no limit) or only by Spawn player"},
	"queue": {"title": "Queue", "ins": ["push", "push front", "pop", "remove", "clear"], "outs": ["then", "empty"], "props": {"list": "queue", "player": "who"},
		"hint": "A waiting line (a player list in order): push adds the player at the back (front), pop takes the first into the player variable (empty: nobody waiting), remove takes them out"},
	"score": {"title": "Score", "ins": ["add", "set"], "outs": ["then"], "props": {"scoreof": "player", "player": "who", "a": "1"},
		"hint": "Adds to or sets the mode's score of the player or the player's team: what placement ranks by (after rounds won). The game's own points (kills etc.) stay apart and still earn career points"},
	"playerinfo": {"title": "Get player info", "ins": ["in"], "outs": ["then"], "props": {"player": "who", "info": "team", "var": "value"},
		"hint": "Stores the player's team, score, kills, deaths or lives left in a number variable"},
	"teamlist": {"title": "Team players", "ins": ["in"], "outs": ["then"], "props": {"player": "who", "alive": false, "list": "mates"},
		"hint": "Fills the list with the players on the player's team (Alive only: those in play)"},
	"endround": {"title": "End round", "ins": ["in"], "outs": [], "props": {"scoreof": "team", "player": "winner"},
		"hint": "Ends the round, won by the player or their team (nobody in the variable: a draw)"},
	"endmatch": {"title": "End match", "ins": ["in"], "outs": [], "props": {"scoreof": "team", "player": "winner"},
		"hint": "Ends the match now, won by the player or their team (nobody: by score)"},
	"showtext": {"title": "Show text", "ins": ["in"], "outs": ["then"], "props": {"text": "{who} is up next", "showto": "all", "player": "who",
		"style": "banner", "font": "", "colour": "ffffff", "seconds": 3.0},
		"hint": "Shows a message on our overlay: to everyone, one player or their team; banner (middle), top line, or under the HUD. {name} shows a variable (a player's name for player variables)"},
	"modeevent": {"title": "Fire map event", "ins": ["in"], "outs": ["then"], "props": {"text": "my_event", "player": "who"},
		"hint": "Sends a named event to the map: its script's On mode event nodes with that name run (with the player). Maps that don't listen ignore it"},
}
const MODE_ORDER := ["matchstart", "roundstart", "roundend", "worldupdate", "onkill", "ondeath", "onjoin", "onspawn", "zoneenter", "timer",
	"delay", "flipflop", "counter", "if", "compare", "switch", "sequence", "gate", "once", "branch", "chance", "cooldown", "loop",
	"set", "random", "math", "findmarkers", "getmarker", "getpos", "vector", "players", "teamlist", "list", "listremove", "listget",
	"listcount", "foreach", "queue", "playercheck", "playerget", "playerinfo",
	"spawnplayer", "holdplayer", "eliminate", "respawnrules", "score", "endround", "endmatch", "showtext", "modeevent", "zoneoutline", "playeract", "spawn", "teleport", "log"]
const MODE_EVENTS := ["matchstart", "roundstart", "roundend", "worldupdate", "onkill", "ondeath", "onjoin", "onspawn", "zoneenter", "timer"]
const MODE_ACTIONS := ["spawnplayer", "holdplayer", "eliminate", "respawnrules", "score", "endround", "endmatch", "showtext", "modeevent", "zoneoutline", "playeract", "spawn", "teleport", "log"]
const MODE_DATA := ["set", "random", "math", "getpos", "vector", "findmarkers", "getmarker", "players", "teamlist", "list", "listremove",
	"listget", "listcount", "queue", "playerget", "playerinfo"]
const BASES := [["team", "Teams (two sides)"], ["ffa", "Free for all"]]
const SETTING_KINDS := [["number", "Number"], ["choice", "Choice"], ["onoff", "On / Off"]]
# Fonts the overlay can draw with: the game's PC lists them (xlive writes <game>/ModCache/fonts.txt); these until then
const DEFAULT_FONTS := ["Arial", "Tahoma", "Times New Roman", "Courier New", "Verdana", "Trebuchet MS", "Georgia", "Impact"]

var doc := {}            # the open mode
var doc_path := ""
var dirty := false
var name_edit: LineEdit
var desc_edit: LineEdit
var base_button: OptionButton
var settings_box: VBoxContainer
var req_box: VBoxContainer
var req_result: Label
var file_dialog: FileDialog
var fonts: Array = []

func _init() -> void:
	# (scripts.gd's _init has run: Godot calls the parent's first)
	title = "Game Mode"
	size = Vector2i(1400, 760)
	var t := {}
	for k in TYPES:
		if k not in ["start", "enter", "volume", "setvalue"]:   # map-only: one map's volume by id
			t[k] = TYPES[k]
	for k in MODE_TYPES:
		t[k] = MODE_TYPES[k]
	types = t
	order = MODE_ORDER.filter(func(k): return t.has(k))

func setup(m: Node) -> void:
	super.setup(m)
	# scripts.gd's window settings (its _init doesn't run for this subclass when made by set_script): hidden until
	# asked for, and the close button hides it
	visible = false
	transient = true
	wrap_controls = true
	min_size = Vector2i(500, 300)
	if not close_requested.is_connected(hide):
		close_requested.connect(hide)
	pick_button.visible = false
	info.text = "Game modes run on any map that has what they require (Requirements). Events (orange) start chains, flow (blue), data (yellow), actions (green). Settings are lobby rows and variables of the same name. Save compiles it for the game; mode.txt in the game folder names the mode to play (Survival, Survival FFA ship with it)."
	var file := MenuButton.new()
	file.text = "File"
	file.flat = false
	var p := file.get_popup()
	p.add_item("New mode", 0)
	p.add_item("Open...", 1)
	p.add_item("Save (Ctrl+S)", 2)
	p.add_item("Save as...", 3)
	p.id_pressed.connect(_on_file)
	toolbar.add_child(file)
	toolbar.move_child(file, 0)
	# graph on the left, the mode's details on the right
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.remove_child(graph)
	split.add_child(graph)
	graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var side_scroll := ScrollContainer.new()
	side_scroll.custom_minimum_size.x = 340
	side_scroll.size_flags_horizontal = Control.SIZE_FILL   # the graph takes the rest
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_scroll.add_child(side)
	split.add_child(side_scroll)
	column.add_child(split)
	split.split_offset = 100000   # clamped: the details column at its narrowest, the graph the rest
	_build_details(side)
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.lp2mode ; LP2 game mode"])
	file_dialog.use_native_dialog = false
	file_dialog.size = Vector2i(800, 500)
	add_child(file_dialog)
	window_input.connect(func(e):
		if e is InputEventKey and e.pressed and e.ctrl_pressed and e.keycode == KEY_S:
			save_mode(doc_path)
			set_input_as_handled())
	close_requested.connect(func(): if dirty: main.log_line("Game mode not saved: %s (File > Save)." % doc.get("name", "")))
	new_mode()

# ---------------------------------------------------------------- the document

func data() -> Dictionary:
	if not doc.has("script") or not (doc["script"] is Dictionary):
		doc["script"] = {"nodes": [], "links": []}
	var d: Dictionary = doc["script"]
	if not d.has("nodes"):
		d["nodes"] = []
	if not d.has("links"):
		d["links"] = []
	return d

func _undo(_key: String) -> void:
	dirty = true
	_title()

func _no_doc() -> bool:
	return doc.is_empty()

func _title() -> void:
	title = "Game Mode: %s%s" % [doc.get("name", "untitled"), " *" if dirty else ""]

func modes_dir() -> String:
	var g: String = main.game if "game" in main and str(main.game) != "" else OS.get_user_data_dir()
	return g.path_join("Modes")

func new_mode() -> void:
	doc = {"format": MODE_FORMAT, "name": "New mode", "description": "", "base": "team", "settings": [],
		"requires": {"markers": [], "volumes": []}, "script": {"nodes": [], "links": []}}
	doc_path = ""
	dirty = false
	_uid = 0
	_load_fields()
	refresh()

func open_mode(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		main.log_line("Game mode: can't open %s." % path)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		main.log_line("Game mode: %s isn't a mode file." % path)
		return
	doc = parsed
	for k in ["settings"]:
		if not (doc.get(k) is Array):
			doc[k] = []
	if not (doc.get("requires") is Dictionary):
		doc["requires"] = {"markers": [], "volumes": []}
	doc_path = path
	dirty = false
	_uid = 0
	_load_fields()
	refresh()
	main.log_line("Game mode: opened %s." % path)

func save_mode(path: String) -> void:
	if path == "":
		_ask_path(true)
		return
	doc["format"] = MODE_FORMAT
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		main.log_line("Game mode: can't write %s." % path)
		return
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
	doc_path = path
	dirty = false
	_title()
	main.log_line("Game mode: saved %s." % path)
	# the runtime graph the game loads ("compiled", lp2mode.py); the game runs the mode named in its folder's mode.txt
	main.run_tool("lp2mode.py", [path], func(): main.log_line("Game mode: compiled for the game (put \"%s\" in mode.txt in the game folder to play it)." % path.get_file().get_basename()))

func _ask_path(saving: bool) -> void:
	DirAccess.make_dir_recursive_absolute(modes_dir())
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if saving else FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.current_dir = modes_dir()
	if saving:
		file_dialog.current_file = str(doc.get("name", "mode")).replace(" ", "") + ".lp2mode"
	for c in file_dialog.file_selected.get_connections():
		file_dialog.file_selected.disconnect(c["callable"])
	file_dialog.file_selected.connect(func(path: String):
		if saving:
			save_mode(path if path.ends_with(".lp2mode") else path + ".lp2mode")
		else:
			open_mode(path))
	file_dialog.popup_centered()

func _on_file(id: int) -> void:
	match id:
		0:
			if dirty:
				main.log_line("Game mode: the last one wasn't saved (%s)." % doc.get("name", ""))
			new_mode()
		1:
			_ask_path(false)
		2:
			save_mode(doc_path)
		3:
			_ask_path(true)

# ---------------------------------------------------------------- details: name, base, settings, requirements

func _build_details(side: VBoxContainer) -> void:
	side.add_child(_heading("Mode"))
	var r := HBoxContainer.new()
	r.add_child(main._label("Name"))
	name_edit = LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(func(x):
		doc["name"] = x
		_undo(""))
	r.add_child(name_edit)
	side.add_child(r)
	r = HBoxContainer.new()
	r.add_child(main._label("About"))
	desc_edit = LineEdit.new()
	desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_edit.placeholder_text = "one line for the lobby"
	desc_edit.text_changed.connect(func(x):
		doc["description"] = x
		_undo(""))
	r.add_child(desc_edit)
	side.add_child(r)
	r = HBoxContainer.new()
	r.add_child(main._label("Base"))
	base_button = OptionButton.new()
	for b in BASES:
		base_button.add_item(b[1])
	base_button.tooltip_text = "What the game's own rules start from: two teams or everyone for themselves"
	base_button.item_selected.connect(func(i):
		doc["base"] = BASES[i][0]
		_undo(""))
	r.add_child(base_button)
	side.add_child(r)
	side.add_child(HSeparator.new())
	side.add_child(_heading("Settings (lobby rows)"))
	var hint: Label = main._label("Each is a variable of the same name in the graph, set from the lobby.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	side.add_child(hint)
	settings_box = VBoxContainer.new()
	side.add_child(settings_box)
	var add := Button.new()
	add.text = "Add setting"
	add.pressed.connect(func():
		(doc["settings"] as Array).append({"var": "setting%d" % ((doc["settings"] as Array).size() + 1), "label": "New setting",
			"kind": "number", "default": 1, "min": 0, "max": 10, "step": 1, "choices": []})
		_undo("")
		_fill_settings_box())
	side.add_child(add)
	side.add_child(HSeparator.new())
	side.add_child(_heading("Requirements (what a map needs)"))
	req_box = VBoxContainer.new()
	side.add_child(req_box)
	var row := HBoxContainer.new()
	var scan := Button.new()
	scan.text = "Scan graph"
	scan.tooltip_text = "Lists the markers and volumes (by name / wildcard) the graph uses, with how many of each it needs; keeps counts you raised"
	scan.pressed.connect(scan_requirements)
	row.add_child(scan)
	var check := Button.new()
	check.text = "Check against map"
	check.tooltip_text = "Counts what the open map has for each requirement"
	check.pressed.connect(check_against_map)
	row.add_child(check)
	var addm := MenuButton.new()
	addm.text = "Add..."
	addm.flat = false
	addm.get_popup().add_item("Marker", 0)
	addm.get_popup().add_item("Volume", 1)
	addm.get_popup().id_pressed.connect(func(i):
		(doc["requires"][["markers", "volumes"][i]] as Array).append({"name": "name_*", "count": 1})
		_undo("")
		_fill_req_box())
	row.add_child(addm)
	side.add_child(row)
	req_result = main._label("")
	req_result.autowrap_mode = TextServer.AUTOWRAP_WORD
	side.add_child(req_result)

func _heading(t: String) -> Label:
	var l: Label = main._label(t)
	l.add_theme_font_size_override("font_size", 15)
	l.modulate = Color(0.7, 0.9, 1.0)
	return l

func _load_fields() -> void:
	_updating = true
	name_edit.text = str(doc.get("name", ""))
	desc_edit.text = str(doc.get("description", ""))
	base_button.selected = maxi(0, BASES.map(func(b): return b[0]).find(doc.get("base", "team")))
	_updating = false
	_fill_settings_box()
	_fill_req_box()
	_title()

func _fill_settings_box() -> void:
	for c in settings_box.get_children():
		c.queue_free()
	var list: Array = doc.get("settings", [])
	for i in list.size():
		var st: Dictionary = list[i]
		var box := VBoxContainer.new()
		var r1 := HBoxContainer.new()
		var label := LineEdit.new()
		label.text = str(st.get("label", ""))
		label.placeholder_text = "lobby label"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_changed.connect(func(x):
			st["label"] = x
			_undo(""))
		r1.add_child(label)
		var v := LineEdit.new()
		v.text = str(st.get("var", ""))
		v.placeholder_text = "variable"
		v.custom_minimum_size.x = 90
		v.tooltip_text = "The graph's variable that holds it"
		v.text_changed.connect(func(x):
			st["var"] = x
			_undo(""))
		r1.add_child(v)
		var del := Button.new()
		del.text = "x"
		del.tooltip_text = "Remove this setting"
		del.pressed.connect(func():
			list.remove_at(list.find(st))
			_undo("")
			_fill_settings_box())
		r1.add_child(del)
		box.add_child(r1)
		var r2 := HBoxContainer.new()
		var kind := OptionButton.new()
		for k in SETTING_KINDS:
			kind.add_item(k[1])
		kind.selected = maxi(0, SETTING_KINDS.map(func(k): return k[0]).find(st.get("kind", "number")))
		kind.item_selected.connect(func(j):
			st["kind"] = SETTING_KINDS[j][0]
			_undo("")
			_fill_settings_box())
		r2.add_child(kind)
		match str(st.get("kind", "number")):
			"number":
				for k in ["default", "min", "max", "step"]:
					r2.add_child(main._label({"default": "=", "min": "from", "max": "to", "step": "by"}[k]))
					var e := LineEdit.new()
					e.text = str(st.get(k, 0))
					e.custom_minimum_size.x = 44
					e.text_changed.connect(func(x):
						st[k] = float(x) if x.is_valid_float() else 0.0
						_undo(""))
					r2.add_child(e)
			"choice":
				var e := LineEdit.new()
				e.text = ", ".join(st.get("choices", []))
				e.placeholder_text = "choice 1, choice 2..."
				e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				e.tooltip_text = "The variable holds the picked choice's number (from 1)"
				e.text_changed.connect(func(x):
					st["choices"] = Array(x.split(",", false)).map(func(c): return c.strip_edges())
					_undo(""))
				r2.add_child(e)
				r2.add_child(main._label("default #"))
				var d: SpinBox = main._spin(1, 20, 1)
				d.value = float(st.get("default", 1))
				d.value_changed.connect(func(x):
					st["default"] = int(x)
					_undo(""))
				r2.add_child(d)
			"onoff":
				var c := CheckBox.new()
				c.text = "On by default"
				c.button_pressed = bool(st.get("default", 1))
				c.toggled.connect(func(x):
					st["default"] = 1 if x else 0
					_undo(""))
				r2.add_child(c)
		box.add_child(r2)
		box.add_child(HSeparator.new())
		settings_box.add_child(box)

func _fill_req_box() -> void:
	for c in req_box.get_children():
		c.queue_free()
	var req: Dictionary = doc.get("requires", {})
	for kind in ["markers", "volumes", "zones"]:
		var list: Array = req.get(kind, [])
		if list.is_empty():
			continue
		req_box.add_child(main._label({"markers": "Markers", "volumes": "Volumes (script)", "zones": "Bot zones (name or tag)"}[kind]))
		for e in list:
			var r := HBoxContainer.new()
			var n := LineEdit.new()
			n.text = str(e.get("name", ""))
			n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			n.tooltip_text = "A script name, or a wildcard (* any run of letters, ? any one)"
			n.text_changed.connect(func(x):
				e["name"] = x
				_undo(""))
			r.add_child(n)
			r.add_child(main._label("x"))
			var c: SpinBox = main._spin(1, 64, 1)
			c.value = int(e.get("count", 1))
			c.tooltip_text = "At least this many matching"
			c.value_changed.connect(func(x):
				e["count"] = int(x)
				_undo(""))
			r.add_child(c)
			var del := Button.new()
			del.text = "x"
			del.pressed.connect(func():
				list.remove_at(list.find(e))
				_undo("")
				_fill_req_box())
			r.add_child(del)
			req_box.add_child(r)
	if req.get("markers", []).is_empty() and req.get("volumes", []).is_empty() and req.get("zones", []).is_empty():
		req_box.add_child(main._label("None: runs on any map. Scan graph finds them."))

# ---------------------------------------------------------------- scan

func _scan() -> Dictionary:
	# name -> count needed, per kind. Find markers: the list it fills needs as many as the largest entry number read
	# from it (Get from list) or as many players as pop from a queue into Spawn player... kept simple: 1, or the highest
	# whole Number a Get from list asks of that list.
	var markers := {}
	var volumes := {}
	var zones := {}
	var list_need := {}
	for n in data()["nodes"]:
		if n["type"] == "listget" and str(n.get("a", "")).is_valid_int() and not n.get("random", false):
			var l := str(n.get("list", ""))
			list_need[l] = maxi(int(list_need.get(l, 1)), int(n["a"]))
	for n in data()["nodes"]:
		match str(n["type"]):
			"findmarkers":
				var name := str(n.get("text", "")).strip_edges()
				if name != "":
					markers[name] = maxi(int(markers.get(name, 1)), int(list_need.get(str(n.get("list", "")), 1)))
			"getmarker":
				var name := str(n.get("text", "")).strip_edges()
				if name != "":
					markers[name] = maxi(int(markers.get(name, 1)), 1)
			"zoneenter":
				var name := str(n.get("text", "")).strip_edges()
				if name != "":
					volumes[name] = maxi(int(volumes.get(name, 1)), 1)
			"zoneoutline":
				var name := str(n.get("text", "")).strip_edges()
				if name != "":
					zones[name] = maxi(int(zones.get(name, 1)), 1)
	return {"markers": markers, "volumes": volumes, "zones": zones}

func scan_requirements() -> void:
	var found := _scan()
	var req: Dictionary = doc["requires"]
	var lines: Array = []
	for kind in ["markers", "volumes", "zones"]:
		var list: Array = req.get(kind, [])
		var have := {}
		for e in list:
			have[str(e.get("name", ""))] = e
		for name in found[kind]:
			if have.has(name):
				have[name]["count"] = maxi(int(have[name].get("count", 1)), int(found[kind][name]))   # keeps a raised count
			else:
				list.append({"name": name, "count": int(found[kind][name])})
		req[kind] = list
		for e in list:
			lines.append("%s %s x%d%s" % [{"markers": "Marker", "volumes": "Volume", "zones": "Zone"}[kind], e["name"], int(e["count"]),
				"" if found[kind].has(e["name"]) else " (not in the graph)"])
	_undo("")
	_fill_req_box()
	req_result.text = "Scan: " + (", ".join(lines) if lines else "the graph names no markers or volumes: runs on any map.")
	main.log_line("Game mode scan: " + ("; ".join(lines) if lines else "no requirements."))

func _map_names() -> Dictionary:
	# the open map's script names: markers (and marker volumes) and pieces; volumes with effects by their marker name
	var markers: Array = []
	var volumes: Array = []
	if main.project.is_empty():
		return {"markers": markers, "volumes": volumes}
	for n in main.markers_root.get_children() + main.geometry.pieces():
		var t: String = main.object_tag(n)
		if t == "":
			continue
		if n.has_meta("volume"):
			volumes.append(t)
		markers.append(t)   # a volume's box is a marker too (Get marker)
	# bot zones (lp2navmap's .preview/navzones.json, from Build Navmesh): each by its name and its tags
	var zones: Array = []
	var nz_text := FileAccess.get_file_as_string(str(main.project_dir).path_join(".preview/navzones.json"))
	var nz = JSON.parse_string(nz_text) if nz_text != "" else null
	if nz is Dictionary:
		for z in nz.get("zones", []):
			var keys: Array = [str(z.get("name", ""))]
			for t in z.get("tags", []):
				keys.append(str(t))
			zones.append(keys)
	return {"markers": markers, "volumes": volumes, "zones": zones}

func check_against_map() -> void:
	if main.project.is_empty():
		req_result.text = "Open a map first."
		return
	var names := _map_names()
	var lines: Array = []
	var ok := true
	for kind in ["markers", "volumes", "zones"]:
		for e in doc["requires"].get(kind, []):
			var have: int = 0
			if kind == "zones":   # a zone counts once if its name or any tag matches
				have = (names[kind] as Array).filter(func(keys): return (keys as Array).any(func(t): return String(t).matchn(str(e["name"])))).size()
			else:
				have = (names[kind] as Array).filter(func(t): return String(t).matchn(str(e["name"]))).size()
			var good: bool = have >= int(e.get("count", 1))
			ok = ok and good
			lines.append("%s %s: %d of %d %s" % [{"markers": "Marker", "volumes": "Volume", "zones": "Zone"}[kind], e["name"], have, int(e.get("count", 1)), "ok" if good else "MISSING"])
	req_result.text = ("This map fits the mode." if ok else "This map is missing what the mode needs (it would show Invalid Map).") + \
		("\n" + "\n".join(lines) if lines else "")

# ---------------------------------------------------------------- nodes

func _kind(t: String) -> Color:
	if t in MODE_EVENTS:
		return EVENT_COLOUR
	if t in MODE_ACTIONS:
		return ACTION_COLOUR
	if t in MODE_DATA:
		return DATA_COLOUR
	return FLOW_COLOUR

func font_names() -> Array:
	if fonts.is_empty():
		var path: String = str(main.game).path_join("ModCache").path_join("fonts.txt") if "game" in main and str(main.game) != "" else ""
		var f := FileAccess.open(path, FileAccess.READ) if path != "" else null
		if f:
			for line in f.get_as_text().split("\n", false):
				if line.strip_edges() != "":
					fonts.append(line.strip_edges())
		if fonts.is_empty():
			fonts = DEFAULT_FONTS.duplicate()
	return fonts

func _prop_control(n: Dictionary, k: String) -> Control:
	var h := HBoxContainer.new()
	match k:
		"killer", "victim":
			h.add_child(main._label("Killer" if k == "killer" else "Victim"))
			var e := LineEdit.new()
			e.text = str(n.get(k, ""))
			e.custom_minimum_size.x = 140
			e.tooltip_text = "A player variable's name"
			e.text_changed.connect(func(x): _set_prop(n, k, x))
			h.add_child(e)
			return h
		"respawn", "scoreof", "showto", "style", "info":
			var opts: Array = {
				"respawn": [["auto", "Automatic after the delay"], ["manual", "Only by Spawn player"]],
				"scoreof": [["player", "The player"], ["team", "The player's team"]] if n["type"] == "score" else [["player", "The player"], ["team", "The player's team"], ["against", "The player's opponents"]],
				"showto": [["all", "Everyone"], ["player", "The player"], ["team", "The player's team"]],
				"style": [["banner", "Banner (middle)"], ["top", "Top line"], ["hud", "Under the HUD"]],
				"info": [["team", "Team"], ["score", "Mode score"], ["kills", "Kills"], ["deaths", "Deaths"], ["lives", "Lives left"]],
			}[k]
			h.add_child(main._label({"respawn": "Respawn", "scoreof": "Of" if n["type"] == "score" else "Winner", "showto": "To",
				"style": "As", "info": "Value"}[k]))
			var o := OptionButton.new()
			for x in opts:
				o.add_item(x[1])
			o.selected = maxi(0, opts.map(func(x): return x[0]).find(n.get(k, opts[0][0])))
			o.item_selected.connect(func(i): _set_prop(n, k, opts[i][0]))
			h.add_child(o)
			return h
		"font":
			h.add_child(main._label("Font"))
			var o := OptionButton.new()
			o.add_item("Default")
			var names := font_names()
			for f in names:
				o.add_item(f)
			o.selected = maxi(0, names.find(n.get("font", "")) + 1)
			o.item_selected.connect(func(i): _set_prop(n, "font", "" if i == 0 else names[i - 1]))
			h.add_child(o)
			return h
		"colour":
			h.add_child(main._label("Colour"))
			var c := ColorPickerButton.new()
			c.custom_minimum_size = Vector2(60, 24)
			c.color = Color.html(str(n.get("colour", "ffffff")))
			c.color_changed.connect(func(x): _set_prop(n, "colour", x.to_html(false)))
			h.add_child(c)
			return h
		"alive":
			var c := CheckBox.new()
			c.text = "Alive only"
			c.button_pressed = bool(n.get("alive", false))
			c.toggled.connect(func(x): _set_prop(n, "alive", x))
			h.add_child(c)
			return h
		"a", "b":
			if n["type"] in ["respawnrules", "score"]:
				h.add_child(main._label({"respawnrules": "Delay (s)" if k == "a" else "Lives (0: no limit)", "score": "Amount"}[n["type"]]))
				var e := LineEdit.new()
				e.text = str(n.get(k, ""))
				e.custom_minimum_size.x = 80
				e.tooltip_text = "A number, or a variable's name (its value)"
				e.text_changed.connect(func(x): _set_prop(n, k, x))
				h.add_child(e)
				return h
		"text":
			if n["type"] in ["showtext", "zoneenter"]:
				h.add_child(main._label("Text" if n["type"] == "showtext" else "Zone"))
				var e := LineEdit.new()
				e.text = str(n.get("text", ""))
				e.custom_minimum_size.x = 200
				e.tooltip_text = "{name} shows a variable" if n["type"] == "showtext" else "A volume's script name, or a wildcard"
				e.text_changed.connect(func(x): _set_prop(n, "text", x))
				h.add_child(e)
				return h
		"var":
			if n["type"] in ["roundstart", "roundend", "worldupdate", "playerinfo"]:
				h.add_child(main._label({"worldupdate": "Seconds into", "playerinfo": "Into"}.get(n["type"], "Round into")))
				var e := LineEdit.new()
				e.text = str(n.get("var", ""))
				e.custom_minimum_size.x = 120
				e.tooltip_text = "A number variable's name"
				e.text_changed.connect(func(x): _set_prop(n, "var", x))
				h.add_child(e)
				return h
	h.free()
	return super._prop_control(n, k)
