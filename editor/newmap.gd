extends Window
# Import map window: a new map (.lpme) from one of Lost Planet 1's maps (lp2project.py import-lp1 --game: its stage,
# collision, physics and layout, converted to explicit LP2 markers) or one of Lost Planet 2's online maps
# (lp2project.py import-lp2), saved and opened.

var main: Node
var source_pick: OptionButton
var map_pick: OptionButton
var name_edit: LineEdit
var folder_edit: LineEdit
var note: Label
var browse: FileDialog

func _init() -> void:
	title = "Import map from Lost Planet 1 / 2"
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
	_label(g, "From")
	source_pick = OptionButton.new()
	source_pick.add_item("Lost Planet 1 (Extreme Condition)")
	source_pick.add_item("Lost Planet 2")
	source_pick.item_selected.connect(func(_i): _list_maps())
	g.add_child(source_pick)
	_label(g, "Map")
	map_pick = OptionButton.new()
	map_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_pick.item_selected.connect(func(_i): _suggest())
	g.add_child(map_pick)
	_label(g, "Map name")
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Area 921"
	name_edit.text_changed.connect(func(_t): _suggest_folder())
	g.add_child(name_edit)
	_label(g, "Save as")
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(h)
	folder_edit = LineEdit.new()
	folder_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(folder_edit)
	main._button(h, "Browse...", func():
		browse.current_dir = folder_edit.text.get_base_dir()
		browse.current_file = folder_edit.text.get_file()
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
	browse.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	browse.access = FileDialog.ACCESS_FILESYSTEM
	browse.filters = PackedStringArray(["*.lpme ; LP2 map"])
	browse.use_native_dialog = true
	browse.file_selected.connect(func(f: String): folder_edit.text = f if f.get_extension().to_lower() == "lpme" else f + ".lpme")
	add_child(browse)

func _label(g: GridContainer, t: String) -> void:
	var l := Label.new()
	l.text = t
	g.add_child(l)

func open() -> void:
	_list_maps()
	popup_centered()

func _lp2() -> bool:
	return source_pick.selected == 1

func _list_maps() -> void:
	map_pick.clear()
	note.text = ""
	if _lp2():
		if not main.is_lp2_folder(main.game):
			note.text = "Set the Lost Planet 2 folder in Settings first."
		for k in main.lighting.MAP_NAMES:
			map_pick.add_item("%s (online %s)" % [main.lighting.MAP_NAMES[k], k])
			map_pick.set_item_metadata(map_pick.item_count - 1, int(k))
	else:
		var dir: String = main.lp1_dir.path_join("nativePC/ZZPack2")
		var arcs: Array = []
		for f in DirAccess.get_files_at(dir):
			if f.to_lower().begins_with("s9") and f.to_lower().ends_with(".arc"):
				arcs.append(f)
		arcs.sort()
		for f in arcs:
			map_pick.add_item(f.get_basename())
			map_pick.set_item_metadata(map_pick.item_count - 1, dir.path_join(f))
		if arcs.is_empty():
			note.text = "No LP1 maps found: set the Lost Planet 1 folder in Settings first."
	_suggest()

func _suggest() -> void:
	if map_pick.item_count:
		var t := map_pick.get_item_text(map_pick.selected)
		name_edit.text = t.get_slice(" (online", 0) + " (edit)" if _lp2() else "LP1 " + t
	_suggest_folder()

func _suggest_folder() -> void:
	folder_edit.text = main.maps_dir().path_join(name_edit.text.strip_edges().validate_filename().replace(" ", "") + ".lpme")

func _on_create() -> void:
	if not map_pick.item_count or name_edit.text.strip_edges() == "":
		return
	var out := folder_edit.text.strip_edges()
	if out.get_extension().to_lower() != "lpme":
		out += ".lpme"
	if FileAccess.file_exists(out):
		note.text = "%s already exists: pick another name" % out.get_file()
		return
	hide()
	if _lp2():
		main.import_lp2_map(map_pick.get_selected_metadata(), out, name_edit.text.strip_edges())
	else:
		main.import_lp1_map(map_pick.get_selected_metadata(), out, name_edit.text.strip_edges())
