class_name Neon
extends RefCounted
## Ретро-неоновая палитра и мелкие помощники рисования. Общие для всех игр
## аркады: аэрохоккей, «Трон» и меню — чтобы стиль не расходился.

const BG := Color(0.020, 0.0, 0.078)
const GRID := Color(0.45, 0.25, 0.95, 0.07)
const LINE := Color(0.541, 0.361, 1.0)
const LEFT := Color(0.0, 0.918, 1.0)
const RIGHT := Color(1.0, 0.239, 0.949)
const PUCK := Color(1.0, 0.953, 0.690)
const TEXT := Color(0.88, 0.92, 1.0)
const DIM := Color(0.62, 0.66, 0.92, 0.85)
const WARN := Color(1.0, 0.45, 0.32)
const OK := Color(0.35, 1.0, 0.72)
const TENTATIVE := Color(1.0, 0.73, 0.25)

# Цвета игроков, если трекер не дал свой color.
const PLAYERS := [
	Color(0.0, 0.918, 1.0),      # голубой
	Color(1.0, 0.239, 0.949),    # розовый
	Color(0.45, 1.0, 0.35),      # салатовый
	Color(1.0, 0.78, 0.2),       # янтарный
]


static func text(ci: CanvasItem, s: String, pos: Vector2, size: int, c: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var p := pos - Vector2(w * 0.5, 0.0)
	ci.draw_string(font, p + Vector2(1.5, 1.5), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
		Color(c.r, c.g, c.b, 0.3))
	ci.draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)


static func text_left(ci: CanvasItem, s: String, pos: Vector2, size: int, c: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	ci.draw_string(font, pos + Vector2(1.5, 1.5), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
		Color(c.r, c.g, c.b, 0.3))
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)


static func glow(ci: CanvasItem, a: Vector2, b: Vector2, c: Color, w: float) -> void:
	ci.draw_line(a, b, Color(c.r, c.g, c.b, 0.10), w * 4.0)
	ci.draw_line(a, b, Color(c.r, c.g, c.b, 0.25), w * 2.0)
	ci.draw_line(a, b, c, w)


static func box(ci: CanvasItem, r: Rect2, c: Color, w: float, fill := Color(0, 0, 0, 0)) -> void:
	if fill.a > 0.0:
		ci.draw_rect(r, fill)
	ci.draw_rect(r, Color(c.r, c.g, c.b, c.a * 0.25), false, w * 2.0)
	ci.draw_rect(r, c, false, w)


static func grid_bg(ci: CanvasItem, size: Vector2, step := 120.0) -> void:
	ci.draw_rect(Rect2(Vector2.ZERO, size), BG)
	var x := 0.0
	while x <= size.x:
		ci.draw_line(Vector2(x, 0), Vector2(x, size.y), GRID, 1.0)
		x += step
	var y := 0.0
	while y <= size.y:
		ci.draw_line(Vector2(0, y), Vector2(size.x, y), GRID, 1.0)
		y += step


static func scanlines(ci: CanvasItem, size: Vector2, step := 6.0) -> void:
	var y := 0.0
	while y < size.y:
		ci.draw_line(Vector2(0, y), Vector2(size.x, y), Color(0, 0, 0, 0.10), 2.0)
		y += step


static func player_color(i: int, fallback: Color = Color.WHITE) -> Color:
	if i >= 0 and i < PLAYERS.size():
		return PLAYERS[i]
	return fallback


static func with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)
