extends Node2D
## «Трон»: световые мотоциклы на сетке. 1–4 игрока (в одиночку — против ботов).
## Управление то же, что в аэрохоккее: лицо отклоняется в сторону — мотоцикл
## поворачивает туда. След не прощает: врезался в свой или чужой — выбыл.

const Inp := preload("res://core/FaceInput.gd")
const Neo := preload("res://core/Neon.gd")
const Sfx := preload("res://core/Sfx.gd")

const ARENA := Rect2(360.0, 260.0, 1200.0, 560.0)
const CELL := 20.0
const TICK := 0.075              # шаг мотоцикла, с
const WIN_ROUNDS := 3
const TURN_DEADZONE := 0.35      # отклонение лица, после которого поворот
const STALE := 0.5
const MENU_SCENE := "res://ui/Menu.tscn"
const MAX_HUMANS := 4

enum St { WAIT, READY, RUN, RESULT, OVER }


class Bike:
	var id := 0
	var human := false
	var color := Color.WHITE
	var title := "бот"
	var cell := Vector2i.ZERO
	var dir := Vector2i.RIGHT
	var want := Vector2i.RIGHT
	var alive := true
	var trail: Array[Vector2i] = []
	var score := 0
	var inp := Inp.new()
	var nose := Vector2(0.5, 0.5)
	var wander := 0
	var track_slot := -1
	var track_id := -1


var bridge: Node
var state: int = St.WAIT
var state_t := 0.0
var bikes: Array[Bike] = []
var occ := {}
var round_no := 0
var tick_acc := 0.0
var winner := -1
var frozen := false
var survival := 0.0
var best_time := 0.0
var solo := false
var arena_cells := Vector2i.ZERO

var synth := Sfx.new()
var selftest := ""
var input_mode := "face"
var gain := 1.0
var flip_x := 1.0
var flip_y := 1.0
var debug_ui := false
var demo := false
var no_audio := false
var sparks: Array = []
var shake := 0.0
var st_t := 0.0
var st_mark := 0.0
var frame_px := Vector2(1920.0, 1080.0)


func _ready() -> void:
	bridge = get_node_or_null("/root/GameDirector")
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
		input_mode = "face"
	if not no_audio:
		synth.setup(self)
	arena_cells = Vector2i(int(ARENA.size.x / CELL), int(ARENA.size.y / CELL))
	printerr("TRON START players=", _human_count_hint(), " mode=", input_mode)
	_set_state(St.WAIT)
	state_t = 100.0 if selftest == "tron" else 0.0   # в автотесте не ждём игроков


func _exit_tree() -> void:
	synth.stop()


func _human_count_hint() -> int:
	if demo:
		return 1
	if bridge == null:
		return 0
	return mini(bridge.players().size(), MAX_HUMANS)


# ---------------------------------------------------------------- игровой цикл


func _process(dt: float) -> void:
	state_t += dt
	synth.pump()
	shake = maxf(0.0, shake - dt * 1.6)
	_update_sparks(dt)
	match state:
		St.WAIT:
			_tick_wait(dt)
		St.READY:
			_collect_inputs(dt)
			if state_t >= 1.8:
				_set_state(St.RUN)
		St.RUN:
			_tick_run(dt)
		St.RESULT:
			if state_t >= 2.5:
				_next_round()
		St.OVER:
			if state_t >= 8.0:
				_back_to_menu()
	queue_redraw()
	if selftest != "":
		_selftest_tick()


func _set_state(s: int) -> void:
	state = s
	state_t = 0.0
	if selftest != "":
		printerr("TRON STATE ", s)


func _tick_wait(dt: float) -> void:
	if bridge != null:
		bridge.rotation_checkpoint()
	if state_t < 0.2:
		return
	var humans := _humans()
	if selftest == "tron":
		_start_match([], 4)
	elif demo:
		_start_match([], 4)      # в демо один человек на стрелках + боты
	elif humans.size() >= 1:
		# одному человеку нужны соперники, иначе играть не с кем
		_start_match(humans, 4 if humans.size() == 1 else humans.size())


func _frame_px() -> Vector2:
	var px := Vector2(bridge.frame_size)
	if px.x < 1.0 or px.y < 1.0:
		px = Vector2(1920.0, 1080.0)
	return px


func _aspect() -> float:
	var px := _frame_px()
	return px.x / px.y


func _humans() -> Array:
	if demo:
		return []
	if bridge == null:
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


func _start_match(humans: Array, total: int) -> void:
	bikes.clear()
	solo = humans.size() == 1 and selftest == ""
	round_no = 0
	var n := mini(maxi(total, 2), 4)
	for i in n:
		var b := Bike.new()
		b.id = i
		b.human = i < humans.size() or (demo and i == 0)
		b.color = Neo.player_color(i)
		b.title = "игрок %d" % (i + 1)
		if b.human and i < humans.size():
			b.color = humans[i].color if humans[i].color is Color else b.color
			b.track_slot = humans[i].slot
			b.track_id = humans[i].track_id
		elif not b.human:
			b.title = "бот %d" % (i + 1)
			b.color = Neo.with_alpha(Neo.player_color(i), 0.75)
		bikes.append(b)
	_new_round()


func _new_round() -> void:
	round_no += 1
	occ.clear()
	sparks.clear()
	survival = 0.0
	frozen = false
	tick_acc = 0.0
	winner = -1
	var n := bikes.size()
	for i in n:
		var b: Bike = bikes[i]
		b.alive = true
		b.trail.clear()
		_place_bike(b, i, n)
	_set_state(St.READY)
	synth.tone(330.0, 660.0, 0.12, 0.25)


func _place_bike(b: Bike, i: int, n: int) -> void:
	# Ставим по кругу вокруг центра и направляем внутрь — так честно при любом
	# числе игроков.
	var center := Vector2(arena_cells) * 0.5
	var radius := minf(center.x, center.y) * 0.72
	var ang := -PI * 0.5 + TAU * float(i) / float(maxi(n, 1))
	if n == 1:
		ang = PI
	var pos := center + Vector2(cos(ang), sin(ang)) * radius
	b.cell = Vector2i(int(clampf(pos.x, 1.0, arena_cells.x - 2.0)),
		int(clampf(pos.y, 1.0, arena_cells.y - 2.0)))
	var to_center := center - Vector2(b.cell)
	if to_center.length() < 0.01:
		to_center = Vector2(1, 0)
	if absf(to_center.x) >= absf(to_center.y):
		b.dir = Vector2i.RIGHT if to_center.x > 0.0 else Vector2i.LEFT
	else:
		b.dir = Vector2i.DOWN if to_center.y > 0.0 else Vector2i.UP
	b.want = b.dir
	b.trail.append(b.cell)
	occ[b.cell] = b.id


func _collect_inputs(dt: float) -> void:
	# Ввод людей читаем КАЖДЫЙ кадр: в отсчёте копим нейтраль, в игре — рулим.
	if demo or bridge == null:
		return
	var players: Array = bridge.players()
	for b in bikes:
		if not b.human:
			continue
		var p = null
		for cand in players:
			if cand.slot == b.track_slot and cand.track_id == b.track_id \
					and str(cand.state) == "confirmed":
				p = cand
				break
		if p == null:
			continue
		b.inp.mode = input_mode
		b.inp.gain = gain
		b.inp.flip_x = flip_x
		b.inp.flip_y = flip_y
		b.inp.update(p, dt, _aspect(), _frame_px())
		b.nose = Inp.nose_screen(p, _frame_px())
		if not b.inp.have_neutral:
			b.inp.accumulate()
			if b.inp.samples >= 12:
				b.inp.finish_calibration()
				printerr("TRON CALIB slot=%d nx=%.2f ny=%.2f" % [b.track_slot, b.inp.nx, b.inp.ny])
		if selftest == "log" and Engine.get_process_frames() % 20 == 0:
			printerr("TRON INPUT slot=%d ax=%+.2f ay=%+.2f neutral=%s want=(%d,%d)" % [
				b.track_slot, b.inp.ax, b.inp.ay, b.inp.have_neutral, b.want.x, b.want.y])


func _tick_run(dt: float) -> void:
	_collect_inputs(dt)
	_update_frozen()
	if frozen:
		if bridge != null:
			bridge.rotation_checkpoint()
		return
	survival += dt
	_read_humans(dt)
	for b in bikes:
		if b.alive and not b.human:
			b.want = _bot_dir(b)
	tick_acc += dt
	var guard := 0
	while tick_acc >= TICK and guard < 8:
		tick_acc -= TICK
		guard += 1
		_step_world()
		if state != St.RUN:
			return


func _update_frozen() -> void:
	# Игрок вышел из кадра или поток замолк — замораживаем раунд, чтобы
	# мотоцикл не разбился без хозяина.
	if demo or bridge == null:
		frozen = false
		return
	if bridge.tracking_age() > STALE:
		frozen = true
		return
	var ps: Array = bridge.players()
	for b in bikes:
		if not b.human:
			continue
		var found := false
		for p in ps:
			if p.slot == b.track_slot and p.track_id == b.track_id \
					and str(p.state) == "confirmed":
				found = true
				break
		if not found:
			frozen = true
			return
	frozen = false


func _read_humans(_dt: float) -> void:
	if demo:
		var b0: Bike = bikes[0] if bikes.size() > 0 else null
		if b0 != null:
			var k := Vector2i.ZERO
			if Input.is_key_pressed(KEY_LEFT):
				k = Vector2i.LEFT
			elif Input.is_key_pressed(KEY_RIGHT):
				k = Vector2i.RIGHT
			elif Input.is_key_pressed(KEY_UP):
				k = Vector2i.UP
			elif Input.is_key_pressed(KEY_DOWN):
				k = Vector2i.DOWN
			if k != Vector2i.ZERO:
				b0.want = k
		return
	for b in bikes:
		if not b.human or not b.inp.have_neutral:
			continue
		var ax: float = b.inp.ax
		var ay: float = b.inp.ay
		if maxf(absf(ax), absf(ay)) < TURN_DEADZONE:
			continue
		# гистерезис: на границе осей не переключаем направление туда-сюда
		if absf(ax) >= absf(ay) * 1.15:
			b.want = Vector2i.RIGHT if ax > 0.0 else Vector2i.LEFT
		elif absf(ay) >= absf(ax) * 1.15:
			b.want = Vector2i.DOWN if ay > 0.0 else Vector2i.UP


func _step_world() -> void:
	var targets := {}
	for b in bikes:
		if not b.alive:
			continue
		# поворот: нельзя развернуться на 180 градусов
		if b.want != Vector2i.ZERO and b.want != -b.dir:
			b.dir = b.want
		targets[b.id] = b.cell + b.dir
	var dead := {}
	for b in bikes:
		if not b.alive:
			continue
		var t: Vector2i = targets[b.id]
		if t.x < 0 or t.y < 0 or t.x >= arena_cells.x or t.y >= arena_cells.y:
			dead[b.id] = true
		elif occ.has(t):
			dead[b.id] = true
	# лобовое столкновение: двое в одну клетку
	for a in bikes:
		if not a.alive or dead.has(a.id):
			continue
		for c in bikes:
			if c.id != a.id and c.alive and not dead.has(c.id) \
					and targets[c.id] == targets[a.id]:
				dead[a.id] = true
	for b in bikes:
		if not b.alive:
			continue
		if dead.has(b.id):
			b.alive = false
			_burst(_cell_center(b.cell), b.color, 22)
			synth.tone(220.0, 40.0, 0.22, 0.35)
			shake = maxf(shake, 0.35)
		else:
			b.cell = targets[b.id]
			b.trail.append(b.cell)
			occ[b.cell] = b.id
			synth.tone(140.0, 120.0, 0.03, 0.05)
	var alive := 0
	var last := -1
	for b in bikes:
		if b.alive:
			alive += 1
			last = b.id
	if alive <= 1:
		_end_round(last)


func _end_round(last: int) -> void:
	winner = last
	if last >= 0:
		bikes[last].score += 1
		synth.tone(660.0, 990.0, 0.2, 0.35)
		synth.tone(990.0, 1320.0, 0.2, 0.25, 0.12)
	else:
		synth.tone(180.0, 90.0, 0.3, 0.3)
	if solo:
		if best_time <= 0.0 or survival > best_time:
			best_time = survival
		if round_no >= 3:
			_set_state(St.OVER)
			return
	_set_state(St.RESULT)


func _next_round() -> void:
	if not solo:
		for b in bikes:
			if b.score >= WIN_ROUNDS:
				_set_state(St.OVER)
				return
	if solo and round_no >= 3:
		_set_state(St.OVER)
		return
	_new_round()


func _bot_dir(b: Bike) -> Vector2i:
	# Простой ИИ: из трёх безопасных направлений берём то, где дольше живёшь.
	var best := b.dir
	var best_score := -1
	var opts := [b.dir, _turn_left(b.dir), _turn_right(b.dir)]
	for d in opts:
		var score := 0
		var c: Vector2i = b.cell
		for i in 12:
			c += d
			if c.x < 0 or c.y < 0 or c.x >= arena_cells.x or c.y >= arena_cells.y:
				break
			if occ.has(c):
				break
			score += 1
		# чуть тянемся к центру, чтобы боты не липли к стене
		var to_center := Vector2(arena_cells) * 0.5 - Vector2(b.cell)
		score += clampf(Vector2(d).dot(to_center.normalized()), -1.0, 1.0) * 1.5
		score += b.wander * 0.001
		if score > best_score:
			best_score = score
			best = d
	b.wander = (b.wander + 7) % 13
	if b.wander == 0:
		best = opts[randi() % opts.size()]
	return best


static func _turn_left(d: Vector2i) -> Vector2i:
	return Vector2i(d.y, -d.x)


static func _turn_right(d: Vector2i) -> Vector2i:
	return Vector2i(-d.y, d.x)


func _back_to_menu() -> void:
	if demo or selftest != "":
		# без трекинга остаёмся в игре: в меню некому голосовать
		round_no = 0
		for b in bikes:
			b.score = 0
		_new_round()
		return
	get_tree().change_scene_to_file(MENU_SCENE)


# ---------------------------------------------------------------- эффекты


func _cell_center(c: Vector2i) -> Vector2:
	return ARENA.position + (Vector2(c) + Vector2(0.5, 0.5)) * CELL


func _burst(pos: Vector2, col: Color, n: int) -> void:
	for i in n:
		var a := randf() * TAU
		var sp := randf_range(60.0, 420.0)
		sparks.append({"p": pos, "v": Vector2(cos(a), sin(a)) * sp, "t": 0.0,
			"life": randf_range(0.25, 0.7), "c": col})


func _update_sparks(dt: float) -> void:
	var i := sparks.size() - 1
	while i >= 0:
		var s: Dictionary = sparks[i]
		s.t += dt
		if s.t >= s.life:
			sparks.remove_at(i)
		else:
			s.p += s.v * dt
			s.v *= 1.0 - 2.4 * dt
		i -= 1


# ---------------------------------------------------------------- отрисовка


func _draw() -> void:
	Neo.grid_bg(self, Vector2(1920, 1080))
	if shake > 0.0:
		var tm := Time.get_ticks_msec() * 0.001
		draw_set_transform(Vector2(sin(tm * 71.0) * shake * 8.0, cos(tm * 63.0) * shake * 6.0),
			0.0, Vector2.ONE)
	_draw_arena()
	_draw_trails()
	_draw_bikes()
	_draw_sparks()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud()
	_draw_overlay()
	Neo.scanlines(self, Vector2(1920, 1080))


func _draw_arena() -> void:
	draw_rect(ARENA, Color(0.03, 0.0, 0.10, 0.9))
	var x := ARENA.position.x
	while x <= ARENA.end.x + 0.5:
		draw_line(Vector2(x, ARENA.position.y), Vector2(x, ARENA.end.y),
			Color(Neo.LINE.r, Neo.LINE.g, Neo.LINE.b, 0.10), 1.0)
		x += CELL
	var y := ARENA.position.y
	while y <= ARENA.end.y + 0.5:
		draw_line(Vector2(ARENA.position.x, y), Vector2(ARENA.end.x, y),
			Color(Neo.LINE.r, Neo.LINE.g, Neo.LINE.b, 0.10), 1.0)
		y += CELL
	draw_rect(ARENA, Color(Neo.LINE.r, Neo.LINE.g, Neo.LINE.b, 0.35), false, 6.0)
	draw_rect(ARENA, Neo.LINE, false, 2.0)


func _draw_trails() -> void:
	for b in bikes:
		if b.trail.size() < 2:
			continue
		var pts := PackedVector2Array()
		for c in b.trail:
			pts.append(_cell_center(c))
		var col: Color = b.color if b.alive else Neo.with_alpha(b.color, 0.5)
		draw_polyline(pts, Neo.with_alpha(col, 0.16), CELL * 1.5, true)
		draw_polyline(pts, col, CELL * 0.62, true)


func _draw_bikes() -> void:
	for b in bikes:
		if not b.alive:
			continue
		var p := _cell_center(b.cell)
		draw_circle(p, CELL * 1.5, Neo.with_alpha(b.color, 0.18))
		draw_circle(p, CELL * 0.75, b.color)
		draw_circle(p, CELL * 0.35, Color.WHITE)
		# курсор лица — куда целится игрок
		if b.human:
			var c := Vector2(b.inp.ax, b.inp.ay)
			if c.length() > 0.05:
				Neo.glow(self, p, p + c * 70.0, Neo.with_alpha(b.color, 0.8), 2.0)


func _draw_sparks() -> void:
	for s in sparks:
		var k: float = 1.0 - s.t / s.life
		draw_circle(s.p, 3.0 * k + 1.0, Neo.with_alpha(s.c, k))


func _draw_hud() -> void:
	Neo.text(self, "ТРОН", Vector2(960, 120), 64, Neo.TEXT)
	Neo.text(self, "раунд %d · до %d побед" % [round_no, WIN_ROUNDS], Vector2(960, 165), 24, Neo.DIM)
	var n := bikes.size()
	var total_w := n * 240.0
	var x0 := 960.0 - total_w * 0.5
	for i in n:
		var b: Bike = bikes[i]
		var p := Vector2(x0 + 240.0 * i + 120.0, 215.0)
		draw_circle(p - Vector2(58, 0), 12.0, b.color if b.alive else Neo.with_alpha(b.color, 0.35))
		Neo.text(self, "%s  %d" % [b.title, b.score], p, 28, Neo.TEXT)
	var hint := "отклоните лицо в сторону — мотоцикл повернёт · в след нельзя"
	if demo:
		hint = "стрелки — поворот · в след нельзя"
	Neo.text(self, hint, Vector2(960, 1000), 24, Neo.DIM)
	if frozen and state == St.RUN:
		Neo.text(self, "ПАУЗА: ждём игроков в кадре", Vector2(960, 620), 40, Neo.WARN)
	if solo:
		Neo.text(self, "продержался %.1f с · лучший %.1f с · попытка %d/3" % [
			survival, best_time, round_no], Vector2(960, 955), 22, Neo.DIM)
	if debug_ui:
		var y := 900.0
		for b in bikes:
			if b.human:
				Neo.text(self, "%s ax=%+.2f ay=%+.2f" % [b.title, b.inp.ax, b.inp.ay],
					Vector2(960, y), 18, Neo.DIM)
				y += 22.0


func _draw_overlay() -> void:
	match state:
		St.WAIT:
			Neo.text(self, "ВСТАНЬТЕ ПЕРЕД КАМЕРОЙ", Vector2(960, 560), 44, Neo.TEXT)
			Neo.text(self, "от 1 до 4 игроков", Vector2(960, 615), 26, Neo.DIM)
		St.READY:
			var k := ceili(1.8 - state_t)
			Neo.text(self, str(maxi(k, 1)), Vector2(960, 560), 120, Neo.PUCK)
		St.RESULT:
			var who := "никто" if winner < 0 else bikes[winner].title
			Neo.text(self, "раунд взял %s" % who, Vector2(960, 560), 46,
				Neo.TEXT if winner < 0 else bikes[winner].color)
		St.OVER:
			var best := 0
			for b in bikes:
				best = maxi(best, b.score)
			var lead := ""
			for b in bikes:
				if b.score == best:
					lead = b.title
					break
			if solo:
				Neo.text(self, "лучшее время %.1f с" % best_time, Vector2(960, 540), 56, Neo.OK)
			else:
				Neo.text(self, "победил %s" % lead, Vector2(960, 540), 56, Neo.OK)
			Neo.text(self, "возвращаемся в меню…", Vector2(960, 610), 26, Neo.DIM)


# ---------------------------------------------------------------- автотест


func _selftest_tick() -> void:
	st_t += get_process_delta_time()
	if selftest != "tron":
		return
	if st_t - st_mark > 25.0:
		printerr("SELFTEST TRON FAIL: раунд не закончился за 25 с")
		get_tree().quit(1)
		return
	if state == St.RESULT and st_mark == 0.0:
		st_mark = st_t
		var who := "никто" if winner < 0 else bikes[winner].title
		printerr("SELFTEST TRON PASS: раунд %d закончился, победил %s" % [round_no, who])
		get_tree().quit(0)
