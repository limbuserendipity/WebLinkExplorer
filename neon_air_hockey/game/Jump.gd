extends Node2D
## «Неон-джамп»: прыжки по платформам вверх — механика Doodle Jump в неоновом
## стиле аркады. 1–4 игрока, все в одном кадре и в одном мире.
##
## Правило, из-за которого гонка не обрывается: упал ниже кадра — не выбываешь.
## Через пару секунд падаешь обратно сверху, на платформу, и платишь за это
## очками (−250). Так один промах не решает исход — можно догнать.
##
## Управление как во всей аркаде: лицо (или рука) отклоняется в сторону —
## человечек бежит вбок, прыгает сам, как только встал на платформу.
## Мир зациклен по горизонтали: убежал за правый край — появился слева.

const Inp := preload("res://core/FaceInput.gd")
const Neo := preload("res://core/Neon.gd")
const Sfx := preload("res://core/Sfx.gd")
const CamView := preload("res://core/CamView.gd")
const InputHint := preload("res://core/InputHint.gd")
const Lay := preload("res://core/Layout.gd")

var ARENA: Rect2 = Lay.JUMP_ARENA

const GRAV := 2200.0             # ускорение падения, px/с²
const JUMP_V := 900.0            # скорость отскока: высота прыжка ≈ 184 px
const RUN_SPEED := 440.0         # боковая скорость при полном отклонении
const ACCEL_RATE := 11.0         # как быстро разгоняемся
const BODY_R := 18.0
const STEP := 1.0 / 120.0        # фиксированный шаг физики
const BAND := 92.0               # вертикальный шаг платформ
const PLAT_H := 18.0
const PENALTY := 250             # минус очков за падение
const RESPAWN := 2.2             # сколько ждать возвращения, с
const GHOST := 1.2               # мигание после возврата, с
const ROUND_TIME := 90.0         # длительность раунда, с
const MAX_HUMANS := 4
const STALE := 0.5
const FALL_MARGIN := 40.0        # насколько ниже кадра считается «упал»
const MENU_SCENE := "res://ui/Menu.tscn"

enum St { WAIT, READY, RUN, RESULT, OVER }


class Pl:
	var x := 0.0                 # левый край платформы, мир
	var y := 0.0                 # верхняя кромка, мир (вверх — отрицательные)
	var w := 118.0
	var vx := 0.0                # едет вбок
	var kind := 0                # 0 обычная, 1 едет, 2 узкая


class Player:
	var id := 0
	var human := false
	var color := Color.WHITE
	var title := "бот"
	var pos := Vector2.ZERO      # центр тела, мир
	var vel := Vector2.ZERO
	var prev_y := 0.0
	var alive := true
	var falls := 0
	var best := 0.0              # лучшая высота, px (положительная)
	var respawn_t := 0.0
	var ghost := 0.0
	var flash := 0.0
	var ax := 0.0
	var trail: Array = []
	var inp := Inp.new()
	var track_slot := -1
	var track_id := -1


var bridge: Node
var state: int = St.WAIT
var state_t := 0.0
var players: Array[Player] = []
var plats: Array[Pl] = []
var cam_y := 0.0                 # мировой y нижней кромки кадра
var gen_y := 0.0                 # до какой высоты уже насоздавали платформ
var gen_x := 0.0                 # x последней созданной платформы (случайная походка)
var time_left := ROUND_TIME
var winner := -1
var falls_total := 0
var respawns_total := 0
var frozen := false
var solo := false
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
var flashes: Array = []
var acc := 0.0
var frame_px := Vector2(1920.0, 1080.0)

# автотест
var st_t := 0.0
var probe_done := false
var probe_t := 0.0
var probe_falls := 0
var probe_score := 0
var probe_after_fall := 0


func _ready() -> void:
	bridge = get_node_or_null("/root/GameDirector")
	cam_view = CamView.new()
	add_child(cam_view)
	cam_view.setup(Lay.JUMP_CAM)
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
	if not no_audio:
		synth.setup(self)
	# Раскладка по сетке: поле 1360×720, справа камера, подсказка и состояние.
	var frac := ARENA.get_area() / (Lay.W * Lay.H)
	var clean: bool = not ARENA.intersects(Lay.JUMP_CAM) \
		and not ARENA.intersects(Lay.JUMP_HINT) \
		and not ARENA.intersects(Lay.JUMP_STATUS)
	printerr("JUMP START players=%d mode=%s поле=%.0fx%.0f доля=%.2f чисто=%s" % [
		_human_count_hint(), input_mode, ARENA.size.x, ARENA.size.y, frac, clean])
	_set_state(St.WAIT)
	state_t = 100.0 if selftest == "jump" else 0.0   # в автотесте не ждём игроков


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
	_update_cam_view()
	match state:
		St.WAIT:
			_tick_wait(dt)
		St.READY:
			_collect_inputs(dt)
			_read_humans(dt)
			if state_t >= 1.8:
				_set_state(St.RUN)
		St.RUN:
			_tick_run(dt)
		St.RESULT:
			if state_t >= 5.0:
				_set_state(St.OVER)
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
		printerr("JUMP STATE ", s)


func _tick_wait(_dt: float) -> void:
	if bridge != null:
		bridge.rotation_checkpoint()
	if state_t < 0.2:
		return
	var humans := _humans()
	if selftest == "jump":
		_start_match([])
	elif demo:
		_start_match([])                     # один на стрелках + боты
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
	solo = humans.size() == 1 and selftest == ""
	# одному человеку нужна компания, иначе гонки нет
	var n := mini(maxi(humans.size(), 2), MAX_HUMANS)
	if humans.size() > 2:
		n = humans.size()
	falls_total = 0
	respawns_total = 0
	for i in n:
		var p := Player.new()
		p.id = i
		p.human = i < humans.size() or (demo and i == 0)
		p.color = Neo.player_color(i)
		p.title = "игрок %d" % (i + 1)
		if p.human and i < humans.size():
			p.color = humans[i].color if humans[i].color is Color else p.color
			p.track_slot = humans[i].slot
			p.track_id = humans[i].track_id
		elif not p.human:
			p.title = "бот %d" % (i + 1)
			p.color = Neo.with_alpha(Neo.player_color(i), 0.75)
		players.append(p)
	printerr("JUMP MATCH players=%d людей=%d" % [players.size(), humans.size()])
	_new_round()


func _new_round() -> void:
	plats.clear()
	flashes.clear()
	cam_y = 0.0
	gen_y = 0.0
	gen_x = ARENA.size.x * 0.5
	time_left = ROUND_TIME
	winner = -1
	acc = 0.0
	frozen = false
	var w := ARENA.size.x
	# стартовый «пол»: несколько широких платформ на нулевой высоте
	var slots := maxi(players.size(), 2)
	for i in slots:
		var seg := w / float(slots)
		_add_plat(seg * float(i) + 26.0, 0.0, seg - 52.0, 0, 0.0)
	for i in players.size():
		var p: Player = players[i]
		var seg := w / float(slots)
		p.pos = Vector2(seg * float(i) + 26.0 + (seg - 52.0) * 0.5, -BODY_R)
		p.vel = Vector2.ZERO
		p.alive = true
		p.falls = 0
		p.best = 0.0
		p.respawn_t = 0.0
		p.ghost = 0.0
		p.flash = 0.0
		p.ax = 0.0
		p.trail.clear()
		p.inp.reset_calibration()
	_spawn_platforms()
	_set_state(St.READY)
	synth.tone(330.0, 660.0, 0.12, 0.25)


func _add_plat(x: float, y: float, w: float, kind: int, vx: float) -> void:
	var pl := Pl.new()
	pl.x = clampf(x, 8.0, ARENA.size.x - w - 8.0)
	pl.y = y
	pl.w = w
	pl.kind = kind
	pl.vx = vx
	plats.append(pl)


func _spawn_platforms() -> void:
	# Достраиваем платформы вверх, пока хватает на полтора экрана над кадром.
	var guard := 0
	while gen_y > cam_y - ARENA.size.y * 1.5 and guard < 200:
		guard += 1
		gen_y -= BAND
		var idx := int(-gen_y / BAND)
		var kind := 0
		if idx % 7 == 0:
			kind = 2
		elif idx % 5 == 0:
			kind = 1
		var w := 86.0 if kind == 2 else 118.0
		# «Случайная походка»: каждая следующая платформа не дальше 150 px по
		# горизонтали — так до неё всегда можно допрыгнуть (и боту, и человеку).
		var step_x := fposmod(float(idx) * 211.7, 300.0) - 150.0
		gen_x = clampf(gen_x + step_x, 16.0, ARENA.size.x - w - 16.0)
		_add_plat(gen_x, gen_y, w, kind, 70.0 * (1.0 if idx % 2 == 0 else -1.0) if kind == 1 else 0.0)
		# иногда вторая платформа в той же полосе — чтобы был выбор, куда прыгать
		if idx % 3 == 1:
			var x2 := clampf(gen_x + (250.0 if idx % 2 == 0 else -250.0), 16.0, ARENA.size.x - 134.0)
			_add_plat(x2, gen_y - BAND * 0.5, 118.0, 0, 0.0)


func _tick_run(dt: float) -> void:
	_collect_inputs(dt)
	_read_humans(dt)
	_update_frozen()
	if frozen:
		if bridge != null:
			bridge.rotation_checkpoint()
		return
	time_left = maxf(0.0, time_left - dt)
	acc += dt
	var guard := 0
	while acc >= STEP and guard < 12:
		acc -= STEP
		guard += 1
		_step(STEP)
	if time_left <= 0.0:
		_finish()


func _step(dt: float) -> void:
	for pl in plats:
		if pl.vx != 0.0:
			pl.x += pl.vx * dt
			if pl.x < 8.0:
				pl.x = 8.0
				pl.vx = -pl.vx
			elif pl.x + pl.w > ARENA.size.x - 8.0:
				pl.x = ARENA.size.x - 8.0 - pl.w
				pl.vx = -pl.vx
	for p in players:
		if not p.human and p.alive:
			p.ax = _bot_ax(p)
		_step_player(p, dt)
	_move_camera(dt)
	_spawn_platforms()
	# давно ушедшие вниз платформы выкидываем, чтобы список не рос
	if plats.size() > 260:
		var keep: Array[Pl] = []
		for pl in plats:
			if pl.y > cam_y - ARENA.size.y * 1.8:
				keep.append(pl)
		plats = keep


func _step_player(p: Player, dt: float) -> void:
	if not p.alive:
		p.respawn_t -= dt
		if p.respawn_t <= 0.0:
			_respawn(p)
		return
	p.ghost = maxf(0.0, p.ghost - dt)
	p.flash = maxf(0.0, p.flash - dt * 3.0)
	p.vel.x = lerpf(p.vel.x, p.ax * RUN_SPEED, 1.0 - exp(-ACCEL_RATE * dt))
	p.prev_y = p.pos.y
	p.vel.y += GRAV * dt
	p.pos += p.vel * dt
	var w := ARENA.size.x
	if p.pos.x < 0.0:
		p.pos.x += w
	elif p.pos.x > w:
		p.pos.x -= w
	if p.vel.y > 0.0:
		for pl in plats:
			if p.prev_y + BODY_R > pl.y + 0.5 or p.pos.y + BODY_R < pl.y:
				continue
			if p.pos.x < pl.x - 4.0 or p.pos.x > pl.x + pl.w + 4.0:
				continue
			p.pos.y = pl.y - BODY_R
			p.vel.y = -JUMP_V
			p.flash = 1.0
			if p.human:
				synth.tone(520.0, 880.0, 0.05, 0.16)
			break
	p.best = maxf(p.best, -p.pos.y)
	p.trail.append(p.pos)
	if p.trail.size() > 10:
		p.trail.pop_front()
	if p.pos.y > cam_y + FALL_MARGIN:
		_fall(p)


## Бот целится в ближайшую платформу над собой, до которой дотянется; если
## такой нет — идёт под ближайшую сверху и пробует ещё раз.
func _bot_ax(p: Player) -> float:
	var best: Pl = null
	var best_dy := 1e9
	var far: Pl = null
	var far_dy := 1e9
	for pl in plats:
		# только платформы, до которых реально дотянуться прыжком
		var dy := (p.pos.y + BODY_R) - pl.y      # >0 — платформа выше ног
		if dy < 24.0 or dy > 420.0:
			continue
		var d := (pl.x + pl.w * 0.5) - p.pos.x
		var span := ARENA.size.x
		if d > span * 0.5:
			d -= span
		elif d < -span * 0.5:
			d += span
		if dy < far_dy:
			far = pl
			far_dy = dy
		if absf(d) <= 230.0 and dy < best_dy:
			best = pl
			best_dy = dy
	var target: Pl = best if best != null else far
	if target == null:
		return 0.0
	var dx := (target.x + target.w * 0.5) - p.pos.x
	var w := ARENA.size.x
	if dx > w * 0.5:
		dx -= w
	elif dx < -w * 0.5:
		dx += w
	return clampf(dx / 90.0, -1.0, 1.0)


func _move_camera(dt: float) -> void:
	var top := INF
	for p in players:
		if p.alive:
			top = minf(top, p.pos.y)
	if top == INF:
		return
	# Камера не дёргается, пока лидер ниже середины кадра: на старте он стоит
	# на полу, и кадр стоит. Дальше лидер «тянет» кадр за собой (только вверх).
	var limit := cam_y - ARENA.size.y * 0.52
	if top < limit:
		var target := top + ARENA.size.y * 0.52
		cam_y = lerpf(cam_y, target, 1.0 - exp(-7.0 * dt))
		if cam_y < target + 0.5:
			cam_y = target


func _fall(p: Player) -> void:
	if not p.alive:
		return
	p.alive = false
	p.falls += 1
	falls_total += 1
	p.respawn_t = RESPAWN
	p.vel = Vector2.ZERO
	p.trail.clear()
	var at := Vector2(p.pos.x, cam_y + FALL_MARGIN - 30.0)
	flashes.append({"p": _screen(at), "t": 1.5, "c": p.color, "txt": "−%d" % PENALTY})
	synth.tone(200.0, 90.0, 0.22, 0.28)
	p.pos.y = cam_y + FALL_MARGIN


func _respawn(p: Player) -> void:
	# Падает обратно сверху, на платформу в верхней половине кадра.
	var best: Pl = null
	var lo := cam_y - ARENA.size.y * 0.80
	var hi := cam_y - ARENA.size.y * 0.35
	for pl in plats:
		if pl.y < hi and pl.y > lo:
			if best == null or pl.y > best.y:      # ниже — безопаснее
				best = pl
	var x := ARENA.size.x * 0.5
	var y := cam_y - ARENA.size.y * 0.5
	if best != null:
		x = best.x + best.w * 0.5
		y = best.y - 130.0
	p.pos = Vector2(x, y)
	p.vel = Vector2(0.0, 140.0)
	p.alive = true
	p.ghost = GHOST
	p.flash = 1.0
	respawns_total += 1
	flashes.append({"p": _screen(p.pos), "t": 1.2, "c": p.color, "txt": p.title})
	synth.tone(660.0, 990.0, 0.10, 0.18)


func _finish() -> void:
	var lead := _leader()
	winner = -1 if lead == null else lead.id
	_set_state(St.RESULT)
	synth.tone(440.0, 880.0, 0.20, 0.3)


func _score(p: Player) -> int:
	return maxi(0, int(p.best) - p.falls * PENALTY)


func _leader() -> Player:
	var best: Player = null
	for p in players:
		if best == null or _score(p) > _score(best):
			best = p
	return best


func _back_to_menu() -> void:
	if demo or selftest != "":
		_new_round()          # без трекинга остаёмся в игре
		return
	get_tree().change_scene_to_file(MENU_SCENE)


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
				printerr("JUMP CALIB slot=%d nx=%.2f ny=%.2f" % [p.track_slot, p.inp.nx, p.inp.ny])


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
		return
	for p in players:
		if not p.human or not p.inp.have_neutral:
			continue
		p.ax = clampf(p.inp.ax, -1.0, 1.0)


func _update_frozen() -> void:
	# Поток замолк или игрок вышел из кадра — замораживаем физику, чтобы
	# человечек не улетел вниз без хозяина.
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
	if event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		match k:
			KEY_ESCAPE:
				_back_to_menu()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
				var idx := k - KEY_1
				if idx < Inp.MODES.size():
					input_mode = Inp.MODES[idx]
					for p in players:
						p.inp.mode = input_mode
					printerr("JUMP MODE ", input_mode)


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


func _screen(w: Vector2) -> Vector2:
	return Vector2(ARENA.position.x + w.x, ARENA.end.y - cam_y + w.y)


func _draw() -> void:
	Neo.grid_bg(self, Vector2(Lay.W, Lay.H))
	_draw_field()
	_draw_platforms()
	_draw_players()
	_draw_flashes()
	_draw_ruler()
	_draw_hud()
	Neo.scanlines(self, Vector2(Lay.W, Lay.H))


func _draw_field() -> void:
	var a := ARENA
	draw_rect(a, Color(0.012, 0.0, 0.05, 0.94))
	var step := 80.0
	var x := 0.0
	while x <= a.size.x:
		draw_line(Vector2(a.position.x + x, a.position.y), Vector2(a.position.x + x, a.end.y),
			Neo.with_alpha(Neo.LINE, 0.09), 1.0)
		x += step
	var y := fposmod(-cam_y, step)
	while y <= a.size.y:
		draw_line(Vector2(a.position.x, a.position.y + y), Vector2(a.end.x, a.position.y + y),
			Neo.with_alpha(Neo.LINE, 0.09), 1.0)
		y += step
	for i in 80:
		var sx := a.position.x + fposmod(float(i) * 311.7, a.size.x)
		var sy := a.position.y + fposmod(float(i) * 143.3 - cam_y * 0.25, a.size.y)
		var tw := 0.35 + 0.35 * sin(Time.get_ticks_msec() * 0.001 + float(i))
		draw_circle(Vector2(sx, sy), 1.3, Color(0.8, 0.85, 1.0, 0.12 + 0.22 * tw))
	draw_rect(a, Neo.with_alpha(Neo.LINE, 0.55), false, 1.5)


func _draw_platforms() -> void:
	for pl in plats:
		var sy := ARENA.end.y - cam_y + pl.y
		if sy < ARENA.position.y - 30.0 or sy > ARENA.end.y + 30.0:
			continue
		var r := Rect2(ARENA.position.x + pl.x, sy - PLAT_H, pl.w, PLAT_H)
		var col: Color = Neo.OK if pl.kind == 2 else (Neo.PUCK if pl.kind == 1 else Neo.LEFT)
		draw_rect(Rect2(r.position + Vector2(0.0, -2.0), r.size + Vector2(0.0, 4.0)),
			Neo.with_alpha(col, 0.10))
		draw_rect(r, Neo.with_alpha(col, 0.16))
		draw_rect(r, Neo.with_alpha(col, 0.9), false, 2.0)
		draw_line(Vector2(r.position.x + 8.0, r.position.y + 4.0),
			Vector2(r.end.x - 8.0, r.position.y + 4.0), Neo.with_alpha(col, 0.85), 2.0)


func _draw_players() -> void:
	for p in players:
		if not p.alive:
			continue
		var sp := _screen(p.pos)
		var a := 1.0
		if p.ghost > 0.0:
			a = 0.35 + 0.65 * absf(sin(p.ghost * 9.0))
		var col := Neo.with_alpha(p.color, a)
		# хвост
		for i in p.trail.size():
			var t: Vector2 = p.trail[i]
			var k := float(i) / float(maxi(p.trail.size(), 1))
			draw_circle(_screen(t), BODY_R * 0.55 * k, Neo.with_alpha(p.color, 0.10 * k))
		draw_circle(sp, BODY_R + 6.0, Neo.with_alpha(p.color, 0.10 * a))
		draw_circle(sp, BODY_R, Neo.with_alpha(p.color, 0.20 * a))
		draw_arc(sp, BODY_R, 0.0, TAU, 28, col, 2.5, true)
		var look := clampf(p.vel.x / RUN_SPEED, -1.0, 1.0) * 4.0
		draw_circle(sp + Vector2(-5.0 + look, -4.0), 3.2, col)
		draw_circle(sp + Vector2(5.0 + look, -4.0), 3.2, col)
		if p.flash > 0.0:
			draw_arc(sp, BODY_R + 8.0 + (1.0 - p.flash) * 26.0, 0.0, TAU, 32,
				Neo.with_alpha(p.color, 0.5 * p.flash), 2.0, true)
		Neo.text(self, p.title, sp + Vector2(0.0, BODY_R + 22.0), Lay.T_TINY,
			Neo.with_alpha(Neo.TEXT, 0.7 * a))


func _draw_flashes() -> void:
	var dt := get_process_delta_time()
	var keep: Array = []
	for f in flashes:
		var d: Dictionary = f
		d.t = float(d.t) - dt
		if float(d.t) <= 0.0:
			continue
		var k := clampf(float(d.t) / 1.5, 0.0, 1.0)
		var p: Vector2 = d.p
		var cc: Color = d.c
		var pos := p + Vector2(0.0, -60.0 * (1.0 - k))
		if str(d.txt).begins_with("−"):
			Neo.text(self, str(d.txt), pos, Lay.T_H1, Neo.with_alpha(cc, k))
			Neo.text(self, "падение", pos + Vector2(0.0, 22.0), Lay.T_TINY,
				Neo.with_alpha(Neo.WARN, 0.8 * k))
		else:
			Neo.text(self, str(d.txt), pos, Lay.T_SMALL, Neo.with_alpha(cc, k))
		keep.append(d)
	flashes = keep


func _draw_ruler() -> void:
	# Шкала очков по левому краю поля: 1 px мира = 1 очко.
	var step := 500.0
	var y0 := floorf(cam_y / step) * step
	for i in 6:
		var wy := y0 - float(i) * step
		var sy := ARENA.end.y - cam_y + wy
		if sy < ARENA.position.y + 6.0 or sy > ARENA.end.y - 6.0:
			continue
		draw_line(Vector2(ARENA.position.x, sy), Vector2(ARENA.position.x + 16.0, sy),
			Neo.with_alpha(Neo.DIM, 0.45), 1.0)
		Neo.text_left(self, str(int(-wy)), Vector2(ARENA.position.x + 22.0, sy - 4.0),
			Lay.T_TINY, Neo.with_alpha(Neo.DIM, 0.45))


func _draw_hud() -> void:
	var t := maxf(time_left, 0.0)
	# Справа в шапке — ряд чипов, поэтому время живёт в подзаголовке.
	Lay.header(self, "НЕОН-ДЖАМП", "раунд %d:%02d · упал — минус %d очков и возврат через %.0f с" % [
		int(t) / 60, int(t) % 60, PENALTY, RESPAWN], "", "")
	_draw_chips()
	_draw_status()
	_draw_footer()
	InputHint.draw(self, Lay.JUMP_HINT, _active_src(), Time.get_ticks_msec() * 0.001)
	if frozen and state == St.RUN:
		Neo.text(self, "ПАУЗА: ждём игроков в кадре", ARENA.get_center() + Vector2(0.0, 20.0),
			Lay.T_H1, Neo.WARN)
	_draw_overlay()
	if debug_ui:
		var y := Lay.FOOT_Y + 100.0
		for p in players:
			if p.human:
				Neo.text(self, "%s ax=%+.2f очки=%d падений=%d" % [
					p.title, p.ax, _score(p), p.falls], Vector2(ARENA.get_center().x, y),
					Lay.T_TINY, Neo.DIM)
				y += 20.0


func _draw_chips() -> void:
	var n := players.size()
	if n == 0:
		return
	var w := 210.0
	var gap := 20.0
	var total := float(n) * w + float(maxi(n - 1, 0)) * gap
	var x0 := Lay.JUMP_SCORES.end.x - total
	for i in n:
		var p: Player = players[i]
		var val := "очков: %d" % _score(p)
		if not p.alive:
			val = "падение: %.1f с" % maxf(p.respawn_t, 0.0)
		Lay.chip(self, Vector2(x0 + float(i) * (w + gap), Lay.JUMP_SCORES.position.y),
			p.color if p.alive else Neo.with_alpha(p.color, 0.45), p.title, val, w)


func _draw_status() -> void:
	var r := Lay.JUMP_STATUS
	Lay.panel(self, r, "состояние")
	var b := Lay.body(r)
	var rows := [
		["ввод", "рука" if _active_src() == "hand" else "лицо"],
		["данные", _age_text()],
		["падений", str(falls_total)],
		["платформ", str(plats.size())],
	]
	var y := b.position.y + 6.0
	for row in rows:
		Neo.text_left(self, row[0], Vector2(b.position.x, y), Lay.T_TINY,
			Neo.with_alpha(Neo.DIM, 0.8))
		Neo.text_left(self, row[1], Vector2(b.position.x + 108.0, y), Lay.T_TINY, Neo.TEXT)
		y += 22.0


func _age_text() -> String:
	if bridge == null:
		return "нет трекера"
	var age: float = bridge.tracking_age()
	return "нет данных" if is_inf(age) else "%.0f мс" % (age * 1000.0)


func _draw_footer() -> void:
	var hint := "наклоняйте лицо — человечек бежит вбок · прыгает сам · упал — вернёшься с минусом"
	if demo:
		hint = "демо без трекинга: ← → — бег · прыгает сам · экран зациклен по бокам"
	Neo.text_left(self, hint, Vector2(Lay.M, Lay.FOOT_Y + 36.0), Lay.T_BODY, Neo.DIM)
	var keys := "1..5 — режим ввода · ESC — меню"
	if solo:
		keys = "лучшая высота %d · падений %d · %s" % [int(_score(players[0])) if players.size() > 0 else 0, falls_total, keys]
	Neo.text_left(self, keys, Vector2(Lay.M, Lay.FOOT_Y + 70.0), Lay.T_SMALL,
		Neo.with_alpha(Neo.DIM, 0.65))


func _draw_overlay() -> void:
	var c := ARENA.get_center()
	match state:
		St.WAIT:
			Neo.text(self, "ВСТАНЬТЕ ПЕРЕД КАМЕРОЙ", c - Vector2(0.0, 20.0), Lay.T_H1, Neo.TEXT)
			Neo.text(self, "от 1 до 4 игроков", c + Vector2(0.0, 26.0), Lay.T_H2, Neo.DIM)
		St.READY:
			var k := ceili(1.8 - state_t)
			Neo.text(self, str(maxi(k, 1)), c + Vector2(0.0, 40.0), 120, Neo.PUCK)
			Neo.text(self, "прыгайте вверх — платформы сами подбросят", c - Vector2(0.0, 60.0),
				Lay.T_H2, Neo.DIM)
		St.RESULT:
			var who := "никто" if winner < 0 else players[winner].title
			var col: Color = Neo.TEXT if winner < 0 else players[winner].color
			Neo.text(self, "выше всех — %s" % who, c - Vector2(0.0, 20.0), Lay.T_DISPLAY, col)
			Neo.text(self, "очков %d · падений %d" % [
				_score(players[winner]) if winner >= 0 else 0, players[winner].falls if winner >= 0 else 0],
				c + Vector2(0.0, 30.0), Lay.T_H2, Neo.TEXT)
		St.OVER:
			Neo.text(self, "возвращаемся в меню…", c, Lay.T_H1, Neo.DIM)


# ---------------------------------------------------------------- автотест


func _selftest_tick() -> void:
	st_t += get_process_delta_time()
	if selftest != "jump":
		return
	if st_t > 40.0:
		printerr("SELFTEST JUMP FAIL: не дождались возврата игрока за 40 с")
		get_tree().quit(1)
		return
	if players.size() < 2:
		return
	var p1: Player = players[1]
	if not probe_done:
		# ждём, пока второй игрок наберёт очки — иначе минус срежется нулём
		if state != St.RUN or not p1.alive or p1.best < 350.0:
			return
		probe_done = true
		probe_t = st_t
		probe_falls = p1.falls
		probe_score = _score(p1)
		_fall(p1)
		probe_after_fall = _score(p1)
		printerr("JUMP SELFTEST: роняем игрока 2, очки %d → %d (минус %d)" % [
			probe_score, probe_after_fall, PENALTY])
		return
	if not p1.alive or p1.falls <= probe_falls:
		return
	var now := _score(p1)
	var delay := st_t - probe_t
	var climbed := 0.0
	for p in players:
		climbed = maxf(climbed, p.best)
	var cost_ok: bool = probe_score >= PENALTY \
		and probe_after_fall == maxi(0, probe_score - PENALTY)
	var delay_ok: bool = delay >= RESPAWN * 0.8
	var climb_ok: bool = climbed > 300.0
	printerr("JUMP SELFTEST: вернулся через %.1f с, очки сейчас %d, высота лидера %.0f px" % [
		delay, now, climbed])
	if p1.alive and cost_ok and delay_ok and climb_ok:
		printerr("SELFTEST JUMP PASS: упал — вернулся с минусом %d очков, гонка продолжается" % PENALTY)
		get_tree().quit(0)
	else:
		printerr("SELFTEST JUMP FAIL: back=%s cost=%s(%d→%d) delay=%s climb=%s" % [
			p1.alive, cost_ok, probe_score, probe_after_fall, delay_ok, climb_ok])
		get_tree().quit(1)
