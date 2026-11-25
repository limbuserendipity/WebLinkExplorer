extends RefCounted
## Подсказка «близко — лицом, далеко — рукой»: одна панель по сетке
## (core/Layout.gd) с двумя строками — лицо и рука. Активный источник
## подсвечен, рядом чип «сейчас: лицо / рука».
##
## Раскладка подстраивается под панель:
##   высокая и широкая  — значок слева, название и пояснение справа;
##   узкая              — значок сверху, название под ним;
##   низкая             — одна строка: значок и название.

const Neo := preload("res://core/Neon.gd")
const Lay := preload("res://core/Layout.gd")

const TITLES := ["БЛИЗКО — ЛИЦОМ", "ДАЛЕКО — РУКОЙ"]
const SUBS := ["поворачивайте голову — курсор идёт за носом",
	"поднимите руку и ведите ей — курсор за ладонью"]


static func draw(ci: CanvasItem, r: Rect2, active := "face", t := 0.0) -> void:
	Lay.panel(ci, r, "как управлять")
	var b := Lay.body(r)
	_mode_chip(ci, r, active)
	var gap := 8.0
	var row_h := (b.size.y - gap) * 0.5
	if row_h < 8.0:
		return
	var stacked: bool = b.size.x < 330.0 and row_h >= 52.0
	var compact: bool = row_h < 52.0
	for i in 2:
		var rr := Rect2(b.position.x, b.position.y + float(i) * (row_h + gap), b.size.x, row_h)
		var on: bool = (i == 1) == (active == "hand")
		_row(ci, rr, i, on, stacked, compact, t if on else 0.0)


static func _mode_chip(ci: CanvasItem, r: Rect2, active: String) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var col: Color = Neo.RIGHT if active == "hand" else Neo.LEFT
	var txt := "сейчас: рука" if active == "hand" else "сейчас: лицо"
	var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, Lay.T_TINY).x + 20.0
	var chip := Rect2(r.end.x - Lay.PAD - w, r.position.y + Lay.PAD - 2.0, w, Lay.T_TINY + 12.0)
	ci.draw_rect(chip, Neo.with_alpha(col, 0.14))
	ci.draw_rect(chip, Neo.with_alpha(col, 0.8), false, 1.0)
	Neo.text(ci, txt, Vector2(chip.position.x + chip.size.x * 0.5,
		chip.position.y + chip.size.y - 4.0), Lay.T_TINY, col)


static func _row(ci: CanvasItem, r: Rect2, kind: int, on: bool, stacked: bool,
		compact: bool, t: float) -> void:
	var col: Color = Neo.LEFT if kind == 0 else Neo.RIGHT
	var a := 1.0 if on else 0.30
	if on:
		var pulse := 0.5 + 0.5 * sin(t * 2.6)
		ci.draw_rect(r, Neo.with_alpha(col, 0.10 + 0.06 * pulse))
		ci.draw_rect(r, Neo.with_alpha(col, 0.9), false, 1.5)
	else:
		ci.draw_rect(r, Neo.with_alpha(Neo.DIM, 0.18), false, 1.0)
	var title_col: Color = Neo.with_alpha(Neo.TEXT if on else Neo.DIM, 0.55 + 0.45 * a)
	if compact:
		var sz := minf(r.size.y - 8.0, 26.0)
		var c := Vector2(r.position.x + 14.0 + sz * 0.5, r.position.y + r.size.y * 0.5)
		if kind == 0:
			_glyph_face(ci, c, sz * 0.5, Neo.with_alpha(col, a), t)
		else:
			_glyph_hand(ci, c, sz * 0.5, Neo.with_alpha(col, a), t)
		Neo.text_left(ci, TITLES[kind], Vector2(c.x + sz * 0.5 + 10.0,
			r.position.y + r.size.y * 0.5 + 6.0), Lay.T_SMALL, title_col)
		return
	if stacked:
		# Значок сверху, подпись под ним — вся группа по центру строки.
		var sz2 := minf(r.size.y * 0.45, 38.0)
		var block := sz2 + 10.0 + float(Lay.T_SMALL)
		var top := r.position.y + (r.size.y - block) * 0.5
		var c2 := Vector2(r.position.x + r.size.x * 0.5, top + sz2 * 0.5)
		if kind == 0:
			_glyph_face(ci, c2, sz2 * 0.5, Neo.with_alpha(col, a), t)
		else:
			_glyph_hand(ci, c2, sz2 * 0.5, Neo.with_alpha(col, a), t)
		Neo.text(ci, TITLES[kind], Vector2(r.position.x + r.size.x * 0.5,
			top + sz2 + 10.0 + float(Lay.T_SMALL) - 4.0), Lay.T_SMALL, title_col)
		return
	var sz3 := minf(r.size.y - 12.0, 48.0)
	var c3 := Vector2(r.position.x + 12.0 + sz3 * 0.5, r.position.y + r.size.y * 0.5)
	if kind == 0:
		_glyph_face(ci, c3, sz3 * 0.5, Neo.with_alpha(col, a), t)
	else:
		_glyph_hand(ci, c3, sz3 * 0.5, Neo.with_alpha(col, a), t)
	var tx := c3.x + sz3 * 0.5 + 12.0
	var mid := r.position.y + r.size.y * 0.5
	Neo.text_left(ci, TITLES[kind], Vector2(tx, mid - 2.0), Lay.T_SMALL, title_col)
	if r.size.y > 62.0:
		Neo.text_left(ci, SUBS[kind], Vector2(tx, mid + 18.0), Lay.T_TINY,
			Neo.with_alpha(Neo.DIM, 0.5 + 0.5 * a))


## Пиктограмма лица: круг, глаза, нос и стрелка от носа.
static func _glyph_face(ci: CanvasItem, c: Vector2, rad: float, col: Color, t: float) -> void:
	ci.draw_circle(c, rad, Neo.with_alpha(col, col.a * 0.12))
	ci.draw_arc(c, rad, 0.0, TAU, 40, col, 2.0, true)
	ci.draw_circle(c + Vector2(-rad * 0.34, -rad * 0.18), rad * 0.13, col)
	ci.draw_circle(c + Vector2(rad * 0.34, -rad * 0.18), rad * 0.13, col)
	var nose := c + Vector2(0.0, rad * 0.30)
	ci.draw_line(c + Vector2(0.0, -rad * 0.05), nose, Neo.with_alpha(col, col.a * 0.85), 2.0)
	ci.draw_circle(nose, rad * 0.12, col)
	if t > 0.0:
		var dx := sin(t * 1.9) * rad * 0.30
		ci.draw_line(nose, nose + Vector2(dx, rad * 0.34), Neo.with_alpha(col, 0.5), 1.5)


## Пиктограмма руки: ладонь, четыре пальца, большой палец.
static func _glyph_hand(ci: CanvasItem, c: Vector2, rad: float, col: Color, t: float) -> void:
	var w := rad * 1.0
	var h := rad * 0.9
	var palm := Rect2(c + Vector2(-w * 0.5, -h * 0.05), Vector2(w, h * 0.95))
	ci.draw_rect(palm, Neo.with_alpha(col, col.a * 0.18))
	ci.draw_rect(palm, col, false, 2.0)
	var sway := (sin(t * 2.2) * rad * 0.10) if t > 0.0 else 0.0
	for i in 4:
		var fx := palm.position.x + w * (0.12 + 0.25 * float(i))
		var fh := h * (0.55 - absf(1.5 - float(i)) * 0.10)
		ci.draw_line(Vector2(fx + sway, palm.position.y - fh), Vector2(fx + sway, palm.position.y),
			col, 3.0)
	ci.draw_line(palm.position + Vector2(-w * 0.02, h * 0.35),
		palm.position + Vector2(-w * 0.42, h * 0.10), col, 3.0)
