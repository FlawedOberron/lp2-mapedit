extends RefCounted
# .lpme map files: a zip of the project folder (project.json, layout.json, geometry.json, thumbnail.png, assets/).
# The editor and the tools work on an unpacked copy, the file's workspace (user://work/<name>-<path hash>), kept
# between sessions with its preview cache (.preview/) and last package (build/); every save packs it back.

const SKIP := [".preview", "build", ".lpme"]   # never packed (.lpme: the workspace's stamp of the file it holds)

static func workspace(file: String) -> String:
	var name := file.get_file().get_basename().validate_filename()
	return ProjectSettings.globalize_path("user://work").path_join("%s-%s" % [name, file.simplify_path().md5_text().substr(0, 8)])

static func _stamp(file: String) -> String:
	var f := FileAccess.open(file, FileAccess.READ)
	return "%d %d" % [FileAccess.get_modified_time(file), f.get_length() if f else -1]

static func _write_stamp(ws: String, file: String) -> void:
	var f := FileAccess.open(ws.path_join(".lpme"), FileAccess.WRITE)
	if f:
		f.store_string(_stamp(file))

static func clear(ws: String, keep_cache := true) -> void:
	# the workspace's project files away (keep_cache: its .preview / build stay)
	var d := DirAccess.open(ws)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		if not (keep_cache and sub in SKIP):
			_remove_tree(ws.path_join(sub))

static func _remove_tree(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_remove_tree(dir.path_join(sub))
	DirAccess.remove_absolute(dir)

static func unpack(file: String) -> String:
	# -> the file's workspace, unpacked (as it is when it already holds this version of the file); "" if it's no map
	var ws := workspace(file)
	if FileAccess.get_file_as_string(ws.path_join(".lpme")) == _stamp(file) and FileAccess.file_exists(ws.path_join("project.json")):
		return ws
	var z := ZIPReader.new()
	if z.open(file) != OK:
		return ""
	var names := z.get_files()
	if not names.has("project.json"):
		z.close()
		return ""
	DirAccess.make_dir_recursive_absolute(ws)
	clear(ws)
	for n in names:
		var rel := n.simplify_path()
		if n.ends_with("/") or rel.begins_with("..") or rel.is_absolute_path() or rel.get_slice("/", 0) in SKIP:
			continue
		var out := ws.path_join(rel)
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var w := FileAccess.open(out, FileAccess.WRITE)
		if w == null:
			z.close()
			return ""
		w.store_buffer(z.read_file(n))
		w.close()
	z.close()
	_write_stamp(ws, file)
	return ws

static func pack(ws: String, file: String) -> Error:
	# the workspace into the file (written beside it first, then swapped in)
	var tmp := file + ".tmp"
	var z := ZIPPacker.new()
	var err := z.open(tmp)
	if err != OK:
		return err
	err = _add(z, ws, "")
	z.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return err
	if FileAccess.file_exists(file):
		DirAccess.remove_absolute(file)
	err = DirAccess.rename_absolute(tmp, file)
	if err == OK:
		_write_stamp(ws, file)
	return err

static func _add(z: ZIPPacker, dir: String, rel: String) -> Error:
	var d := DirAccess.open(dir)
	if d == null:
		return ERR_CANT_OPEN
	d.include_hidden = true
	for f in d.get_files():
		if rel == "" and f in SKIP:
			continue
		var data := FileAccess.get_file_as_bytes(dir.path_join(f))
		if z.start_file(rel + f) != OK or z.write_file(data) != OK:
			return ERR_FILE_CANT_WRITE
		z.close_file()
	for sub in d.get_directories():
		if rel == "" and sub in SKIP:
			continue
		var err := _add(z, dir.path_join(sub), rel + sub + "/")
		if err != OK:
			return err
	return OK
