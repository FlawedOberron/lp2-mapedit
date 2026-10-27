extends Node
# Update check: asks GitHub for the newest lp2-mapedit release and offers its download page when it is newer than
# this one. The running version is version.txt beside the executable (packaging/build.sh writes it); without it
# (run from the Godot editor or run.sh) only a check asked for in Settings runs, and it just reports the newest.
# On start once per run unless switched off in Settings ([updates] check = false); "Skip this version" remembers
# the tag ([updates] skip).

const API := "https://api.github.com/repos/FlawedOberron/lp2-mapedit/releases/latest"

var main: Node
var http: HTTPRequest
var dialog: ConfirmationDialog
var version := ""
var manual := false
var latest_tag := ""
var latest_url := ""

func setup(m: Node) -> void:
	main = m
	var bundle: String = main.bundle_dir()
	if bundle != "" and FileAccess.file_exists(bundle.path_join("version.txt")):
		version = FileAccess.get_file_as_string(bundle.path_join("version.txt")).strip_edges()
	http = HTTPRequest.new()
	http.timeout = 15.0
	http.request_completed.connect(_on_done)
	add_child(http)
	dialog = ConfirmationDialog.new()
	dialog.title = "Update available"
	dialog.ok_button_text = "Download"
	dialog.get_cancel_button().text = "Later"
	dialog.add_button("Skip this version", true, "skip")
	dialog.confirmed.connect(func(): OS.shell_open(latest_url))
	dialog.custom_action.connect(func(_a: StringName):
		main.cfg.set_value("updates", "skip", latest_tag)
		main.cfg.save(main.SETTINGS)
		dialog.hide())
	add_child(dialog)

func enabled() -> bool:
	return main.cfg.get_value("updates", "check", true)

func check_on_start() -> void:
	if version != "" and version != "dev" and enabled():
		_check(false)

func check_now() -> void:
	_check(true)

func _check(asked: bool) -> void:
	manual = asked
	http.cancel_request()
	var err := http.request(API, ["User-Agent: lp2-mapedit", "Accept: application/vnd.github+json"])
	if err != OK and manual:
		main.log_line("Update check failed to start (error %d)" % err)

func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		if manual:
			main.log_line("Update check: no answer from GitHub (%s)" % (("HTTP %d" % code) if result == HTTPRequest.RESULT_SUCCESS else "offline?"))
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY or not data.has("tag_name"):
		return
	latest_tag = data["tag_name"]
	latest_url = data.get("html_url", "https://github.com/FlawedOberron/lp2-mapedit/releases")
	if version == "" or version == "dev":
		if manual:
			main.log_line("Update check: newest release %s (this copy has no version: run from source)" % latest_tag)
		return
	if not newer(latest_tag, version):
		if manual:
			main.log_line("LP2 Map Editor %s is up to date" % version)
		return
	if not manual and main.cfg.get_value("updates", "skip", "") == latest_tag:
		return
	main.log_line("LP2 Map Editor %s is available (this is %s)" % [latest_tag, version])
	dialog.dialog_text = "LP2 Map Editor %s is available (you have %s).\nOpen the download page?" % [latest_tag, version]
	dialog.popup_centered()

static func newer(a: String, b: String) -> bool:
	# "v0.2.0" > "v0.1.3"; numbers compared part by part, anything after '-' ignored
	var pa := _parts(a)
	var pb := _parts(b)
	for i in max(pa.size(), pb.size()):
		var x: int = pa[i] if i < pa.size() else 0
		var y: int = pb[i] if i < pb.size() else 0
		if x != y:
			return x > y
	return false

static func _parts(v: String) -> Array:
	var out: Array = []
	for p in v.trim_prefix("v").get_slice("-", 0).split("."):
		out.append(p.to_int())
	return out
