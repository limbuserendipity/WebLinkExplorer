extends Control
## Кадр с вебкамеры в единой панели: подпись «КАМЕРА», рамка 16:9 по сетке
## (core/Layout.gd), неоновый ретро-фильтр (core/cam_view.gdshader), рамки
## найденных игроков и подпись «ВЫ В КАДРЕ» с источником ввода.
##
##     var cam := preload("res://core/CamView.gd").new()
##     add_child(cam)
##     cam.setup(Layout.TRON_CAM)              # прямоугольник панели из Layout
##     cam.set_feed(bridge.camera_texture, boxes, bridge.frame_age() < 1.5)

const Neo := preload("res://core/Neon.gd")
const Lay := preload("res://core/Layout.gd")
const SHADER := preload("res://core/cam_view.gdshader")


class Overlay extends Control:
	var cam: Control = null

	func _draw() -> void:
		if cam != null:
			cam.draw_overlay(self)


var panel := Rect2(0.0, 0.0, 344.0, 238.0)   # панель целиком (с подписью)
var frame := Rect2(0.0, 0.0, 312.0, 176.0)   # окно кадра внутри панели
var boxes: Array = []                        # [{rect: Rect2 (0..1), color: Color, label: String}]
var caption := "ВЫ В КАДРЕ"
var subtitle := ""                           # например «ввод: лицо»
var fresh := false
var filter_amount := 0.55
var t := 0.0

var _img: TextureRect
var _over: Overlay
var _mat: ShaderMaterial


func setup(r: Rect2) -> void:
	panel = r
	frame = Lay.cam_frame(r)
	_apply_geometry()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("strength", filter_amount)
	_img = TextureRect.new()
	_img.name = "Feed"
	_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_img.material = _mat
	_img.visible = false
	add_child(_img)
	_over = Overlay.new()
	_over.name = "Overlay"
	_over.cam = self
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_over.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_over)
	_apply_geometry()


func _apply_geometry() -> void:
	if _img == null:
		return
	_img.position = frame.position
	_img.size = frame.size


func _process(dt: float) -> void:
	t += dt
	if _mat != null:
		_mat.set_shader_parameter("time_s", t)
	if _over != null:
		_over.queue_redraw()


func set_feed(tex: Texture2D, new_boxes: Array, is_fresh: bool) -> void:
	boxes = new_boxes
	fresh = is_fresh
	if _img != null:
		_img.texture = tex
		_img.visible = tex != null and is_fresh


func has_filter() -> bool:
	return _mat != null and _mat.shader != null


func set_filter(amount: float) -> void:
	filter_amount = clampf(amount, 0.0, 1.0)
	if _mat != null:
		_mat.set_shader_parameter("strength", filter_amount)


## Панель, окно кадра, рамки игроков и подпись — всё поверх игры.
func draw_overlay(ci: CanvasItem) -> void:
	Lay.panel(ci, panel, "камера")
	var r := frame
	ci.draw_rect(r, Color(0.02, 0.0, 0.08, 0.9))
	if not fresh:
		Neo.text(ci, "НЕТ ВИДЕО", r.get_center() + Vector2(0.0, -4.0), Lay.T_BODY, Neo.DIM)
		Neo.text(ci, "включите камеру", r.get_center() + Vector2(0.0, 22.0), Lay.T_TINY,
			Neo.with_alpha(Neo.DIM, 0.7))
		ci.draw_rect(r, Neo.with_alpha(Neo.LEFT, 0.35), false, 1.5)
		return
	for b in boxes:
		var rr: Rect2 = b.get("rect", Rect2())
		if rr.size.x <= 0.001 or rr.size.y <= 0.001:
			continue
		var col: Color = b.get("color", Neo.TEXT)
		var box := Rect2(r.position + Vector2(rr.position.x * r.size.x, rr.position.y * r.size.y),
			Vector2(rr.size.x * r.size.x, rr.size.y * r.size.y))
		ci.draw_rect(box.grow(2.0), Color(col.r, col.g, col.b, 0.25), false, 4.0)
		ci.draw_rect(box, col, false, 1.5)
	# засечки по углам кадра
	var k := 16.0
	for c in [[r.position, Vector2(1, 1)], [Vector2(r.end.x, r.position.y), Vector2(-1, 1)],
			[Vector2(r.position.x, r.end.y), Vector2(1, -1)], [r.end, Vector2(-1, -1)]]:
		var p: Vector2 = c[0]
		var d: Vector2 = c[1]
		ci.draw_line(p, p + Vector2(k * d.x, 0.0), Neo.LEFT, 2.0)
		ci.draw_line(p, p + Vector2(0.0, k * d.y), Neo.LEFT, 2.0)
	# подпись внутри кадра
	var strip := Rect2(r.position.x, r.end.y - 26.0, r.size.x, 26.0)
	ci.draw_rect(strip, Color(0.02, 0.0, 0.08, 0.66))
	var pulse := 0.55 + 0.45 * sin(t * 3.4)
	var dot := strip.position + Vector2(12.0, 13.0)
	ci.draw_circle(dot, 5.0, Neo.with_alpha(Neo.WARN, 0.25 * pulse))
	ci.draw_circle(dot, 3.0, Neo.with_alpha(Neo.WARN, 0.4 + 0.6 * pulse))
	Neo.text_left(ci, caption, dot + Vector2(10.0, 5.0), Lay.T_TINY, Neo.with_alpha(Neo.TEXT, 0.9))
	if subtitle != "":
		var font := ThemeDB.fallback_font
		if font != null:
			var w := font.get_string_size(subtitle, HORIZONTAL_ALIGNMENT_LEFT, -1, Lay.T_TINY).x
			Neo.text_left(ci, subtitle, Vector2(strip.end.x - w - 10.0, dot.y + 5.0), Lay.T_TINY,
				Neo.with_alpha(Neo.LEFT, 0.9))
	ci.draw_rect(r, Neo.with_alpha(Neo.LEFT, 0.5), false, 1.5)
