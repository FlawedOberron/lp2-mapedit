extends Window
# Visual scripting window (K): a node graph (GraphEdit) saved as project "scripts" {nodes: [{id, type, pos: [x, y],
# props}], links: [[from id, out port, to id, in port]]}. lp2mapc compiles it into map.json "script" for the xlive
# mod (scripts.cpp), which runs it during the match on every machine: its events come from what every machine sees
# (characters in volumes, time), its actions switch our volumes' effects. Volumes are referenced by their "id"
# (given when a node first picks one).
#
# Node types (TYPES): events start a chain (Map start, Volume entered / left, Timer), flow nodes pass it on (Delay,
# Flip-flop, Counter, If variable, Compare), data nodes store numbers in variables (Set, Random, Math) and actions do
# something (Volume effects on / off / toggle, Set volume value, Log). Pulses travel along the white links: an output
# port fires the input ports linked to it. Variables are made by name: numbers (on / off = 1 / 0), players (who
# entered a volume, a list's entry) or lists of players; any value field takes a number or a variable's name (its
# value then). Player nodes check, read (health, T-Eng) and act on a player (damage, kill, T-Eng). In a match the host
# runs the script. Script markers (marker volumes, named) are found by name or wildcard into marker variables / lists,
# which the same list nodes handle. Each player's own machine reports its character entering / leaving volumes and its health / T-Eng,
# and applies actions on itself.
# Planned: buttons (interact prompt), movers (doors, lifts), messages on screen: they need more of the game decoded.

const TYPES := {
	"start": {"title": "Map start", "ins": [], "outs": ["then"], "hint": "Fires once when the match starts"},
	"enter": {"title": "Volume entered", "ins": [], "outs": ["entered", "left"], "props": {"volume": "", "who": "any", "player": ""},
		"hint": "Fires when a character goes into (entered) or out of (left) the volume; Player: a variable to store who (nobody for the AI)"},
	"timer": {"title": "Timer", "ins": ["start", "stop"], "outs": ["tick"], "props": {"seconds": 5.0, "max_seconds": 0.0, "repeat": true, "autostart": false},
		"hint": "After its seconds fires tick (again and again with Repeat); start restarts it, stop stops it. Up to: a random time between the two each time"},
	"delay": {"title": "Delay", "ins": ["in"], "outs": ["then"], "props": {"seconds": 1.0, "max_seconds": 0.0},
		"hint": "Passes each pulse on after its seconds (Up to: a random time between the two)"},
	"flipflop": {"title": "Flip-flop", "ins": ["in"], "outs": ["A", "B"], "hint": "Pulses go to A, then B, then A..."},
	"counter": {"title": "Counter", "ins": ["in", "reset"], "outs": ["reached"], "props": {"target": 3},
		"hint": "Counts pulses; at the target fires reached and starts again from 0"},
	"set": {"title": "Set variable", "ins": ["in"], "outs": ["then"], "props": {"var": "open", "value": "toggle"},
		"hint": "Stores a value in a variable (all start at 0): a number, another variable's name, on (1), off (0) or toggle"},
	"if": {"title": "If variable", "ins": ["in"], "outs": ["on", "off"], "props": {"var": "open"},
		"hint": "Passes the pulse to on (the variable isn't 0) or off"},
	"random": {"title": "Random value", "ins": ["in"], "outs": ["then"], "props": {"var": "roll", "a": "1", "b": "6", "integer": true},
		"hint": "Stores a random number between From and To (each a number or a variable) in the variable"},
	"math": {"title": "Math", "ins": ["in"], "outs": ["then"], "props": {"var": "count", "a": "count", "op": "+", "b": "1"},
		"hint": "Stores A (op) B in the variable; A and B are numbers or variables"},
	"compare": {"title": "Compare", "ins": ["in"], "outs": ["yes", "no"], "props": {"a": "count", "op": ">=", "b": "3"},
		"hint": "Passes the pulse to yes or no by comparing A and B (numbers or variables)"},
	"volume": {"title": "Volume effects", "ins": ["on", "off", "toggle"], "outs": ["then"], "props": {"volume": "", "start_off": false},
		"hint": "Switches the volume's effects (gravity, damage, post-process, water); Starts off: off until switched on"},
	"setvalue": {"title": "Set volume value", "ins": ["in"], "outs": ["then"], "props": {"volume": "", "setting": "", "a": "1", "seconds": 0.0},
		"hint": "Changes a setting of the volume (damage, gravity, screen colour) to the value (a number or a variable), fading over its seconds"},
	"players": {"title": "All players", "ins": ["in"], "outs": ["then"], "props": {"list": "everyone"},
		"hint": "Fills the list with every player in the match"},
	"list": {"title": "Player list", "ins": ["add", "remove", "clear"], "outs": ["then"], "props": {"list": "team", "player": "who"},
		"hint": "Adds the player to the list (once), removes them, or empties the list"},
	"listremove": {"title": "Remove from list where", "ins": ["in"], "outs": ["then"], "props": {"list": "team", "check": "gone_or_dead", "a": "25"},
		"hint": "Removes every player in the list matching the condition (Below: the health % or T-Eng limit)"},
	"listget": {"title": "Get from list", "ins": ["in"], "outs": ["found", "none"], "props": {"list": "team", "random": false, "a": "1", "player": "picked"},
		"hint": "Stores the list's entry number N (from 1), or a random one, in the player variable; none: no such entry"},
	"listcount": {"title": "List count", "ins": ["in"], "outs": ["then"], "props": {"list": "team", "var": "count"},
		"hint": "Stores how many players the list holds"},
	"foreach": {"title": "For each player", "ins": ["in"], "outs": ["each", "done"], "props": {"list": "team", "player": "each"},
		"hint": "Fires each once per player in the list (stored in the player variable), then done"},
	"playercheck": {"title": "Check player", "ins": ["in"], "outs": ["yes", "no"], "props": {"player": "who", "check": "dead", "a": "25"},
		"hint": "Passes the pulse to yes or no: is the player gone (left / nobody), dead, alive, below a health % or T-Eng"},
	"playerget": {"title": "Get player value", "ins": ["in"], "outs": ["then"], "props": {"player": "who", "stat": "health_percent", "var": "hp"},
		"hint": "Stores the player's health or T-Eng in a number variable (0 when gone)"},
	"playeract": {"title": "Player action", "ins": ["in"], "outs": ["then"], "props": {"player": "who", "action": "damage_percent", "a": "10"},
		"hint": "Damages (points or % of full health), kills, or adds / removes T-Eng"},
	"findmarkers": {"title": "Find markers", "ins": ["in"], "outs": ["found", "none"], "props": {"text": "spawn_*", "list": "spots"},
		"hint": "Fills the list with every script marker whose name matches (* any run of letters, ? any one: spawn_* finds spawn_1, spawn_2...), in name order"},
	"getmarker": {"title": "Get marker", "ins": ["in"], "outs": ["found", "none"], "props": {"text": "spawn_1", "random": false, "player": "spot"},
		"hint": "Stores the script marker with the name (or, with wildcards, the first or a random match) in a marker variable"},
	"spawn": {"title": "Spawn", "ins": ["in"], "outs": ["spawned", "skipped"], "props": {"kind": "weapon", "items": [0x30], "player": "spot", "random": false, "a": "100"},
		"hint": "Makes a weapon pickup (grenades, VS weapons too) or an empty VS at the marker (a marker variable: Get marker / For each), one of its items at random, with the chance (%); skipped: no marker or the chance said no. Experimental: untested in game"},
	"teleport": {"title": "Set player position", "ins": ["in"], "outs": ["moved", "skipped"], "props": {"player": "who", "to": "marker", "marker": "spot", "vec": "pos", "random": false, "face": true},
		"hint": "Teleports the player to the marker (its floor centre, or anywhere in its box) or a vector, facing the arrow / the vector's facing (Face; a vector without one keeps the player's); skipped: nobody, gone or no marker. Done on the player's own machine. Experimental: untested in game"},
	"getpos": {"title": "Get position", "ins": ["in"], "outs": ["then", "none"], "props": {"from": "player", "player": "who", "marker": "spot", "var": "pos"},
		"hint": "Stores a player's or a marker's position and facing in a vector variable; none: nobody / no marker"},
	"vector": {"title": "Vector math", "ins": ["in"], "outs": ["then"], "props": {"vecop": "tolocal", "a": "pos", "b": "0", "marker": "spot", "var": "local"},
		"hint": "Vectors are x, y, z (cm) and a facing. Into a marker's frame: where A is relative to the marker (its arrow forward); out of a marker's frame: back to the map, so moving between two markers keeps the offset and turn. Also add, subtract, scale / rotate by B, length, get or set one part"},
	"switch": {"title": "Switch", "ins": ["in"], "outs": ["1", "2", "3", "4", "5", "6", "default"], "props": {"a": "choice", "cases": [1, 2, 3]},
		"hint": "Passes the pulse to the output whose case value A equals (Cases: up to 6 numbers, comma separated), else default"},
	"sequence": {"title": "Sequence", "ins": ["in"], "outs": ["1", "2", "3", "4", "5", "6"],
		"hint": "Fires its outputs one after another, 1 first: each chain runs to its end (or its first delay) before the next"},
	"gate": {"title": "Gate", "ins": ["in", "open", "close", "toggle"], "outs": ["then"], "props": {"autostart": true},
		"hint": "Passes pulses on while open; open, close and toggle change it"},
	"once": {"title": "Do once", "ins": ["in", "reset"], "outs": ["then"],
		"hint": "Passes the first pulse on, then none until reset"},
	"branch": {"title": "Random branch", "ins": ["in"], "outs": ["1", "2", "3", "4", "5", "6"], "props": {"target": 2},
		"hint": "Passes the pulse to one of its first N outputs at random"},
	"chance": {"title": "Chance", "ins": ["in"], "outs": ["yes", "no"], "props": {"a": "50"},
		"hint": "Passes the pulse to yes with the chance (%, a number or variable), else no"},
	"cooldown": {"title": "Cooldown", "ins": ["in", "reset"], "outs": ["then", "blocked"], "props": {"seconds": 5.0},
		"hint": "Passes a pulse on at most once per its seconds (the rest go to blocked); reset lets the next one through"},
	"loop": {"title": "Loop", "ins": ["in"], "outs": ["each", "done"], "props": {"var": "i", "a": "1", "b": "5"},
		"hint": "Fires each with the variable at From, From + 1 ... To (counting down when To is lower), then done"},
	"log": {"title": "Log", "ins": ["in"], "outs": ["then"], "props": {"text": "hello"},
		"hint": "Writes its text to the xlive log (for testing a script); {name} shows a variable's value"},
}
const ORDER := ["start", "enter", "timer", "delay", "flipflop", "counter", "if", "compare", "switch", "sequence", "gate", "once", "branch", "chance", "cooldown", "loop", "set", "random", "math",
	"findmarkers", "getmarker", "spawn", "teleport", "getpos", "vector", "players", "list", "listremove", "listget", "listcount", "foreach", "playercheck", "playerget", "playeract",
	"volume", "setvalue", "log"]
# player conditions / values / actions (scripts.cpp ScriptCheck, ScriptStat, ScriptAction)
const CHECKS := [["gone", "Gone (left, nobody)"], ["dead", "Dead"], ["gone_or_dead", "Gone or dead"], ["alive", "Alive"],
	["health_below", "Health % below"], ["teng_below", "T-Eng below"]]
const STATS := [["health", "Health"], ["health_percent", "Health %"], ["health_max", "Full health"], ["teng", "T-Eng"],
	["teng_max", "T-Eng max"]]
# vector math (scripts.cpp ScriptVecOp)
const VEC_OPS := [["tolocal", "A into the marker's frame"], ["fromlocal", "A out of the marker's frame"],
	["add", "A + B (vectors)"], ["sub", "A - B (vectors)"], ["scale", "A x B (number)"], ["rotate", "A turned by B degrees"],
	["length", "Length of A (number)"], ["getx", "X of A (number)"], ["gety", "Y (height) of A"], ["getz", "Z of A"],
	["getyaw", "Facing of A (degrees)"], ["setx", "A with X = B"], ["sety", "A with Y = B"], ["setz", "A with Z = B"],
	["setyaw", "A with facing = B"]]
const ACTIONS := [["damage", "Damage (points)"], ["damage_percent", "Damage (% of full)"], ["kill", "Kill"],
	["add_teng", "Add T-Eng"], ["remove_teng", "Remove T-Eng"]]
const MATH_OPS := ["+", "-", "*", "/", "min", "max", "mod"]
const COMPARE_OPS := ["==", "!=", "<", "<=", ">", ">="]
# Set volume value: the settings each volume effect has (scripts.cpp ScriptSetting)
const SETTINGS := [["damage_player", "Damage: players %/s", "damage"], ["damage_vs", "Damage: VS %/s", "damage"],
	["gravity", "Gravity x", "gravity"], ["brightness", "Screen: brightness", "post"],
	["saturation", "Screen: saturation", "post"], ["contrast", "Screen: contrast", "post"],
	["tint_r", "Screen: tint red", "post"], ["tint_g", "Screen: tint green", "post"], ["tint_b", "Screen: tint blue", "post"]]
const DATA_COLOUR := Color(0.85, 0.75, 0.3)
const WHO := [["any", "Anyone"], ["player", "A player (on foot)"], ["vs", "A VS"]]
const PORT := 0
const EVENT_COLOUR := Color(0.95, 0.55, 0.2)
const FLOW_COLOUR := Color(0.45, 0.7, 1.0)
const ACTION_COLOUR := Color(0.45, 0.9, 0.5)

var main: Node
var graph: GraphEdit
var add_menu: PopupMenu
var info: Label
var _add_at := Vector2.ZERO
var _uid := 0
var _updating := false
var picking := false       # the eyedropper is on: main.gd sends the next click in the level to picked()
var pick_button: Button
var pick_menu: PopupMenu   # what to add for a picked volume
var _picked: Node3D

func _init() -> void:
	title = "Scripts"
	size = Vector2i(1000, 640)
	min_size = Vector2i(500, 300)
	transient = true
	visible = false
	wrap_controls = true
	close_requested.connect(hide)

func setup(m: Node) -> void:
	main = m
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var v := VBoxContainer.new()
	bg.add_child(v)
	var row := HBoxContainer.new()
	var mb := MenuButton.new()
	mb.text = "Add node"
	mb.flat = false
	for i in ORDER.size():
		mb.get_popup().add_item(TYPES[ORDER[i]]["title"], i)
		mb.get_popup().set_item_tooltip(i, TYPES[ORDER[i]]["hint"])
	mb.get_popup().id_pressed.connect(func(i):
		_add_at = (graph.scroll_offset + graph.size / 2) / graph.zoom
		add_node(ORDER[i]))
	row.add_child(mb)
	pick_button = Button.new()
	pick_button.text = "Pick from level"
	pick_button.toggle_mode = true
	pick_button.tooltip_text = "Eyedropper: click a volume, piece, light, spawn, pickup or VS in the level to add it to the script " \
		+ "(as a marker variable named after it; volumes: an event or action too). It gets a script name if it has none. Esc: cancel"
	pick_button.toggled.connect(func(on):
		picking = on
		main.set_status("Click an object in the level to add it to the script (Esc: cancel)" if on else ""))
	row.add_child(pick_button)
	info = main._label("Experimental. Events (orange) start a chain, pulses run along the links to flow (blue), data (yellow: variables) and action (green) nodes. Value fields take a number or a variable name. Right-click: add; Delete: remove selected. Runs in the match (xlive mod; the host runs it).")
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	v.add_child(row)
	graph = GraphEdit.new()
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.right_disconnects = true
	graph.connection_request.connect(_on_connect)
	graph.disconnection_request.connect(_on_disconnect)
	graph.delete_nodes_request.connect(_on_delete)
	graph.popup_request.connect(_on_popup)
	v.add_child(graph)
	add_menu = PopupMenu.new()
	for i in ORDER.size():
		add_menu.add_item(TYPES[ORDER[i]]["title"], i)
	add_menu.id_pressed.connect(func(i): add_node(ORDER[i]))
	add_child(add_menu)
	pick_menu = PopupMenu.new()
	for t in ["getmarker", "enter", "volume", "setvalue"]:
		pick_menu.add_item(TYPES[t]["title"] + (" (its box, as a marker)" if t == "getmarker" else ""))
	pick_menu.id_pressed.connect(func(i): _add_picked(["getmarker", "enter", "volume", "setvalue"][i]))
	add_child(pick_menu)

# ---------------------------------------------------------------- eyedropper

func stop_pick() -> void:
	pick_button.button_pressed = false   # toggled: picking off

func picked(n: Node3D) -> void:
	# a click in the level while picking: a volume asks what to add, anything else becomes a Get marker node
	if n == null or main._is_wall(n):
		main.set_status("Nothing to pick there: click a volume, piece, light or marker (Esc: cancel)")
		return
	stop_pick()
	_picked = n
	main.select([n])
	if n.has_meta("volume"):
		grab_focus()
		pick_menu.popup(Rect2i(position + Vector2i(graph.position + graph.size / 2), Vector2i.ZERO))
	else:
		_add_picked("getmarker")

func _add_picked(t: String) -> void:
	var n := _picked
	if not is_instance_valid(n):
		return
	_add_at = (graph.scroll_offset + graph.size / 2) / graph.zoom + Vector2(randf_range(-40, 40), randf_range(-40, 40))
	if t == "getmarker":
		var tag: String = main.ensure_tag(n)
		add_node("getmarker")
		var nd: Dictionary = data()["nodes"][-1]
		nd["text"] = tag
		nd["player"] = tag   # the marker variable, named after it
	else:
		add_node(t)   # picks up the selected volume
	var g := graph.get_node_or_null(str(data()["nodes"][-1]["id"]))
	if g:
		graph.remove_child(g)
		g.queue_free()
		_make(data()["nodes"][-1])
	grab_focus()
	main.log_line("Script: added %s for %s." % [TYPES[t]["title"], main.object_tag(n) if main.object_tag(n) != "" else "the volume"])

# ---------------------------------------------------------------- data

func data() -> Dictionary:
	if not main.project.has("scripts") or not (main.project["scripts"] is Dictionary):
		main.project["scripts"] = {"nodes": [], "links": []}
	var d: Dictionary = main.project["scripts"]
	if not d.has("nodes"):
		d["nodes"] = []
	if not d.has("links"):
		d["links"] = []
	return d

func _node_data(id: String) -> Dictionary:
	for n in data()["nodes"]:
		if n["id"] == id:
			return n
	return {}

func _kind(t: String) -> Color:
	if t in ["start", "enter", "timer"]:
		return EVENT_COLOUR
	if t in ["volume", "setvalue", "log", "playeract", "spawn", "teleport"]:
		return ACTION_COLOUR
	if t in ["set", "random", "math", "getpos", "vector", "findmarkers", "getmarker", "players", "list", "listremove", "listget", "listcount", "playerget"]:
		return DATA_COLOUR
	return FLOW_COLOUR

func refresh() -> void:
	# the graph from the project (open, undo)
	_updating = true
	graph.clear_connections()
	for c in graph.get_children():
		if c is GraphNode:
			graph.remove_child(c)
			c.queue_free()
	if main.project.is_empty():
		_updating = false
		return
	for n in data()["nodes"]:
		_uid = maxi(_uid, int(str(n["id"]).trim_prefix("n")))
		_make(n)
	for l in data()["links"]:
		var a := _port_index(str(l[0]), str(l[1]), false)
		var b := _port_index(str(l[2]), str(l[3]), true)
		if a >= 0 and b >= 0:
			graph.connect_node(str(l[0]), a, str(l[2]), b)
	_updating = false

func _port_index(id: String, port: String, input: bool) -> int:
	var n := _node_data(id)
	if n.is_empty() or not TYPES.has(n["type"]):
		return -1
	return (TYPES[n["type"]]["ins" if input else "outs"] as Array).find(port)

func add_node(t: String) -> void:
	if main.project.is_empty():
		return
	main._push_undo("")
	_uid += 1
	var n := {"id": "n%d" % _uid, "type": t, "pos": [snappedf(_add_at.x, 10), snappedf(_add_at.y, 10)]}
	for k in TYPES[t].get("props", {}):
		n[k] = TYPES[t]["props"][k]
	if t in ["enter", "volume", "setvalue"]:
		var sel: Array = main.selection.filter(func(x): return is_instance_valid(x) and main.volumes.is_volume(x))
		if sel.size() == 1:
			n["volume"] = main.volumes.ensure_id(sel[0].get_meta("data"))   # the selected volume
	data()["nodes"].append(n)
	_make(n)

func _make(n: Dictionary) -> void:
	var t: String = n["type"]
	var spec: Dictionary = TYPES.get(t, {})
	if spec.is_empty():
		return
	var g := GraphNode.new()
	g.name = n["id"]
	g.title = spec["title"]
	g.tooltip_text = spec["hint"]
	g.position_offset = Vector2(float(n["pos"][0]), float(n["pos"][1]))
	g.position_offset_changed.connect(func():
		n["pos"] = [snappedf(g.position_offset.x, 1), snappedf(g.position_offset.y, 1)])
	var ins: Array = spec["ins"]
	var outs: Array = spec["outs"]
	var col := _kind(t)
	for i in maxi(ins.size(), outs.size()):
		var h := HBoxContainer.new()
		var l := Label.new()
		l.text = ins[i] if i < ins.size() else ""
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var r := Label.new()
		r.text = outs[i] if i < outs.size() else ""
		if t == "switch" and i < 6:
			var cs: Array = n.get("cases", [])
			r.text = ("= %s" % str(cs[i])) if i < cs.size() else "(unused)"
		r.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(r)
		g.add_child(h)
		g.set_slot(i, i < ins.size(), PORT, Color.WHITE, i < outs.size(), PORT, col)
	for k in spec.get("props", {}):
		g.add_child(_prop_control(n, k))
	var head := g.get_titlebar_hbox()
	if head:
		head.modulate = col.lightened(0.3)
	graph.add_child(g)

func _prop_control(n: Dictionary, k: String) -> Control:
	var h := HBoxContainer.new()
	match k:
		"volume":
			h.add_child(main._label("Volume"))
			var o := OptionButton.new()
			o.custom_minimum_size.x = 170
			o.clip_text = true
			var vs: Array = main.project.get("volumes", [])
			o.add_item("(pick one)")
			o.set_item_metadata(0, "")
			for d in vs:
				o.add_item(main.volumes.label(d).trim_prefix("Volume: "))
				o.set_item_metadata(o.item_count - 1, d)
				if str(d.get("id", "")) != "" and d.get("id") == n.get("volume"):
					o.select(o.item_count - 1)
			o.pressed.connect(func(): _refill_volumes(o, n))
			o.item_selected.connect(func(i):
				var d: Variant = o.get_item_metadata(i)
				main._push_undo("")
				n["volume"] = main.volumes.ensure_id(d) if d is Dictionary else "")
			h.add_child(o)
			var b := Button.new()
			b.text = "Show"
			b.tooltip_text = "Select it in the level"
			b.pressed.connect(func(): main.volumes.select_id(str(n.get("volume", ""))))
			h.add_child(b)
		"who":
			h.add_child(main._label("Who"))
			var o := OptionButton.new()
			for w in WHO:
				o.add_item(w[1])
			o.selected = maxi(0, WHO.map(func(w): return w[0]).find(n.get("who", "any")))
			o.item_selected.connect(func(i): _set_prop(n, "who", WHO[i][0]))
			h.add_child(o)
		"value":
			h.add_child(main._label("To"))
			var e := LineEdit.new()
			e.text = str(n.get("value", "toggle"))
			e.custom_minimum_size.x = 100
			e.tooltip_text = "A number, a variable's name, on (1), off (0) or toggle (0 <-> 1)"
			e.text_changed.connect(func(x): _set_prop(n, "value", x))
			h.add_child(e)
		"cases":
			h.add_child(main._label("Cases"))
			var e := LineEdit.new()
			e.text = ", ".join((n.get("cases", []) as Array).map(func(x): return str(x)))
			e.custom_minimum_size.x = 120
			e.tooltip_text = "Up to 6 numbers, comma separated: the values of outputs 1-6 (Enter to apply)"
			var apply := func(x: String):
				var cs: Array = []
				for part in x.split(",", false):
					if part.strip_edges().is_valid_float() and cs.size() < 6:
						cs.append(float(part.strip_edges()) if "." in part else int(part.strip_edges()))
				_set_prop(n, "cases", cs)
				refresh()
			e.text_submitted.connect(apply)
			e.focus_exited.connect(func(): apply.call(e.text))
			h.add_child(e)
		"seconds", "target", "max_seconds":
			var caption: String = {"seconds": "Fade (s)" if n["type"] == "setvalue" else "Seconds", "target": "Outputs" if n["type"] == "branch" else "Target",
				"max_seconds": "Up to (s)"}[k]
			h.add_child(main._label(caption))
			var s: SpinBox = main._spin(1.0 if k == "target" else 0.0, 6.0 if n["type"] == "branch" else 3600.0, 1.0 if k == "target" else 0.1)
			s.value = float(n.get(k, 0.0 if k == "max_seconds" else 1.0))
			if k == "max_seconds":
				s.tooltip_text = "Above Seconds: a random time between the two each time; 0: always Seconds"
			s.value_changed.connect(func(x): _set_prop(n, k, int(x) if k == "target" else x))
			h.add_child(s)
		"a", "b":
			var caption := "Value"
			if n["type"] in ["random", "loop"]:
				caption = "From" if k == "a" else "To"
			elif n["type"] in ["listremove", "playercheck"]:
				caption = "Below"
			elif n["type"] == "listget":
				caption = "Number"
			elif n["type"] == "playeract":
				caption = "Amount"
			elif n["type"] in ["spawn", "chance"]:
				caption = "Chance %"
			elif n["type"] == "switch":
				caption = "Value"
			elif n["type"] == "vector":
				caption = k.to_upper()
			elif n["type"] in ["math", "compare"]:
				caption = k.to_upper()
			h.add_child(main._label(caption))
			var e := LineEdit.new()
			e.text = str(n.get(k, ""))
			e.custom_minimum_size.x = 100
			e.tooltip_text = "A number, or a variable's name (its value)"
			e.text_changed.connect(func(x): _set_prop(n, k, x))
			h.add_child(e)
		"op":
			h.add_child(main._label("Op"))
			var ops: Array = MATH_OPS if n["type"] == "math" else COMPARE_OPS
			var o := OptionButton.new()
			for x in ops:
				o.add_item(x)
			o.selected = maxi(0, ops.find(n.get("op", ops[0])))
			o.item_selected.connect(func(i): _set_prop(n, "op", ops[i]))
			h.add_child(o)
		"setting":
			h.add_child(main._label("Setting"))
			var o := OptionButton.new()
			o.custom_minimum_size.x = 170
			_fill_settings(o, n)
			o.pressed.connect(func(): _fill_settings(o, n))
			o.item_selected.connect(func(i): _set_prop(n, "setting", str(o.get_item_metadata(i))))
			h.add_child(o)
		"check", "stat", "action", "vecop", "from", "to":
			var opts: Array = {"check": CHECKS, "stat": STATS, "action": ACTIONS, "vecop": VEC_OPS,
				"from": [["player", "A player"], ["marker", "A marker"]], "to": [["marker", "A marker"], ["vector", "A vector"]]}[k]
			h.add_child(main._label({"check": "If", "stat": "Value", "action": "Do", "vecop": "Do", "from": "Of", "to": "To"}[k]))
			var o := OptionButton.new()
			for x in opts:
				o.add_item(x[1])
			o.selected = maxi(0, opts.map(func(x): return x[0]).find(n.get(k, opts[0][0])))
			o.item_selected.connect(func(i): _set_prop(n, k, opts[i][0]))
			h.add_child(o)
		"kind":
			h.add_child(main._label("Make"))
			var o := OptionButton.new()
			o.add_item("Weapon / grenade pickup")
			o.add_item("VS (empty)")
			o.selected = 1 if n.get("kind", "weapon") == "vs" else 0
			o.item_selected.connect(func(i):
				_set_prop(n, "kind", "vs" if i == 1 else "weapon")
				n["items"] = []
				refresh())
			h.add_child(o)
		"items":
			var v := VBoxContainer.new()
			var names := Label.new()
			names.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			names.custom_minimum_size.x = 230
			var choices := _spawn_choices(n)
			var shown := func():
				var picked: Array = n.get("items", [])
				names.text = "One of: " + ", ".join(picked.map(func(i):
					var c: Variant = choices.filter(func(x): return int(x[0]) == int(i)).front()
					return str(c[1]) if c != null else "%02X" % int(i))) if picked else "(add what it may make)"
			shown.call()
			v.add_child(names)
			var row := HBoxContainer.new()
			var add := MenuButton.new()
			add.text = "Add..."
			add.flat = false
			for i in choices.size():
				add.get_popup().add_item(str(choices[i][1]), i)
			add.get_popup().id_pressed.connect(func(i):
				var picked: Array = (n.get("items", []) as Array).duplicate()
				if not picked.has(int(choices[i][0])):
					picked.append(int(choices[i][0]))
				_set_prop(n, "items", picked)
				shown.call())
			row.add_child(add)
			var clear := Button.new()
			clear.text = "Clear"
			clear.pressed.connect(func():
				_set_prop(n, "items", [])
				shown.call())
			row.add_child(clear)
			v.add_child(row)
			h.add_child(v)
		"repeat", "autostart", "start_off", "integer", "random", "face":
			var c := CheckBox.new()
			c.text = {"repeat": "Repeat", "start_off": "Starts off",
				"integer": "Whole numbers", "face": "Face the marker's arrow",
				"autostart": "Starts open" if n["type"] == "gate" else "Starts with the match", "random": "Anywhere in its box" if n["type"] in ["spawn", "teleport"] else "A random one"}[k]
			c.button_pressed = n.get(k, k == "face")
			c.toggled.connect(func(x): _set_prop(n, k, x))
			h.add_child(c)
		"var", "text", "player", "list", "marker", "vec":
			var cap: String = {"var": "Variable", "text": "Text", "player": "Player", "list": "List", "marker": "Marker", "vec": "Vector"}[k]
			if k == "text" and n["type"] in ["findmarkers", "getmarker"]:
				cap = "Name"
			elif k == "player" and n["type"] in ["getmarker", "spawn"]:
				cap = "Marker"
			elif k == "player" and n["type"] in ["list", "listget", "foreach"]:
				cap = "Entry"
			h.add_child(main._label(cap))
			var e := LineEdit.new()
			e.text = str(n.get(k, ""))
			if k == "player":
				e.tooltip_text = "A marker variable's name" if n["type"] in ["getmarker", "spawn"] else "A player variable's name (a marker's for a list Find markers fills)" if n["type"] in ["list", "listget", "foreach"] else "A player variable's name" + (" (empty: not stored)" if n["type"] == "enter" else "")
			elif k == "list":
				e.tooltip_text = "A list variable's name"
			elif k == "marker":
				e.tooltip_text = "A marker variable's name (Get marker, For each over Find markers)"
			elif k == "vec":
				e.tooltip_text = "A vector variable's name (Get position, Vector math)"
			e.custom_minimum_size.x = 140
			e.text_changed.connect(func(x): _set_prop(n, k, x))
			h.add_child(e)
	return h

func _spawn_choices(n: Dictionary) -> Array:
	# [id, name]: the placer's VS families, or the pickup items (not "stock")
	if n.get("kind", "weapon") == "vs":
		var out: Array = []
		for t in main.placer.vs_types:
			out.append([t[0], str(t[2]).get_slice("\n", 0)])
		return out
	return main.PICKUP_ITEMS.filter(func(x): return int(x[0]) >= 0)

func _volume_of(n: Dictionary) -> Dictionary:
	for d in main.project.get("volumes", []):
		if str(d.get("id", "")) != "" and d.get("id") == n.get("volume"):
			return d
	return {}

func _fill_settings(o: OptionButton, n: Dictionary) -> void:
	# the settings of the node's volume's effects (all while it has none picked)
	o.clear()
	var d := _volume_of(n)
	for st in SETTINGS:
		if d.is_empty() or d.get(st[2]):
			o.add_item(st[1])
			o.set_item_metadata(o.item_count - 1, st[0])
			if st[0] == n.get("setting", ""):
				o.select(o.item_count - 1)
	if o.item_count and str(n.get("setting", "")) == "":
		n["setting"] = str(o.get_item_metadata(0))   # a new node: the first
		o.select(0)

func _refill_volumes(o: OptionButton, n: Dictionary) -> void:
	# the level's volumes now (added / renamed since the node was made)
	o.clear()
	o.add_item("(pick one)")
	o.set_item_metadata(0, "")
	for d in main.project.get("volumes", []):
		o.add_item(main.volumes.label(d).trim_prefix("Volume: "))
		o.set_item_metadata(o.item_count - 1, d)
		if str(d.get("id", "")) != "" and d.get("id") == n.get("volume"):
			o.select(o.item_count - 1)

func _set_prop(n: Dictionary, k: String, v: Variant) -> void:
	if _updating:
		return
	main._push_undo("script-" + n["id"] + k)
	n[k] = v

func _on_connect(from: StringName, fp: int, to: StringName, tp: int) -> void:
	var a := _node_data(str(from))
	var b := _node_data(str(to))
	if a.is_empty() or b.is_empty():
		return
	main._push_undo("")
	graph.connect_node(from, fp, to, tp)
	data()["links"].append([str(from), TYPES[a["type"]]["outs"][fp], str(to), TYPES[b["type"]]["ins"][tp]])

func _on_disconnect(from: StringName, fp: int, to: StringName, tp: int) -> void:
	var a := _node_data(str(from))
	var b := _node_data(str(to))
	main._push_undo("")
	graph.disconnect_node(from, fp, to, tp)
	if a.is_empty() or b.is_empty():
		return
	var key := [str(from), TYPES[a["type"]]["outs"][fp], str(to), TYPES[b["type"]]["ins"][tp]]
	data()["links"] = (data()["links"] as Array).filter(func(l): return l != key)

func _on_delete(names: Array) -> void:
	if names.is_empty():
		return
	main._push_undo("")
	var ids: Array = names.map(func(x): return str(x))
	data()["nodes"] = (data()["nodes"] as Array).filter(func(n): return not ids.has(n["id"]))
	data()["links"] = (data()["links"] as Array).filter(func(l): return not ids.has(l[0]) and not ids.has(l[2]))
	refresh()

func _on_popup(at: Vector2) -> void:
	_add_at = (graph.scroll_offset + at) / graph.zoom
	add_menu.position = Vector2i(position) + Vector2i(graph.global_position + at)
	add_menu.popup()

func problems() -> Array:
	# what the export would skip: nodes missing a volume
	var out: Array = []
	var ids := {}
	for d in main.project.get("volumes", []):
		if str(d.get("id", "")) != "":
			ids[d["id"]] = true
	for n in data()["nodes"]:
		if n["type"] in ["enter", "volume", "setvalue"] and not ids.has(n.get("volume", "")):
			out.append("%s (%s) has no volume" % [TYPES[n["type"]]["title"], n["id"]])
		elif n["type"] == "setvalue":
			var d := _volume_of(n)
			var st: Array = SETTINGS.filter(func(x): return x[0] == n.get("setting", ""))
			if st.is_empty() or not d.get(st[0][2]):
				out.append("Set volume value (%s): its volume has no %s" % [n["id"], "such setting" if st.is_empty() else st[0][2]])
	return out
