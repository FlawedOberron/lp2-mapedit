extends Node
# LP2 Map Editor: open a map project (lp2-tools/lp2project.py), fly round its stage, edit the layout markers
# per layout variant and the level geometry (pieces: move, rotate, scale, group, duplicate, delete, prefabs),
# save, compile (lp2mapc.py) and install the package.
#
# Units: projects are in LP2 centimetres (Y up); the viewport is in metres (cm / 100).
# Command line (after --): --project DIR   open it on start
#                           --screenshot PNG save a frame once the stage is shown, then quit (tests)
#                           --place      (with --screenshot) place a VS mid-screen by a scripted click and drag
#                           --place-volume  (with --screenshot) the same for a post-process volume, its floor dragged out
#                           --preview-post  (with --place-volume) the camera inside it, the post-process preview on
#                           --select N       select marker N; --piece N select piece N (--lift M: raise it M metres); --lit; --save

const SETTINGS := "user://settings.cfg"
const DEFAULT_TOOLS := "~/Projects/lp2-tools"
const CM := 0.01
const ROLE_COLOURS := {
	"team_a": Color(0.9, 0.15, 0.12), "team_b": Color(0.15, 0.35, 0.95),
}
const SPAWN_COLOUR := Color(0.2, 0.85, 0.3)
const OBJECT_STYLE := {  # role -> [colour, size (m)]
	"vs": [Color(1.0, 0.55, 0.1), Vector3(3.0, 3.0, 3.0)],
	"weapon": [Color(1.0, 0.9, 0.2), Vector3(0.8, 0.5, 0.8)],
	"object": [Color(0.7, 0.3, 0.9), Vector3(1.2, 2.5, 1.2)],
}
# pickup colours: green = a loadout slot's weapon, orange = grenade, blue = VS weapon / gear (battle armor, flying
# gear), red = an explicit weapon; yellow = no item (an LP1 record: the stock pickup)
const PICKUP_COLOURS := {"slot": Color(0.25, 0.9, 0.3), "grenade": Color(1.0, 0.5, 0.1), "vs": Color(0.25, 0.55, 1.0),
	"explicit": Color(0.95, 0.2, 0.2)}
const PICKUP_RAISE := 0.3   # m: weapon models float above their marker, as the game shows them
# weapon pickup ids (rObjSet +0x1a, the game's uWpXX classes). Slots: the match settings and loadouts pick the
# weapon (the lobby's "only X" weapon rules turn pickups below 0x35 into 0x30-0x33). Names of fixed weapons come
# from their models / vibration types where nothing better is known; 0x00 is the Anchor (grappling hook), not a pickup.
# VS weapon names: the game's id -> MsgCommon name function (DX9 FUN_008a1980); ids it doesn't name are VS-only
# (mounted, no pickup / carry logic) and aren't offered
const PICKUP_ITEMS := [
	[-1, "Stock pickup (differs per game type)"],
	[0x30, "Slot: Standard (Assault Rifle)"], [0x31, "Slot: Short range (Shotgun)"], [0x32, "Slot: Long range (Rifle)"],
	[0x33, "Slot: Heavy Weapons (Rocket Launcher)"], [0x34, "Slot: Support (Shield)"], [0x0c, "Slot: Handgun"],
	[0x15, "Frag Grenade"], [0x16, "Gum Grenade"], [0x17, "Disk Grenade"], [0x18, "Dummy Grenade"],
	[0x19, "Plasma Grenade"],
	[0x01, "Machine Gun"], [0x02, "Fixed 02 (long range)"], [0x03, "Fixed 03 (energy)"],
	[0x04, "Fixed 04 (heavy)"], [0x05, "Fixed 05 (short range)"], [0x06, "Fixed 06"], [0x0d, "Fixed 0D (handgun?)"],
	[0x0e, "Fixed 0E (handgun?)"], [0x0f, "Fixed 0F"],
	[0x1c, "Battle Armor (wp1a)"], [0x1e, "Battle Armor (wp1a, 1e)"], [0x1f, "Flying gear / bike (vsd1)"],
	[0x1d, "Flying gear (vsd1, 1d)"],
	[0x41, "VS Gatling Gun"], [0x42, "VS Laser Rifle"], [0x43, "VS Rocket Launcher"], [0x44, "VS Shotgun"],
	[0x45, "VS Grenade Launcher"], [0x46, "VS EM Laser"], [0x47, "VS Homing Laser"], [0x60, "VS Pile Bunker"],
	[0x61, "VS Rocket Pod"], [0x62, "VS Laser Lance"], [0x63, "VS Rifle"],
]
# VS tiers (rObjSet +0x04), as the game filters them (DX9 FUN_00f71410, the lobby's VS setting): None shows no VS,
# Few tier 0, Many tiers 0 + 10, All every tier; -1 = the base map's record's
const VS_TIERS := [[-1, "Stock (base map's, by index)"], [0, "Few, Many and All"], [10, "Many and All"],
	[20, "All only"]]
const DIG_PILES := ["Pile A (om8100: Pirate Fortress, Frozen Wasteland)", "Pile B (om8103: Desecration, Jungle)",
	"Pile C (om8104: Desecration, Jungle)"]
# LP2 game types (lp2layout.py MODES: the game's layout file names); sets and markers list them in "modes"
const GAME_TYPES := [["team", "Team Elimination"], ["slayer", "Elimination"], ["datapost", "Data Post"],
	["fox", "Fugitive"], ["egg", "Akrid Egg"], ["counter", "Counter (name unknown)"], ["vs", "VS (name unknown)"]]
# top bar view icons (white line art, drawn from SVG at run time: no imported files)
const ICON_VOLUMES := '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" stroke="#e8e8e8" stroke-width="1.6" stroke-linejoin="round"><path d="M3 7l7-4 7 4v7l-7 4-7-4z"/><path d="M3 7l7 4 7-4M10 11v7" stroke-dasharray="2 1.6"/></svg>'
const ICON_LIGHTS := '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" stroke="#e8e8e8" stroke-width="1.6" stroke-linecap="round"><path d="M10 2.5a5 5 0 0 0-3 9c.7.6 1 1.3 1 2.2h4c0-.9.3-1.6 1-2.2a5 5 0 0 0-3-9z"/><path d="M8 16h4M8.7 18.3h2.6"/></svg>'
const ICON_ADD_LIGHT := '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" stroke="#e8e8e8" stroke-width="1.6" stroke-linecap="round"><path d="M9 3.5a4.5 4.5 0 0 0-2.7 8.1c.6.5.9 1.2.9 2h3.6c0-.8.3-1.5.9-2A4.5 4.5 0 0 0 9 3.5z"/><path d="M7.4 16.3h3.2"/><path d="M16 1.5v5M13.5 4h5" stroke="#9fe29f"/></svg>'
const ICON_FOG := '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" stroke="#e8e8e8" stroke-width="1.6" stroke-linecap="round"><path d="M2.5 6c2-1.6 3.5-1.6 5 0s3 1.6 5 0 3.5-1.6 5 0M2.5 10.5c2-1.6 3.5-1.6 5 0s3 1.6 5 0 3.5-1.6 5 0M2.5 15c2-1.6 3.5-1.6 5 0s3 1.6 5 0 3.5-1.6 5 0"/></svg>'
const ICON_POST := '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" stroke="#e8e8e8" stroke-width="1.6" stroke-linejoin="round"><rect x="2.5" y="5" width="12" height="10" rx="1.5"/><path d="M14.5 8.5l3.5-2v7l-3.5-2z"/><circle cx="8.5" cy="10" r="2.3" fill="#e8e8e8" fill-opacity="0.35"/></svg>'

const CATEGORIES := ["Spawns & game logic", "Pickups", "Vehicles", "Level geometry", "Lights", "Volumes"]
const LAYER_STAGE := 1
const LAYER_MARKERS := 2
const LAYER_COLLISION := 3   # View collision's triangles: clicking one selects the piece it belongs to

var cfg := ConfigFile.new()
var tools := ""
var game := ""
var python := "python3"

var project_dir := ""
var save_as_dialog: FileDialog
var project := {}
var layout := {}
var variant := 0
var set_index := -1
var visible_sets: Array = []

var world: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var geometry: Node3D
var markers_root: Node3D
var gizmo: Node3D
var baked := true
var bake_scale := 2.0
var select_on_start := -1
var piece_on_start := -1
var lift_on_start := 0.0

var selection: Array = []
var drag_start: Array = []
var face_press := {}   # a Ctrl+press on a volume face: a drag pushes / pulls it (volumes.gd), a click selects
var screenshot_path := ""
const Lpme := preload("res://lpme.gd")
var project_file := ""     # the open .lpme (its workspace is project_dir); "" = a project folder (older)
var packing := false        # a save's pack into the .lpme runs on a worker
var pack_again := false
var busy := false
var job_queue: Array = []   # [script, args, done] waiting for the running job
var undo_stack: Array = []
var redo_stack: Array = []
var undo_key := ""
var undo_time := 0
var stats_dirty := false

# UI
var status: Label
var job_bar: ProgressBar
var log_box: TextEdit
var set_pick: OptionButton
var set_types: MenuButton
var type_box: Control         # the inspector's game types (markers)
var type_checks: Array = []
var type_exists: Label
var layout_buttons: Array = []
var mode_buttons: Array = []
var snap_toggle: CheckButton
var outliner: Tree
var cat_items: Array = []
var prefab_list: ItemList   # in the browser window
var browser: Window
var mesh_builder: Window
var lighting: Window
var fog_win: Window
var settings_win: Window
var new_win: Window
var placer: Window   # place.gd: click-and-drag placing of spawns, weapons, VS
var preview: Node3D
var ui_root: Control   # the editor's panels (hidden while previewing)
var lighting_dialog: FileDialog
var world_env: Environment
var thumbs: Node
var library: Node
var library_dir := ""
var lp1_dir := ""
var browser_tab := -1
var browser_group := ""
var marker_tint: StandardMaterial3D   # selection tint on marker models (fainter than the stage's: models stack many layers)
var insp_title: Label
var insp_name: LineEdit
var insp_pos: Array = []
var insp_rot: Array = []
var insp_scale: Array = []
var insp_rows: Array = []   # rows hidden for markers (tilt, scale)
var piece_buttons: Array = []
var mesh_col: CheckBox   # selected pieces: collision made from their visible mesh
var info_name: LineEdit
var info_size: OptionButton
var water_on: CheckBox
var water_height: SpinBox
var kill_on: CheckBox
var kill_height: SpinBox
var kill_plane: MeshInstance3D
var physics_on: CheckBox
var thumb_preview: TextureRect  # Map info: the create-match picture (project info.thumbnail), in its menu circle
var thumb_zoom: SpinBox
var thumb_dialog: FileDialog
var lowgrav_on: CheckBox        # Map info: environment jump_packs / underwater / gravity (xlive gravity.cpp)
var underwater_on: CheckBox
var gravity_spin: SpinBox
var volumes: Node               # volumes.gd: kill / gravity / post-process boxes
var vrow_add: HBoxContainer     # Map info row the Add volume menu goes in
var pickup_row: Control   # explicit weapon pickup
var pickup_pick: OptionButton
var tier_row: Control     # VS tier
var vs_props: VBoxContainer   # VS variant + arm weapons (vsprops.gd)
var tier_pick: OptionButton
var dig_row: Control   # buried pickups / VS ("dig here" pile)
var dig_on: CheckBox
var dig_count: SpinBox
var dig_pile: OptionButton
var baked_toggle: CheckButton
var wire_toggle: CheckButton
var drag_sizes: Array = []   # volumes' sizes when a gizmo drag began
var view_toggles := {}   # top bar icons: "volumes", "lights", "fog", "post" (remembered in settings)
var wire_on_start := false   # --wireframe (tests)
var thumb_on_start := false  # --capture-thumbnail (tests): the view's thumbnail once the map is framed
var col_toggle: CheckButton
var info_win: Window
var col_mesh: MeshInstance3D   # View collision: the movement collision, green see-through
var col_body: StaticBody3D     # its triangles, for picking
var col_owner := PackedInt32Array()   # per triangle: stage atom, or -2 - k for copy k (lp2colview.py)
var col_pieces := {}           # "a<atom>" / "c<copy>" -> piece index, from the geometry the view was built from
const WALL := -1000000         # col_owner of collision-only wall k: WALL - k (no visible geometry: invisible boundaries)
var col_key := ""             # the inputs the shown collision view was built from (_collision_key)
var col_walls := {}            # wall id -> Node3D (meta "wall"), selectable while View collision is on
var open_dialog: FileDialog
var perf_button: Button
var perf_bar: ProgressBar
var perf_panel: PanelContainer
var perf_grid: GridContainer
var updating_ui := false
var updates: Node
var quit_dialog: ConfirmationDialog
var saved_state := ""   # _saved_state() at the last save / open
var opening := false     # a project just opened: its state counts as saved once its geometry has loaded

func _notification(what: int) -> void:
	# low-processor mode (project.godot) already redraws only on changes; in the background, cap it lower still
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Engine.max_fps = 10
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		Engine.max_fps = 0
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if project_dir != "" and screenshot_path == "" and _saved_state() != saved_state:
			quit_dialog.popup_centered()
		else:
			get_tree().quit()

func _svg_icon(svg: String) -> Texture2D:
	var img := Image.new()
	img.load_svg_from_string(svg, DisplayServer.screen_get_scale() if OS.get_name() == "macOS" else 1.0)
	return ImageTexture.create_from_image(img)

func _on_view_toggle(on: bool, what: String) -> void:
	cfg.set_value("view", what, on)
	cfg.save(SETTINGS)
	match what:
		"fog":
			fog_win.apply_preview()
		"post":
			volumes.preview_post_off()
		_:
			apply_marker_visibility()

func view_on(what: String) -> bool:
	return view_toggles[what].button_pressed if view_toggles.has(what) else true

func apply_marker_visibility() -> void:
	# the view toggles: volumes / light nodes hidden (still in the outliner); a hidden one can't stay selected
	var hidden: Array = []
	for n in markers_root.get_children():
		var show := not (n.has_meta("volume") and not view_on("volumes") or n.has_meta("light") and not view_on("lights"))
		n.visible = show
		if not show and selection.has(n):
			hidden.append(n)
	if not hidden.is_empty():
		select(selection.filter(func(m): return not hidden.has(m)))

func _saved_state() -> String:
	# what Save writes; unsaved changes = it differs from the last save / open
	if project.is_empty():
		return ""
	return JSON.stringify(project) + JSON.stringify(layout) + (JSON.stringify(geometry.to_json()) if geometry.get_child_count() else "")

func _ready() -> void:
	get_tree().auto_accept_quit = false
	quit_dialog = ConfirmationDialog.new()
	quit_dialog.title = "Unsaved changes"
	quit_dialog.dialog_text = "Save the map's changes before closing?"
	quit_dialog.ok_button_text = "Save and close"
	quit_dialog.add_button("Close without saving", true, "discard")
	quit_dialog.confirmed.connect(func(): save_project(); get_tree().quit())
	quit_dialog.custom_action.connect(func(_a): get_tree().quit())
	add_child(quit_dialog)
	RenderingServer.set_debug_generate_wireframes(true)   # before any mesh exists: the Wireframe toggle needs them
	cfg.load(SETTINGS)
	var bundle := bundle_dir()
	if bundle != "":   # the release (Windows zip / AppImage): its own Python and tools, beside the executable
		tools = bundle.path_join("tools")
		python = bundle.path_join("python/python.exe" if OS.has_feature("windows") else "python/bin/python3")
	else:
		var repo_tools := ProjectSettings.globalize_path("res://").path_join("../tools").simplify_path()   # lp2-mapedit checkout
		tools = _home(cfg.get_value("paths", "tools", repo_tools if FileAccess.file_exists(repo_tools.path_join("runtool.py")) else DEFAULT_TOOLS))
		python = cfg.get_value("paths", "python", "python3")
	game = cfg.get_value("paths", "game", "")
	if not is_lp2_folder(game):
		game = _steam_game("Lost Planet 2")
	library_dir = _home(cfg.get_value("paths", "library", OS.get_user_data_dir().path_join("library") if bundle != "" else "~/Projects/lp2-assets/library"))
	lp1_dir = _home(cfg.get_value("paths", "lp1", ""))
	if lp1_dir == "":
		lp1_dir = _steam_game("lost planet extreme condition")
	library = Node.new()
	library.set_script(load("res://library.gd"))
	add_child(library)
	library.load_index(library_dir)
	marker_tint = StandardMaterial3D.new()
	marker_tint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker_tint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	marker_tint.albedo_color = Color(1.0, 0.7, 0.15, 0.12)
	var args := OS.get_cmdline_user_args()
	if args.is_empty() and bundle != "":   # the release takes them without "--" too
		args = OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "--project" and i + 1 < args.size():
			call_deferred("open_map_file" if args[i + 1].get_extension().to_lower() == "lpme" else "open_project", args[i + 1])
		elif args[i] == "--screenshot" and i + 1 < args.size():
			screenshot_path = args[i + 1]
			OS.low_processor_usage_mode = false   # it waits on frames; idle redraw-on-change would never draw one
		elif args[i] == "--select" and i + 1 < args.size():
			select_on_start = int(args[i + 1])
		elif args[i] == "--piece" and i + 1 < args.size():
			piece_on_start = int(args[i + 1])
		elif args[i] == "--lift" and i + 1 < args.size():
			lift_on_start = float(args[i + 1])
		elif args[i] == "--browser":
			call_deferred("toggle_browser")
		elif args[i] == "--mesh-builder":
			call_deferred("toggle_mesh_builder")
		elif args[i] == "--lighting":
			call_deferred("toggle_lighting")
		elif args[i] == "--fog":
			call_deferred("toggle_fog")
		elif args[i] == "--browser-tab" and i + 1 < args.size():
			browser_tab = int(args[i + 1])
		elif args[i] == "--browser-group" and i + 1 < args.size():
			browser_group = args[i + 1]
		elif args[i] == "--capture-thumbnail":
			thumb_on_start = true
		elif args[i] == "--info":
			call_deferred("toggle_info")
		elif args[i] == "--collision":
			call_deferred("_test_collision")
		elif args[i] == "--wireframe":
			wire_on_start = true
		elif args[i] == "--lit":
			baked = false
		elif args[i] == "--bake-scale" and i + 1 < args.size():
			bake_scale = float(args[i + 1])
	_build_world()
	_build_ui()
	if (not is_lp2_folder(game) or not FileAccess.file_exists(library_dir.path_join("index.json"))) and not args.has("--project"):
		settings_win.call_deferred("open", true)
	elif project_dir == "" and not args.has("--project"):
		var last: String = cfg.get_value("recent", "project", "")
		if last.get_extension().to_lower() == "lpme" and FileAccess.file_exists(last):
			call_deferred("open_map_file", last)
		elif last != "" and DirAccess.dir_exists_absolute(last):
			call_deferred("open_project", last)
	log_line("LP2 Map Editor. Right mouse: look (WASD, Q E / Ctrl Space down up, Shift fast, wheel speed). Left click: select (Shift / Ctrl: add). " +
		"W / E / R: move / rotate / scale with the gizmo (Ctrl while dragging: snap). F: frame. End: drop to floor. Ctrl+drag a volume face: push / pull it (Shift: snap); Ctrl+Shift+drag: a new box out of it; Ctrl+Shift+right click: delete that box. " +
		"Ctrl+D duplicate, Ctrl+G group, Ctrl+Shift+G ungroup, Delete, Ctrl+Z / Ctrl+Y undo / redo.")

# ---------------------------------------------------------------- world

func _build_world() -> void:
	world = Node3D.new()
	add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	world_env = env
	world.add_child(we)
	sun = DirectionalLight3D.new()
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	world.add_child(sun)
	_set_sun(Vector3(0.472, 0.848, 0.241))
	camera = Camera3D.new()
	camera.set_script(load("res://fly_camera.gd"))
	world.add_child(camera)
	camera.look_at_point(Vector3.ZERO, Vector3(60, 60, 60))
	camera.right_clicked.connect(_on_right_click)
	geometry = Node3D.new()
	geometry.set_script(load("res://geometry.gd"))
	geometry.bake_scale = bake_scale
	geometry.library = library
	geometry.baked = baked
	world.add_child(geometry)
	markers_root = Node3D.new()
	world.add_child(markers_root)
	gizmo = Node3D.new()
	gizmo.set_script(load("res://gizmo.gd"))
	gizmo.camera = camera
	gizmo.visible = false
	world.add_child(gizmo)
	preview = Node3D.new()
	preview.set_script(load("res://preview.gd"))
	world.add_child(preview)
	preview.setup(self)

func _set_sun(towards: Vector3) -> void:
	# the light travels away from the sun
	var d := -towards.normalized()
	sun.global_transform = Transform3D(Basis.looking_at(d, Vector3.UP if abs(d.y) < 0.99 else Vector3.FORWARD), Vector3.ZERO)

# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	var ui := Control.new()
	ui_root = ui
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ui)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)

	# two rows: the project, the windows and the job status; then the layout, the edit tools and the preview
	var bars := VBoxContainer.new()
	root.add_child(_panel(bars))
	var bar := _scroll_row(bars)
	_button(bar, "Import map from LP/LP2...", func(): new_win.open()).tooltip_text = "A new map from one of Lost Planet 1's or Lost Planet 2's maps"
	_button(bar, "Open...", _on_open)
	_button(bar, "Save", save_project)
	_button(bar, "Save as...", _on_save_as)
	_button(bar, "Install to game", install_package).tooltip_text = "Save, export, and copy the package to the game's Maps folder"
	bar.add_child(VSeparator.new())
	_button(bar, "Browser (B)", toggle_browser).tooltip_text = "Floating window of prefabs and the level's pieces, with thumbnails"
	_button(bar, "Preview (P)", toggle_preview).tooltip_text = "Walk the map: a soldier-sized character with the game's camera (Esc back)"
	_button(bar, "Lighting (L)", toggle_lighting).tooltip_text = "The sun, sky light, sky dome and placed point / spot lights"
	_button(bar, "Map info (I)", toggle_info).tooltip_text = "Name, size, water and kill floor heights, physics rebuild"
	_button(bar, "Fog & weather (H)", toggle_fog).tooltip_text = "Distance fog, low-lying height fog, rain / snow / ash and no-weather boxes"
	_button(bar, "Place (T)", toggle_placer).tooltip_text = "Place spawn points, weapons, VS and volumes: click the map to put one down, drag to aim it (volumes: drag out the floor)"
	_button(bar, "Settings", toggle_settings).tooltip_text = "The game folders and the asset library folder"
	status = _label("No project open")
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.clip_text = true
	status.custom_minimum_size.x = 160
	bar.add_child(status)
	job_bar = ProgressBar.new()
	job_bar.custom_minimum_size = Vector2(220, 0)
	job_bar.max_value = 1.0
	job_bar.step = 0.001
	job_bar.visible = false
	bar.add_child(job_bar)
	bar = _scroll_row(bars)
	bar.add_child(_label("Layout"))
	for v in 4:
		var b := Button.new()
		b.text = str(v + 1)
		b.toggle_mode = true
		b.tooltip_text = "Show layout variant %d (the game's layout -%02d files)" % [v + 1, v]
		b.pressed.connect(set_variant.bind(v))
		bar.add_child(b)
		layout_buttons.append(b)
	set_pick = OptionButton.new()
	set_pick.custom_minimum_size.x = 280
	set_pick.tooltip_text = "Marker set within this layout, named by the game types it is exported for"
	set_pick.item_selected.connect(func(i): show_set(visible_sets[i]))
	bar.add_child(set_pick)
	set_types = MenuButton.new()
	set_types.text = "Game types"
	set_types.flat = false
	set_types.tooltip_text = "Which game types use the shown set. Each game type uses one set per layout; the LP1 mode 0 set takes every type no other set claims"
	set_types.about_to_popup.connect(_fill_set_types)
	set_types.get_popup().hide_on_checkable_item_selection = false
	set_types.get_popup().index_pressed.connect(_on_set_type)
	bar.add_child(set_types)
	bar.add_child(VSeparator.new())
	for m in [["Move (W)", 0], ["Rotate (E)", 1], ["Scale (R)", 2]]:
		var b := Button.new()
		b.text = m[0]
		b.toggle_mode = true
		b.pressed.connect(set_tool.bind(m[1]))
		bar.add_child(b)
		mode_buttons.append(b)
	snap_toggle = CheckButton.new()
	snap_toggle.text = "Snap"
	snap_toggle.tooltip_text = "Snap moves to 50 cm, turns to 15 degrees, scale to 0.1 (or hold Ctrl while dragging)"
	bar.add_child(snap_toggle)
	bar.add_child(VSeparator.new())
	baked_toggle = CheckButton.new()
	baked_toggle.text = "Baked light"
	baked_toggle.button_pressed = baked
	baked_toggle.toggled.connect(_on_baked)
	bar.add_child(baked_toggle)
	col_toggle = CheckButton.new()
	col_toggle.text = "View collision"
	col_toggle.tooltip_text = "Show what players walk on (the game's movement collision, with your geometry edits) as a green see-through mesh. Refreshes on Save"
	col_toggle.toggled.connect(_on_collision)
	bar.add_child(col_toggle)
	wire_toggle = CheckButton.new()
	wire_toggle.text = "Wireframe"
	wire_toggle.tooltip_text = "Draw the view as wireframe, with the triangles in view counted (density, detail baking)"
	wire_toggle.toggled.connect(_on_wireframe)
	bar.add_child(wire_toggle)
	bar.add_child(VSeparator.new())
	for t in [["volumes", ICON_VOLUMES, "Show volumes (kill, gravity, post-process, no-weather boxes)", true],
			["lights", ICON_LIGHTS, "Show light nodes", true],
			["fog", ICON_FOG, "Fog in the view (the Fog & weather window's distance and ground fog)", true],
			["post", ICON_POST, "Post-process in the view: the colour grade of the volume the camera is in", false]]:
		var b := Button.new()
		b.icon = _svg_icon(t[1])
		b.toggle_mode = true
		b.button_pressed = cfg.get_value("view", t[0], t[3])
		b.tooltip_text = t[2]
		b.toggled.connect(_on_view_toggle.bind(t[0]))
		bar.add_child(b)
		view_toggles[t[0]] = b
		if t[0] == "lights":   # quick add: a point or spot light where the view points
			var add := MenuButton.new()
			add.icon = _svg_icon(ICON_ADD_LIGHT)
			add.flat = false
			add.tooltip_text = "Add a light where the view points (set it up in Lighting, L)"
			add.get_popup().add_item("Point light", 0)
			add.get_popup().add_item("Spot light", 1)
			add.get_popup().id_pressed.connect(func(i):
				view_toggles["lights"].button_pressed = true   # a new light hidden by the toggle would look like nothing happened
				lighting.add_light("spot" if i == 1 else "point"))
			bar.add_child(add)
	bar.add_child(VSeparator.new())
	_button(bar, "Rebuild preview", func(): build_preview(true))
	if wire_on_start:
		wire_toggle.button_pressed = true
	set_tool(0)

	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(mid)

	var tabs := TabContainer.new()
	tabs.custom_minimum_size.x = 290
	var outl := VBoxContainer.new()
	outl.name = "Outliner"
	outliner = Tree.new()
	outliner.hide_root = true
	outliner.select_mode = Tree.SELECT_MULTI
	outliner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outliner.multi_selected.connect(_on_tree_selected)
	outliner.item_activated.connect(func(): frame_selected())
	outl.add_child(outliner)
	var orow := HBoxContainer.new()
	_button(orow, "Group", group_selected).tooltip_text = "Ctrl+G: join the selected pieces into one"
	_button(orow, "Ungroup", ungroup_selected).tooltip_text = "Ctrl+Shift+G: split a piece into its parts"
	_button(orow, "Restore deleted", restore_deleted).tooltip_text = "Bring back every deleted original piece"
	outl.add_child(orow)
	tabs.add_child(outl)
	mid.add_child(tabs)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(spacer)

	var rightscroll := ScrollContainer.new()
	rightscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rightscroll.custom_minimum_size.x = 316
	rightscroll.mouse_filter = Control.MOUSE_FILTER_IGNORE  # clicks below the panels reach the viewport
	var rightbox := VBoxContainer.new()
	rightbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rightbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 296
	insp_title = _label("Nothing selected")
	insp_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	right.add_child(insp_title)
	insp_name = LineEdit.new()
	insp_name.placeholder_text = "Piece name"
	insp_name.text_submitted.connect(func(_t): _on_rename())
	insp_name.focus_exited.connect(_on_rename)
	right.add_child(insp_name)
	insp_pos = _vec_row(right, "Position (cm)", -1e6, 1e6, 1.0, null)
	insp_rot = _vec_row(right, "Rotation (deg)", -360, 360, 0.5, null)
	insp_scale = _vec_row(right, "Scale", 0.01, 100, 0.01, "scale")
	var brow := HBoxContainer.new()
	_button(brow, "Drop to floor", drop_selected)
	_button(brow, "Frame (F)", frame_selected)
	right.add_child(brow)
	var brow2 := HBoxContainer.new()
	piece_buttons.append(_button(brow2, "Duplicate", duplicate_selected))
	piece_buttons.append(_button(brow2, "Delete", delete_selected))
	piece_buttons.append(_button(brow2, "Reset", reset_selected))
	piece_buttons[2].tooltip_text = "Put the selected pieces back where the map had them"
	right.add_child(brow2)
	mesh_col = CheckBox.new()
	mesh_col.text = "Collision from mesh"
	mesh_col.tooltip_text = "Replace the selected pieces' collision (walking and shots) with their visible triangles, wherever they are. For pieces whose imported collision is missing or doesn't match"
	mesh_col.toggled.connect(_on_mesh_col)
	right.add_child(mesh_col)
	var prow := HBoxContainer.new()
	prow.add_child(_label("Pickup"))
	pickup_pick = OptionButton.new()
	pickup_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for e in PICKUP_ITEMS:
		pickup_pick.add_item(e[1] if e[0] < 0 else "%s  [%02X]" % [e[1], e[0]])
	pickup_pick.tooltip_text = "Slot: the match settings and loadouts pick the weapon. Fixed: always this weapon. Stock pickup: whatever the base map's layout had at that index, a different item per game type (LP1 weapon names mean nothing in LP2). Applies to every selected pickup"
	pickup_pick.item_selected.connect(_on_pickup)
	prow.add_child(pickup_pick)
	pickup_row = prow
	right.add_child(prow)
	var trow := HBoxContainer.new()
	trow.add_child(_label("Tier"))
	tier_pick = OptionButton.new()
	tier_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for e in VS_TIERS:
		tier_pick.add_item(e[1])
	tier_pick.tooltip_text = "Which of the lobby's VS settings show this VS (None never shows any). Stock: the tier of the base map's record it replaces (effectively random for imported maps). Applies to every selected VS"
	tier_pick.item_selected.connect(_on_tier)
	trow.add_child(tier_pick)
	tier_row = trow
	right.add_child(trow)
	vs_props = VBoxContainer.new()
	vs_props.set_script(load("res://vsprops.gd"))
	right.add_child(vs_props)
	vs_props.setup(self)
	var dbox := VBoxContainer.new()
	var drow := HBoxContainer.new()
	dig_on = CheckBox.new()
	dig_on.text = "Buried: digs"
	dig_on.tooltip_text = "The pickup or VS starts under a \"dig here\" pile; players dig it up (this many digs). Applies to every selected pickup and VS"
	dig_on.toggled.connect(func(_b): _on_dig())
	drow.add_child(dig_on)
	dig_count = _spin(1, 200, 1)
	dig_count.value = 10
	dig_count.value_changed.connect(func(_v): _on_dig())
	drow.add_child(dig_count)
	dbox.add_child(drow)
	dig_pile = OptionButton.new()
	for t in DIG_PILES:
		dig_pile.add_item(t)
	dig_pile.tooltip_text = "Pile model (the stock maps that use it)"
	dig_pile.item_selected.connect(func(_i): _on_dig())
	dbox.add_child(dig_pile)
	dig_row = dbox
	right.add_child(dbox)
	var tbox := VBoxContainer.new()
	tbox.add_child(_label("On game types"))
	var tg := GridContainer.new()
	tg.columns = 2
	for t in GAME_TYPES:
		var c := CheckBox.new()
		c.text = t[1].split(" (")[0]
		c.tooltip_text = "In %s matches (if the set is used for them). Applies to every selected marker" % t[1]
		c.toggled.connect(func(_b): _on_marker_types())
		tg.add_child(c)
		type_checks.append(c)
	tbox.add_child(tg)
	type_exists = _label("")
	type_exists.autowrap_mode = TextServer.AUTOWRAP_WORD
	tbox.add_child(type_exists)
	type_box = tbox
	right.add_child(tbox)
	# Map info: a floating window (I), like the other tools
	info_win = Window.new()
	info_win.title = "Map info"
	info_win.size = Vector2i(360, 440)
	info_win.transient = true
	info_win.visible = false
	info_win.wrap_controls = true
	info_win.close_requested.connect(info_win.hide)
	var ibg := PanelContainer.new()
	ibg.set_anchors_preset(Control.PRESET_FULL_RECT)
	info_win.add_child(ibg)
	var iv := VBoxContainer.new()
	ibg.add_child(iv)
	add_child(info_win)
	info_name = LineEdit.new()
	info_name.placeholder_text = "Map name"
	info_name.text_changed.connect(func(t): if project: project["info"]["name"] = t)
	iv.add_child(info_name)
	info_size = OptionButton.new()
	for s in ["small", "medium", "large"]:
		info_size.add_item(s)
	info_size.item_selected.connect(func(i): if project: project["info"]["size"] = info_size.get_item_text(i))
	iv.add_child(info_size)
	var thumb_row := HBoxContainer.new()
	thumb_preview = TextureRect.new()
	thumb_preview.custom_minimum_size = Vector2(96, 96)
	thumb_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var circle := ShaderMaterial.new()
	circle.shader = Shader.new()
	circle.shader.code = """shader_type canvas_item;
uniform float zoom = 1.0;
void fragment() {
	vec2 d = UV - 0.5;
	COLOR = length(d) > 0.5 * 401.0 / 512.0 ? vec4(0.0) : texture(TEXTURE, 0.5 + d / zoom);
}"""
	thumb_preview.material = circle
	thumb_row.add_child(thumb_preview)
	var tcol := VBoxContainer.new()
	tcol.add_child(_label("Thumbnail (create match)"))
	var tb := HBoxContainer.new()
	_button(tb, "Capture view", capture_thumbnail).tooltip_text = "The 3D view as it is now becomes the map's picture in Create Match (a circle cut from the middle)"
	_button(tb, "Image...", func(): thumb_dialog.popup_centered_ratio(0.6)).tooltip_text = "Use a picture file (png / jpg)"
	_button(tb, "Clear", func(): _set_thumbnail(null))
	tcol.add_child(tb)
	var zr := HBoxContainer.new()
	zr.add_child(_label("Zoom"))
	thumb_zoom = _spin(1.0, 4.0, 0.05)
	thumb_zoom.tooltip_text = "How close the circle crops in (1 = the picture's full height)"
	thumb_zoom.value_changed.connect(func(v):
		if not updating_ui and project and project["info"].get("thumbnail") is Dictionary:
			project["info"]["thumbnail"]["zoom"] = v
			_show_thumbnail())
	zr.add_child(thumb_zoom)
	tcol.add_child(zr)
	thumb_row.add_child(tcol)
	iv.add_child(thumb_row)
	thumb_dialog = FileDialog.new()
	thumb_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	thumb_dialog.access = FileDialog.ACCESS_FILESYSTEM
	thumb_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Pictures"])
	thumb_dialog.title = "Map thumbnail picture"
	thumb_dialog.use_native_dialog = true
	thumb_dialog.file_selected.connect(_thumbnail_from_file)
	add_child(thumb_dialog)
	var wrow := HBoxContainer.new()
	water_on = CheckBox.new()
	water_on.text = "Water at (cm)"
	water_on.toggled.connect(func(_b): _on_water())
	wrow.add_child(water_on)
	water_height = _spin(-1e6, 1e6, 10.0)
	water_height.value_changed.connect(func(_v): _on_water())
	wrow.add_child(water_height)
	iv.add_child(wrow)
	var krow := HBoxContainer.new()
	kill_on = CheckBox.new()
	kill_on.text = "Kill floor at (cm)"
	kill_on.tooltip_text = "Players who fall below this height die: built into the map as the game's kill floor (a kill surface quad in the bullet collision under the whole map, like the stock maps)"
	kill_on.toggled.connect(func(_b): _on_kill())
	krow.add_child(kill_on)
	kill_height = _spin(-1e6, 1e6, 10.0)
	kill_height.value_changed.connect(func(_v): _on_kill())
	krow.add_child(kill_height)
	iv.add_child(krow)
	lowgrav_on = CheckBox.new()
	lowgrav_on.text = "Give players jump packs"
	lowgrav_on.tooltip_text = "NEOS's air boost: a short dash while airborne. Gravity stays the map's (Gravity x; NEOS is about 0.3). Needs the xlive mod"
	lowgrav_on.toggled.connect(func(_b): _on_gravity())
	iv.add_child(lowgrav_on)
	underwater_on = CheckBox.new()
	underwater_on.text = "Lighter under water"
	underwater_on.tooltip_text = "Players below the water level get lighter, as on the stock maps with water (needs Water set). Needs the xlive mod"
	underwater_on.toggled.connect(func(_b): _on_gravity())
	iv.add_child(underwater_on)
	var grow := HBoxContainer.new()
	grow.add_child(_label("Gravity x"))
	gravity_spin = _spin(0.01, 10.0, 0.01)
	gravity_spin.tooltip_text = "Multiplies gravity for players and physics objects (debris, ragdolls) on the whole map; 1 = normal. Gravity volumes multiply on top. Needs the xlive mod"
	gravity_spin.value_changed.connect(func(_v): _on_gravity())
	grow.add_child(gravity_spin)
	iv.add_child(grow)
	var vrow := HBoxContainer.new()
	vrow_add = vrow
	iv.add_child(vrow)
	physics_on = CheckBox.new()
	physics_on.text = "Rebuild physics on export"
	physics_on.tooltip_text = "Grenades, debris and ragdolls follow moved, hidden and placed pieces (a new physics tree is built; slower export). Off: physics keeps the map's original shape"
	physics_on.toggled.connect(_on_physics)
	iv.add_child(physics_on)
	rightbox.add_child(_panel(right))
	perf_panel = PanelContainer.new()
	var pv := VBoxContainer.new()
	pv.add_child(_label("Performance"))
	perf_grid = GridContainer.new()
	perf_grid.columns = 2
	pv.add_child(perf_grid)
	perf_panel.add_child(pv)
	perf_panel.visible = false
	rightbox.add_child(perf_panel)
	rightscroll.add_child(rightbox)
	mid.add_child(rightscroll)

	var bottom := VBoxContainer.new()
	var strip := HBoxContainer.new()
	perf_button = Button.new()
	perf_button.flat = true
	perf_button.text = "Memory: -"
	perf_button.tooltip_text = "Click for the performance stats"
	perf_button.pressed.connect(func(): perf_panel.visible = not perf_panel.visible; _update_stats())
	strip.add_child(perf_button)
	perf_bar = ProgressBar.new()
	perf_bar.custom_minimum_size = Vector2(200, 0)
	perf_bar.max_value = 1.5
	perf_bar.step = 0.001
	perf_bar.show_percentage = false
	perf_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	strip.add_child(perf_bar)
	bottom.add_child(strip)
	log_box = TextEdit.new()
	log_box.editable = false
	log_box.custom_minimum_size.y = 110
	bottom.add_child(log_box)
	root.add_child(_panel(bottom))

	open_dialog = FileDialog.new()
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.title = "Open a map"
	open_dialog.filters = PackedStringArray(["*.lpme ; LP2 map", "project.json ; Older map project folder"])
	open_dialog.file_selected.connect(_on_open_file)
	open_dialog.use_native_dialog = true
	add_child(open_dialog)
	save_as_dialog = FileDialog.new()
	save_as_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_as_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_as_dialog.title = "Save the map as"
	save_as_dialog.filters = PackedStringArray(["*.lpme ; LP2 map"])
	save_as_dialog.file_selected.connect(save_project_as)
	save_as_dialog.use_native_dialog = true
	add_child(save_as_dialog)
	thumbs = Node.new()
	thumbs.set_script(load("res://thumbs.gd"))
	add_child(thumbs)
	browser = Window.new()
	browser.set_script(load("res://browser.gd"))
	add_child(browser)
	browser.setup(self, thumbs)
	prefab_list = browser.prefab_list
	mesh_builder = Window.new()
	mesh_builder.set_script(load("res://meshbuilder.gd"))
	add_child(mesh_builder)
	mesh_builder.setup(self, thumbs)
	lighting = Window.new()
	lighting.set_script(load("res://lighting.gd"))
	add_child(lighting)
	lighting.setup(self)
	volumes = Node.new()
	volumes.set_script(load("res://volumes.gd"))
	add_child(volumes)
	volumes.setup(self, type_box.get_parent())
	volumes.add_menu(vrow_add)
	settings_win = Window.new()
	settings_win.set_script(load("res://settings.gd"))
	add_child(settings_win)
	settings_win.setup(self)
	updates = Node.new()
	updates.set_script(load("res://updates.gd"))
	add_child(updates)
	updates.setup(self)
	updates.call_deferred("check_on_start")
	new_win = Window.new()
	new_win.set_script(load("res://newmap.gd"))
	add_child(new_win)
	new_win.setup(self)
	fog_win = Window.new()
	fog_win.set_script(load("res://fog.gd"))
	add_child(fog_win)
	fog_win.setup(self)
	placer = Window.new()
	placer.set_script(load("res://place.gd"))
	add_child(placer)
	placer.setup(self)
	# Place is its own OS window: while it's open, the view takes the focus back as soon as the mouse is over it, so
	# the first click there places instead of only focusing the editor
	get_window().mouse_entered.connect(func(): if placer.visible and not get_window().has_focus(): get_window().grab_focus())
	for w: Window in [info_win, browser, mesh_builder, lighting, settings_win, new_win, fog_win, placer]:
		w.window_input.connect(_on_tool_window_input.bind(w))   # Ctrl+S saves from any of them too
	lighting_dialog = FileDialog.new()
	lighting_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	lighting_dialog.access = FileDialog.ACCESS_FILESYSTEM
	lighting_dialog.title = "A panorama sky image (equirectangular, 2:1)"
	lighting_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp, *.exr, *.hdr ; Images"])
	lighting_dialog.use_native_dialog = true
	lighting_dialog.file_selected.connect(func(f): lighting.set_panorama(f))
	add_child(lighting_dialog)
	_rebuild_outliner()
	_show_inspector()

func _vec_row(parent: Control, title: String, lo: float, hi: float, step: float, tag: Variant) -> Array:
	var box := VBoxContainer.new()
	box.add_child(_label(title))
	var row := HBoxContainer.new()
	var out: Array = []
	for axis in ["X", "Y", "Z"]:
		var s := _spin(lo, hi, step)
		s.custom_minimum_size.x = 90
		s.prefix = axis
		s.value_changed.connect(func(_v): _on_inspector())
		row.add_child(s)
		out.append(s)
	box.add_child(row)
	parent.add_child(box)
	if tag != null:
		insp_rows.append(box)
	return out

# a toolbar row that scrolls sideways when the window is too narrow for it
func _scroll_row(parent: Control) -> HBoxContainer:
	var sc := ScrollContainer.new()
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(sc)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(row)
	return row

func _panel(c: Control) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_child(c)
	return p

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _button(parent: Control, t: String, f: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(f)
	parent.add_child(b)
	return b

func _spin(lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size.x = 150
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s

func _send_mouse(at: Vector2, pressed: Variant, ctrl := false, shift := false) -> void:
	# pressed: true / false = a left button press / release, null = a move (button held)
	var ev: InputEventMouse
	if pressed == null:
		ev = InputEventMouseMotion.new()
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	else:
		ev = InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	Input.parse_input_event(ev)
	await get_tree().process_frame

func _input_test() -> void:
	var vols := func() -> int: return markers_root.get_children().filter(func(n): return n.has_meta("volume")).size()
	var mid := get_viewport().get_visible_rect().size / 2
	placer.popup()
	placer.kind_pick.select(3)
	placer._fill_items()
	placer.item_pick.select(0)
	await get_tree().create_timer(0.5).timeout
	var n0: int = vols.call()
	await _send_mouse(mid, true)
	for k in 5:
		await _send_mouse(mid + Vector2(40, 30) * (k + 1), null)
	await _send_mouse(mid + Vector2(200, 150), false)
	var v: Node3D = selection[0] if selection.size() == 1 and selection[0].has_meta("volume") else null
	print("input-test: drag-place: volumes ", n0, " -> ", vols.call(), ", size ", v.get_meta("data")["size"] if v else "none")
	if v == null:
		return
	set_tool(0)
	var g := camera.unproject_position(gizmo.global_position)
	var before: Vector3 = v.global_position
	await _send_mouse(g, true)
	var grabbed: bool = gizmo.dragging()
	for k in 4:
		await _send_mouse(g + Vector2(15, 0) * (k + 1), null)
	await _send_mouse(g + Vector2(60, 0), false)
	print("input-test: gizmo over Place: grabbed ", grabbed, ", moved ", (v.global_position - before).length() > 0.01, ", volumes ", vols.call())
	set_tool(2)
	await get_tree().process_frame
	var size0: Array = (v.get_meta("data")["size"] as Array).duplicate()
	var x_tip := camera.unproject_position(gizmo.global_position + Vector3.RIGHT * gizmo._size() * 0.9)
	await _send_mouse(x_tip, true)
	grabbed = gizmo.dragging()
	for k in 4:
		await _send_mouse(x_tip + (x_tip - g).normalized() * 20.0 * (k + 1), null)
	await _send_mouse(x_tip + (x_tip - g).normalized() * 80.0, false)
	print("input-test: scale X: grabbed ", grabbed, ", size ", size0, " -> ", v.get_meta("data")["size"], ", volumes ", vols.call())
	set_tool(1)
	await get_tree().process_frame
	print("input-test: rotate rings shown for a volume: ", gizmo._parts.filter(func(p): return p.visible).size())
	set_tool(0)
	var vs: Array = v.get_meta("data")["size"]   # a point on the top face away from the gizmo's arrows
	var top := camera.unproject_position(v.global_position + Vector3(float(vs[0]) * 0.3, float(vs[1]), float(vs[2]) * 0.3) * CM)
	var hit: Dictionary = volumes.face_hit(top)
	await _send_mouse(top, true, true)
	var pressed_face := not face_press.is_empty()
	for k in 3:
		await _send_mouse(top + Vector2(0, -15) * (k + 1), null, true)
	await _send_mouse(top + Vector2(0, -45), false, true)
	print("input-test: Ctrl+face over Place: face ", hit.get("axis", -1), ", pressed ", pressed_face, ", size ", v.get_meta("data")["size"], ", volumes ", vols.call())
	placer.hide()
	select([v])
	set_tool(1)
	await get_tree().process_frame
	var go := gizmo.global_position
	var gs: float = gizmo._size()
	var r0 := camera.unproject_position(go + Vector3.BACK * gs)
	var rings: int = gizmo._parts.filter(func(p): return p.visible).size()
	var grab: int = gizmo.hit(r0)
	await _send_mouse(r0, true)
	for k in range(1, 6):
		var ang := deg_to_rad(9.0 * k)
		await _send_mouse(camera.unproject_position(go + (Vector3.BACK * cos(ang) + Vector3.RIGHT * sin(ang)) * gs), null)
	await _send_mouse(camera.unproject_position(go + (Vector3.BACK * cos(PI / 4) + Vector3.RIGHT * sin(PI / 4)) * gs), false)
	var vd: Dictionary = v.get_meta("data")
	var vsz: Array = vd["size"]
	# a point just inside the turned box's +x end, which the unturned box wouldn't hold
	var edge: Vector3 = v.global_transform * (Vector3(float(vsz[0]) * 0.49, float(vsz[1]) * 0.5, 0.0) * CM)
	print("input-test: volume rotate: rings ", rings, ", grabbed ring ", grab, ", yaw ", vd.get("yaw"), ", inside at the turned end ",
		volumes.contains(v, edge), ", outside past it ", volumes.contains(v, v.global_transform * (Vector3(float(vsz[0]) * 0.52, float(vsz[1]) * 0.5, 0.0) * CM)))
	set_tool(0)
	# Ctrl+Shift+drag the turned box's +x end face: a new box grows out of it
	var face_at: Vector3 = v.global_transform * (Vector3(float(vsz[0]) * 0.5, float(vsz[1]) * 0.5, float(vsz[2]) * 0.25) * CM)
	camera.global_position = face_at + (v.global_transform.basis.x * 12.0 + Vector3(0, 4, 0)) + v.global_transform.basis.z * 6.0
	camera.look_at(face_at)
	await get_tree().process_frame
	var fp := camera.unproject_position(face_at)
	var fh: Dictionary = volumes.face_hit(fp)
	var out_dir := camera.unproject_position(face_at + v.global_transform.basis.x * 1.0) - fp
	await _send_mouse(fp, true, true, true)
	for k in range(1, 6):
		await _send_mouse(fp + out_dir.normalized() * 20.0 * k, null, true, true)
	await _send_mouse(fp + out_dir.normalized() * 100.0, false, true, true)
	var past: Vector3 = v.global_transform * (Vector3(float(vsz[0]) * 0.5 + 50.0, float(vsz[1]) * 0.5, float(vsz[2]) * 0.25) * CM)
	print("input-test: extrude: face box ", fh.get("box", -1), " axis ", fh.get("axis", -1), ", boxes ", vd.get("boxes", []),
		", main size ", vd["size"], ", inside past the old end ", volumes.contains(v, past))
	select([v])
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(screenshot_path.get_basename() + "-extrude.png")
	# Ctrl+Shift+right click on the main box: it goes, the extruded box becomes the volume
	var box_mid: Vector3 = v.global_transform * (Vector3(0, float(vsz[1]) * 0.5, 0) * CM)
	camera.global_position = box_mid + Vector3(0, 25, 0.5)
	camera.look_at(box_mid)
	await get_tree().process_frame
	var rp := camera.unproject_position(box_mid + Vector3(0, float(vsz[1]) * 0.5 * CM, 0))
	var hb: int = volumes.face_hit(rp).get("box", -1)
	for down in [true, false]:
		var rb := InputEventMouseButton.new()
		rb.button_index = MOUSE_BUTTON_RIGHT
		rb.pressed = down
		rb.position = rp
		rb.global_position = rp
		rb.ctrl_pressed = true
		rb.shift_pressed = true
		Input.parse_input_event(rb)
		await get_tree().process_frame
	print("input-test: delete box: clicked box ", hb, ", boxes left ", vd.get("boxes", []).size(), ", size ", vd["size"],
		", old centre inside ", volumes.contains(v, box_mid), ", extruded part inside ", volumes.contains(v, past), ", looking ", camera.is_looking())
	var mk: Array = markers_root.get_children().filter(func(n): return _is_marker(n) and not n.has_meta("volume"))
	if not mk.is_empty():
		var m: Node3D = mk[0]
		camera.global_position = m.global_position + Vector3(0, 6, 8)
		camera.look_at(m.global_position)
		select([m])
		set_tool(1)
		await get_tree().process_frame
		await get_tree().process_frame
		var ring := camera.unproject_position(gizmo.global_position + Vector3(0, 0, 1) * gizmo._size())
		print("input-test: marker rotate: gizmo visible ", gizmo.visible, ", rings ", gizmo._parts.filter(func(p): return p.visible).size(),
			", parts ", gizmo._parts.size(), ", hit on ring ", gizmo.hit(ring), ", gizmo at ", gizmo.global_position, " marker at ", m.global_position)

func log_line(t: String) -> void:
	log_box.text += t + "\n"
	log_box.scroll_vertical = log_box.get_line_count()

func set_status(t: String) -> void:
	status.text = t

func set_tool(m: int) -> void:
	for i in mode_buttons.size():
		mode_buttons[i].button_pressed = i == m
	gizmo.set_mode(m)
	_gizmo_limits()

# ---------------------------------------------------------------- project I/O

func _on_open() -> void:
	open_dialog.popup_centered_ratio(0.6)

func _on_open_file(path: String) -> void:
	if path.get_extension().to_lower() == "lpme":
		open_map_file(path)
	else:
		open_project(path.get_base_dir())

func open_map_file(path: String) -> void:
	# a .lpme: unpacked into its workspace (Lpme), which is then the open project
	var ws: String = Lpme.unpack(path)
	if ws == "":
		log_line("Not an LP2 map file (or it can't be read): " + path)
		return
	open_project(ws)
	if project_dir != ws:
		return
	project_file = path
	if screenshot_path == "":
		cfg.set_value("recent", "project", path)
		cfg.save(SETTINGS)
	DisplayServer.window_set_title("LP2 Map Editor - %s" % path.get_file())

func _pack() -> void:
	# the workspace into the .lpme, off the main thread; a save during a pack packs again after it
	if project_file == "":
		return
	if packing:
		pack_again = true
		return
	packing = true
	var ws := project_dir
	var file := project_file
	WorkerThreadPool.add_task(func(): call_deferred("_packed", Lpme.pack(ws, file), file))

func _packed(err: Error, file: String) -> void:
	packing = false
	if err != OK:
		log_line("SAVE FAILED: can't write %s (%s)" % [file, error_string(err)])
		set_status("Save failed")
	elif pack_again:
		pack_again = false
		_pack()
	else:
		set_status("Saved " + file.get_file())

# ---------------------------------------------------------------- paths and settings

func bundle_dir() -> String:
	# the release's folder (lp2-mapedit.exe / the AppImage's inside), "" when run from the Godot editor or run.sh
	if OS.has_feature("editor"):
		return ""
	var d := OS.get_executable_path().get_base_dir()
	return d if FileAccess.file_exists(d.path_join("tools/runtool.py")) else ""

func _home(p: String) -> String:
	var home := OS.get_environment("USERPROFILE" if OS.has_feature("windows") else "HOME")
	return home + p.substr(1) if p.begins_with("~") else p

func is_lp2_folder(d: String) -> bool:
	return d != "" and FileAccess.file_exists(d.path_join("LP2DX9.exe"))

func _steam_game(folder: String) -> String:
	# the game's folder in any Steam library (steamapps/libraryfolders.vdf), or ""
	var roots: Array = []
	if OS.has_feature("windows"):
		roots = ["C:/Program Files (x86)/Steam", "C:/Program Files/Steam"]
	else:
		roots = [_home("~/.local/share/Steam"), _home("~/.steam/steam"), _home("~/.var/app/com.valvesoftware.Steam/.local/share/Steam")]
	var libs: Array = []
	for r in roots:
		libs.append(r)
		var vdf := FileAccess.get_file_as_string(r.path_join("steamapps/libraryfolders.vdf"))
		var re := RegEx.create_from_string('"path"\\s+"([^"]+)"')
		for m in re.search_all(vdf):
			libs.append(m.get_string(1).replace("\\\\", "/"))
	for l in libs:
		var d: String = l.path_join("steamapps/common").path_join(folder)
		if DirAccess.dir_exists_absolute(d):
			return d
	return ""

func maps_dir() -> String:
	# where new map projects go by default
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join("LP2 Maps")

func toggle_settings() -> void:
	settings_win.open(false)

func set_paths(g: String, lp1: String, lib: String) -> void:
	var first := not FileAccess.file_exists(library_dir.path_join("index.json")) or lib != library_dir
	game = g
	lp1_dir = lp1
	library_dir = lib
	cfg.set_value("paths", "game", game)
	cfg.set_value("paths", "lp1", lp1_dir)
	cfg.set_value("paths", "library", library_dir)
	cfg.save(SETTINGS)
	log_line("Lost Planet 2: %s%s" % [game, ("; Lost Planet 1: " + lp1_dir) if lp1_dir != "" else ""])
	if first and library.load_index(library_dir) == 0:
		get_assets()

func import_lp1_map(arc: String, file: String, name: String) -> void:
	# a new .lpme from an LP1 map: imported into the file's workspace, packed, opened
	var ws: String = Lpme.workspace(file)
	DirAccess.make_dir_recursive_absolute(ws)
	Lpme.clear(ws, false)
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	set_status("Importing %s..." % arc.get_file())
	log_line("New map: %s -> %s" % [arc, file])
	run_tool("lp2project.py", ["import-lp1", arc, ws, "--name", name, "--game", game], func(): _imported(ws, file))

func import_lp2_map(stock: int, file: String, name: String) -> void:
	# a new .lpme from one of LP2's online maps: its own stage, collision and layout (lp2project.py import-lp2)
	var ws: String = Lpme.workspace(file)
	DirAccess.make_dir_recursive_absolute(ws)
	Lpme.clear(ws, false)
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	set_status("Importing online map %02d..." % stock)
	log_line("New map: Lost Planet 2 online %02d -> %s" % [stock, file])
	run_tool("lp2project.py", ["import-lp2", str(stock), ws, "--name", name, "--game", game, "--library", library_dir], func(): _imported(ws, file))

func _imported(ws: String, file: String) -> void:
	var err: Error = Lpme.pack(ws, file)
	if err != OK:
		log_line("Import: can't write %s (%s)" % [file, error_string(err)])
		return
	open_map_file(file)

func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())

func _ints(v: Variant, key := "") -> Variant:
	# JSON numbers come back as floats; whole numbers outside positions / angles go back to ints
	if v is Dictionary:
		for k in v.keys():
			v[k] = _ints(v[k], k)
	elif v is Array and key not in ["pos", "yaw", "sun", "tint", "sky", "bloom", "R", "G", "B", "cam", "tgt", "at"]:
		for i in v.size():
			v[i] = _ints(v[i], key)
	elif v is float and key not in ["pos", "yaw", "zoom", "water", "kill_floor", "light_scale"] and v == floor(v) and abs(v) < 1e15:
		return int(v)
	return v

func geometry_path() -> String:
	var g: Dictionary = project.get("geometry", {"file": "geometry.json"})
	return project_dir.path_join(g.get("file", "geometry.json"))

func open_project(dir: String) -> void:
	var p: Variant = _read_json(dir.path_join("project.json"))
	if not (p is Dictionary) or p.get("format", "") != "lp2map":
		log_line("Not a map project (no lp2map project.json): " + dir)
		return
	project_dir = dir
	project_file = ""
	project = _ints(p)
	library.load_imports(dir)
	var lay: Variant = _read_json(dir.path_join(project["layout"]["file"]))
	layout = _ints(lay) if lay is Dictionary else {"sets": []}
	if screenshot_path == "":   # test runs (--screenshot) don't become the project the editor reopens
		cfg.set_value("recent", "project", dir)
		cfg.save(SETTINGS)
	updating_ui = true
	info_name.text = project["info"].get("name", "")
	_show_thumbnail()
	for i in info_size.item_count:
		if info_size.get_item_text(i) == project["info"].get("size", "large"):
			info_size.select(i)
	var env: Dictionary = project.get("environment", {})
	water_on.button_pressed = env.get("water") != null
	water_height.value = float(env.get("water")) if env.get("water") != null else 0.0
	kill_on.button_pressed = env.get("kill_floor") != null
	kill_height.value = float(env.get("kill_floor")) if env.get("kill_floor") != null else -5000.0
	physics_on.button_pressed = project.get("collision", {}).get("rebuild_physics", false)
	if env.get("low_gravity", false):   # older projects: NEOS's low gravity = jump packs + gravity x0.3
		env["jump_packs"] = true
		env["gravity"] = snappedf(float(env.get("gravity", 1.0)) * 0.3, 0.001)
		env.erase("low_gravity")
	lowgrav_on.button_pressed = env.get("jump_packs", false)
	underwater_on.button_pressed = env.get("underwater", false)
	gravity_spin.value = float(env.get("gravity", 1.0))
	updating_ui = false
	_show_kill()
	lighting.presets = {}
	lighting.apply_preview()
	fog_win.refresh()
	DisplayServer.window_set_title("LP2 Map Editor - %s" % project["info"].get("name", dir))
	log_line("Opened %s (%d marker sets)" % [dir, layout["sets"].size()])
	col_toggle.set_pressed_no_signal(false)
	if col_mesh:
		col_mesh.visible = false
	col_key = ""
	undo_stack = []
	redo_stack = []
	set_variant(0)
	saved_state = _saved_state()
	opening = true
	build_preview(false)
	if mesh_builder.visible:
		mesh_builder.refresh()
	if lighting.visible:
		lighting.refresh()

func _on_tool_window_input(e: InputEvent, w: Window) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.ctrl_pressed and e.keycode == KEY_S:
		save_project()
		w.set_input_as_handled()

func save_project() -> void:
	if project_dir == "":
		return
	if geometry.get_child_count():
		if not project.has("geometry"):
			project["geometry"] = {"file": "geometry.json"}
		var g := FileAccess.open(geometry_path(), FileAccess.WRITE)
		g.store_string(JSON.stringify(geometry.to_json(), " "))
		g.close()
	for w in [["project.json", project], [project["layout"]["file"], layout]]:
		var f := FileAccess.open(project_dir.path_join(w[0]), FileAccess.WRITE)
		if f == null:
			log_line("SAVE FAILED: can't write %s (%s)" % [w[0], error_string(FileAccess.get_open_error())])
			set_status("Save failed")
			return
		f.store_string(JSON.stringify(w[1], " "))
		f.close()
	saved_state = _saved_state()
	log_line("Saved project.json, %s and the level geometry%s" % [project["layout"]["file"],
		" into " + project_file if project_file != "" else ""])
	if col_toggle.button_pressed:
		_on_collision(true)
	set_status("Saving..." if project_file != "" else "Saved")
	_pack()

func _on_save_as() -> void:
	if project_dir != "":
		var from := project_file if project_file != "" else project_dir.simplify_path()
		save_as_dialog.current_dir = from.get_base_dir()
		save_as_dialog.current_file = from.get_file().get_basename() + "_copy.lpme"
		save_as_dialog.popup_centered_ratio(0.6)

func _copy_tree(from: String, to: String) -> void:
	# the project's files (assets, the stage preview) into the new folder; build/ (the old package) is left out
	DirAccess.make_dir_recursive_absolute(to)
	var d := DirAccess.open(from)
	d.include_hidden = true
	for f in d.get_files():
		if not (from == project_dir and f == ".lpme"):   # the workspace's stamp
			DirAccess.copy_absolute(from.path_join(f), to.path_join(f))
	for sub in d.get_directories():
		if not (from == project_dir and sub == "build"):
			_copy_tree(from.path_join(sub), to.path_join(sub))

func save_project_as(path: String) -> void:
	# the map as a new .lpme (its own workspace, a copy of this one), which then becomes the open map. It gets its own
	# tag (the package's resource folder, unique per package) so installing it doesn't replace the original map
	if project_dir == "":
		return
	if path.get_extension().to_lower() != "lpme":
		path += ".lpme"
	if path.simplify_path() == project_file.simplify_path():
		save_project()
		return
	var ws: String = Lpme.workspace(path)
	if ws.simplify_path() != project_dir.simplify_path():
		Lpme.clear(ws, false)
		_copy_tree(project_dir, ws)
	var stem := ""
	for c in path.get_file().get_basename().to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			stem += c
	project["info"]["tag"] = (stem + "map___").substr(0, 6) + "%02x" % (randi() % 256)
	var old := project_file if project_file != "" else project_dir
	project_dir = ws
	project_file = path
	library.load_imports(ws)
	cfg.set_value("recent", "project", path)
	cfg.save(SETTINGS)
	save_project()
	DisplayServer.window_set_title("LP2 Map Editor - %s" % path.get_file())
	log_line("Saved as %s (copied from %s; package tag %s)" % [path, old, project["info"]["tag"]])

func _on_water() -> void:
	if updating_ui or project.is_empty():
		return
	project["environment"]["water"] = water_height.value if water_on.button_pressed else null

func _on_physics(b: bool) -> void:
	if not updating_ui and project.has("collision"):
		project["collision"]["rebuild_physics"] = b

# ---------------------------------------------------------------- thumbnail

func capture_thumbnail() -> void:
	# a square render from the current camera in an off-screen viewport (no panels in it), saved as thumbnail.png
	if project_dir == "":
		return
	var sv := SubViewport.new()
	sv.size = Vector2i(1024, 1024)
	sv.world_3d = get_viewport().world_3d
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	var cam := Camera3D.new()
	cam.global_transform = camera.global_transform
	cam.fov = camera.fov
	cam.near = camera.near
	cam.far = camera.far
	cam.environment = camera.environment
	sv.add_child(cam)
	add_child(sv)
	cam.make_current()
	# as the game shows it: no markers, volumes, gizmo, kill sheet, collision view or selection
	var keep_sel := selection.duplicate()
	select([])
	var hide: Array = [markers_root, gizmo, preview, kill_plane, col_mesh] + world.find_children("wall_*", "", true, false)
	var shown: Array = hide.filter(func(n): return n != null and is_instance_valid(n) and n.visible)
	for n in shown:
		n.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := sv.get_texture().get_image()
	sv.queue_free()
	for n in shown:
		n.visible = true
	select(keep_sel)
	img.save_png(project_dir.path_join("thumbnail.png"))
	_set_thumbnail({"image": "thumbnail.png", "zoom": 1.0, "at": [0.5, 0.5]})
	log_line("Thumbnail captured from the view (thumbnail.png); it goes into the map on the next Install / Export.")

func _thumbnail_from_file(path: String) -> void:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		log_line("Thumbnail: can't read " + path)
		return
	img.save_png(project_dir.path_join("thumbnail.png"))   # a copy in the project, so it travels with it
	_set_thumbnail({"image": "thumbnail.png", "zoom": 1.0, "at": [0.5, 0.5]})
	log_line("Thumbnail set from " + path.get_file())

func _set_thumbnail(t: Variant) -> void:
	if project.is_empty():
		return
	_push_undo("")
	project["info"]["thumbnail"] = t
	_show_thumbnail()

func _show_thumbnail() -> void:
	var t: Variant = project.get("info", {}).get("thumbnail") if not project.is_empty() else null
	var tex: Texture2D = null
	if t is Dictionary:
		var img := Image.load_from_file(project_dir.path_join(String(t.get("image", ""))))
		if img and not img.is_empty():
			var side := mini(img.get_width(), img.get_height())   # the square the circle sits in
			var at: Array = t.get("at", [0.5, 0.5])
			var x := clampi(int(float(at[0]) * img.get_width() - side / 2.0), 0, img.get_width() - side)
			var y := clampi(int(float(at[1]) * img.get_height() - side / 2.0), 0, img.get_height() - side)
			tex = ImageTexture.create_from_image(img.get_region(Rect2i(x, y, side, side)))
	thumb_preview.texture = tex
	var z := float(t.get("zoom", 1.0)) if t is Dictionary else 1.0
	(thumb_preview.material as ShaderMaterial).set_shader_parameter("zoom", z)
	var was := updating_ui   # open_project calls this mid-load: keep its guard up
	updating_ui = true
	thumb_zoom.value = z
	thumb_zoom.editable = t is Dictionary
	updating_ui = was

func _on_gravity() -> void:
	if updating_ui or project.is_empty():
		return
	if not project.has("environment"):
		project["environment"] = {}
	var env: Dictionary = project["environment"]
	for k in [["jump_packs", lowgrav_on.button_pressed], ["underwater", underwater_on.button_pressed]]:
		if k[1]:
			env[k[0]] = true
		else:
			env.erase(k[0])
	if gravity_spin.value != 1.0:
		env["gravity"] = gravity_spin.value
	else:
		env.erase("gravity")

func _on_kill() -> void:
	if updating_ui or project.is_empty():
		return
	if not project.has("environment"):
		project["environment"] = {}
	project["environment"]["kill_floor"] = kill_height.value if kill_on.button_pressed else null
	_show_kill()

func _show_kill() -> void:
	# a red sheet over the level's extent at the kill height
	if kill_plane == null:
		kill_plane = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(1, 1)
		kill_plane.mesh = pm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.albedo_color = Color(0.9, 0.1, 0.1, 0.25)
		kill_plane.material_override = m
		kill_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(kill_plane)
	kill_plane.visible = kill_on.button_pressed and not project.is_empty()
	var box := AABB(Vector3(-200, 0, -200), Vector3(400, 0, 400))
	var ps: Array = geometry.pieces()
	for i in ps.size():
		box = geometry.world_box(ps[i]) if i == 0 else box.merge(geometry.world_box(ps[i]))
	var c := box.get_center()
	kill_plane.transform = Transform3D(Basis.from_scale(Vector3(box.size.x + 100, 1, box.size.z + 100)), Vector3(c.x, kill_height.value * CM, c.z))

# ---------------------------------------------------------------- python tools (background, with progress)

func run_tool(script: String, args: Array, done: Callable) -> void:
	if busy:
		job_queue.append([script, args, done])
		return
	busy = true
	job_bar.value = 0.0
	job_bar.visible = true
	var t := Thread.new()
	t.start(func():
		# runtool.py: the script with its stderr on stdout (one pipe to read), unbuffered, paths as UTF-8
		var p := OS.execute_with_pipe(python, ["-u", "-X", "utf8", tools.path_join("runtool.py"), tools.path_join(script)] + args)
		var lines: Array = []
		var code := -1
		if p.is_empty():
			lines.append("could not start " + python)
		else:
			var io: FileAccess = p["stdio"]
			while true:
				var l := io.get_line()
				if l == "" and io.get_error() != OK:
					break
				if l.begins_with("@progress "):
					call_deferred("_progress", l.substr(10))
				elif l != "" and not l.begins_with("@result "):
					lines.append(l)
			while OS.is_process_running(p["pid"]):
				OS.delay_msec(20)
			code = OS.get_process_exit_code(p["pid"])
		call_deferred("_tool_done", t, script, code, "\n".join(lines), done))

func _progress(s: String) -> void:
	var f := s.get_slice(" ", 0)
	job_bar.value = float(f)
	var text := s.substr(f.length() + 1)
	if text != "":
		set_status("%s  %d%%" % [text, int(float(f) * 100)])

func _tool_done(t: Thread, script: String, code: int, out: String, done: Callable) -> void:
	t.wait_to_finish()
	busy = false
	job_bar.visible = false
	for l in out.strip_edges().split("\n"):
		if l != "":
			log_line("  " + l)
	if code != 0:
		log_line("%s failed (exit %d)" % [script, code])
		set_status(script + " failed")
	else:
		done.call()
	if not busy and not job_queue.is_empty():
		var j: Array = job_queue.pop_front()
		run_tool(j[0], j[1], j[2])

func build_preview(force: bool) -> void:
	if project_dir == "":
		return
	if force:
		DirAccess.remove_absolute(project_dir.path_join(".preview/stage.key"))
		if lighting.bake_settings().get("source", "lp1") == "bake":
			save_project()   # lp2preview.py re-bakes from the project on disk
			log_line("Saved first: the rebuilt preview is re-baked with the current lighting settings")
	set_status("Building the stage preview...")
	run_tool("lp2preview.py", ["--game", game, project_dir], load_stage)

func export_path() -> String:
	return project_dir.path_join("build").path_join(project["info"].get("tag", "map").strip_edges() + ".zip")

func export_package(then: Callable = Callable()) -> void:
	# saves first: the package is built from the files on disk
	if project_dir == "":
		return
	save_project()
	DirAccess.make_dir_recursive_absolute(project_dir.path_join("build"))
	set_status("Compiling the map package...")
	log_line("Export -> " + export_path())
	run_tool("lp2mapc.py", ["--game", game, "--library", library_dir, project_dir, export_path()], func():
		set_status("Exported " + export_path())
		if then.is_valid():
			then.call())

func _game_running() -> bool:
	if OS.has_feature("windows"):
		var out: Array = []
		OS.execute("tasklist", ["/NH", "/FO", "CSV"], out)
		var t: String = "".join(out).to_lower()
		return t.contains("\"lp2dx9.exe\"") or t.contains("\"lp2dx11.exe\"")
	return OS.execute("pgrep", ["-f", "LP2DX(9|11)\\.exe"], []) == 0

func install_package() -> void:
	# save, export, then copy the fresh package into the game's Maps folder
	if project_dir == "":
		return
	if _game_running():
		log_line("Lost Planet 2 is running: close it, then install.")
		return
	export_package(_copy_to_game)

func _copy_to_game() -> void:
	if _game_running():
		log_line("Lost Planet 2 started during the export: close it, then Install again.")
		return
	var name: String = project["info"].get("name", "map").replace(" ", "")
	var dst := game.path_join("Maps").path_join(name + ".zip")
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var err := DirAccess.copy_absolute(export_path(), dst)
	log_line(("Installed -> " + dst) if err == OK else "Install failed (%d)" % err)
	set_status("Installed to the game" if err == OK else "Install failed")

# ---------------------------------------------------------------- stage

func load_stage(frame := true) -> void:
	select([])
	var t0 := Time.get_ticks_msec()
	var err: String = geometry.load_preview(project_dir.path_join(".preview"), geometry_path())
	if err != "":
		log_line(err + ": rebuild the preview")
		return
	log_line("Level geometry: %d pieces (%.1f s)" % [geometry.get_child_count(), (Time.get_ticks_msec() - t0) / 1000.0])
	if opening:
		saved_state = _saved_state()
		opening = false
	lighting.preview_bake()   # the new materials get the bake's live settings
	_rebuild_prefabs()
	_rebuild_outliner()
	_update_stats()
	_show_kill()
	set_status("%s: stage loaded" % project["info"].get("name", ""))
	if frame:   # not after a bake: the view stays where it was
		frame_markers()
	if piece_on_start >= 0 and piece_on_start < geometry.get_child_count():
		var p: Node3D = geometry.get_child(piece_on_start)
		p.position.y += lift_on_start
		select([p])
		frame_selected()
	if OS.get_cmdline_user_args().has("--selftest"):
		_selftest()
	if screenshot_path != "":
		_screenshot()

func _selftest() -> void:
	# the editing paths without a mouse (tests): move, duplicate, group, ungroup, delete, prefab, undo / redo
	var g := geometry
	var p: Node3D = g.get_child(8)
	select([p])
	_push_undo("")
	p.position.y += 10.0
	duplicate_selected()
	select([g.get_child(9), g.get_child(10)])
	group_selected()
	select([g.get_child(3)])
	ungroup_selected()
	select([g.get_child(12)])
	delete_selected()
	select([g.get_child(8)])
	make_prefab()
	prefab_list.select(0)
	place_prefab(0)
	var n := g.get_child_count()
	undo()
	log_line("selftest: undo %d -> %d pieces" % [n, g.get_child_count()])
	redo()
	log_line("selftest: redo -> %d pieces, %s" % [g.get_child_count(), str(g.stats())])
	for a in library.assets:   # a piece of another map (the first library map's second piece)
		if a.has("map") and library.map_geometry(a["key"]):
			place_map_piece(a["key"], 1)
			log_line("selftest: placed %s piece 1 -> %s" % [a["key"], geometry.label(selection[0])])
			break
	if library.map_geometry("lp2_props"):   # an LP2 object (the props map)
		place_map_piece("lp2_props", 0)
		print("selftest: placed lp2_props piece 0 -> ", geometry.label(selection[0]))
	var imps: Array = library.imports()
	if imps.size():   # an imported mesh, then as if it were rebuilt
		place_map_piece(imps[0]["key"], 0)
		var before: int = geometry.members_of(selection[0].get_meta("tree")).size()
		library.forget_map(imps[0]["key"])
		geometry.refresh_import(imps[0]["map"])
		print("selftest: placed import %s -> %s; refreshed: %d -> %d members, %d placed" % [imps[0]["name"],
			geometry.label(selection[0]), before, geometry.members_of(selection[0].get_meta("tree")).size(),
			geometry.placed_from(imps[0]["map"]).size()])
	print("selftest ", g.get_child_count(), " ", g.stats())
	perf_panel.visible = true
	_update_stats()
	select([g.get_child(8)])
	frame_selected()

func frame_markers() -> void:
	# view the play area: the shown markers' bounds (else the stage's)
	var n := markers_root.get_child_count()
	var box := AABB()
	if n:
		box = AABB(markers_root.get_child(0).global_position, Vector3.ZERO)
		for c in markers_root.get_children():
			box = box.expand(c.global_position)
	elif geometry.get_child_count():
		box = geometry.world_box(geometry.get_child(0))
	var r: float = max(box.size.length() * 0.6, 20.0)
	camera.look_at_point(box.get_center(), box.get_center() + Vector3(r * 0.5, r * 0.6, r * 0.6))
	if select_on_start >= 0 and select_on_start < n:
		select([markers_root.get_child(select_on_start)])
		frame_selected()

func _test_collision() -> void:
	await get_tree().create_timer(1.0).timeout
	col_toggle.button_pressed = true

func _on_collision(on: bool) -> void:
	if col_mesh:
		col_mesh.visible = on
	if not on or project_dir == "":
		return
	# the current (maybe unsaved) geometry edits, as the export would apply them
	var g := project_dir.path_join(".preview/colview-geo.json")
	var f := FileAccess.open(g, FileAccess.WRITE)
	var gj: Dictionary = geometry.to_json() if geometry.get_child_count() else {}
	f.store_string(JSON.stringify(gj))
	f.close()
	col_pieces = {}
	var tree: Array = gj.get("tree", [])
	for i in tree.size():
		_index_tree(tree[i], i)
	var out := project_dir.path_join(".preview/collision.bin")
	var key := _collision_key(JSON.stringify(gj))
	if key == col_key and col_mesh:
		return   # unchanged: the view already shows it
	var kf := project_dir.path_join(".preview/collision.key")
	if FileAccess.file_exists(out) and FileAccess.get_file_as_string(kf) == key:
		col_key = key
		_load_collision(out)   # built before (an earlier session or toggle) from the same inputs
		return
	set_status("Building the collision view...")
	run_tool("lp2colview.py", [project_dir, out, "--library", library_dir, "--geometry", g], func():
		var kw := FileAccess.open(kf, FileAccess.WRITE)
		kw.store_string(key)
		kw.close()
		col_key = key
		_load_collision(out))

func _collision_key(geo: String) -> String:
	# what the view depends on: the geometry edits, the project's collision files, the built stage (its preview key)
	# and the tools that build it (by modification time)
	var parts := [geo, JSON.stringify(project.get("collision", {})),
		FileAccess.get_file_as_string(project_dir.path_join(".preview/stage.key")), library_dir]
	for t in ["lp2colview.py", "lp2pieces.py", "lp2col.py"]:
		parts.append(str(FileAccess.get_modified_time(tools.path_join(t))))
	return "\n".join(parts).sha256_text()

func _index_tree(t: Dictionary, piece: int) -> void:
	for c in t.get("children", []):
		_index_tree(c, piece)
	for a in t.get("atoms", []):
		col_pieces["a%d" % int(a)] = piece
	for k in t.get("copies", []):
		col_pieces["c%d" % int(k)] = piece

# the piece a View collision triangle belongs to (null: none / view off)
func _collision_piece(mp: Vector2) -> Node3D:
	if col_body == null or not col_mesh.visible:
		return null
	var hit := _mouse_ray(mp, (1 << (LAYER_COLLISION - 1)) | (1 << (LAYER_STAGE - 1)))
	if not hit or hit["collider"] != col_body:
		return null
	var face := int(hit.get("face_index", -1))
	if face < 0 or face >= col_owner.size():
		return null
	var o := col_owner[face]
	if o <= WALL and col_walls.has(WALL - o):
		return col_walls[WALL - o]
	var key := ("a%d" % o) if o >= 0 else ("c%d" % (-2 - o)) if o <= -2 else ""
	if not col_pieces.has(key):
		return null
	var ps: Array = geometry.pieces()
	var i: int = col_pieces[key]
	return ps[i] if i < ps.size() else null

# collision-only walls: one node per wall, its triangles drawn red while selected
func _build_walls(pos: PackedVector3Array) -> void:
	for w in col_walls.values():
		if is_instance_valid(w):
			if selection.has(w):
				selection.erase(w)
			w.queue_free()
	col_walls = {}
	var tris := {}
	for t in col_owner.size():
		var o := col_owner[t]
		if o <= WALL:
			if not tris.has(WALL - o):
				tris[WALL - o] = []
			(tris[WALL - o] as Array).append(t)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.15, 0.1, 0.55)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	for k in tris:
		var w := Node3D.new()
		w.name = "wall_%d" % k
		w.set_meta("wall", k)
		var mi := MeshInstance3D.new()
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		var vs := PackedVector3Array()
		for t in tris[k]:
			vs.append_array(pos.slice(t * 3, t * 3 + 3))
		arr[Mesh.ARRAY_VERTEX] = vs
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mi.mesh = m
		mi.material_override = mat
		mi.visible = false
		w.add_child(mi)
		var box := m.get_aabb()
		w.position = box.get_center()   # the gizmo / frame point; the mesh stays in world space
		mi.position = -box.get_center()
		col_mesh.add_child(w)
		col_walls[k] = w

func _is_wall(n: Node3D) -> bool:
	return n.has_meta("wall")

func _load_collision(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var n := f.get_32()
	var raw := f.get_buffer(n * 36).to_float32_array()
	f.get_buffer(n * 4)   # surfaces
	col_owner = f.get_buffer(n * 4).to_int32_array() if f.get_length() >= 4 + n * 44 else PackedInt32Array()
	f.close()
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	pos.resize(n * 3)
	nrm.resize(n * 3)
	for t in n:
		var a := Vector3(raw[t * 9], raw[t * 9 + 1], raw[t * 9 + 2]) * CM
		var b := Vector3(raw[t * 9 + 3], raw[t * 9 + 4], raw[t * 9 + 5]) * CM
		var c := Vector3(raw[t * 9 + 6], raw[t * 9 + 7], raw[t * 9 + 8]) * CM
		var w := (b - a).cross(c - a).normalized()
		var lift := w * 0.03   # a little off the surface it lies on, so it doesn't flicker against the stage
		pos[t * 3] = a + lift
		pos[t * 3 + 1] = b + lift
		pos[t * 3 + 2] = c + lift
		nrm[t * 3] = w
		nrm[t * 3 + 1] = w
		nrm[t * 3 + 2] = w
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_NORMAL] = nrm
	var m := ArrayMesh.new()
	if n > 0:
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if col_mesh == null:
		col_mesh = MeshInstance3D.new()
		col_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.1, 1.0, 0.25, 0.35)
		mat.emission_enabled = true
		mat.emission = Color(0.05, 0.5, 0.1)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		col_mesh.material_override = mat
		add_child(col_mesh)
	col_mesh.mesh = m
	col_mesh.visible = col_toggle.button_pressed
	if col_body == null:
		col_body = StaticBody3D.new()
		col_body.collision_layer = 1 << (LAYER_COLLISION - 1)
		col_body.collision_mask = 0
		col_body.add_child(CollisionShape3D.new())
		col_mesh.add_child(col_body)
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(pos)
	_build_walls(pos)
	(col_body.get_child(0) as CollisionShape3D).shape = shape
	set_status("Collision: %d triangles" % n)

func _on_wireframe(on: bool) -> void:
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if on else Viewport.DEBUG_DRAW_DISABLED
	if not on:
		wire_toggle.text = "Wireframe"
		return
	while wire_toggle.button_pressed:   # the count of what's drawn, while on
		await get_tree().create_timer(0.5).timeout
		var tris: Vector2i = geometry.triangles_in_view(camera)   # the stage's own (the renderer's count adds passes)
		if wire_toggle.button_pressed:
			wire_toggle.text = "Wireframe (%dk of %dk tris in view)" % [tris.x / 1000, tris.y / 1000]

func _on_baked(on: bool) -> void:
	baked = on
	geometry.set_baked(on)

func _screenshot() -> void:
	await get_tree().create_timer(1.5).timeout
	if OS.get_cmdline_user_args().has("--collision"):
		await get_tree().create_timer(6.0).timeout   # lp2colview.py
		var cp := _collision_piece(get_viewport().get_visible_rect().size / 2)   # a click mid-screen
		if OS.get_environment("LP2_PICK_WALL") != "" and not col_walls.is_empty():
			var big: Node3D = null
			for w in col_walls.values():   # the wall with the most triangles
				if big == null or (w.get_child(0) as MeshInstance3D).mesh.get_faces().size() > (big.get_child(0) as MeshInstance3D).mesh.get_faces().size():
					big = w
			cp = big
		print("collision pick: ", (("wall %d" % cp.get_meta("wall")) if _is_wall(cp) else geometry.label(cp)) if cp else "none", ", walls: ", col_walls.size())
		if cp:
			select([cp])
			await get_tree().create_timer(0.5).timeout
			if OS.get_environment("LP2_PICK_WALL") == "delete" and _is_wall(cp):
				delete_selected()
				await get_tree().create_timer(7.0).timeout   # the view rebuilt without it
				print("after delete: walls ", col_walls.size(), ", hidden ", geometry.walls_hidden.keys())
				undo()
				await get_tree().create_timer(7.0).timeout
				print("after undo: walls ", col_walls.size(), ", hidden ", geometry.walls_hidden.keys())
	if OS.get_cmdline_user_args().has("--preview"):
		toggle_preview()
		await get_tree().create_timer(3.0).timeout   # falls onto the floor
	if lighting.visible:
		var ls := markers_root.get_children().filter(func(n): return n.has_meta("light"))
		if not ls.is_empty():
			select([ls[0]])
		await get_tree().create_timer(4.0).timeout
	if OS.get_cmdline_user_args().has("--input-test"):   # placing / gizmo / Ctrl+face through the real input path
		await _input_test()
	var place_volume := OS.get_cmdline_user_args().has("--place-volume")
	if OS.get_cmdline_user_args().has("--place") or place_volume:   # a VS put down mid-screen, aimed to the right
		placer.popup()                                              # (--place-volume: a post volume dragged out)
		placer.kind_pick.select(3 if place_volume else 2)
		placer._fill_items()
		if place_volume:
			placer.item_pick.select(2)
		var mid := get_viewport().get_visible_rect().size / 2
		var far := Vector2(160, 120) if place_volume else Vector2(160, 10)
		for ev in [[true, mid], [false, mid + Vector2(80, 0)], [false, mid + far]]:
			var b := InputEventMouseButton.new() if ev[0] else null
			if b:
				b.button_index = MOUSE_BUTTON_LEFT
				b.pressed = true
				b.position = ev[1]
				placer.handle(b)
			else:
				var mm := InputEventMouseMotion.new()
				mm.position = ev[1]
				placer.handle(mm)
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.position = mid + far
		placer.handle(up)
		if OS.get_cmdline_user_args().has("--preview-post") and not selection.is_empty():   # the camera into it, preview on
			view_toggles["post"].set_pressed_no_signal(true)
			var c: Vector3 = selection[0].global_position + Vector3(0, 3, 0)
			camera.look_at_point(c + Vector3(30, -8, 0), c)
			await get_tree().create_timer(2.0).timeout
		await get_tree().create_timer(8.0).timeout   # thumbnails render one per frame
		await RenderingServer.frame_post_draw
		placer.get_texture().get_image().save_png(screenshot_path.get_basename() + "-place.png")
		var bar: VScrollBar = placer.vs_list.get_v_scroll_bar()   # and the end of the list
		bar.value = bar.max_value * float(OS.get_environment("LP2_PLACE_SCROLL") if OS.has_environment("LP2_PLACE_SCROLL") else "1")
		await get_tree().create_timer(4.0).timeout
		await RenderingServer.frame_post_draw
		placer.get_texture().get_image().save_png(screenshot_path.get_basename() + "-place-end.png")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(screenshot_path)
	if thumb_on_start:
		await capture_thumbnail()
		save_project()
	if info_win.visible:
		await RenderingServer.frame_post_draw
		info_win.get_texture().get_image().save_png(screenshot_path.get_basename() + "-info.png")
	if fog_win.visible and OS.has_environment("LP2_FOG_PRESET"):   # tests: a stock map's fog in the view
		for i in fog_win.preset_pick.item_count:
			if fog_win.preset_pick.get_item_metadata(i) == OS.get_environment("LP2_FOG_PRESET"):
				fog_win.preset_pick.select(i)
		fog_win.apply_preset()
		await get_tree().create_timer(1.0).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(screenshot_path.get_basename() + "-fogview.png")
	if fog_win.visible:
		fog_win.get_texture().get_image().save_png(screenshot_path.get_basename() + "-fog.png")
	if lighting.visible:
		lighting.get_texture().get_image().save_png(screenshot_path.get_basename() + "-lighting.png")
		if not selection.is_empty():
			_on_right_click(camera.unproject_position(selection[0].global_position))
			await get_tree().create_timer(1.0).timeout
			await RenderingServer.frame_post_draw
			lighting.light_popup.get_texture().get_image().save_png(screenshot_path.get_basename() + "-lightmenu.png")
	if browser.visible:
		if browser_tab >= 0:
			browser.tabs.current_tab = browser_tab
		if browser_group != "":
			browser.show_group(browser_group)
		await get_tree().create_timer(15.0).timeout
		browser.get_texture().get_image().save_png(screenshot_path.get_basename() + "-browser.png")
	if mesh_builder.visible:
		if mesh_builder.import_list.item_count:
			mesh_builder.import_list.select(0)
			mesh_builder._show_import()
		if mesh_builder.mat_list.item_count:
			mesh_builder.mat_list.select(mesh_builder.mat_list.item_count - 1)
			mesh_builder._show_material()
		await get_tree().create_timer(3.0).timeout
		mesh_builder.get_texture().get_image().save_png(screenshot_path.get_basename() + "-meshbuilder.png")
	if OS.get_cmdline_user_args().has("--save"):
		save_project()
	var sa := OS.get_cmdline_user_args().find("--save-as")
	if sa >= 0 and sa + 1 < OS.get_cmdline_user_args().size():
		save_project_as(OS.get_cmdline_user_args()[sa + 1])
	print("screenshot ", screenshot_path)
	get_tree().quit()

# ---------------------------------------------------------------- layouts and markers

func set_variant(v: int) -> void:
	variant = v
	for i in layout_buttons.size():
		layout_buttons[i].button_pressed = i == v
	visible_sets = []
	set_pick.clear()
	var sets: Array = layout.get("sets", [])
	for i in sets.size():
		var ids: Array = sets[i].get("ids", [])
		var hit := false
		for id in ids:
			if str(id).length() >= 2 and str(id)[1] == str(v):
				hit = true
		if hit:
			visible_sets.append(i)
			set_pick.add_item(_set_label(i))
	if visible_sets.is_empty():
		show_set(-1)
		log_line("Layout %d has no marker sets." % (v + 1))
	else:
		set_pick.select(0)
		show_set(visible_sets[0])

func show_set(i: int) -> void:
	set_index = i
	select([])
	for c in markers_root.get_children():
		markers_root.remove_child(c)
		c.queue_free()
	if i >= 0:
		var s: Dictionary = layout["sets"][i]
		for p in s["points"]:
			_add_marker(p, false)
		for o in s["objects"]:
			_add_marker(o, true)
	lighting.add_markers()
	volumes.add_markers()
	_rebuild_outliner()
	_update_stats()

func _marker_label(d: Dictionary, is_object: bool) -> String:
	var role: String = d.get("role", "?")
	if is_object:
		var what: String = (" " + str(d["model"])) if d.has("model") else ""
		if d.has("item"):
			var e: Variant = PICKUP_ITEMS.filter(func(x): return x[0] == int(d["item"])).front()
			what = ": " + (str(e[1]) if e != null else "item %02X" % int(d["item"]))
		elif role == "weapon":
			# LP1 weapon ids mean nothing in LP2: the export keeps the stock record's pickup, which differs per game type
			what += " (LP1): stock pickup, varies by game type"
		return "%s%s%s" % [role, what, " (buried)" if int(d.get("dig", 0)) > 0 else ""]
	# LP1 layouts: the stock map's extra weapon records go on k40 points, then FFA starts (lp2layout.patch_objset)
	if role == "k40" and not layout.get("explicit", false):
		return "spawn k40 (+ stock weapon pickup)"
	if role == "start" and not layout.get("explicit", false):
		return "spawn start (may get a stock pickup)"
	return "spawn " + role

func _category(n: Node3D) -> int:
	if _is_wall(n):
		return 6
	if n.get_parent() == geometry:
		return 3
	if n.has_meta("volume"):
		return 5
	if n.has_meta("light"):
		return 4
	if not n.get_meta("object"):
		return 0
	var role: String = (n.get_meta("data") as Dictionary).get("role", "")
	return 1 if role == "weapon" else 2 if role == "vs" else 0

func _add_marker(d: Dictionary, is_object: bool) -> void:
	var n := Node3D.new()
	n.set_meta("data", d)
	n.set_meta("object", is_object)
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	var shape := CollisionShape3D.new()
	var role: String = d.get("role", "")
	if is_object:
		var style: Array = OBJECT_STYLE.get(role, OBJECT_STYLE["object"])
		var box := BoxMesh.new()
		box.size = style[1]
		mi.mesh = box
		mi.position.y = style[1].y / 2
		mat.albedo_color = pickup_colour(d) if role == "weapon" else style[0]
		var bs := BoxShape3D.new()
		bs.size = style[1]
		shape.shape = bs
		shape.position.y = style[1].y / 2
	else:
		var cap := CapsuleMesh.new()
		cap.radius = 0.4
		cap.height = 1.8
		mi.mesh = cap
		mi.position.y = 0.9
		mat.albedo_color = ROLE_COLOURS.get(role, SPAWN_COLOUR)
		var cs := CapsuleShape3D.new()
		cs.radius = 0.4
		cs.height = 1.8
		shape.shape = cs
		shape.position.y = 0.9
	mi.material_override = mat
	n.add_child(mi)
	# facing: a small cone pointing along the marker's yaw
	var arrow := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.25
	cone.height = 0.7
	arrow.mesh = cone
	arrow.rotation_degrees.x = -90
	arrow.position = Vector3(0, 1.0, -0.8)
	var amat := StandardMaterial3D.new()
	amat.albedo_color = Color.WHITE
	arrow.material_override = amat
	n.add_child(arrow)
	# a dot that keeps its size on screen, so markers show from across the map
	var dot := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.012, 0.012)
	dot.mesh = q
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dmat.fixed_size = true
	dmat.albedo_color = mat.albedo_color
	dmat.render_priority = 1
	dot.material_override = dmat
	dot.position.y = 2.2 if not is_object else mi.position.y * 2 + 0.6
	n.add_child(dot)
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_MARKERS
	body.collision_mask = 0
	body.add_child(shape)
	n.add_child(body)
	markers_root.add_child(n)
	_place(n)
	if is_object:
		_marker_model(n)

func _marker_model(n: Node3D) -> void:
	# the game's model instead of the box, when the library has it (Browser: Get assets)
	var d: Dictionary = n.get_meta("data")
	# a pickup shows the weapon it gives (its item), else its LP1 model
	var key: String = library.marker_key(("wp%02x" % int(d["item"])) if d.has("item") else String(d.get("model", "")))
	var model: Node3D = library.instance(key) if key != "" else null
	if model == null:
		return
	model.name = "model"
	n.add_child(model)
	(n.get_child(0) as MeshInstance3D).visible = false
	var b: AABB = library.box(model)
	var shape: CollisionShape3D = n.find_children("*", "CollisionShape3D", true, false)[0]
	var bs := BoxShape3D.new()
	bs.size = b.size.max(Vector3(0.3, 0.3, 0.3))
	shape.shape = bs
	shape.position = b.get_center()
	n.set_meta("asset", key)
	if d.get("role", "") == "weapon":
		model.position.y += PICKUP_RAISE
		b.position.y += PICKUP_RAISE
		shape.position = b.get_center()
		_pickup_frame(n, b.grow(0.1))

static func pickup_colour(d: Dictionary) -> Color:
	if not d.has("item"):
		return OBJECT_STYLE["weapon"][0]
	var it := int(d["item"])
	if it >= 0x30 and it <= 0x34 or it == 0x0c:
		return PICKUP_COLOURS["slot"]
	if it >= 0x15 and it <= 0x19:
		return PICKUP_COLOURS["grenade"]
	if it >= 0x1c and it <= 0x1f or it >= 0x41:
		return PICKUP_COLOURS["vs"]
	return PICKUP_COLOURS["explicit"]

func _pickup_frame(n: Node3D, b: AABB) -> void:
	# the pickup's box: coloured edges plus faint faces, in its category's colour (pickup_colour)
	var c := pickup_colour(n.get_meta("data"))
	var am := ArrayMesh.new()
	var lines := PackedVector3Array()
	for e in [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		lines.append(b.get_endpoint(e[0]))
		lines.append(b.get_endpoint(e[1]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = lines
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = c
	am.surface_set_material(0, lm)
	var frame := MeshInstance3D.new()
	frame.name = "frame"
	frame.mesh = am
	frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var faces := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = b.size
	faces.mesh = bm
	faces.position = b.get_center()
	faces.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	fm.albedo_color = Color(c, 0.12)
	faces.material_override = fm
	frame.add_child(faces)
	n.add_child(frame)

func _place(n: Node3D) -> void:
	var d: Dictionary = n.get_meta("data")
	var p: Array = d["pos"]
	n.position = Vector3(p[0], p[1], p[2]) * CM
	n.rotation_degrees = Vector3(0, float(d.get("yaw", 0.0)), 0)

func _store_marker(n: Node3D) -> void:
	var d: Dictionary = n.get_meta("data")
	d["pos"] = [n.position.x / CM, n.position.y / CM, n.position.z / CM]
	d["yaw"] = snappedf(n.rotation_degrees.y, 0.01)
	if n.has_meta("light"):
		lighting.update_marker(n)
	elif n.has_meta("volume"):
		volumes.update_marker(n)

func _is_marker(n: Node3D) -> bool:
	return n.get_parent() == markers_root

# ---------------------------------------------------------------- outliner

func _rebuild_outliner() -> void:
	var was_collapsed: Array = []
	for it in cat_items:
		was_collapsed.append(it.collapsed)
	outliner.clear()
	var root := outliner.create_item()
	cat_items = []
	var nodes: Array = [[], [], [], [], [], [], []]
	for n in markers_root.get_children():
		nodes[_category(n)].append(n)
	nodes[3] = geometry.get_children()
	for c in CATEGORIES.size():
		var it := outliner.create_item(root)
		it.set_text(0, "%s (%d)" % [CATEGORIES[c], nodes[c].size()])
		it.set_selectable(0, false)
		it.collapsed = was_collapsed[c] if was_collapsed.size() == CATEGORIES.size() else c == 3
		cat_items.append(it)
		for n in nodes[c]:
			var ch := outliner.create_item(it)
			ch.set_metadata(0, n)
			n.set_meta("item", ch)
			if c == 3:
				ch.set_text(0, geometry.label(n))
			else:
				var d: Dictionary = n.get_meta("data")
				ch.set_text(0, volumes.label(d) if n.has_meta("volume") else lighting.label(d) if c == 4 else _marker_label(d, n.get_meta("object")))
				var col: Color = ((n.get_child(0) as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.lightened(0.3)
				col.a = 1.0   # volumes' boxes are see-through
				ch.set_custom_color(0, col)
	apply_marker_visibility()
	_sync_tree()
	if browser:
		browser.refresh_level()

func _sync_tree() -> void:
	selection = _valid(selection)
	updating_ui = true
	outliner.deselect_all()
	for n in selection:
		var ref: Variant = n.get_meta("item") if n.has_meta("item") else null
		if ref == null or not is_instance_valid(ref):  # a piece being removed (its row is gone)
			continue
		var it: TreeItem = ref
		it.select(0)
		var par := it.get_parent()
		if par and par.collapsed and selection.size() == 1:
			par.collapsed = false
		outliner.scroll_to_item(it)
	updating_ui = false

func _on_tree_selected(item: TreeItem, _col: int, _sel: bool) -> void:
	if updating_ui:
		return
	var out: Array = []
	var it := outliner.get_next_selected(null)
	while it:
		var n: Variant = it.get_metadata(0)
		if n is Node3D and is_instance_valid(n):
			out.append(n)
		it = outliner.get_next_selected(it)
	_set_selection(out)

# ---------------------------------------------------------------- selection

func select(ns: Array) -> void:
	_set_selection(ns)
	_sync_tree()

func _valid(ns: Array) -> Array:
	# without the freed nodes (a loop variable cannot even hold one)
	var out: Array = []
	for i in ns.size():
		if is_instance_valid(ns[i]):
			out.append(ns[i])
	return out

func _set_selection(ns: Array) -> void:
	for n in _valid(selection):
		_highlight(n, false)
	selection = _valid(ns)
	for n in selection:
		_highlight(n, true)
	_place_gizmo()
	_show_inspector()
	if browser:
		browser.sync_selection(selection)
	if lighting:
		lighting.selection_changed()

func _highlight(n: Node3D, on: bool) -> void:
	if _is_wall(n):
		(n.get_child(0) as Node3D).visible = on
	elif _is_marker(n) and n.has_meta("volume"):
		volumes.set_selected(n, on)
	elif _is_marker(n):
		var m := (n.get_child(0) as MeshInstance3D).material_override as StandardMaterial3D
		m.emission_enabled = on
		m.emission = Color(1, 1, 1)
		m.emission_energy_multiplier = 0.6
		var model := n.get_node_or_null("model")
		if model:
			library.set_overlay(model, marker_tint if on else null)
	else:
		geometry.set_selected(n, on)

func _place_gizmo() -> void:
	gizmo.visible = not selection.is_empty() and not selection.all(func(n): return _is_wall(n))
	if selection.is_empty():
		return
	var c := Vector3.ZERO
	for n in selection:
		c += n.global_position
	gizmo.global_position = c / selection.size()
	_gizmo_limits()

func _gizmo_limits() -> void:
	# markers: move and turn about Y; volumes: move, size and turn about Y; pieces: everything
	var markers := selection.any(func(n): return _is_marker(n) and not n.has_meta("volume"))
	var vols := selection.any(func(n): return n.has_meta("volume"))
	gizmo.set_limits(not markers, not markers and not vols, true)

func _show_inspector() -> void:
	updating_ui = true
	var one: Node3D = selection[0] if selection.size() == 1 and not _is_wall(selection[0]) else null
	var pieces := _pieces_selected()
	for b in piece_buttons:
		b.disabled = pieces.is_empty()
	var geo_pieces := pieces.filter(func(n): return n.has_meta("tree"))
	mesh_col.visible = not geo_pieces.is_empty()
	mesh_col.button_pressed = geo_pieces.any(func(n): return n.get_meta("tree").get("mesh_collision", false))
	insp_name.visible = one != null and not _is_marker(one)
	for r in insp_rows:
		r.visible = one != null and not _is_marker(one)
	for s in insp_pos + insp_rot + insp_scale:
		s.editable = one != null
	var pickups := _diggable().filter(func(n): return _category(n) == 1)
	pickup_row.visible = not pickups.is_empty()
	if not pickups.is_empty():
		var it := int(pickups[0].get_meta("data").get("item", -1))
		pickup_pick.selected = maxi(0, PICKUP_ITEMS.find_custom(func(e): return e[0] == it))
	var vss := _diggable().filter(func(n): return _category(n) == 2)
	vs_props.refresh(vss)
	tier_row.visible = not vss.is_empty()
	if not vss.is_empty():
		var t := int(vss[0].get_meta("data").get("tier", -1))
		tier_pick.selected = maxi(0, VS_TIERS.find_custom(func(e): return e[0] == t))
	var diggable := _diggable()
	dig_row.visible = not diggable.is_empty()
	if not diggable.is_empty():
		var d0: Dictionary = diggable[0].get_meta("data")
		dig_on.button_pressed = int(d0.get("dig", 0)) > 0
		dig_count.value = int(d0.get("dig", 0)) if dig_on.button_pressed else dig_count.value
		dig_pile.selected = clampi(int(d0.get("dig_pile", 0)), 0, DIG_PILES.size() - 1)
		dig_count.editable = dig_on.button_pressed
		dig_pile.disabled = not dig_on.button_pressed
	var typed := _typed_markers()
	type_box.visible = not typed.is_empty()
	volumes.show_inspector(selection)
	if not typed.is_empty():
		var have: Array = _marker_types(typed[0].get_meta("data"))
		for i in GAME_TYPES.size():
			type_checks[i].button_pressed = GAME_TYPES[i][0] in have
		_show_exists(typed)
	var tilt := one != null and not _is_marker(one)
	insp_rot[0].editable = tilt
	insp_rot[2].editable = tilt
	if selection.is_empty():
		insp_title.text = "Nothing selected"
	elif one == null:
		insp_title.text = "%d selected" % selection.size()
	elif _is_marker(one):
		var d: Dictionary = one.get_meta("data")
		insp_title.text = volumes.label(d) if one.has_meta("volume") else lighting.label(d) if one.has_meta("light") else "%s\nkind %s" % [_marker_label(d, one.get_meta("object")), str(d.get("kind", "?"))]
		for a in 3:
			insp_pos[a].value = float(d["pos"][a])
		insp_rot[1].value = float(d.get("yaw", 0.0))
	else:
		var t: Dictionary = one.get_meta("tree")
		insp_title.text = "Level geometry: " + geometry.label(one)
		insp_name.text = t["name"]
		var tr: Transform3D = one.transform
		var sc := tr.basis.get_scale()
		var rot := tr.basis.orthonormalized().get_euler() * (180.0 / PI)
		for a in 3:
			insp_pos[a].value = tr.origin[a] / CM
			insp_rot[a].value = rot[a]
			insp_scale[a].value = sc[a]
	updating_ui = false

func _on_inspector() -> void:
	if updating_ui or selection.size() != 1:
		return
	var n: Node3D = selection[0]
	_push_undo("inspector")
	if _is_marker(n):
		var d: Dictionary = n.get_meta("data")
		d["pos"] = [insp_pos[0].value, insp_pos[1].value, insp_pos[2].value]
		d["yaw"] = insp_rot[1].value
		_place(n)
		if n.has_meta("light"):
			lighting.update_marker(n)
		elif n.has_meta("volume"):
			volumes.update_marker(n)
	else:
		var rot := Vector3(insp_rot[0].value, insp_rot[1].value, insp_rot[2].value) * (PI / 180.0)
		var sc := Vector3(insp_scale[0].value, insp_scale[1].value, insp_scale[2].value)
		n.transform = Transform3D(Basis.from_euler(rot) * Basis.from_scale(sc),
			Vector3(insp_pos[0].value, insp_pos[1].value, insp_pos[2].value) * CM)
		_stats_later()
	_place_gizmo()

func _diggable() -> Array:
	# selected pickups and VS (the records the game can bury)
	return selection.filter(func(n): return _is_marker(n) and n.get_meta("object") and _category(n) in [1, 2])

func _on_pickup(i: int) -> void:
	if updating_ui:
		return
	_push_undo("")
	var id: int = PICKUP_ITEMS[i][0]
	for n in _diggable().filter(func(m): return _category(m) == 1):
		var d: Dictionary = n.get_meta("data")
		if id < 0:
			d.erase("item")
		else:
			d["item"] = id
		refresh_marker(n)

func refresh_marker(n: Node3D) -> void:
	# after its data's item / model changed: outliner label and the shown model
	var d: Dictionary = n.get_meta("data")
	var ref: Variant = n.get_meta("item") if n.has_meta("item") else null
	if ref != null and is_instance_valid(ref):
		(ref as TreeItem).set_text(0, _marker_label(d, true))
	for nm in ["model", "frame"]:
		var old: Node = n.get_node_or_null(nm)
		if old:
			n.remove_child(old)
			old.queue_free()
	if d.get("role", "") == "weapon":   # the item's category colour (pickup_colour)
		var c := pickup_colour(d)
		((n.get_child(0) as MeshInstance3D).material_override as StandardMaterial3D).albedo_color = c
		for m in n.get_children():
			if m is MeshInstance3D and m.material_override is StandardMaterial3D \
					and (m.material_override as StandardMaterial3D).fixed_size:
				(m.material_override as StandardMaterial3D).albedo_color = c
	(n.get_child(0) as MeshInstance3D).visible = true
	n.remove_meta("asset")
	_marker_model(n)

func _on_tier(i: int) -> void:
	if updating_ui:
		return
	_push_undo("")
	var t: int = VS_TIERS[i][0]
	for n in _diggable().filter(func(m): return _category(m) == 2):
		var d: Dictionary = n.get_meta("data")
		if t < 0:
			d.erase("tier")
		else:
			d["tier"] = t

# ---------------------------------------------------------------- game types

func _set_variant_digit(i: int) -> String:
	var ids: Array = layout["sets"][i].get("ids", [])
	return str(ids[0]).substr(1, 1) if not ids.is_empty() else ""

func _is_default_set(i: int) -> bool:
	# the LP1 mode 0 set of its variant: lp2layout.py's fallback for every game type
	return ("0" + _set_variant_digit(i)) in layout["sets"][i].get("ids", []).map(func(x): return str(x))

func set_game_types(i: int) -> Array:
	# the game types that export set i: its "modes"; the default set also takes the ones no other set claims
	var sets: Array = layout["sets"]
	var own: Array = sets[i].get("modes", [])
	if not _is_default_set(i):
		return own
	var claimed := []
	for j in sets.size():
		if j != i and _set_variant_digit(j) == _set_variant_digit(i):
			claimed.append_array(sets[j].get("modes", []))
	return GAME_TYPES.map(func(t): return t[0]).filter(func(m): return m in own or m not in claimed)

func _type_names(modes: Array) -> String:
	if modes.size() == GAME_TYPES.size():
		return "All game types"
	return ", ".join(PackedStringArray(GAME_TYPES.filter(func(t): return t[0] in modes).map(func(t): return t[1].split(" (")[0])))

func _set_label(i: int) -> String:
	var s: Dictionary = layout["sets"][i]
	var m := set_game_types(i)
	var ids := " ".join(PackedStringArray(s.get("ids", []).map(func(x): return str(x))))
	var what := _type_names(m) if not m.is_empty() else "Unused (LP1 ids %s)" % ids
	return "%s: %d spawns, %d objects" % [what, s["points"].size(), s["objects"].size()]

func _fill_set_types() -> void:
	var pm := set_types.get_popup()
	pm.clear()
	if set_index < 0:
		return
	var m := set_game_types(set_index)
	for t in GAME_TYPES:
		pm.add_check_item(t[1])
		var k := pm.item_count - 1
		pm.set_item_checked(k, t[0] in m)
		# the default set keeps a type until another set takes it
		pm.set_item_disabled(k, t[0] in m and _is_default_set(set_index))
	if _is_default_set(set_index):
		pm.add_separator("Default set: to move a type, tick it on another set")

func _on_set_type(k: int) -> void:
	if set_index < 0 or k >= GAME_TYPES.size():
		return
	var mode: String = GAME_TYPES[k][0]
	var sets: Array = layout["sets"]
	var on := mode not in set_game_types(set_index)
	_push_undo("")
	var own: Array = sets[set_index].get("modes", []).duplicate()
	if on:
		for j in sets.size():   # one set per game type in a layout
			if j != set_index and _set_variant_digit(j) == _set_variant_digit(set_index) and sets[j].has("modes"):
				sets[j]["modes"] = sets[j]["modes"].filter(func(x): return x != mode)
		if not _is_default_set(set_index):
			own.append(mode)
	else:
		own.erase(mode)
	sets[set_index]["modes"] = own
	if own.is_empty():
		sets[set_index].erase("modes")
	var shown := set_index
	for i in visible_sets.size():
		set_pick.set_item_text(i, _set_label(visible_sets[i]))
	_fill_set_types()
	if not selection.is_empty():
		_show_inspector()
	log_line("Set: %s" % _set_label(shown))

func _typed_markers() -> Array:
	return selection.filter(func(n): return _is_marker(n) and not n.has_meta("light") and not n.has_meta("volume"))

func _marker_types(d: Dictionary) -> Array:
	return d["modes"] if d.get("modes") is Array else GAME_TYPES.map(func(t): return t[0])

func _show_exists(typed: Array) -> void:
	var on: Array = _marker_types(typed[0].get_meta("data")).filter(func(m): return m in set_game_types(set_index))
	type_exists.text = "Exists on: " + (_type_names(on) if not on.is_empty() else "none (this set or these ticks leave it out)")

func _on_marker_types() -> void:
	if updating_ui:
		return
	var typed := _typed_markers()
	if typed.is_empty():
		return
	_push_undo("types")
	var modes := []
	for i in GAME_TYPES.size():
		if type_checks[i].button_pressed:
			modes.append(GAME_TYPES[i][0])
	for n in typed:
		var d: Dictionary = n.get_meta("data")
		if modes.size() == GAME_TYPES.size():
			d.erase("modes")
		else:
			d["modes"] = modes.duplicate()
	_show_exists(typed)

func _on_dig() -> void:
	if updating_ui:
		return
	_push_undo("dig")
	for n in _diggable():
		var d: Dictionary = n.get_meta("data")
		if dig_on.button_pressed:
			d["dig"] = int(dig_count.value)
			d["dig_pile"] = dig_pile.selected
		else:
			d.erase("dig")
			d.erase("dig_pile")
		var ref: Variant = n.get_meta("item") if n.has_meta("item") else null
		if ref != null and is_instance_valid(ref):
			(ref as TreeItem).set_text(0, _marker_label(d, true))
	dig_count.editable = dig_on.button_pressed
	dig_pile.disabled = not dig_on.button_pressed

func _on_rename() -> void:
	if updating_ui or selection.size() != 1 or _is_marker(selection[0]):
		return
	var t: Dictionary = selection[0].get_meta("tree")
	if insp_name.text != "" and insp_name.text != t["name"]:
		_push_undo("")
		t["name"] = insp_name.text
		var ref: Variant = selection[0].get_meta("item")
		if is_instance_valid(ref):
			(ref as TreeItem).set_text(0, geometry.label(selection[0]))

func frame_selected() -> void:
	if selection.is_empty():
		return
	var box := AABB()
	for i in selection.size():
		var n: Node3D = selection[i]
		var b: AABB = AABB(n.global_position, Vector3(0, 2, 0)) if _is_marker(n) else \
			(n.get_child(0) as MeshInstance3D).global_transform * (n.get_child(0) as MeshInstance3D).mesh.get_aabb() if _is_wall(n) else geometry.world_box(n)
		box = b if i == 0 else box.merge(b)
	var r: float = max(box.size.length() * 0.8, 6.0)
	var at := box.get_center()
	camera.look_at_point(at, at + Vector3(r * 0.6, r * 0.5, r * 0.6))

func drop_selected() -> void:
	if selection.is_empty():
		return
	_push_undo("")
	for n in selection.filter(func(q): return not _is_wall(q)):
		if _is_marker(n):
			var from: Vector3 = n.global_position + Vector3(0, 2.0, 0)
			var hit := _ray(from, from + Vector3(0, -500, 0), 1 << (LAYER_STAGE - 1))
			if hit:
				var d: Dictionary = n.get_meta("data")
				d["pos"] = [hit["position"].x / CM, hit["position"].y / CM + 5.0, hit["position"].z / CM]
				_place(n)
		else:
			var box: AABB = geometry.world_box(n)
			var from2 := Vector3(box.get_center().x, box.end.y, box.get_center().z)
			var ex: Array = []
			for c in n.get_children():
				if c is StaticBody3D:
					ex.append(c.get_rid())
			var hit2 := _ray(from2, from2 + Vector3(0, -1000, 0), 1 << (LAYER_STAGE - 1), ex)
			if hit2:
				n.global_position.y += hit2["position"].y - box.position.y
	_place_gizmo()
	_show_inspector()

func _on_right_click(at: Vector2) -> void:
	# a quick right click on a light: its settings in a popup
	var n := _pick(at)
	if n and n.has_meta("light"):
		lighting.light_menu(n, at)

func _pick(mp: Vector2) -> Node3D:
	# the marker nearest the camera whose position or dot is within 14 px of the mouse, else what the ray hits
	var best: Node3D = null
	var best_d := INF
	for n in markers_root.get_children():
		if not n.visible:   # hidden by the view toggles
			continue
		for at in [n.global_position + Vector3(0, 1.0, 0), (n.get_child(2) as Node3D).global_position]:
			if camera.is_position_behind(at):
				continue
			if camera.unproject_position(at).distance_to(mp) < 14.0:
				var d := camera.global_position.distance_to(at)
				if d < best_d:
					best_d = d
					best = n
	if best:
		return best
	var cp := _collision_piece(mp)
	if cp:
		return cp
	var hit := _mouse_ray(mp, (1 << (LAYER_MARKERS - 1)) | (1 << (LAYER_STAGE - 1)))
	if not hit:
		return null
	var col: Node = hit["collider"]
	if (col as CollisionObject3D).collision_layer & (1 << (LAYER_MARKERS - 1)):
		return col.get_parent()
	return geometry.piece_of(col)

func _ray(from: Vector3, to: Vector3, mask: int, exclude: Array = []) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	return world.get_world_3d().direct_space_state.intersect_ray(q)

func _mouse_ray(mp: Vector2, mask: int) -> Dictionary:
	var from := camera.project_ray_origin(mp)
	return _ray(from, from + camera.project_ray_normal(mp) * 5000.0, mask)

# ---------------------------------------------------------------- geometry edits

func _pieces_selected() -> Array:
	return selection.filter(func(n): return not _is_marker(n) and not _is_wall(n))

func _on_mesh_col(on: bool) -> void:
	if updating_ui:
		return
	_push_undo("")
	var n := 0
	for p in _pieces_selected().filter(func(q): return q.has_meta("tree")):
		var t: Dictionary = p.get_meta("tree")
		if on:
			t["mesh_collision"] = true
		else:
			_clear_mesh_col(t)
		n += 1
	log_line("%d piece(s): collision %s" % [n, "from their mesh" if on else "as imported"])
	if col_toggle.button_pressed:
		_on_collision(true)

func _clear_mesh_col(t: Dictionary) -> void:
	t.erase("mesh_collision")
	for c in t.get("children", []):
		_clear_mesh_col(c)

func group_selected() -> void:
	var ps := _pieces_selected()
	if ps.size() < 2:
		log_line("Select two or more pieces to group.")
		return
	_push_undo("")
	var p: Node3D = geometry.group(ps, ps[0].get_meta("tree")["name"] + " group")
	_after_structure([p])

func ungroup_selected() -> void:
	var ps := _pieces_selected()
	if ps.is_empty():
		return
	_push_undo("")
	var out: Array = []
	for p in ps:
		var parts: Array = geometry.ungroup(p)
		if parts.size() > 300:
			log_line("Ungrouped into %d parts." % parts.size())
		out.append_array(parts)
	_after_structure(out)

func duplicate_selected() -> void:
	var ps := _pieces_selected()
	var ls := selection.filter(func(n): return n.has_meta("light"))
	var vs := selection.filter(func(n): return n.has_meta("volume"))
	if ps.is_empty() and ls.is_empty() and vs.is_empty():
		return
	_push_undo("")
	var out: Array = lighting.duplicate_lights(ls) + volumes.duplicate_volumes(vs)
	for p in ps:
		out.append(geometry.duplicate_piece(p, Vector3(2.0, 0, 0)))
	_after_structure(out)
	log_line("Duplicated %d item(s), 2 m along X." % out.size())

func delete_selected() -> void:
	var ps := _pieces_selected()
	var ls := selection.filter(func(n): return n.has_meta("light"))
	# markers placed in the editor (place.gd); the stock ones' counts follow the stock files
	var vs := selection.filter(func(n): return n.has_meta("volume"))
	var ms := selection.filter(func(n): return _is_marker(n) and not n.has_meta("light") and not n.has_meta("volume") and (n.get_meta("data") as Dictionary).get("placed", false))
	var ws := selection.filter(func(n): return _is_wall(n))
	if not ws.is_empty():
		_push_undo("")
		for w in ws:
			geometry.walls_hidden[int(w.get_meta("wall"))] = true
		log_line("%d invisible wall(s) removed (kept out of the export; Restore deleted brings them back)" % ws.size())
		select(selection.filter(func(n): return not _is_wall(n)))
		_on_collision(true)
		if ps.is_empty() and ls.is_empty() and ms.is_empty() and vs.is_empty():
			return
	if ps.is_empty() and ls.is_empty() and ms.is_empty() and vs.is_empty():
		if not selection.is_empty():
			log_line("Only markers placed in the editor can be deleted (the stock ones' counts follow the stock files).")
		return
	_push_undo("")
	lighting.delete_lights(ls)
	volumes.delete_volumes(vs)
	if not ms.is_empty() and set_index >= 0:
		var st: Dictionary = layout["sets"][set_index]
		for n in ms:
			var d: Dictionary = n.get_meta("data")
			for key in ["points", "objects"]:
				var arr: Array = st[key]
				for i in range(arr.size() - 1, -1, -1):
					if is_same(arr[i], d):
						arr.remove_at(i)
		show_set(set_index)
	for p in ps:
		geometry.delete_piece(p)
	_after_structure([])

func reset_selected() -> void:
	var ps := _pieces_selected()
	if ps.is_empty():
		return
	_push_undo("")
	for p in ps:
		var t: Dictionary = p.get_meta("tree")
		var w: Transform3D = p.transform
		for m in geometry.members_of(t):
			if not m["copy"]:
				m["L"] = w.affine_inverse()  # world = identity
		geometry.rebuild(p)
	_after_structure(ps)

func restore_deleted() -> void:
	_push_undo("")
	if not geometry.walls_hidden.is_empty():
		log_line("%d invisible wall(s) back" % geometry.walls_hidden.size())
		geometry.walls_hidden = {}
		if col_toggle.button_pressed:
			_on_collision(true)
	var p: Node3D = geometry.restore_hidden()
	_after_structure([p] if p else [])

func _after_structure(sel: Array) -> void:
	_rebuild_outliner()
	select(sel)
	_update_stats()

func _rebuild_prefabs() -> void:
	browser.refresh_prefabs()

func get_assets() -> void:
	var args := ["get", "--game", game]
	if DirAccess.dir_exists_absolute(lp1_dir):
		args += ["--lp1", lp1_dir]
	log_line("Getting assets from your game installs into %s (the first run takes a few minutes)" % library_dir)
	run_tool("lp2library.py", args + [library_dir], func():
		log_line("%d assets in the library" % library.load_index(library_dir))
		if project_dir != "":
			show_set(set_index)   # markers pick up their models
		browser.refresh_assets())

func toggle_mesh_builder() -> void:
	if mesh_builder.visible:
		mesh_builder.hide()
	else:
		mesh_builder.popup()

func toggle_preview() -> void:
	# walk the map from the spawn point nearest where the view points (else from that point, or below the
	# camera); the editor camera comes back after
	if preview.active():
		preview.end()
		camera.process_mode = Node.PROCESS_MODE_INHERIT
		ui_root.visible = true
		markers_root.visible = true
		set_status("Editing")
		return
	if project_dir == "":
		return
	var mp: Vector2 = get_viewport().get_visible_rect().size / 2
	var hit := _mouse_ray(mp, 1 << (LAYER_STAGE - 1))
	var at: Vector3 = hit["position"] if hit else camera.global_position
	if not hit:
		var down := _ray(at, at + Vector3(0, -2000, 0), 1 << (LAYER_STAGE - 1))
		if down:
			at = down["position"]
	var f := -camera.global_transform.basis.z
	var facing := atan2(-f.x, -f.z)
	var spawn: Variant = _nearest_spawn(at if hit else camera.global_position)
	if spawn != null:
		var p: Array = spawn["pos"]
		at = Vector3(p[0], p[1], p[2]) * CM
		facing = deg_to_rad(float(spawn.get("yaw", 0.0)))
	select([])
	camera.process_mode = Node.PROCESS_MODE_DISABLED
	ui_root.visible = false
	markers_root.visible = false
	preview.begin(at, facing)
	set_status("Preview from %s (Esc back)" % ("spawn " + str(spawn.get("role", "?")) if spawn != null else "the view"))

func _nearest_spawn(from: Vector3) -> Variant:
	# the shown marker set's spawn points, else every set's
	if layout.is_empty():
		return null
	var sets: Array = layout.get("sets", [])
	var pools: Array = []
	if set_index >= 0 and set_index < sets.size():
		pools.append(sets[set_index]["points"])
	var all: Array = []
	for s in sets:
		all.append_array(s.get("points", []))
	pools.append(all)
	for pool in pools:
		var best: Variant = null
		var dist := INF
		for d in pool:
			var p: Array = d["pos"]
			var dd := from.distance_squared_to(Vector3(p[0], p[1], p[2]) * CM)
			if dd < dist:
				dist = dd
				best = d
		if best != null:
			return best
	return null

func toggle_lighting() -> void:
	if lighting.visible:
		lighting.hide()
	else:
		lighting.popup()

func toggle_info() -> void:
	if info_win.visible:
		info_win.hide()
	else:
		info_win.popup()

func toggle_fog() -> void:
	if fog_win.visible:
		fog_win.hide()
	else:
		fog_win.popup()

func toggle_placer() -> void:
	if placer.visible:
		placer.hide()
	else:
		placer.popup()

func toggle_browser() -> void:
	if browser.visible:
		browser.hide()
	else:
		browser.popup()

func _prefab_pick() -> int:
	# the browser's selected prefab (My assets items: ["prefab", index] / folders / meshes)
	var s := prefab_list.get_selected_items()
	var m: Variant = prefab_list.get_item_metadata(s[0]) if s.size() else null
	return m[1] if m is Array and m.size() == 2 and m[0] == "prefab" else -1

func make_prefab() -> void:
	var ps := _pieces_selected()
	if ps.is_empty():
		log_line("Select level geometry first.")
		return
	var pf: Dictionary = geometry.make_prefab(ps, ps[0].get_meta("tree")["name"])
	if browser.folder != "":
		pf["folder"] = browser.folder
	_rebuild_prefabs()
	log_line("Prefab '%s' made from %d piece(s). Place copies from the Browser (B)." % [pf["name"], ps.size()])

func place_prefab(i: int) -> void:
	if i < 0 or i >= geometry.prefabs.size():
		log_line("Pick a prefab first.")
		return
	var mp := get_viewport().get_visible_rect().size / 2
	var hit := _mouse_ray(mp, 1 << (LAYER_STAGE - 1))
	var at: Vector3 = hit["position"] if hit else camera.global_position - camera.global_transform.basis.z * 20.0
	_push_undo("")
	var p: Node3D = geometry.place_prefab(geometry.prefabs[i], at)
	_after_structure([p])

func place_map_piece(key: String, k: int) -> void:
	# a copy of piece k of a library map (Browser > Game assets > LP1 map ...) where the view points
	var mg: Node = library.map_geometry(key)
	if mg == null or project_dir == "":
		return
	var ts: Array = mg.default_trees()
	if k >= ts.size():
		return
	var mp := get_viewport().get_visible_rect().size / 2
	var hit := _mouse_ray(mp, 1 << (LAYER_STAGE - 1))
	var at: Vector3 = hit["position"] if hit else camera.global_position - camera.global_transform.basis.z * 20.0
	_push_undo("")
	var p: Node3D = geometry.place_foreign(library.by_key[key]["map"], ts[k], at)
	_after_structure([p])
	log_line("Placed %s from %s. Its textures add to the map's memory when it is built." % [ts[k]["name"], key])

func delete_prefab() -> void:
	var i := _prefab_pick()
	if i >= 0:
		geometry.prefabs.remove_at(i)
		_rebuild_prefabs()

# ---------------------------------------------------------------- undo

func _snapshot() -> Array:
	return [geometry.snapshot(), layout.duplicate(true), (project.get("environment", {}) as Dictionary).duplicate(true), (project.get("lights", []) as Array).duplicate(true), (project.get("volumes", []) as Array).duplicate(true)]

func _push_undo(key: String) -> void:
	# one entry per action; a run of the same key (typing in the inspector) within 1.5 s is one entry
	var now := Time.get_ticks_msec()
	if key != "" and key == undo_key and now - undo_time < 1500:
		undo_time = now
		return
	undo_key = key
	undo_time = now
	undo_stack.append(_snapshot())
	if undo_stack.size() > 100:
		undo_stack.pop_front()
	redo_stack = []

func _restore(s: Array) -> void:
	var walls_before: Dictionary = geometry.walls_hidden.duplicate()
	geometry.restore(s[0])
	if geometry.walls_hidden != walls_before and col_toggle.button_pressed:
		_on_collision(true)
	layout = s[1]
	project["environment"] = s[2]
	project["lights"] = s[3]
	project["volumes"] = s[4] if s.size() > 4 else []
	for i in visible_sets.size():
		set_pick.set_item_text(i, _set_label(visible_sets[i]))
	show_set(set_index)
	lighting.apply_preview()
	if lighting.visible:
		lighting.refresh()
	fog_win.refresh()
	_after_structure([])

func undo() -> void:
	if undo_stack.is_empty():
		return
	redo_stack.append(_snapshot())
	_restore(undo_stack.pop_back())
	undo_key = ""
	set_status("Undo")

func redo() -> void:
	if redo_stack.is_empty():
		return
	undo_stack.append(_snapshot())
	_restore(redo_stack.pop_back())
	undo_key = ""
	set_status("Redo")

# ---------------------------------------------------------------- performance

func _stats_later() -> void:
	if not stats_dirty:
		stats_dirty = true
		call_deferred("_update_stats")

func _update_stats() -> void:
	stats_dirty = false
	if geometry.data.is_empty():
		return
	var base: Dictionary = geometry.data["stats"]
	var now: Dictionary = geometry.stats()
	var v0 := float(base["vertices"]) * 28.0 + float(base["triangles"]) * 6.0
	var model: float = float(base.get("model_bytes", 0)) * (float(now["vertices"]) * 28.0 + float(now["triangles"]) * 6.0) / max(v0, 1.0)
	var detail: Dictionary = lighting.detail_estimate()   # the lighting detail splits the built stage
	model += float(detail.get("bytes", 0.0))
	var borrowed: Dictionary = geometry.borrowed_textures()
	var btex := 0.0
	for n in borrowed:
		btex += float(borrowed[n])
	var tex := float(base.get("texture_bytes", 0)) + btex
	var stock: Dictionary = base.get("stock", {})
	var target := float(stock.get("rModel", 0)) + float(stock.get("rTexture", 0))
	var total: float = model + tex
	var ratio: float = total / target if target > 0 else 0.0
	perf_button.text = "Memory %.1f / %.1f MB %s" % [total / 1e6, target / 1e6, "▾" if perf_panel.visible else "▸"]
	perf_bar.value = ratio
	perf_bar.modulate = Color(0.4, 0.9, 0.4) if ratio <= 1.0 else Color(1.0, 0.75, 0.2) if ratio <= 1.15 else Color(1.0, 0.3, 0.3)
	perf_bar.tooltip_text = "Stage model + textures against the stock map (Desecration) the package is built on: %d%%" % int(ratio * 100)
	lighting.show_detail(model, total, target)
	if not perf_panel.visible:
		return
	for c in perf_grid.get_children():
		perf_grid.remove_child(c)
		c.queue_free()
	var counts := [0, 0, 0, 0, 0, 0, 0]
	for n in markers_root.get_children():
		counts[_category(n)] += 1
	var rows := [
		["Memory (estimate)", "%.1f MB of %.1f MB (%d%%)" % [total / 1e6, target / 1e6, int(ratio * 100)]],
		["  stage model", "%.1f MB (stock %.1f)" % [model / 1e6, float(stock.get("rModel", 0)) / 1e6]],
		["  lighting detail", "%.1f MB, up to %d vertices" % [float(detail.get("bytes", 0.0)) / 1e6, int(detail.get("added", 0))]],
		["  textures", "%.1f MB, %d (stock %.1f)" % [tex / 1e6, int(base["textures"]) + borrowed.size(), float(stock.get("rTexture", 0)) / 1e6]],
		["  from other maps", "%.1f MB, %d textures" % [btex / 1e6, borrowed.size()]],
		["  collision (stock)", "%.1f MB" % (float(stock.get("rCollision", 0)) / 1e6)],
		["Triangles", "%d (map had %d)" % [now["triangles"], base["triangles"]]],
		["Vertices", "%d" % now["vertices"]],
		["Pieces", "%d" % now["pieces"]],
		["Atoms shown", "%d of %d, %d copies" % [now["atoms"], base["atoms"], now["copies"]]],
		["Deleted originals", "%d" % now["hidden"]],
		["Materials", "%d" % int(base["materials"])],
		["Prefabs", "%d" % geometry.prefabs.size()],
		["Marker set", "%d spawns/logic, %d pickups, %d vehicles" % [counts[0], counts[1], counts[2]]],
		["Marker sets", "%d" % layout.get("sets", []).size()],
	]
	for r in rows:
		perf_grid.add_child(_label(r[0]))
		var l := _label(r[1])
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		perf_grid.add_child(l)

# ---------------------------------------------------------------- input

func _unhandled_input(e: InputEvent) -> void:
	if camera.is_looking() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		camera.stop_look()   # its release went to another window: don't swallow clicks until the next right click
	if camera.is_looking() or preview.active():
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT and e.pressed and e.ctrl_pressed and e.shift_pressed:
		var bh: Dictionary = volumes.face_hit(e.position)   # Ctrl+Shift+right click: delete the volume box under the mouse
		if not bh.is_empty() and volumes.sub_boxes(bh["node"].get_meta("data")).size() > 1:
			_push_undo("")
			volumes.delete_box(bh["node"], bh["box"])
			select([bh["node"]])
			log_line("Removed a box from the volume.")
		elif not bh.is_empty():
			set_status("A volume's only box: delete the volume instead")
		get_viewport().set_input_as_handled()
		return
	# the gizmo and Ctrl+drag on a volume face come before placing (a click elsewhere places)
	var tool_press: bool = e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed \
		and (gizmo.hit(e.position) >= 0 or (e.ctrl_pressed and not volumes.face_hit(e.position).is_empty()))
	if not tool_press and not gizmo.dragging() and face_press.is_empty() and placer.placing() and placer.handle(e):
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			var h: int = gizmo.hit(e.position)
			if h >= 0:
				_push_undo("")
				gizmo.begin(h, e.position)
				drag_start = selection.map(func(n): return n.transform)
				drag_sizes = selection.map(func(n): return (n.get_meta("data")["size"] as Array).duplicate() if n.has_meta("volume") else null)
			elif e.ctrl_pressed and not volumes.face_hit(e.position).is_empty():
				face_press = {"hit": volumes.face_hit(e.position), "at": e.position, "shift": e.shift_pressed}
			else:
				var n := _pick(e.position)
				if e.shift_pressed or e.ctrl_pressed:
					var s := selection.duplicate()
					if n and s.has(n):
						s.erase(n)
					elif n:
						s.append(n)
					select(s)
				else:
					select([n] if n else [])
		elif not face_press.is_empty():
			if volumes.face.is_empty():   # a Ctrl+click, not a drag: add / remove from the selection as before
				var n: Node3D = face_press["hit"]["node"]
				var s := selection.duplicate()
				if s.has(n):
					s.erase(n)
				else:
					s.append(n)
				select(s)
			else:
				volumes.end_face()
				_place_gizmo()
				_update_stats()
			face_press = {}
		elif gizmo.dragging():
			gizmo.end()
			for n in selection:
				if _is_marker(n):
					_store_marker(n)
			_place_gizmo()
			_show_inspector()
			_update_stats()
	elif e is InputEventMouseMotion and not face_press.is_empty():
		if volumes.face.is_empty() and e.position.distance_to(face_press["at"]) > 4.0:
			_push_undo("")
			select([face_press["hit"]["node"]])
			volumes.begin_face(face_press["hit"], face_press["shift"])   # Ctrl+Shift: a new box out of the face
		if not volumes.face.is_empty():
			volumes.drag_face(e.position, snap_toggle.button_pressed or (e.shift_pressed and not face_press["shift"]))
	elif e is InputEventMouseMotion and gizmo.dragging():
		gizmo.snap = snap_toggle.button_pressed or Input.is_key_pressed(KEY_CTRL)
		var delta: Transform3D = gizmo.drag(e.position)
		var local_scale: int = gizmo.scale_axis() if selection.size() == 1 else -1
		for i in selection.size():
			var n: Node3D = selection[i]
			var st: Transform3D = drag_start[i]
			if n.has_meta("volume"):   # boxes: moved, or sized by the scale (never turned or scaled as nodes)
				var d: Dictionary = n.get_meta("data")
				var f := delta.basis.get_scale() if gizmo.mode == 2 else Vector3.ONE
				if gizmo.mode == 2 and absf(st.basis.get_euler().y) > 0.001:
					# a turned box: the world axis dragged sizes its nearest own axis
					var ax := [0, 1, 2]
					var r := st.basis.orthonormalized()
					if absf(r.x.dot(Vector3.RIGHT)) < absf(r.z.dot(Vector3.RIGHT)):
						ax = [2, 1, 0]
					f = Vector3(f[ax[0]], f[1], f[ax[2]])
				d["size"] = [maxf(10.0, drag_sizes[i][0] * f.x), maxf(10.0, drag_sizes[i][1] * f.y), maxf(10.0, drag_sizes[i][2] * f.z)]
				var turned := (delta * st).orthonormalized() if gizmo.mode == 1 else Transform3D(st.basis.orthonormalized(), st.origin)
				n.transform = Transform3D(turned.basis, (delta * st).origin if selection.size() > 1 or gizmo.mode != 2 else st.origin)
				_store_marker(n)
				continue
			if local_scale >= 0 or (gizmo.mode == 2 and gizmo._handle == 3 and selection.size() == 1):
				n.transform = Transform3D(st.basis * delta.basis, st.origin)  # scale along the piece's own axes
			else:
				n.transform = delta * st
			if _is_marker(n):
				_store_marker(n)
		var c := Vector3.ZERO
		for n in selection:
			c += n.global_position
		if gizmo.mode != 1:
			gizmo.global_position = c / selection.size()
		else:
			gizmo.global_position = gizmo._origin
		_show_inspector()
	elif e is InputEventKey and e.pressed and not e.echo:
		var k: int = e.keycode
		if e.ctrl_pressed:
			if k == KEY_S:
				save_project()
			elif k == KEY_Z and not e.shift_pressed:
				undo()
			elif k == KEY_Y or (k == KEY_Z and e.shift_pressed):
				redo()
			elif k == KEY_D:
				duplicate_selected()
			elif k == KEY_G and e.shift_pressed:
				ungroup_selected()
			elif k == KEY_G:
				group_selected()
			return
		match k:
			KEY_W:
				set_tool(0)
			KEY_E:
				set_tool(1)
			KEY_R:
				set_tool(2)
			KEY_F:
				frame_selected()
			KEY_B:
				toggle_browser()
			KEY_M:
				toggle_mesh_builder()
			KEY_L:
				toggle_lighting()
			KEY_T:
				toggle_placer()
			KEY_H:
				toggle_fog()
			KEY_I:
				toggle_info()
			KEY_P:
				toggle_preview()
			KEY_END:
				drop_selected()
			KEY_DELETE:
				delete_selected()
			KEY_ESCAPE:
				if placer.visible:
					placer.hide()
				else:
					select([])
