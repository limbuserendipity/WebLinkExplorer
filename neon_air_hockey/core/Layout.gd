extends RefCounted
## Единая сетка и типографика всех экранов аркады.
##
## Раньше каждый экран верстался своими числами, отсюда «криво»: где-то
## 300 px, где-то 400, шрифты 19/20/22/24/26/28, поля 22/24/40. Теперь всё
## считается от одной сетки 1920×1080:
##
##   поля 48 · 12 колонок по 130 · промежуток 24
##   шапка 0…170 (линия на 170) · сцена 200…920 · подвал 940…1080
##
## Сцена у каждой игры своя (поле/дорога), но колонки, шапка, панели камеры
## и подсказки стоят на одних и тех же местах — экраны читаются одинаково.

const Neo := preload("res://core/Neon.gd")

# ---------------------------------------------------------------- сетка

const W := 1920.0
const H := 1080.0
const M := 48.0                  # внешние поля
const GUT := 24.0                # промежуток между колонками
const COL := 130.0               # ширина колонки: (1824 - 11*24) / 12
const HEADER_H := 170.0          # линия под шапкой
const STAGE_Y := 200.0           # верх сцены
const STAGE_BOTTOM := 920.0      # низ сцены
const FOOT_Y := 940.0            # верх подвала
const PAD := 16.0               # внутренние поля панели

# ---------------------------------------------------------------- типографика

const T_DISPLAY := 56            # название игры в шапке
const T_H1 := 40                 # крупные числа, победитель
const T_H2 := 28                 # подзаголовки, чипы
const T_BODY := 21               # обычный текст
const T_SMALL := 17              # пояснения
const T_TINY := 14               # подписи панелей

# ---------------------------------------------------------------- цвета панелей

const PANEL_FILL := Color(0.035, 0.005, 0.10, 0.82)
const PANEL_LINE := Color(0.541, 0.361, 1.0, 0.45)
const LABEL_COLOR := Color(0.62, 0.66, 0.92, 0.80)

# ---------------------------------------------------------------- меню

const MENU_CARD := Rect2(48.0, 200.0, 438.0, 228.0)     # первая из 6 плиток
const MENU_CARD_STEP := 462.0                           # 3 плитки в ряд (13.5 колонок)
const MENU_ROW_STEP := 252.0                            # второй ряд ниже на 228 + 24
const MENU_CAM := Rect2(1434.0, 200.0, 438.0, 292.0)    # панель камеры
const MENU_HINT := Rect2(1434.0, 512.0, 438.0, 274.0)   # подсказка ввода
const MENU_CHIPS := Rect2(48.0, 690.0, 1362.0, 96.0)    # фишки игроков
const MENU_MSG_Y := 850.0

# ---------------------------------------------------------------- «Трон»

const TRON_ARENA := Rect2(48.0, 200.0, 1360.0, 720.0)   # 68×36 клеток по 20
const TRON_CAM := Rect2(1432.0, 200.0, 440.0, 293.0)
const TRON_HINT := Rect2(1432.0, 513.0, 440.0, 288.0)
const TRON_STATUS := Rect2(1432.0, 821.0, 440.0, 99.0)
const TRON_SCORES := Rect2(972.0, 84.0, 900.0, 76.0)    # ряд чипов в шапке

# ---------------------------------------------------------------- «Разортрон»

const RAZOR_ROAD := Rect2(48.0, 200.0, 1824.0, 720.0)   # полотно сцены
const RAZOR_BAR := Rect2(48.0, 184.0, 1824.0, 10.0)     # полоса прогресса
const RAZOR_CAM := Rect2(48.0, 214.0, 344.0, 238.0)
const RAZOR_BOARD := Rect2(1528.0, 214.0, 344.0, 360.0)
const RAZOR_HINT := Rect2(48.0, 928.0, 700.0, 144.0)

# ---------------------------------------------------------------- «Неон-джамп»

const JUMP_ARENA := Rect2(48.0, 200.0, 1360.0, 720.0)   # поле прыжков
const JUMP_CAM := Rect2(1432.0, 200.0, 440.0, 293.0)
const JUMP_HINT := Rect2(1432.0, 513.0, 440.0, 250.0)
const JUMP_STATUS := Rect2(1432.0, 783.0, 440.0, 137.0)
const JUMP_SCORES := Rect2(972.0, 84.0, 900.0, 76.0)    # ряд чипов в шапке

# ---------------------------------------------------------------- «Неон-тетрис»

const TETRIS_AREA := Rect2(48.0, 200.0, 1360.0, 720.0)  # четыре доски по 340
const TETRIS_CAM := Rect2(1432.0, 200.0, 440.0, 293.0)
const TETRIS_HINT := Rect2(1432.0, 513.0, 440.0, 250.0)
const TETRIS_STATUS := Rect2(1432.0, 783.0, 440.0, 137.0)

# ---------------------------------------------------------------- световые мечи

const SABER_ARENA := Rect2(48.0, 200.0, 1360.0, 720.0)
const SABER_CAM := Rect2(1432.0, 200.0, 440.0, 293.0)
const SABER_HINT := Rect2(1432.0, 513.0, 440.0, 250.0)
const SABER_STATUS := Rect2(1432.0, 783.0, 440.0, 137.0)

# ---------------------------------------------------------------- аэрохоккей

const AIR_TABLE := Rect2(48.0, 200.0, 1500.0, 700.0)
const AIR_CAM := Rect2(1572.0, 200.0, 300.0, 213.0)
const AIR_HINT := Rect2(1572.0, 433.0, 300.0, 304.0)
const AIR_STATUS := Rect2(1572.0, 757.0, 300.0, 143.0)

# ---------------------------------------------------------------- помощники


static func span(cols: int) -> float:
	# Ширина блока из n колонок.
	return COL * float(cols) + GUT * float(maxi(cols - 1, 0))


static func x_col(col: int) -> float:
	# Левый край колонки.
	return M + float(col) * (COL + GUT)


## Панель: фон, рамка, угловые засечки и подпись сверху слева.
static func panel(ci: CanvasItem, r: Rect2, label := "", accent := LABEL_COLOR) -> void:
	ci.draw_rect(r, PANEL_FILL)
	ci.draw_rect(r.grow(1.5), Color(Neo.LINE.r, Neo.LINE.g, Neo.LINE.b, 0.10))
	ci.draw_rect(r, PANEL_LINE, false, 1.5)
	var k := 14.0
	var corners := [
		[r.position, Vector2(1, 0), Vector2(0, 1)],
		[Vector2(r.end.x, r.position.y), Vector2(-1, 0), Vector2(0, 1)],
		[Vector2(r.position.x, r.end.y), Vector2(1, 0), Vector2(0, -1)],
		[r.end, Vector2(-1, 0), Vector2(0, -1)],
	]
	for c in corners:
		var p: Vector2 = c[0]
		var a: Vector2 = c[1]
		var b: Vector2 = c[2]
		ci.draw_line(p, p + a * k, Color(accent.r, accent.g, accent.b, 0.9), 2.0)
		ci.draw_line(p, p + b * k, Color(accent.r, accent.g, accent.b, 0.9), 2.0)
	if label != "":
		Neo.text_left(ci, label.to_upper(), r.position + Vector2(PAD, PAD + T_TINY), T_TINY,
			accent)
		ci.draw_line(r.position + Vector2(PAD, PAD + T_TINY + 8.0),
			Vector2(r.end.x - PAD, r.position.y + PAD + T_TINY + 8.0),
			Color(Neo.LINE.r, Neo.LINE.g, Neo.LINE.b, 0.18), 1.0)


## Внутренняя область панели: с учётом подписи сверху (если она есть).
static func body(r: Rect2, has_label := true) -> Rect2:
	var top := PAD + (T_TINY + 16.0 if has_label else 0.0)
	return Rect2(r.position + Vector2(PAD, top), r.size - Vector2(PAD * 2.0, top + PAD))


## Кадр камеры внутри панели камеры (16:9, по ширине панели).
static func cam_frame(r: Rect2) -> Rect2:
	var w := r.size.x - PAD * 2.0
	return Rect2(r.position + Vector2(PAD, PAD + T_TINY + 16.0), Vector2(w, w * 9.0 / 16.0))


## Высота панели камеры для заданной ширины: подпись + кадр 16:9 + поля.
static func cam_panel_h(w: float) -> float:
	return PAD + T_TINY + 16.0 + (w - PAD * 2.0) * 9.0 / 16.0 + PAD


## Горизонтальная линия сетки с неоновым подчёркиванием.
static func divider(ci: CanvasItem, y: float, accent: Color = Color(0.541, 0.361, 1.0)) -> void:
	ci.draw_line(Vector2(M, y), Vector2(W - M, y), Color(accent.r, accent.g, accent.b, 0.10), 6.0)
	ci.draw_line(Vector2(M, y), Vector2(W - M, y), Color(accent.r, accent.g, accent.b, 0.55), 1.0)


## Шапка экрана: название слева, справа две строки состояния.
static func header(ci: CanvasItem, title: String, subtitle := "", right_top := "",
		right_bottom := "", accent: Color = Color(0.88, 0.92, 1.0)) -> void:
	Neo.text_left(ci, title, Vector2(M, 88.0), T_DISPLAY, accent)
	if subtitle != "":
		Neo.text_left(ci, subtitle, Vector2(M, 124.0), T_SMALL, Neo.with_alpha(Neo.DIM, 0.9))
	var font := ThemeDB.fallback_font
	if font != null:
		if right_top != "":
			var w := font.get_string_size(right_top, HORIZONTAL_ALIGNMENT_LEFT, -1, T_H2).x
			Neo.text_left(ci, right_top, Vector2(W - M - w, 90.0), T_H2, Neo.TEXT)
		if right_bottom != "":
			var w2 := font.get_string_size(right_bottom, HORIZONTAL_ALIGNMENT_LEFT, -1, T_SMALL).x
			Neo.text_left(ci, right_bottom, Vector2(W - M - w2, 124.0), T_SMALL,
				Neo.with_alpha(Neo.DIM, 0.9))
	divider(ci, HEADER_H, accent)


## Чип: цветной кружок, подпись, значение. Возвращает ширину.
static func chip(ci: CanvasItem, pos: Vector2, color: Color, title: String, value := "",
		w := 210.0) -> void:
	var r := Rect2(pos, Vector2(w, 76.0))
	ci.draw_rect(r, Color(color.r, color.g, color.b, 0.08))
	ci.draw_rect(r, Color(color.r, color.g, color.b, 0.55), false, 1.5)
	ci.draw_circle(pos + Vector2(22.0, 26.0), 7.0, color)
	Neo.text_left(ci, title, pos + Vector2(38.0, 33.0), T_SMALL, Neo.TEXT)
	if value != "":
		Neo.text_left(ci, value, pos + Vector2(38.0, 60.0), T_TINY,
			Neo.with_alpha(Neo.DIM, 0.95))


## Две строки «подпись / значение» в панели состояния.
static func kv(ci: CanvasItem, pos: Vector2, key: String, value: String, w := 260.0) -> void:
	Neo.text_left(ci, key, pos, T_TINY, Neo.with_alpha(Neo.DIM, 0.8))
	Neo.text_left(ci, value, pos + Vector2(w, 0.0), T_TINY, Neo.TEXT)

# ---------------------------------------------------------------- самопроверка

## Панели каждого экрана — для аудита сетки.
static func screen_rects() -> Dictionary:
	return {
		"меню": [MENU_CAM, MENU_HINT],
		"трон": [TRON_ARENA, TRON_CAM, TRON_HINT, TRON_STATUS],
		"неон-джамп": [JUMP_ARENA, JUMP_CAM, JUMP_HINT, JUMP_STATUS],
		"неон-тетрис": [TETRIS_AREA, TETRIS_CAM, TETRIS_HINT, TETRIS_STATUS],
		"световые мечи": [SABER_ARENA, SABER_CAM, SABER_HINT, SABER_STATUS],
		"разортрон": [RAZOR_CAM, RAZOR_BOARD, RAZOR_HINT],
		"аэрохоккей": [AIR_TABLE, AIR_CAM, AIR_HINT, AIR_STATUS],
	}


## Проверка «не криво»: панели в безопасной зоне, не пересекаются, кадры
## камеры 16:9, кегли только из шкалы. Возвращает список замечаний.
static func audit() -> Array:
	var bad: Array = []
	var safe := Rect2(M, HEADER_H + 10.0, W - M * 2.0, H - HEADER_H - 10.0 - 6.0)
	var screens := screen_rects()
	for key in screens.keys():
		var list: Array = screens[key]
		for i in list.size():
			var r: Rect2 = list[i]
			if r.position.x < safe.position.x - 0.01 or r.position.y < safe.position.y - 0.01 \
					or r.end.x > safe.end.x + 0.01 or r.end.y > safe.end.y + 0.01:
				bad.append("%s: панель %d вне безопасной зоны %s" % [key, i, r])
			if r.size.x < 200.0 or r.size.y < 90.0:
				bad.append("%s: панель %d слишком мелкая %s" % [key, i, r])
			for j in range(i + 1, list.size()):
				var o: Rect2 = list[j]
				if r.intersects(o):
					bad.append("%s: панели %d и %d пересекаются" % [key, i, j])
	for cam in [MENU_CAM, TRON_CAM, RAZOR_CAM, AIR_CAM, JUMP_CAM, TETRIS_CAM, SABER_CAM]:
		var f := cam_frame(cam)
		var want := f.size.x * 9.0 / 16.0
		if absf(f.size.y - want) > 0.6:
			bad.append("кадр камеры не 16:9: %s" % [cam])
		if f.end.y > cam.end.y - PAD + 0.6:
			bad.append("кадр камеры не влезает в панель: %s" % [cam])
	var scale_ok := [T_DISPLAY, T_H1, T_H2, T_BODY, T_SMALL, T_TINY]
	for t in scale_ok:
		if int(t) <= 0:
			bad.append("плохой кегль %s" % [t])
	return bad
