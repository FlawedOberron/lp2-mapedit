extends VBoxContainer
# Inspector rows for selected VS markers: the variant (LP2 type within the model's family) and the weapon on each
# arm mount the model has. Data: the tools' vs_families.json (lp2vsfamilies.py): families, per type the mounts
# (joints 100-103), the editable arms and the stock loadout. A marker without "weapons" gets its type's stock
# loadout when the map is built (lp2layout.put_weapons); choosing a weapon writes all 4 mounts. Shoulder guns are
# the VS's own (no stock map fits any) and only shown. Changes apply to every selected VS.

const MOUNTS := ["RA", "LA", "RS", "LS"]
const ARM_LABELS := ["Right arm", "Left arm"]
# VS weapon ids (DX9 FUN_008a1980 names, user-confirmed where marked in notes/map-editor-plan.md); the rest unnamed
const WEAPONS := [[0x41, "Gatling"], [0x42, "Laser Rifle"], [0x43, "Rocket Launcher"], [0x44, "Shotgun"],
	[0x45, "Grenade Launcher"], [0x46, "EM Laser"], [0x47, "Homing Laser"], [0x4d, "VS weapon 4D"],
	[0x4e, "Missile Launcher"], [0x50, "VS weapon 50"], [0x60, "Pile Bunker"], [0x61, "Rocket Pod"],
	[0x62, "Laser Lance"], [0x63, "Rifle"], [0x64, "VS weapon 64"], [0x65, "VS weapon 65"], [0x66, "VS weapon 66"],
	[0x67, "VS weapon 67"], [0x68, "VS weapon 68"], [0x69, "VS weapon 69"], [0x6d, "VS weapon 6D"]]

var main: Node
var data := {}            # vs_families.json
var family_of := {}       # type id -> family dictionary
var variant_pick: OptionButton
var arm_picks: Array[OptionButton] = []
var arm_rows: Array[Control] = []
var fixed_label: Label
var _vss: Array = []
var _types: Array = []    # variant_pick index -> type id
var _busy := false

func setup(m: Node) -> void:
	main = m
	var f := FileAccess.open(main.tools.path_join("vs_families.json"), FileAccess.READ)
	if f:
		var j = JSON.parse_string(f.get_as_text())
		if typeof(j) == TYPE_DICTIONARY:
			data = j
	for fam in data.get("families", []):
		for t in fam["types"]:
			family_of[int(t)] = fam
	var vrow := HBoxContainer.new()
	vrow.add_child(main._label("Variant"))
	variant_pick = OptionButton.new()
	variant_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	variant_pick.tooltip_text = "The LP2 VS type within this model's family (faction / stage variants; 0x2X is the set stock online maps use). Applies to every selected VS"
	variant_pick.item_selected.connect(_on_variant)
	vrow.add_child(variant_pick)
	add_child(vrow)
	for k in 2:
		var row := HBoxContainer.new()
		row.add_child(main._label(ARM_LABELS[k]))
		var p := OptionButton.new()
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		p.tooltip_text = "The weapon fitted on this mount. Default: what stock maps fit on this VS type. Applies to every selected VS that has the mount"
		p.item_selected.connect(_on_weapon.bind(k))
		row.add_child(p)
		add_child(row)
		arm_picks.append(p)
		arm_rows.append(row)
	fixed_label = Label.new()
	fixed_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(fixed_label)
	visible = false

func type_info(t: int) -> Dictionary:
	return data.get("types", {}).get("%02x" % t, {})

func weapon_name(id: int) -> String:
	for w in WEAPONS:
		if w[0] == id:
			return w[1]
	return "VS weapon %02X" % id

static func type_of(d: Dictionary) -> int:
	var m := str(d.get("model", ""))
	return m.substr(2).hex_to_int() if m.begins_with("vs") else -1

func refresh(vss: Array) -> void:
	_vss = vss
	visible = not vss.is_empty() and not data.is_empty()
	if not visible:
		return
	_busy = true
	var d0: Dictionary = vss[0].get_meta("data")
	var t0 := type_of(d0)
	var info := type_info(t0)
	var fam: Dictionary = family_of.get(t0, {})
	variant_pick.clear()
	_types = (fam.get("types", [t0]) as Array).map(func(x): return int(x)) if not fam.is_empty() else [t0]   # JSON numbers are floats
	for t in _types:
		var ti := type_info(int(t))
		var stock: int = ti.get("stock", 0)
		variant_pick.add_item("0x%02x  %s%s" % [int(t), ti.get("model", "?"), ("  (stock maps: %d)" % stock) if stock else "  (never in stock maps)"])
	variant_pick.selected = maxi(0, _types.find(t0))
	variant_pick.disabled = _types.size() < 2
	var editable: Array = info.get("editable", [])
	var defaults: Array = info.get("weapons", [])
	var have: Array = d0.get("weapons", [])
	for k in 2:
		var p := arm_picks[k]
		arm_rows[k].visible = MOUNTS[k] in editable
		p.clear()
		var def_id: int = int(defaults[k][1]) if k < defaults.size() and int(defaults[k][0]) else -1
		p.add_item("Default (%s)" % (weapon_name(def_id) if def_id >= 0 else "none"))
		p.add_item("None")
		for w in WEAPONS:
			p.add_item("%s  [%02X]" % [w[1], w[0]])
		if have.size() > k:
			p.selected = 1 if not int(have[k][0]) else 2 + maxi(0, WEAPONS.find_custom(func(w): return w[0] == int(have[k][1])))
		else:
			p.selected = 0
	var fixed: Array = []
	for m in info.get("mounts", []):
		if m in ["RS", "LS"]:
			fixed.append("right shoulder" if m == "RS" else "left shoulder")
	var builtin := editable.is_empty() and defaults.any(func(w): return int(w[0]) != 0)
	fixed_label.text = ("Built-in: " + ", ".join(fixed) if not fixed.is_empty() else "") + \
		("Weapons: built into this VS" if builtin else "") + ("No weapon mounts" if editable.is_empty() and not builtin and fixed.is_empty() else "")
	fixed_label.visible = fixed_label.text != ""
	_busy = false

func _on_variant(i: int) -> void:
	if _busy or i >= _types.size():
		return
	main._push_undo("")
	for n in _vss:
		var d: Dictionary = n.get_meta("data")
		d["model"] = "vs%02x" % int(_types[i])
		d.erase("weapons")   # the new type's mounts differ: back to its stock loadout
		main.refresh_marker(n)
	refresh(_vss)

func _on_weapon(i: int, k: int) -> void:
	if _busy:
		return
	main._push_undo("")
	for n in _vss:
		var d: Dictionary = n.get_meta("data")
		if not MOUNTS[k] in type_info(type_of(d)).get("editable", []):
			continue
		if i == 0 and not d.has("weapons"):
			continue
		var w: Array = d.get("weapons", type_info(type_of(d)).get("weapons", [[0, 0x41], [0, 0x41], [0, 0x41], [0, 0x41]])).duplicate(true)
		if i == 0:
			w[k] = type_info(type_of(d)).get("weapons", w)[k].duplicate()
		elif i == 1:
			w[k] = [0, 0x41]
		else:
			w[k] = [1, WEAPONS[i - 2][0]]
		d["weapons"] = w
	refresh(_vss)
