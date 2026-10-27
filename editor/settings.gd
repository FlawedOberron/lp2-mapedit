extends Window
# Settings window: the game folders (Lost Planet 2; Lost Planet 1 for importing its maps and its pieces in the
# Browser) and the asset library folder. Opens by itself on the first run, or when the LP2 folder isn't found.
# Steam installs are found by themselves (steamapps/libraryfolders.vdf).
# Also the update check switch (updates.gd) and a check on demand.

var main: Node
var game_edit: LineEdit
var lp1_edit: LineEdit
var library_edit: LineEdit
var note: Label
var update_check: CheckBox
var browse: FileDialog
var browse_target: LineEdit

func _init() -> void:
	title = "Settings"
	size = Vector2i(640, 340)
	min_size = Vector2i(480, 300)
	transient = true
	visible = false
	wrap_controls = true
	close_requested.connect(hide)

func setup(m: Node) -> void:
	main = m
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 10)
	add_child(margin)
	var v := VBoxContainer.new()
	margin.add_child(v)
	game_edit = _row(v, "Lost Planet 2 folder (with LP2DX9.exe)")
	lp1_edit = _row(v, "Lost Planet 1 folder (optional: importing its maps; with nativePC)")
	library_edit = _row(v, "Asset library folder (game models for the editor, built from your installs)")
	var u := HBoxContainer.new()
	v.add_child(u)
	update_check = CheckBox.new()
	update_check.text = "Check for updates on start"
	update_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	u.add_child(update_check)
	main._button(u, "Check now", func(): main.updates.check_now())
	note = Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	note.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(note)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(h)
	main._button(h, "Cancel", hide)
	main._button(h, "Save", _on_save)
	browse = FileDialog.new()
	browse.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	browse.access = FileDialog.ACCESS_FILESYSTEM
	browse.use_native_dialog = true
	browse.dir_selected.connect(func(d: String): browse_target.text = d)
	add_child(browse)

func _row(v: VBoxContainer, label: String) -> LineEdit:
	var l := Label.new()
	l.text = label
	v.add_child(l)
	var h := HBoxContainer.new()
	v.add_child(h)
	var e := LineEdit.new()
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(e)
	main._button(h, "Browse...", func():
		browse_target = e
		browse.current_dir = e.text
		browse.popup_centered_ratio(0.6))
	return e

func open(first_run: bool) -> void:
	game_edit.text = main.game
	lp1_edit.text = main.lp1_dir
	library_edit.text = main.library_dir
	update_check.button_pressed = main.updates.enabled()
	title = "Settings  (LP2 Map Editor %s)" % (main.updates.version if main.updates.version != "" else "dev")
	note.text =("Welcome! Point the editor at your Lost Planet 2 install. The first time, it then copies the game "
		+ "models it needs into the asset library (a few minutes); nothing from the game is changed until you "
		+ "Install a map.") if first_run else ""
	popup_centered()

func _on_save() -> void:
	var g := game_edit.text.strip_edges()
	if not main.is_lp2_folder(g):
		note.text = "No LP2DX9.exe in %s: pick the Lost Planet 2 folder" % g
		return
	var lp1 := lp1_edit.text.strip_edges()
	if lp1 != "" and not DirAccess.dir_exists_absolute(lp1.path_join("nativePC")):
		note.text = "No nativePC folder in %s: pick the Lost Planet 1 folder, or leave it empty" % lp1
		return
	hide()
	main.cfg.set_value("updates", "check", update_check.button_pressed)
	main.set_paths(g, lp1, library_edit.text.strip_edges())
