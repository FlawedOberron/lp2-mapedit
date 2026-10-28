extends Control
# Tone curve editor for the Lighting window's colour grading: the game's ColorCorrectFilter curves, 4 points per
# channel (input x -> output y, both 0..1; lp2light.py writes them as mToneCurveR/G/B). Drag a point of the
# channel picked with set_channel ("All" moves the same point of R, G and B together). Emits edited while dragging
# (the viewport preview follows) and changed after a drag.

signal changed
signal edited

const COLOURS := {"R": Color(1, 0.35, 0.35), "G": Color(0.35, 0.9, 0.35), "B": Color(0.4, 0.55, 1)}
const PAD := 8.0
const GRAB := 10.0

var curves := {}          # R / G / B -> [[x0..x3], [y0..y3]]
var channel := "All"
var _drag := -1           # point index being dragged

func _init() -> void:
	custom_minimum_size = Vector2(0, 200)
	mouse_filter = Control.MOUSE_FILTER_STOP

func set_curves(c: Dictionary) -> void:
	curves = c.duplicate(true)
	queue_redraw()

func set_channel(ch: String) -> void:
	channel = ch
	queue_redraw()

func _box() -> Rect2:
	var s := minf(size.x, size.y) - 2 * PAD
	return Rect2(Vector2((size.x - s) / 2, PAD), Vector2(s, s))

func _to_screen(x: float, y: float) -> Vector2:
	var r := _box()
	return r.position + Vector2(x * r.size.x, (1.0 - y) * r.size.y)

func _channels() -> Array:
	return ["R", "G", "B"] if channel == "All" else [channel]

func _draw() -> void:
	var r := _box()
	draw_rect(r, Color(0.1, 0.1, 0.1))
	for i in range(1, 4):
		var f := i / 4.0
		draw_line(r.position + Vector2(f * r.size.x, 0), r.position + Vector2(f * r.size.x, r.size.y), Color(1, 1, 1, 0.08))
		draw_line(r.position + Vector2(0, f * r.size.y), r.position + Vector2(r.size.x, f * r.size.y), Color(1, 1, 1, 0.08))
	draw_line(_to_screen(0, 0), _to_screen(1, 1), Color(1, 1, 1, 0.2))
	for ch in ["R", "G", "B"]:
		if not curves.has(ch):
			continue
		var xs: Array = curves[ch][0]
		var ys: Array = curves[ch][1]
		var active: bool = ch in _channels()
		var col: Color = COLOURS[ch] if active else COLOURS[ch] * Color(1, 1, 1, 0.35)
		var pts := PackedVector2Array([_to_screen(0, 0)])
		for i in 4:
			pts.append(_to_screen(float(xs[i]), float(ys[i])))
		pts.append(_to_screen(1, 1))   # on to white past the last point (Desecration's R ends at .73 -> .75 and looks right)
		draw_polyline(pts, col, 2.0 if active else 1.0, true)
		if active:
			for i in 4:
				draw_circle(_to_screen(float(xs[i]), float(ys[i])), 4.0, col)

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			_drag = _nearest(ev.position)
		elif _drag >= 0:
			_drag = -1
			changed.emit()
		accept_event()
	elif ev is InputEventMouseMotion and _drag >= 0:
		var r := _box()
		var p: Vector2 = (ev.position - r.position) / r.size
		for ch in _channels():
			var xs: Array = curves[ch][0]
			var lo: float = 0.0 if _drag == 0 else float(xs[_drag - 1]) + 0.01
			var hi: float = 1.0 if _drag == 3 else float(xs[_drag + 1]) - 0.01
			xs[_drag] = snappedf(clampf(p.x, lo, hi), 0.001)
			curves[ch][1][_drag] = snappedf(clampf(1.0 - p.y, 0.0, 1.0), 0.001)
		queue_redraw()
		edited.emit()
		accept_event()

static func value_at(curve: Array, t: float) -> float:
	# piecewise linear through (0, 0), the 4 points and (1, 1), as drawn
	var xs := [0.0]
	var ys := [0.0]
	for i in 4:
		xs.append(float(curve[0][i]))
		ys.append(float(curve[1][i]))
	xs.append(1.0)
	ys.append(1.0)
	for i in range(1, xs.size()):
		if t <= xs[i]:
			var span: float = xs[i] - xs[i - 1]
			return ys[i] if span <= 0.0 else lerpf(ys[i - 1], ys[i], (t - xs[i - 1]) / span)
	return 1.0

static func lut(c: Dictionary) -> GradientTexture1D:
	# a 1D colour-correction table for the viewport's Environment (each channel looked up on its own)
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var colours := PackedColorArray()
	for i in 65:
		var t := i / 64.0
		offsets.append(t)
		colours.append(Color(value_at(c["R"], t), value_at(c["G"], t), value_at(c["B"], t)))
	g.offsets = offsets
	g.colors = colours
	var tex := GradientTexture1D.new()
	tex.gradient = g
	tex.width = 256
	return tex

func _nearest(at: Vector2) -> int:
	var best := -1
	var dist := GRAB
	for ch in _channels():
		for i in 4:
			var d := at.distance_to(_to_screen(float(curves[ch][0][i]), float(curves[ch][1][i])))
			if d < dist:
				dist = d
				best = i
	return best
