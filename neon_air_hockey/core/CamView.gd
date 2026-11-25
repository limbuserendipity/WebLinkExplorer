extends Control
## Кадр с вебкамеры с неоновым ретро-фильтром — общий виджет для всех игр.
## Рисует картинку через шейдер core/cam_view.gdshader (тонирование,
## скан-линии, аберрация, виньетка), рамки игроков поверх кадра и подпись
## «ВЫ В КАДРЕ», чтобы люди помнили: камера видит их, а не только игру.
##
## Использование:
##     var cam := preload("res://core/CamView.gd").new()
##     cam.setup(Rect2(1500, 230, 400, 225))
##     add_child(cam)
##     cam.set_feed(bridge.camera_texture, boxes, bridge.frame_age() < 1.5)

const Neo := preload("res://core/Neon.gd")
const SHADER := preload("res://core/cam_view.gdshader")


## Рисует содержимое поверх кадра: так рамки и подписи не попадают под шейдер.
class Overlay extends Control:
	var cam: Control = null

	func _draw() -> void:
		if cam != null:
			cam.draw_overlay(self)


var boxes: Array = []          # [{rect: Rect2 (норм. 0..1), color: Color, label: String}]
var caption := "ВЫ В КАДРЕ"
var subtitle := ""
var fresh := false             # есть ли свежий кадр
var filter_amount := 0.55
var t := 0.0

var _img: TextureRect
var _over: Overlay
var _mat: ShaderMaterial


func setup(r: Rect2) -> void:
	position = r.position
	size = r.size
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("strength", filter_amount)
	_img = TextureRect.new()
	_img.name = "Feed"
	_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_img.set_anchors_preset(Control.PRESET_FULL_RECT)
	_img.material = _mat
	add_child(_img)
	_over = Overlay.new()
	_over.name = "Overlay"
	_over.cam = self
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_over.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_over)


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
		_img.visible = tex != null


## Есть ли у кадра живой неоновый фильтр (шейдер создан и назначен).
func has_filter() -> bool:
	return _mat != null and _mat.shader != null


func set_filter(amount: float) -> void:
	filter_amount = clampf(amount, 0.0, 1.0)
	if _mat != null:
		_mat.set_shader_parameter("strength", filter_amount)


## Всё, что рисуется поверх отфильтрованного кадра.
func draw_overlay(ci: CanvasItem) -> void:
	var r := Rect2(Vector2.ZERO, size)
	# рамка вокруг кадра: внешнее свечение + цветная линия
	ci.draw_rect(r.grow(3.0), Color(Neo.LINE.r, Neo.LINE.g, Neo.LINE.b, 0.10))
	ci.draw_rect(r.grow(1.5), Color(Neo.LINE.r, Neo.LINE.g, Neo.LINE.b, 0.30))
	ci.draw_rect(r, Color(Neo.LEFT.r, Neo.LEFT.g, Neo.LEFT.b, 0.55), false, 2.0)
	# угловые засечки
	var k := minf(18.0, minf(r.size.x, r.size.y) * 0.12)
	var corners := [
		[Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)],
		[Vector2(r.size.x, 0), Vector2(-1, 0), Vector2(0, 1)],
		[Vector2(0, r.size.y), Vector2(1, 0), Vector2(0, -1)],
		[Vector2(r.size.x, r.size.y), Vector2(-1, 0), Vector2(0, -1)],
	]
	for c in corners:
		var p: Vector2 = c[0]
		ci.draw_line(p, p + c[1] * k, Neo.LEFT, 3.0)
		ci.draw_line(p, p + c[2] * k, Neo.LEFT, 3.0)
	for b in boxes:
		var rr: Rect2 = b.get("rect", Rect2())
		if rr.size.x <= 0.001 or rr.size.y <= 0.001:
			continue
		var col: Color = b.get("color", Neo.TEXT)
		var box := Rect2(Vector2(rr.position.x * r.size.x, rr.position.y * r.size.y),
			Vector2(rr.size.x * r.size.x, rr.size.y * r.size.y))
		ci.draw_rect(box.grow(2.0), Color(col.r, col.g, col.b, 0.25), false, 4.0)
		ci.draw_rect(box, col, false, 1.5)
		var label: String = b.get("label", "")
		if label != "":
			Neo.text_left(ci, label, box.position + Vector2(0, -5), 14, col)
	if not fresh:
		ci.draw_rect(r, Color(0.02, 0.0, 0.08, 0.72))
		Neo.text(ci, "НЕТ ВИДЕО", r.size * 0.5 + Vector2(0, -6), 20, Neo.DIM)
		Neo.text(ci, "включите камеру", r.size * 0.5 + Vector2(0, 18), 14,
			Neo.with_alpha(Neo.DIM, 0.7))
		return
	# подпись «ВЫ В КАДРЕ» с пульсирующей точкой
	var strip := Rect2(0, r.size.y - 26.0, r.size.x, 26.0)
	ci.draw_rect(strip, Color(0.02, 0.0, 0.08, 0.62))
	var pulse := 0.55 + 0.45 * sin(t * 3.4)
	var dot := strip.position + Vector2(14.0, 13.0)
	ci.draw_circle(dot, 5.0, Neo.with_alpha(Neo.WARN, 0.25 * pulse))
	ci.draw_circle(dot, 3.0, Neo.with_alpha(Neo.WARN, 0.4 + 0.6 * pulse))
	Neo.text_left(ci, caption, dot + Vector2(11.0, 5.0), 15, Neo.with_alpha(Neo.TEXT, 0.9))
	if subtitle != "":
		var font := ThemeDB.fallback_font
		if font != null:
			var w := font.get_string_size(subtitle, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			Neo.text_left(ci, subtitle, Vector2(r.size.x - w - 12.0, strip.position.y + 18.0),
				14, Neo.with_alpha(Neo.LEFT, 0.85))
