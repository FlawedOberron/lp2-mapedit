extends Window
# New map window: a project from one of Lost Planet 1's maps (lp2project.py import-lp1 --game: its stage, collision,
# physics and layout, converted to explicit LP2 markers), saved in a new folder and opened.

var main: Node
var map_pick: OptionButton
var name_edit: LineEdit
var folder_edit: LineEdit
var note: Label
var browse: FileDialog

func _init() -> void:
	title = "New map from Lost Planet 1"
	size = Vector2i(600, 280)
	min_size = Vector2i(460, 240)
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
	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	_label(g, "LP1 map")
	map_pick = OptionButton.new()
	map_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_pick.item_selected.connect(func(_i): _suggest())
	g.add_child(map_pick)
	_label(g, "Map name")
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Area 921"
	name_edit.text_changed.connect(func(_t): _suggest_folder())
	g.add_child(name_edit)
	_label(g, "Project folder")
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(h)
	folder_edit = LineEdit.new()
	folder_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(folder_edit)
	main._button(h, "Browse...", func():
		browse.current_dir = folder_edit.text.get_base_dir()
		browse.popup_centered_ratio(0.6))
	note = Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	note.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(note)
	var b := HBoxContainer.new()
	b.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(b)
	main._button(b, "Cancel", hide)
	main._button(b, "Create", _on_create)
	browse = FileDialog.new()
	browse.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	browse.access = FileDialog.ACCESS_FILESYSTEM
	browse.use_native_dialog = true
	browse.dir_selected.connect(func(d: String): folder_edit.text = d)
	add_child(browse)

func _label(g: GridContainer, t: String) -> void:
	var l := Label.new()
	l.text = t
	g.add_child(l)

func open() -> void:
	map_pick.clear()
	var dir: String = main.lp1_dir.path_join("nativePC/ZZPack2")
	var arcs: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.to_lower().begins_with("s9") and f.to_lower().ends_with(".arc"):
			arcs.append(f)
	arcs.sort()
	for f in arcs:
		map_pick.add_item(f.get_basename())
		map_pick.set_item_metadata(map_pick.item_count - 1, dir.path_join(f))
	note.text = "" if arcs.size() else "No LP1 maps found: set the Lost Planet 1 folder in Settings first."
	_suggest()
	popup_centered()

func _suggest() -> void:
	if map_pick.item_count:
		name_edit.text = "LP1 " + map_pick.get_item_text(map_pick.selected)
	_suggest_folder()

func _suggest_folder() -> void:
	folder_edit.text = main.maps_dir().path_join(name_edit.text.strip_edges().replace(" ", ""))

func _on_create() -> void:
	if not map_pick.item_count or name_edit.text.strip_edges() == "":
		return
	var out := folder_edit.text.strip_edges()
	if DirAccess.dir_exists_absolute(out) and not (DirAccess.get_files_at(out).is_empty() and DirAccess.get_directories_at(out).is_empty()):
		note.text = "%s has files in it: pick a new or empty folder" % out
		return
	hide()
	main.import_lp1_map(map_pick.get_selected_metadata(), out, name_edit.text.strip_edges())
