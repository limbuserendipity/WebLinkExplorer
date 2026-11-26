extends Node2D
## «Неон-тетрис»: до четырёх стаканов в одном кадре.
##
## У каждого игрока свой стакан в общей сцене: фигуры падают, ряд собирается —
## ряд сгорает. Управление без рук на клавиатуре:
##   · наклон влево-вправо — сдвиг фигуры по стакану;
##   · наклон вниз (рука/подбородок) — ускорить падение;
##   · короткий жест — поворот фигуры;
##   · удержание жеста (0.55 с) — мгновенный сброс вниз.
## Стакан заполнился доверху — игрок не выбывает: платит штраф очками
## и получает чистый стакан, бой продолжается. Свободные места занимают боты.

const Inp := preload("res://core/FaceInput.gd")
const Neo := preload("res://core/Neon.gd")
const Sfx := preload("res://core/Sfx.gd")
const CamView := preload("res://core/CamView.gd")
const InputHint := preload("res://core/InputHint.gd")
const Lay := preload("res://core/Layout.gd")

const MENU_SCENE := "res://ui/Menu.tscn"

# ---------------------------------------------------------------- стакан

const COLS := 10
const ROWS := 20
const CELL := 28.0                # 10 × 28 = 280, 20 × 28 = 560
const BOARDS := 4
const BOARD_W := 328.0
const BOARD_H := 720.0
const BOARD_X0 := 48.0            # левый край первого стакана
const BOARD_STEP := 344.0         # 328 + 16: четыре стакана ровно в 1360
const BOARD_Y := 200.0
const FIELD_X := 24.0             # отступ поля от края панели
const FIELD_Y := 56.0

# ---------------------------------------------------------------- правила

const GRAV := 2.2                 # клеток в секунду
const SOFT := 8.0                 # множитель ускорения при наклоне вниз
const BOT_FALL := 5.0             # боты роняют фигуру быстрее: раунд успевает
const BOT_TICK := 0.10            # такт бота, с
const BOT_STEP := 3               # клеток за такт: бот успевает доехать до столбца
const MOVE_REPEAT := 0.14         # сдвиг на клетку при полном отклонении, с
const MOVE_AXIS := 0.55           # порог отклонения для сдвига
const SOFT_AXIS := 0.55           # порог отклонения для ускорения падения
const ROT_COOL := 0.22
const DROP_HOLD := 0.55           # столько держим жест — сброс, с
const GESTURE_CONF := 0.5
const CLEAR_SCORE := [0, 100, 300, 600, 1000]
const DROP_POINT := 2             # очков за клетку мгновенного сброса
const TARGET_LINES := 10           # раунд до 10 линий
const OVERFLOW_PENALTY := 300      # заполнил стакан — минус очки, не вылет
const ROUND_TIME := 90.0
const STALE := 0.5
const MAX_HUMANS := 4

const SHAPES := [
	[Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)],  # I
	[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],  # O
	[Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 1)],  # T
	[Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1)],  # S
	[Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1)],  # Z
	[Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)],  # J
	[Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)],  # L
]

enum St { WAIT, READY, RUN, RESULT, OVER }


class Player:
	var id := 0
	var human := false
	var color := Color.WHITE
	var title := "игрок"
	var track_slot := -1
	var track_id := -1
	var inp = Inp.new()
	var grid: Array = []
	var piece: Array = []
	var shape_id := 0
	var next_id := 0
	var px := 3
	var py := 0
	var fall := 0.0
	var score := 0
	var lines := 0
	var clears := 0
	var pieces := 0
	var rots := 0
	var hard_drops := 0
	var overflows := 0
	var flash := 0.0
	var drop_armed := false
	var rot_cool := 0.0
	var move_cool := 0.0
	var move_dir := 0
	var bot_t := 0.0
	var bot_target := -1
	var fall_mult := 1.0
	var ax := 0.0
	var ay := 0.0


var bridge: Node
var state: int = St.WAIT
var state_t := 0.0
var players: Array = []
var time_left := ROUND_TIME
var winner := -1
var frozen := false
var demo := false
var selftest := ""
var input_mode := "auto"
var gain := 1.0
var flip_x := 1.0
var flip_y := 1.0
var debug_ui := false
var no_audio := false
var synth := Sfx.new()
var cam_view = null
var rng := RandomNumberGenerator.new()

var st_t := 0.0
var probe_rot := 0
var probe_drop := 0
var probe_stage := 0


func _ready() -> void:
	bridge = get_node_or_null("/root/GameDirector")
	cam_view = CamView.new()
	add_child(cam_view)
	cam_view.setup(Lay.TETRIS_CAM)
	var has_port := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			has_port = true
		elif arg.begins_with("--selftest="):
			selftest = arg.trim_prefix("--selftest=")
		elif arg.begins_with("--control="):
			input_mode = arg.trim_prefix("--control=").to_lower()
		elif arg.begins_with("--gain="):
			gain = clampf(float(arg.trim_prefix("--gain=")), 0.1, 5.0)
		elif arg == "--flip-x":
			flip_x = -1.0
		elif arg == "--flip-y":
			flip_y = -1.0
		elif arg == "--debug":
			debug_ui = true
		elif arg == "--no-audio":
			no_audio = true
	demo = not has_port
	if not Inp.MODES.has(input_mode):
		input_mode = "auto"
	if selftest != "":
		rng.seed = 12345          # автотест должен повторяться
	else:
		rng.randomize()
	if not no_audio:
		synth.setup(self)
	if bridge != null:
		bridge.gesture.connect(_on_gesture)
		bridge.gesture_phase.connect(_on_gesture_phase)
	var area := Lay.TETRIS_AREA
	var frac := area.get_area() / (Lay.W * Lay.H)
	var clean: bool = not area.intersects(Lay.TETRIS_CAM) \
		and not area.intersects(Lay.TETRIS_HINT) \
		and not area.intersects(Lay.TETRIS_STATUS)
	printerr("TETRIS START players=%d mode=%s поле=%.0fx%.0f доля=%.2f чисто=%s" % [
		_human_count_hint(), input_mode, area.size.x, area.size.y, frac, clean])
	# Пустые стаканы видны ещё до старта — так экран читается сразу.
	for i in BOARDS:
		players.append(_make_player(i, false))
	_set_state(St.WAIT)
	state_t = 100.0 if selftest == "tetris" else 0.0


func _exit_tree() -> void:
	synth.stop()


func _human_count_hint() -> int:
	if demo:
		return 1
	if bridge == null:
		return 0
	return mini(bridge.players().size(), MAX_HUMANS)


func _make_player(i: int, human: bool) -> Player:
	var p := Player.new()
	p.id = i
	p.human = human
	p.color = Neo.player_color(i)
	p.title = "игрок %d" % (i + 1)
	p.grid = _empty_grid()
	p.next_id = rng.randi_range(0, SHAPES.size() - 1)
	_spawn(p)
	return p


# ---------------------------------------------------------------- игровой цикл


func _process(dt: float) -> void:
	state_t += dt
	synth.pump()
	_update_cam_view()
	var sdt := dt * (4.0 if selftest == "tetris" and state == St.RUN else 1.0)
	match state:
		St.WAIT:
			_tick_wait(dt)
		St.READY:
			_collect_inputs(dt)
			_read_humans(dt)
			if state_t >= 1.8:
				_set_state(St.RUN)
		St.RUN:
			_collect_inputs(dt)
			_read_humans(dt)
			_tick_run(sdt)
		St.RESULT:
			if state_t >= 6.0:
				_set_state(St.OVER)
		St.OVER:
			if state_t >= 8.0:
				_back_to_menu()
	queue_redraw()
	if selftest == "tetris":
		_selftest_tick()


func _set_state(s: int) -> void:
	state = s
	state_t = 0.0
	if selftest != "":
		printerr("TETRIS STATE ", s)


func _tick_wait(_dt: float) -> void:
	if bridge != null:
		bridge.rotation_checkpoint()
	if state_t < 0.2:
		return
	var humans := _humans()
	if selftest == "tetris":
		_start_match([])
	elif demo:
		_start_match([])                    # клавиатура за первого + боты
	elif humans.size() >= 1:
		_start_match(humans)


func _humans() -> Array:
	if demo or bridge == null:
		return []
	var list := []
	for p in bridge.players():
		if str(p.state) != "confirmed":
			continue
		list.append(p)
	list.sort_custom(func(a, b): return a.camera_rect_norm.position.x < b.camera_rect_norm.position.x)
	if list.size() > MAX_HUMANS:
		list = list.slice(0, MAX_HUMANS)
	return list


func _start_match(humans: Array) -> void:
	players.clear()
	for i in BOARDS:
		var kb: bool = demo and i == 0 and selftest == ""     # клавиатура — только в демо
		var p := _make_player(i, i < humans.size() or kb)
		if p.human and i < humans.size():
			p.color = humans[i].color if humans[i].color is Color else p.color
			p.track_slot = humans[i].slot
			p.track_id = humans[i].track_id
			p.title = "игрок %d" % (i + 1)
			p.fall_mult = 1.0
		else:
			p.title = "бот %d" % (i + 1)
			p.color = Neo.with_alpha(Neo.player_color(i), 0.78)
			p.track_slot = i if selftest != "" else -1
			p.fall_mult = BOT_FALL
		players.append(p)
	time_left = ROUND_TIME
	winner = -1
	frozen = false
	printerr("TETRIS MATCH стаканов=%d людей=%d свободных=%d" % [
		players.size(), humans.size(), players.size() - humans.size()])
	_set_state(St.READY)


func _tick_run(dt: float) -> void:
	_update_frozen()
	if frozen:
		return                     # никого нет в кадре — стаканы стоят на паузе
	time_left = maxf(0.0, time_left - dt)
	for p in players:
		p.flash = maxf(0.0, p.flash - dt * 2.0)
		p.rot_cool = maxf(0.0, p.rot_cool - dt)
		if p.human:
			_apply_axis(p, dt)
		else:
			_bot_think(p, dt)
		_gravity(p, dt)
	_check_finish()


func _apply_axis(p: Player, dt: float) -> void:
	var ax := clampf(p.ax, -1.0, 1.0)
	var dir := 0
	if ax > MOVE_AXIS:
		dir = 1
	elif ax < -MOVE_AXIS:
		dir = -1
	if dir == 0:
		p.move_dir = 0
		p.move_cool = 0.0
		return
	if dir != p.move_dir:
		p.move_dir = dir
		p.move_cool = MOVE_REPEAT
		_move(p, dir)
		return
	p.move_cool -= dt
	if p.move_cool <= 0.0:
		p.move_cool = MOVE_REPEAT
		_move(p, dir)


func _gravity(p: Player, dt: float) -> void:
	var speed := GRAV * p.fall_mult
	if p.ay > SOFT_AXIS:
		speed *= SOFT
	p.fall += speed * dt
	var guard := 0
	while p.fall >= 1.0 and guard < ROWS:
		guard += 1
		p.fall -= 1.0
		if _can(p, p.piece, p.px, p.py + 1):
			p.py += 1
		else:
			_lock(p)
			return


func _move(p: Player, d: int) -> bool:
	if _can(p, p.piece, p.px + d, p.py):
		p.px += d
		return true
	return false


func _rotate(p: Player) -> bool:
	var cells := _rot(p.piece)
	for kick in [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-2, 0),
			Vector2i(2, 0), Vector2i(0, -1)]:
		var k: Vector2i = kick
		if _can(p, cells, p.px + k.x, p.py + k.y):
			p.piece = cells
			p.px += k.x
			p.py += k.y
			p.rots += 1
			return true
	return false


func _hard_drop(p: Player) -> void:
	var n := 0
	while _can(p, p.piece, p.px, p.py + 1) and n < ROWS:
		p.py += 1
		n += 1
	p.score += n * DROP_POINT
	p.hard_drops += 1
	synth.tone(240.0, 90.0, 0.10, 0.16)
	_lock(p)


func _lock(p: Player) -> void:
	for c in p.piece:
		var x: int = p.px + int(c.x)
		var y: int = p.py + int(c.y)
		if x >= 0 and x < COLS and y >= 0 and y < ROWS:
			p.grid[y][x] = p.shape_id + 1
	var n := _clear_lines(p)
	if n > 0:
		p.lines += n
		p.clears += 1
		p.score += int(CLEAR_SCORE[n])
		p.flash = 1.0
		synth.tone(880.0, 1420.0, 0.12, 0.18)
		printerr("TETRIS CLEAR play=%d n=%d lines=%d score=%d" % [p.id, n, p.lines, p.score])
	_spawn(p)


func _clear_lines(p: Player) -> int:
	var kept: Array = []
	var n := 0
	for y in ROWS:
		var full := true
		for x in COLS:
			if int(p.grid[y][x]) == 0:
				full = false
				break
		if full:
			n += 1
		else:
			kept.append(p.grid[y])
	if n == 0:
		return 0
	while kept.size() < ROWS:
		kept.push_front(_empty_row())
	p.grid = kept
	return n


func _spawn(p: Player, depth := 0) -> void:
	p.shape_id = p.next_id
	p.piece = SHAPES[p.shape_id].duplicate()
	p.next_id = rng.randi_range(0, SHAPES.size() - 1)
	p.px = int((COLS - _width(p.piece)) / 2)
	p.py = 0
	p.bot_target = -1
	p.fall = 0.0
	p.move_dir = 0
	p.move_cool = 0.0
	p.pieces += 1
	if not p.human:
		_bot_plan(p)               # бот сразу ставит фигуру в лучший столбец
	if not _can(p, p.piece, p.px, p.py) and depth < 2:
		_overflow(p, depth)


func _overflow(p: Player, depth := 0) -> void:
	# Стакан заполнен доверху: не выбываем, а платим очками и начинаем заново.
	p.overflows += 1
	p.score -= OVERFLOW_PENALTY
	p.grid = _empty_grid()
	p.flash = 1.0
	synth.tone(160.0, 60.0, 0.30, 0.22)
	printerr("TETRIS OVERFLOW play=%d штраф=%d score=%d" % [p.id, OVERFLOW_PENALTY, p.score])
	_spawn(p, depth + 1)


func _check_finish() -> void:
	var best := -1
	var best_lines := -1
	for p in players:
		if p.lines > best_lines:
			best_lines = p.lines
			best = p.id
	for p in players:
		if p.lines >= TARGET_LINES:
			best = p.id
			best_lines = p.lines
			break
	if best_lines >= TARGET_LINES or time_left <= 0.0:
		winner = best
		printerr("TETRIS FINISH winner=%d lines=%d overflows=%d" % [
			winner, best_lines, _overflows_total()])
		_set_state(St.RESULT)


func _overflows_total() -> int:
	var n := 0
	for p in players:
		n += p.overflows
	return n


func _back_to_menu() -> void:
	if demo or selftest != "":
		_start_match([])
		return
	get_tree().change_scene_to_file(MENU_SCENE)


# ---------------------------------------------------------------- фигуры


func _empty_row() -> Array:
	var row: Array = []
	for x in COLS:
		row.append(0)
	return row


func _empty_grid() -> Array:
	var g: Array = []
	for y in ROWS:
		g.append(_empty_row())
	return g


func _width(cells: Array) -> int:
	var w := 1
	for c in cells:
		w = maxi(w, int(c.x) + 1)
	return w


static func _rot(cells: Array) -> Array:
	# Поворот на 90°: (x, y) → (-y, x), затем сдвиг обратно к левому верхнему углу.
	var out: Array = []
	var minx := 99
	var miny := 99
	for c in cells:
		var p := Vector2i(-int(c.y), int(c.x))
		out.append(p)
		minx = mini(minx, p.x)
		miny = mini(miny, p.y)
	for i in out.size():
		out[i] = out[i] - Vector2i(minx, miny)
	return out


func _can(p: Player, cells: Array, px: int, py: int) -> bool:
	return _can_on(p.grid, cells, px, py)


static func _can_on(g: Array, cells: Array, px: int, py: int) -> bool:
	for c in cells:
		var x: int = px + int(c.x)
		var y: int = py + int(c.y)
		if x < 0 or x >= COLS or y >= ROWS:
			return false
		if y >= 0 and int(g[y][x]) != 0:
			return false
	return true


# ---------------------------------------------------------------- боты


## Бот выбирает поворот и столбец перебором: 4 поворота × все столбцы.
## Решение принимается на спавне, поэтому фигура сразу падает куда надо
## (иначе цель «прыгает» на лету и фигура ложится куда попало).
func _bot_plan(p: Player) -> void:
	var cells: Array = p.piece
	var best_cells: Array = cells
	var best_cx := 0
	var best_val := -1e18
	for r in 4:
		for cx in range(0, COLS - _width(cells) + 1):
			var v := _value_on(p, cells, cx)
			if v > best_val:
				best_val = v
				best_cx = cx
				best_cells = cells
		cells = _rot(cells)
	p.piece = best_cells
	p.px = best_cx
	if rng.randf() < 0.20:
		p.px = rng.randi_range(0, COLS - _width(p.piece))
	p.bot_target = p.px


func _bot_think(p: Player, dt: float) -> void:
	p.bot_t -= dt
	if p.bot_t > 0.0:
		return
	p.bot_t = BOT_TICK
	var steps := 0
	while p.px != p.bot_target and steps < BOT_STEP:
		steps += 1
		if not _move(p, signi(p.bot_target - p.px)):
			break


func _value_on(p: Player, cells: Array, cx: int) -> float:
	# Простая эвристика: сгоревшие ряды хорошо, дыры и рваный верх — плохо.
	var g := _grid_copy(p.grid)
	var py := -4
	while py < ROWS and _can_on(g, cells, cx, py + 1):
		py += 1
	if py < -2:
		return -1e9
	for c in cells:
		var x: int = cx + int(c.x)
		var y: int = py + int(c.y)
		if x >= 0 and x < COLS and y >= 0 and y < ROWS:
			g[y][x] = p.shape_id + 1
	var heights: Array = []
	var holes := 0
	for x in COLS:
		var top := -1
		for y in ROWS:
			if int(g[y][x]) != 0:
				top = y
				break
		heights.append(0 if top < 0 else ROWS - top)
		if top >= 0:
			for y in range(top + 1, ROWS):
				if int(g[y][x]) == 0:
					holes += 1
	var lines := 0
	for y in ROWS:
		var full := true
		for x in COLS:
			if int(g[y][x]) == 0:
				full = false
				break
		if full:
			lines += 1
	var agg := 0
	var bump := 0
	var tallest := 0
	for i in heights.size():
		var h: int = heights[i]
		agg += h
		tallest = maxi(tallest, h)
		if i > 0:
			bump += absi(h - int(heights[i - 1]))
	return 420.0 * float(lines) - 3.0 * float(agg) - 34.0 * float(holes) \
		- 5.0 * float(bump) - 12.0 * float(tallest)


func _grid_copy(g: Array) -> Array:
	var out: Array = []
	for y in ROWS:
		var row: Array = []
		for x in COLS:
			row.append(int(g[y][x]))
		out.append(row)
	return out


# ---------------------------------------------------------------- ввод


func _collect_inputs(dt: float) -> void:
	if demo or bridge == null:
		return
	var list: Array = bridge.players()
	for p in players:
		if not p.human:
			continue
		var cand = null
		for q in list:
			if q.slot == p.track_slot and q.track_id == p.track_id \
					and str(q.state) == "confirmed":
				cand = q
				break
		if cand == null:
			continue
		p.inp.mode = input_mode
		p.inp.gain = gain
		p.inp.flip_x = flip_x
		p.inp.flip_y = flip_y
		p.inp.update(cand, dt, _aspect(), _frame_px())
		if not p.inp.have_neutral:
			p.inp.accumulate()
			if p.inp.samples >= 12:
				p.inp.finish_calibration()
				printerr("TETRIS CALIB slot=%d nx=%.2f ny=%.2f" % [p.track_slot, p.inp.nx, p.inp.ny])


func _read_humans(_dt: float) -> void:
	if demo:
		if players.size() > 0:
			var p0: Player = players[0]
			var ax := 0.0
			if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
				ax -= 1.0
			if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
				ax += 1.0
			p0.ax = ax
			p0.ay = 1.0 if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S) else 0.0
		return
	for p in players:
		if not p.human or not p.inp.have_neutral:
			continue
		p.ax = clampf(p.inp.ax, -1.0, 1.0)
		p.ay = clampf(p.inp.ay, -1.0, 1.0)


## Жест: короткое нажатие — поворот, удержание — сброс фигуры вниз.
func _on_gesture(slot: int, _action: String, confidence: float) -> void:
	if confidence < GESTURE_CONF:
		return
	var p := _player_by_slot(slot)
	if p == null:
		return
	p.drop_armed = true
	_gesture_rotate(p)


func _on_gesture_phase(slot: int, _track_id: int, _action: String, phase: String,
		confidence: float, _at: float, duration: float) -> void:
	if confidence < GESTURE_CONF or state != St.RUN:
		return
	var p := _player_by_slot(slot)
	if p == null:
		return
	match phase:
		"start":
			p.drop_armed = true
			_gesture_rotate(p)
		"hold", "end":
			if p.drop_armed and duration >= DROP_HOLD:
				p.drop_armed = false
				_gesture_drop(p)
		_:
			pass


func _player_by_slot(slot: int) -> Player:
	if slot < 0:
		return null
	for p in players:
		if p.track_slot != slot:
			continue
		if p.human or selftest != "":
			return p
	return null


func _gesture_rotate(p: Player) -> void:
	if state != St.RUN or p.rot_cool > 0.0:
		return
	p.rot_cool = ROT_COOL
	if _rotate(p):
		synth.tone(620.0, 880.0, 0.06, 0.12)


func _gesture_drop(p: Player) -> void:
	if state != St.RUN:
		return
	_hard_drop(p)
	printerr("TETRIS DROP play=%d score=%d" % [p.id, p.score])
	p.rot_cool = ROT_COOL


func _update_frozen() -> void:
	if demo or bridge == null:
		frozen = false
		return
	if bridge.tracking_age() > STALE:
		frozen = true
		return
	var list: Array = bridge.players()
	for p in players:
		if not p.human:
			continue
		var found := false
		for q in list:
			if q.slot == p.track_slot and q.track_id == p.track_id \
					and str(q.state) == "confirmed":
				found = true
				break
		if not found:
			frozen = true
			return
	frozen = false


func _frame_px() -> Vector2:
	var px := Vector2(1920.0, 1080.0)
	if bridge != null:
		px = Vector2(bridge.frame_size)
	if px.x < 1.0 or px.y < 1.0:
		px = Vector2(1920.0, 1080.0)
	return px


func _aspect() -> float:
	var px := _frame_px()
	return px.x / px.y


func _active_src() -> String:
	for p in players:
		if p.human and p.inp.have_input:
			return p.inp.active
	return "hand" if input_mode == "hand" else "face"


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := (event as InputEventKey).keycode
	if k == KEY_ESCAPE:
		_back_to_menu()
		return
	if k == KEY_SPACE or k == KEY_UP or k == KEY_W:
		if players.size() > 0 and (demo or not players[0].human):
			_gesture_rotate(players[0])
		return
	if k >= KEY_1 and k <= KEY_5:
		var idx := k - KEY_1
		if idx < Inp.MODES.size():
			input_mode = Inp.MODES[idx]
			for p in players:
				p.inp.mode = input_mode
			printerr("TETRIS MODE ", input_mode)


func _update_cam_view() -> void:
	if cam_view == null or bridge == null:
		return
	var boxes := []
	for p in bridge.all_players():
		if p.age_ticks >= 30:
			continue
		var rr: Rect2 = p.camera_rect_norm
		if rr.size.x <= 0.001:
			continue
		boxes.append({"rect": rr, "color": p.color, "label": ""})
	cam_view.subtitle = "ввод: рука" if _active_src() == "hand" else "ввод: лицо"
	cam_view.set_feed(bridge.camera_texture, boxes, bridge.frame_age() < 1.5)


# ---------------------------------------------------------------- отрисовка


func _board_rect(i: int) -> Rect2:
	return Rect2(BOARD_X0 + float(i) * BOARD_STEP, BOARD_Y, BOARD_W, BOARD_H)


func _field_rect(i: int) -> Rect2:
	return Rect2(_board_rect(i).position + Vector2(FIELD_X, FIELD_Y),
		Vector2(float(COLS) * CELL, float(ROWS) * CELL))


func _draw() -> void:
	Neo.grid_bg(self, Vector2(Lay.W, Lay.H))
	for p in players:
		_draw_board(p)
	_draw_hud()
	Neo.scanlines(self, Vector2(Lay.W, Lay.H))


func _shape_color(id: int) -> Color:
	var palette := [Neo.PUCK, Neo.LEFT, Neo.RIGHT, Neo.OK, Neo.TENTATIVE, Neo.LINE, Neo.WARN]
	return palette[posmod(id, palette.size())]


func _draw_board(p: Player) -> void:
	var r := _board_rect(p.id)
	var live: bool = state == St.RUN or state == St.READY
	var accent: Color = p.color
	Lay.panel(self, r, "", accent)
	# Шапка стакана: кто играет и сколько очков.
	Neo.text_left(self, p.title.to_upper(), r.position + Vector2(16.0, 32.0), Lay.T_H2,
		Neo.TEXT if live else Neo.with_alpha(Neo.TEXT, 0.75))
	_text_right("%d" % p.score, r.end.x - 16.0, r.position.y + 32.0, Lay.T_H2, accent)
	var f := _field_rect(p.id)
	draw_rect(f, Color(0.008, 0.0, 0.035, 0.92))
	# Сетка поля — еле заметная, чтобы клетки читались.
	for x in range(1, COLS):
		draw_line(Vector2(f.position.x + float(x) * CELL, f.position.y),
			Vector2(f.position.x + float(x) * CELL, f.end.y), Color(0.45, 0.25, 0.95, 0.10), 1.0)
	for y in range(1, ROWS):
		draw_line(Vector2(f.position.x, f.position.y + float(y) * CELL),
			Vector2(f.end.x, f.position.y + float(y) * CELL), Color(0.45, 0.25, 0.95, 0.10), 1.0)
	draw_rect(f, Neo.with_alpha(Neo.LINE, 0.35), false, 1.5)
	# Лежащие клетки.
	for y in ROWS:
		for x in COLS:
			var v := int(p.grid[y][x])
			if v == 0:
				continue
			_draw_cell(f, x, y, _shape_color(v - 1), 0.88)
	# Тень фигуры: куда она упадёт.
	var ghost := p.py
	while _can(p, p.piece, p.px, ghost + 1) and ghost < ROWS:
		ghost += 1
	for c in p.piece:
		var gx: int = p.px + int(c.x)
		var gy: int = ghost + int(c.y)
		if gy >= 0 and gy < ROWS and gx >= 0 and gx < COLS:
			_draw_cell_outline(f, gx, gy, _shape_color(p.shape_id))
	# Сама фигура.
	for c in p.piece:
		var x: int = p.px + int(c.x)
		var y: int = p.py + int(c.y)
		if y >= 0 and y < ROWS and x >= 0 and x < COLS:
			_draw_cell(f, x, y, _shape_color(p.shape_id), 1.0)
	if p.flash > 0.0:
		draw_rect(f, Neo.with_alpha(Color(1.0, 1.0, 1.0), 0.35 * p.flash))
	# Подвал стакана: линии и следующая фигура.
	var fy := f.end.y + 14.0
	Neo.text_left(self, "линии %d" % p.lines, Vector2(r.position.x + 16.0, fy + 16.0),
		Lay.T_SMALL, Neo.with_alpha(Neo.TEXT, 0.9))
	Neo.text_left(self, "до %d" % TARGET_LINES, Vector2(r.position.x + 16.0, fy + 42.0),
		Lay.T_TINY, Neo.with_alpha(Neo.DIM, 0.8))
	if p.overflows > 0:
		Neo.text_left(self, "штрафов %d" % p.overflows,
			Vector2(r.position.x + 16.0, fy + 66.0), Lay.T_TINY, Neo.with_alpha(Neo.WARN, 0.9))
	var nb := Rect2(Vector2(r.end.x - 16.0 - 3.0 * 18.0, fy), Vector2(3.0 * 18.0, 3.0 * 18.0))
	Neo.text_left(self, "далее", Vector2(nb.position.x, fy + 16.0), Lay.T_TINY,
		Neo.with_alpha(Neo.DIM, 0.8))
	for c in SHAPES[p.next_id]:
		var cell := Rect2(nb.position + Vector2(float(c.x) * 18.0, 22.0 + float(c.y) * 18.0),
			Vector2(16.0, 16.0))
		draw_rect(cell, Neo.with_alpha(_shape_color(p.next_id), 0.85))


func _draw_cell(f: Rect2, x: int, y: int, col: Color, alpha: float) -> void:
	var c := Rect2(f.position + Vector2(float(x) * CELL, float(y) * CELL),
		Vector2(CELL, CELL))
	draw_rect(c.grow(-2.0), Neo.with_alpha(col, alpha * 0.22))
	draw_rect(c.grow(-2.0), Neo.with_alpha(col, alpha), false, 1.5)
	draw_line(c.position + Vector2(4.0, 4.0), c.position + Vector2(CELL - 6.0, 4.0),
		Neo.with_alpha(col, alpha * 0.9), 2.0)


func _draw_cell_outline(f: Rect2, x: int, y: int, col: Color) -> void:
	var c := Rect2(f.position + Vector2(float(x) * CELL, float(y) * CELL),
		Vector2(CELL, CELL))
	draw_rect(c.grow(-3.0), Neo.with_alpha(col, 0.22), false, 1.0)


func _text_right(s: String, right_x: float, y: float, size: int, col: Color) -> void:
	var font := ThemeDB.fallback_font
	var w := 0.0
	if font != null:
		w = font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	Neo.text_left(self, s, Vector2(right_x - w, y), size, col)


func _draw_hud() -> void:
	var t := maxf(time_left, 0.0)
	var target := TARGET_LINES
	Lay.header(self, "НЕОН-ТЕТРИС",
		"четыре стакана · до %d линий · жест — поворот, удержание — сброс" % target,
		"раунд %d:%02d" % [int(t) / 60, int(t) % 60],
		"штраф за полный стакан: −%d" % OVERFLOW_PENALTY)
	_draw_status()
	_draw_footer()
	InputHint.draw(self, Lay.TETRIS_HINT, _active_src(), Time.get_ticks_msec() * 0.001)
	if frozen and state == St.RUN:
		Neo.text(self, "ПАУЗА: ждём игроков в кадре",
			Lay.TETRIS_AREA.get_center() + Vector2(0.0, 20.0), Lay.T_H1, Neo.WARN)
	_draw_overlay()
	if debug_ui:
		var y := Lay.FOOT_Y + 100.0
		for p in players:
			if p.human:
				Neo.text(self, "%s ax=%+.2f ay=%+.2f очки=%d фигур=%d" % [
					p.title, p.ax, p.ay, p.score, p.pieces],
					Vector2(Lay.W * 0.5, y), Lay.T_TINY, Neo.DIM)
				y += 20.0


func _draw_status() -> void:
	var r := Lay.TETRIS_STATUS
	Lay.panel(self, r, "состояние")
	var b := Lay.body(r)
	var rows := [
		["ввод", "рука" if _active_src() == "hand" else "лицо"],
		["данные", _age_text()],
		["линий", str(_best_lines())],
		["штрафов", str(_overflows_total())],
	]
	var y := b.position.y + 6.0
	for row in rows:
		Neo.text_left(self, row[0], Vector2(b.position.x, y), Lay.T_TINY,
			Neo.with_alpha(Neo.DIM, 0.8))
		Neo.text_left(self, row[1], Vector2(b.position.x + 108.0, y), Lay.T_TINY, Neo.TEXT)
		y += 22.0


func _best_lines() -> int:
	var n := 0
	for p in players:
		n = maxi(n, p.lines)
	return n


func _age_text() -> String:
	if bridge == null:
		return "нет трекера"
	var age: float = bridge.tracking_age()
	return "нет данных" if is_inf(age) else "%.0f мс" % (age * 1000.0)


func _draw_footer() -> void:
	var hint := "наклон влево-вправо — сдвиг · вниз — быстрее · жест — поворот · держите жест — сброс"
	if demo:
		hint = "демо без трекинга: ← → — сдвиг · ↓ — быстрее · пробел — поворот"
	Neo.text_left(self, hint, Vector2(Lay.M, Lay.FOOT_Y + 36.0), Lay.T_BODY, Neo.DIM)
	Neo.text_left(self, "1..5 — режим ввода · ESC — меню",
		Vector2(Lay.M, Lay.FOOT_Y + 70.0), Lay.T_SMALL, Neo.with_alpha(Neo.DIM, 0.65))


func _draw_overlay() -> void:
	if state == St.RUN:
		return
	var c := Lay.TETRIS_AREA.get_center()
	# Тёмная подложка: оверлей ложится поверх четырёх стаканов.
	var back := Rect2(c - Vector2(620.0, 74.0), Vector2(1240.0, 148.0))
	draw_rect(back, Color(0.01, 0.0, 0.04, 0.84))
	draw_rect(back, Neo.with_alpha(Neo.LINE, 0.45), false, 1.5)
	match state:
		St.WAIT:
			Neo.text(self, "ВСТАНЬТЕ ПЕРЕД КАМЕРОЙ", c - Vector2(0.0, 20.0), Lay.T_H1, Neo.TEXT)
			Neo.text(self, "от 1 до 4 игроков · свободные стаканы займут боты", c + Vector2(0.0, 26.0),
				Lay.T_H2, Neo.DIM)
		St.READY:
			Neo.text(self, str(maxi(ceili(1.8 - state_t), 1)), c + Vector2(0.0, 40.0), 120, Neo.PUCK)
			Neo.text(self, "собирайте ряды · жест — поворот, удержание — сброс",
				c - Vector2(0.0, 60.0), Lay.T_H2, Neo.DIM)
		St.RESULT:
			var who: String = "никто"
			if winner >= 0:
				who = players[winner].title
			var col: Color = Neo.TEXT
			if winner >= 0:
				col = players[winner].color
			Neo.text(self, "больше линий — %s" % who, c - Vector2(0.0, 20.0), Lay.T_DISPLAY, col)
			if winner >= 0:
				var wp: Player = players[winner]
				Neo.text(self, "линий %d · очков %d · штрафов %d" % [wp.lines, wp.score, wp.overflows],
					c + Vector2(0.0, 30.0), Lay.T_H2, Neo.TEXT)
		St.OVER:
			Neo.text(self, "возвращаемся в меню…", c, Lay.T_H1, Neo.DIM)


# ---------------------------------------------------------------- автотест


func _selftest_tick() -> void:
	st_t += get_process_delta_time()
	match probe_stage:
		0:
			if state != St.RUN:
				return
			# Проверяем жесты через тот же путь, что и живой трекер: слот → стакан.
			probe_rot = players[0].rots
			probe_drop = players[0].hard_drops
			_on_gesture_phase(0, -1, "jump", "start", 0.95, 0.0, 0.0)
			probe_stage = 1
			st_t = 0.0
		1:
			if st_t < 0.4:
				return
			var got_rot: int = players[0].rots - probe_rot
			_on_gesture_phase(0, -1, "jump", "hold", 0.95, 0.0, DROP_HOLD + 0.05)
			var got_drop: int = players[0].hard_drops - probe_drop
			probe_rot = got_rot
			probe_drop = got_drop
			printerr("TETRIS GESTURE rotate=%d drop=%d" % [got_rot, got_drop])
			probe_stage = 2
			st_t = 0.0
		2:
			if state == St.RESULT:
				_finish_selftest()
				return
			if st_t > 22.0:
				printerr("TETRIS SELFTEST FAIL: раунд не закончился")
				printerr("TETRIS SELFTEST lines=%d overflows=%d" % [_best_lines(), _overflows_total()])
				get_tree().quit(1)


func _finish_selftest() -> void:
	var with_clears := 0
	var total_lines := 0
	for p in players:
		total_lines += p.lines
		if p.clears > 0:
			with_clears += 1
	printerr("TETRIS SELFTEST gestures rotate=%d drop=%d" % [probe_rot, probe_drop])
	printerr("TETRIS SELFTEST стаканов=%d с_линиями=%d линий=%d штрафов=%d победитель=%d" % [
		players.size(), with_clears, total_lines, _overflows_total(), winner])
	if probe_rot < 1 or probe_drop < 1:
		printerr("TETRIS SELFTEST FAIL: жесты не дошли до стакана")
		get_tree().quit(1)
		return
	if with_clears < players.size():
		printerr("TETRIS SELFTEST FAIL: не все стаканы собрали ряд")
		get_tree().quit(1)
		return
	if winner < 0:
		printerr("TETRIS SELFTEST FAIL: победитель не определён")
		get_tree().quit(1)
		return
	printerr("SELFTEST TETRIS PASS: 4 стакана, жест=%d поворотов и %d сбросов, линий %d, победитель «%s»" % [
		probe_rot, probe_drop, total_lines, players[winner].title])
	get_tree().quit(0)
