extends RefCounted
## Подсказка «близко — лицом, далеко — рукой»: два пиктограммных ряда,
## активный источник подсвечен. Рисуется в меню и во всех играх, чтобы
## человек сразу видел, чем он управляет сейчас и почему.

const Neo := preload("res://core/Neon.gd")


## r — прямоугольник панели, active — "face" | "hand" (текущий источник),
## t — время для пульса. compact — узкий вариант (меньше отступы и шрифт).
static func draw(ci: CanvasItem, r: Rect2, active: String, t: float, compact := false) -> void:
	Neo.box(ci, r, Neo.with_alpha(Neo.LINE, 0.55), 1.5, Color(0.02, 0.0, 0.08, 0.78))
	var head_size := 18 if compact else 24
	var title := "КАК УПРАВЛЯТЬ"
	Neo.text_left(ci, title, r.position + Vector2(16, head_size + 6), head_size,
		Neo.with_alpha(Neo.DIM, 0.95))
	# чип «сейчас»
	var now_txt := "сейчас: рука" if active == "hand" else "сейчас: лицо"
	var font := ThemeDB.fallback_font
	if font != null:
		var chip_size := 14 if compact else 16
		var w := font.get_string_size(now_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, chip_size).x + 22.0
		var chip := Rect2(r.end.x - w - 14.0, r.position.y + 8.0, w, chip_size + 12.0)
		var col := Neo.RIGHT if active == "hand" else Neo.LEFT
		ci.draw_rect(chip, Neo.with_alpha(col, 0.16))
		Neo.box(ci, chip, Neo.with_alpha(col, 0.85), 1.0)
		Neo.text(ci, now_txt, chip.position + Vector2(chip.size.x * 0.5, chip_size + 3.0),
			chip_size, col)

	var top := r.position.y + head_size + (16.0 if compact else 20.0)
	var avail := r.end.y - top - 8.0
	var row_h := avail * 0.5
	var face_on := active != "hand"
	_row(ci, Rect2(r.position.x + 10.0, top, r.size.x - 20.0, row_h - 4.0), "face", face_on,
		"БЛИЗКО — ЛИЦОМ", "поворачивайте голову — курсор идёт за носом", t, compact)
	_row(ci, Rect2(r.position.x + 10.0, top + row_h, r.size.x - 20.0, row_h - 4.0), "hand",
		active == "hand", "ДАЛЕКО — РУКОЙ", "поднимите руку и ведите ей — курсор за ладонью",
		t, compact)


static func _row(ci: CanvasItem, r: Rect2, kind: String, on: bool, title: String,
		sub: String, t: float, compact: bool) -> void:
	var col := Neo.LEFT if kind == "face" else Neo.RIGHT
	var a := 1.0 if on else 0.32
	if on:
		var pulse := 0.5 + 0.5 * sin(t * 2.6)
		ci.draw_rect(r, Neo.with_alpha(col, 0.10 + 0.06 * pulse))
		Neo.box(ci, r, Neo.with_alpha(col, 0.9), 1.5)
	else:
		Neo.box(ci, r, Neo.with_alpha(Neo.DIM, 0.22), 1.0)
	var sz := minf(r.size.y - 6.0, 26.0 if compact else 56.0)
	var show_sub := r.size.y > 44.0
	var c := Vector2(r.position.x + sz * 0.5 + 10.0, r.position.y + r.size.y * 0.5)
	if kind == "face":
		_glyph_face(ci, c, sz * 0.5, Neo.with_alpha(col, a), t if on else 0.0)
	else:
		_glyph_hand(ci, c, sz * 0.5, Neo.with_alpha(col, a), t if on else 0.0)
	var tx := r.position.x + sz + 16.0
	var tsize := 14 if compact else 20
	var ssize := 13 if compact else 15
	var ty := r.position.y + r.size.y * 0.5 - 2.0
	if show_sub:
		ty = r.position.y + r.size.y * 0.5 - 4.0
	Neo.text_left(ci, title, Vector2(tx, ty), tsize,
		Neo.with_alpha(Neo.TEXT if on else Neo.DIM, 0.55 + 0.45 * a))
	if show_sub:
		Neo.text_left(ci, sub, Vector2(tx, ty + ssize + 6.0), ssize,
			Neo.with_alpha(Neo.DIM, 0.5 + 0.5 * a))


## Пиктограмма лица: круг, глаза, нос и стрелки в стороны.
static func _glyph_face(ci: CanvasItem, c: Vector2, rad: float, col: Color, t: float) -> void:
	ci.draw_circle(c, rad, Neo.with_alpha(col, col.a * 0.12))
	ci.draw_arc(c, rad, 0.0, TAU, 40, col, 2.0, true)
	var eye := rad * 0.45
	ci.draw_circle(c + Vector2(-rad * 0.34, -rad * 0.18), eye * 0.28, col)
	ci.draw_circle(c + Vector2(rad * 0.34, -rad * 0.18), eye * 0.28, col)
	var nose := c + Vector2(0, rad * 0.34)
	ci.draw_line(c + Vector2(0, -rad * 0.05), nose, Neo.with_alpha(col, col.a * 0.8), 2.0)
	ci.draw_circle(nose, rad * 0.11, col)
	var k := (0.6 + 0.4 * sin(t * 2.6)) if t > 0.0 else 0.4
	# нос «водит» в сторону — маленькая стрелка
	var dx := (sin(t * 1.9) * rad * 0.35) if t > 0.0 else 0.0
	ci.draw_line(nose, nose + Vector2(dx, rad * 0.3), Neo.with_alpha(col, 0.5 * k), 1.5)


## Пиктограмма руки: ладонь с четырьмя пальцами и большим пальцем.
static func _glyph_hand(ci: CanvasItem, c: Vector2, rad: float, col: Color, t: float) -> void:
	var w := rad * 1.05
	var h := rad * 0.95
	var palm := Rect2(c + Vector2(-w * 0.5, -h * 0.05), Vector2(w, h * 0.95))
	ci.draw_rect(palm, Neo.with_alpha(col, col.a * 0.18))
	ci.draw_rect(palm, col, false, 2.0)
	var sway := (sin(t * 2.2) * rad * 0.10) if t > 0.0 else 0.0
	for i in 4:
		var fx := palm.position.x + w * (0.12 + 0.25 * i)
		var fh := h * (0.55 - absf(1.5 - i) * 0.10)
		ci.draw_line(Vector2(fx + sway, palm.position.y - fh), Vector2(fx + sway, palm.position.y),
			col, 3.0)
	ci.draw_line(palm.position + Vector2(-w * 0.02, h * 0.35),
		palm.position + Vector2(-w * 0.42, h * 0.10), col, 3.0)
