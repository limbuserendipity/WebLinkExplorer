extends Node2D
## «Световые мечи»: дуэль на двоих в неоновом зале.
##
## Клинок растёт из запястья и повторяет движение руки (или наклона лица):
##   · рука на уровне пояса — клинок смотрит в соперника, удар возможен;
##   · рука поднята выше плеча — дюйм обороны: удар соперника уходит в блок,
##     а он сам «залипает» на секунду;
##   · жест (короткий) — выпад: клинок удлиняется и, если соперник не в стойке,
##     забирает %d из %d здоровья.
## Бой до нуля здоровья или до конца минуты; боты дерутся, если за пульт
## встал один игрок. Всё — руки и лицо, никаких клавиш.

const Inp := preload("res://core/FaceInput.gd")
const Neo := preload("res://core/Neon.gd")
const Sfx := preload("res://core/Sfx.gd")
const CamView := preload("res://core/CamView.gd")
const InputHint := preload("res://core/InputHint.gd")
const Lay := preload("res://core/Layout.gd")

const MENU_SCENE := "res://ui/Menu.tscn"

# ---------------------------------------------------------------- геометрия бойца

const FLOOR_DY := 120.0           # пол выше нижней кромки арены
const DUEL_DIST := 380.0          # дистанция дуэли, px
const SPRING := 6.0               # скорость возврата на дистанцию
const PUSH_BACK := 56.0           # отскок после блока
const BODY_R := 74.0              # радиус корпуса: насколько близко нужен клинок
const HIT_LIFT := 0.60            # клинок выше этого наклона — уже не удар
const REACH_GRACE := 30.0         # запас дистанции, чтобы удар считался «в блок»
const BLADE := 270.0              # длина клинка
const LUNGE_EXT := 100.0          # насколько выдвигается клинок в выпаде
const WRIST_FWD := 50.0           # насколько запястье вынесено вперёд
const WRIST_DY := 70.0            # ход запястья по вертикали
const SWING_DEG := 60.0           # насколько поднимается клинок при руке вверх
const SIDE_DEG := 20.0            # наклон клинка вбок
const SHOULDER_H := 320.0         # плечи над полом
const CHEST_TOP := 320.0          # верх корпуса над полом
const CHEST_BOTTOM := 150.0       # низ корпуса над полом
const HIP_H := 160.0              # бёдра над полом
const HEAD_H := 368.0             # центр головы над полом
const HEAD_R := 30.0

# ---------------------------------------------------------------- правила боя

const HP_MAX := 100
const DAMAGE := 25
const STRIKE_COOL := 0.55         # пауза между ударами, с
const STAGGER := 0.90             # «залип» после блока, с
const LUNGE_TIME := 0.22          # сколько клинок выдвинут, с
const GUARD_AY := -0.55           # рука выше — стойка, удар уходит в блок
const GESTURE_CONF := 0.5
const ROUND_TIME := 60.0
const STALE := 0.5
const MAX_HUMANS := 2
const BOT_ATTACK := 0.55          # как часто бот бьёт, когда может

enum St { WAIT, READY, RUN, RESULT, OVER }


class Player:
	var id := 0
	var human := false
	var color := Color.WHITE
	var title := "игрок"
	var track_slot := -1
	var track_id := -1
	var inp = Inp.new()
	var hp := HP_MAX
	var x := 0.0
	var base_x := 0.0
	var push := 0.0
	var facing := 1.0
	var ax := 0.0
	var ay := 0.0
	var cool := 0.0
	var stagger := 0.0
	var lunge := 0.0
	var flash := 0.0
	var strikes := 0
	var hits := 0
	var parries := 0
	var guard := false
	var bot_t := 0.0
	var won := false


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
var sparks: Array = []
var hits_total := 0
var parries_total := 0

var st_t := 0.0
var probe_stage := 0
var probe_strikes := 0


func _ready() -> void:
	bridge = get_node_or_null("/root/GameDirector")
	cam_view = CamView.new()
	add_child(cam_view)
	cam_view.setup(Lay.SABER_CAM)
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
		rng.seed = 777
	else:
		rng.randomize()
	if not no_audio:
		synth.setup(self)
	if bridge != null:
		bridge.gesture.connect(_on_gesture)
		bridge.gesture_phase.connect(_on_gesture_phase)
	var area := Lay.SABER_ARENA
	var frac := area.get_area() / (Lay.W * Lay.H)
	var clean: bool = not area.intersects(Lay.SABER_CAM) \
		and not area.intersects(Lay.SABER_HINT) \
		and not area.intersects(Lay.SABER_STATUS)
	printerr("SABER START players=%d mode=%s поле=%.0fx%.0f доля=%.2f чисто=%s" % [
		_human_count_hint(), input_mode, area.size.x, area.size.y, frac, clean])
	# Два бойца видны ещё до старта: экран читается сразу.
	players.append(_make_player(0, true))
	players.append(_make_player(1, false))
	_place_fighters()
	_set_state(St.WAIT)
	state_t = 100.0 if selftest == "saber" else 0.0


func _exit_tree() -> void:
	synth.stop()


func _human_count_hint() -> int:
	if demo:
		return 1
	if bridge == null:
		return 0
	return mini(bridge.players().size(), MAX_HUMANS)


func _floor_y() -> float:
	return Lay.SABER_ARENA.end.y - FLOOR_DY


func _center_x() -> float:
	return Lay.SABER_ARENA.get_center().x


func _make_player(i: int, human: bool) -> Player:
	var p := Player.new()
	p.id = i
	p.human = human
	p.color = Neo.player_color(i)
	p.title = "игрок %d" % (i + 1)
	p.facing = 1.0 if i == 0 else -1.0
	p.base_x = _center_x() - DUEL_DIST * 0.5 if i == 0 else _center_x() + DUEL_DIST * 0.5
	p.x = p.base_x
	return p


func _place_fighters() -> void:
	for p in players:
		p.base_x = _center_x() - DUEL_DIST * 0.5 if p.id == 0 else _center_x() + DUEL_DIST * 0.5
		p.x = p.base_x
		p.push = 0.0
		p.hp = HP_MAX
		p.cool = 0.0
		p.stagger = 0.0
		p.lunge = 0.0
		p.flash = 0.0
		p.guard = false


# ---------------------------------------------------------------- игровой цикл


func _process(dt: float) -> void:
	state_t += dt
	synth.pump()
	_update_cam_view()
	var sdt := dt * (2.0 if selftest == "saber" else 1.0)
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
			_tick_result(dt)
			if state_t >= 6.0:
				_set_state(St.OVER)
		St.OVER:
			if state_t >= 8.0:
				_back_to_menu()
	queue_redraw()
	if selftest == "saber":
		_selftest_tick()


func _set_state(s: int) -> void:
	state = s
	state_t = 0.0
	if selftest != "":
		printerr("SABER STATE ", s)


func _tick_wait(_dt: float) -> void:
	if bridge != null:
		bridge.rotation_checkpoint()
	if state_t < 0.2:
		return
	var humans := _humans()
	if selftest == "saber":
		_start_match([])
	elif demo:
		_start_match([])
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
	for i in MAX_HUMANS:
		var kb: bool = demo and i == 0 and selftest == ""     # клавиатура — только в демо
		var p := _make_player(i, i < humans.size() or kb)
		if p.human and i < humans.size():
			p.color = humans[i].color if humans[i].color is Color else p.color
			p.track_slot = humans[i].slot
			p.track_id = humans[i].track_id
		else:
			p.title = "бот %d" % (i + 1)
			p.color = Neo.with_alpha(Neo.player_color(i), 0.78)
			p.track_slot = i if selftest != "" else -1
		players.append(p)
	_place_fighters()
	sparks.clear()
	time_left = ROUND_TIME
	winner = -1
	hits_total = 0
	parries_total = 0
	frozen = false
	printerr("SABER MATCH бойцов=%d людей=%d" % [players.size(), humans.size()])
	_set_state(St.READY)


func _tick_run(dt: float) -> void:
	_update_frozen()
	if frozen:
		return
	time_left = maxf(0.0, time_left - dt)
	for p in players:
		p.cool = maxf(0.0, p.cool - dt)
		p.stagger = maxf(0.0, p.stagger - dt)
		p.lunge = maxf(0.0, p.lunge - dt)
		p.flash = maxf(0.0, p.flash - dt * 1.6)
		p.guard = p.ay < GUARD_AY and p.stagger <= 0.0
		if not p.human:
			_bot_think(p, dt)
		# отскок после блока сходит на нет — боец сам возвращается в стойку
		p.push = lerpf(p.push, 0.0, clampf(SPRING * dt, 0.0, 1.0))
		p.x = lerpf(p.x, p.base_x + p.push * -p.facing, clampf(SPRING * dt, 0.0, 1.0))
	for s in sparks:
		s.t -= dt
	var i := sparks.size() - 1
	while i >= 0:
		if float(sparks[i].t) <= 0.0:
			sparks.remove_at(i)
		i -= 1
	_check_finish()


func _check_finish() -> void:
	var dead := -1
	for p in players:
		if p.hp <= 0:
			dead = p.id
	if dead >= 0:
		winner = 1 - dead
		_finish()
		return
	if time_left <= 0.0:
		var a: Player = players[0]
		var b: Player = players[1]
		if a.hp == b.hp:
			winner = -1
		else:
			winner = a.id if a.hp > b.hp else b.id
		_finish()


func _finish() -> void:
	if winner >= 0:
		players[winner].won = true
	printerr("SABER FINISH winner=%d hp=%s ударов=%d блоков=%d" % [
		winner, _hp_text(), hits_total, parries_total])
	_set_state(St.RESULT)


func _hp_text() -> String:
	var parts := []
	for p in players:
		parts.append("%d" % maxi(p.hp, 0))
	return "/".join(parts)


func _tick_result(dt: float) -> void:
	for p in players:
		p.flash = maxf(0.0, p.flash - dt)
		p.lunge = maxf(0.0, p.lunge - dt)


func _back_to_menu() -> void:
	if demo or selftest != "":
		_place_fighters()
		_set_state(St.READY)
		return
	get_tree().change_scene_to_file(MENU_SCENE)


# ---------------------------------------------------------------- клинок и удар


func _shoulder(p: Player) -> Vector2:
	return Vector2(p.x, _floor_y() - SHOULDER_H)


func _wrist(p: Player) -> Vector2:
	return _shoulder(p) + Vector2(p.facing * WRIST_FWD, clampf(p.ay, -1.0, 1.0) * WRIST_DY)


func _blade_dir(p: Player) -> Vector2:
	# Рука поднята — клинок встаёт вертикально (стойка), опущена — смотрит вперёд.
	var lift := clampf(-p.ay, -1.0, 1.0) * deg_to_rad(SWING_DEG)
	var side := clampf(p.ax, -1.0, 1.0) * deg_to_rad(SIDE_DEG)
	var a := lift
	return Vector2(cos(a) * p.facing, -sin(a)).rotated(side * p.facing)


func _tip(p: Player) -> Vector2:
	var ext := BLADE + (LUNGE_EXT if p.lunge > 0.0 else 0.0)
	return _wrist(p) + _blade_dir(p) * ext


## Длина выпада: запястье + клинок (+ выдвижение в ударе).
func _reach(p: Player) -> float:
	return WRIST_FWD + BLADE + (LUNGE_EXT if p.lunge > 0.0 else 0.0)


func _dist(p: Player, foe: Player) -> float:
	return absf(foe.x - p.x)


## Удар проходит, если клинок смотрит в соперника (рука не поднята в стойку)
## и дистанция дуэли в пределах выпада.
func _in_reach(p: Player, foe: Player) -> bool:
	if absf(_blade_dir(p).y) > HIT_LIFT:
		return false                      # клинок задрался вверх — это стойка
	return _dist(p, foe) - BODY_R <= _reach(p)


func _strike(p: Player) -> void:
	if state != St.RUN or p.cool > 0.0 or p.stagger > 0.0 or p.guard:
		return
	p.cool = STRIKE_COOL
	p.strikes += 1
	p.lunge = LUNGE_TIME
	var foe: Player = players[1 - p.id]
	if _dist(p, foe) - BODY_R > _reach(p) + REACH_GRACE:
		synth.tone(520.0, 300.0, 0.08, 0.10)
		printerr("SABER MISS attacker=%d" % p.id)
		return
	if foe.guard:
		# Удар ушёл в блок: атакующий залипает и отскакивает.
		p.stagger = STAGGER
		p.cool = STAGGER
		p.push = -PUSH_BACK
		foe.parries += 1
		parries_total += 1
		foe.flash = 1.0
		_spark((_tip(p) + _chest(foe)) * 0.5, Neo.PUCK)
		synth.tone(1180.0, 640.0, 0.16, 0.20)
		printerr("SABER PARRY attacker=%d defender=%d" % [p.id, foe.id])
		return
	if not _in_reach(p, foe):
		# Клинок задрался: рука слишком высоко — это промах, а не удар.
		synth.tone(520.0, 300.0, 0.08, 0.10)
		printerr("SABER MISS attacker=%d" % p.id)
		return
	foe.hp = maxi(0, foe.hp - DAMAGE)
	foe.flash = 1.0
	p.hits += 1
	hits_total += 1
	p.push = PUSH_BACK * 0.4
	_spark(_chest(foe), foe.color)
	synth.tone(300.0, 120.0, 0.18, 0.22)
	printerr("SABER HIT attacker=%d dmg=%d hp=%s" % [p.id, DAMAGE, _hp_text()])


func _chest(p: Player) -> Vector2:
	return Vector2(p.x, _floor_y() - 235.0)


func _spark(pos: Vector2, col: Color) -> void:
	for i in 7:
		var a := rng.randf() * TAU
		var r := rng.randf_range(20.0, 70.0)
		sparks.append({"pos": pos + Vector2(cos(a), sin(a)) * r, "t": rng.randf_range(0.18, 0.5),
			"col": col, "v": Vector2(cos(a), sin(a)) * 0.0})


# ---------------------------------------------------------------- боты


func _bot_think(p: Player, dt: float) -> void:
	p.bot_t -= dt
	if p.bot_t > 0.0:
		return
	p.bot_t = rng.randf_range(0.30, 0.60)
	var foe: Player = players[1 - p.id]
	p.ay = 0.0
	p.ax = rng.randf_range(-0.25, 0.25)
	# Соперник замахивается — бот уходит в стойку.
	if foe.lunge > 0.0 or (foe.cool <= 0.05 and rng.randf() < 0.50):
		p.ay = -0.85
		return
	if p.cool <= 0.0 and p.stagger <= 0.0 and rng.randf() < BOT_ATTACK:
		_strike(p)


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
				printerr("SABER CALIB slot=%d nx=%.2f ny=%.2f" % [p.track_slot, p.inp.nx, p.inp.ny])


func _read_humans(_dt: float) -> void:
	if demo:
		if players.size() > 0:
			var p0: Player = players[0]
			var ax := 0.0
			var ay := 0.0
			if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
				ax -= 1.0
			if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
				ax += 1.0
			if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
				ay -= 1.0
			if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
				ay += 1.0
			p0.ax = ax
			p0.ay = ay
		return
	for p in players:
		if not p.human or not p.inp.have_neutral:
			continue
		p.ax = clampf(p.inp.ax, -1.0, 1.0)
		p.ay = clampf(p.inp.ay, -1.0, 1.0)


func _on_gesture(slot: int, _action: String, confidence: float) -> void:
	if confidence < GESTURE_CONF:
		return
	_gesture_strike(slot)


func _on_gesture_phase(slot: int, _track_id: int, _action: String, phase: String,
		confidence: float, _at: float, _duration: float) -> void:
	if confidence < GESTURE_CONF or phase != "start":
		return
	_gesture_strike(slot)


func _gesture_strike(slot: int) -> void:
	var p := _player_by_slot(slot)
	if p == null:
		return
	_strike(p)


func _player_by_slot(slot: int) -> Player:
	if slot < 0:
		return null
	for p in players:
		if p.track_slot != slot:
			continue
		if p.human or selftest != "":
			return p
	return null


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
	if k == KEY_SPACE and players.size() > 0 and (demo or not players[0].human):
		_strike(players[0])
		return
	if k >= KEY_1 and k <= KEY_5:
		var idx := k - KEY_1
		if idx < Inp.MODES.size():
			input_mode = Inp.MODES[idx]
			for p in players:
				p.inp.mode = input_mode
			printerr("SABER MODE ", input_mode)


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


func _draw() -> void:
	Neo.grid_bg(self, Vector2(Lay.W, Lay.H))
	_draw_hall()
	for p in players:
		_draw_fighter(p)
	_draw_sparks()
	_draw_hud()
	Neo.scanlines(self, Vector2(Lay.W, Lay.H))


func _draw_hall() -> void:
	var a := Lay.SABER_ARENA
	draw_rect(a, Color(0.012, 0.0, 0.05, 0.94))
	var fy := _floor_y()
	# Пол: две неоновые линии и засечки, как разметка в зале.
	Neo.glow(self, Vector2(a.position.x + 24.0, fy + 8.0), Vector2(a.end.x - 24.0, fy + 8.0),
		Neo.with_alpha(Neo.LEFT, 0.9), 3.0)
	Neo.glow(self, Vector2(a.position.x + 24.0, fy + 26.0), Vector2(a.end.x - 24.0, fy + 26.0),
		Neo.with_alpha(Neo.LINE, 0.5), 1.5)
	for i in 13:
		var x := a.position.x + 24.0 + float(i) * (a.size.x - 48.0) / 12.0
		draw_line(Vector2(x, fy + 8.0), Vector2(x, fy + 22.0), Neo.with_alpha(Neo.LINE, 0.35), 1.0)
	# Центральная линия дуэли.
	var cx := _center_x()
	draw_line(Vector2(cx, a.position.y + 40.0), Vector2(cx, fy + 8.0),
		Neo.with_alpha(Neo.LINE, 0.16), 2.0)
	draw_arc(Vector2(cx, fy - 4.0), 120.0, PI, TAU, 32, Neo.with_alpha(Neo.LINE, 0.18), 2.0, true)
	# Дальняя стена: большие дуги неонового зала.
	for i in 4:
		var h := 260.0 + float(i) * 150.0
		draw_arc(Vector2(cx, fy + 60.0), h, PI + 0.30, TAU - 0.30, 48,
			Neo.with_alpha(Neo.RIGHT if i % 2 == 0 else Neo.LEFT, 0.09), 2.0, true)
	# Арка за каждым бойцом — чтобы фигура читалась на пустом поле.
	for p in players:
		var col: Color = p.color
		draw_arc(Vector2(p.x, fy + 10.0), 200.0, PI, TAU, 40, Neo.with_alpha(col, 0.16), 3.0, true)
		draw_arc(Vector2(p.x, fy + 10.0), 150.0, PI, TAU, 36, Neo.with_alpha(col, 0.10), 2.0, true)
		draw_line(Vector2(p.x, fy + 8.0), Vector2(p.x, fy + 56.0), Neo.with_alpha(col, 0.18), 2.0)
	# Отражение бойцов на полу — глубина сцены.
	for p in players:
		var sh := _shoulder(p)
		draw_line(Vector2(sh.x, fy + 30.0), Vector2(p.x, fy + 30.0 + SHOULDER_H * 0.5),
			Neo.with_alpha(p.color, 0.10), 3.0)
	draw_rect(a, Neo.with_alpha(Neo.LINE, 0.35), false, 1.5)


func _draw_fighter(p: Player) -> void:
	var fy := _floor_y()
	var col := p.color
	if p.hp <= 0:
		col = Neo.with_alpha(col, 0.45)
	var shoulder := _shoulder(p)
	var hip := Vector2(p.x, fy - HIP_H)
	# ноги
	draw_line(hip, Vector2(p.x - 44.0, fy), Neo.with_alpha(col, 0.8), 6.0)
	draw_line(hip, Vector2(p.x + 44.0, fy), Neo.with_alpha(col, 0.8), 6.0)
	draw_line(Vector2(p.x - 44.0, fy), Vector2(p.x - 56.0, fy), Neo.with_alpha(col, 0.6), 4.0)
	draw_line(Vector2(p.x + 44.0, fy), Vector2(p.x + 56.0, fy), Neo.with_alpha(col, 0.6), 4.0)
	# корпус
	Neo.glow(self, shoulder, hip, Neo.with_alpha(col, 0.95), 7.0)
	draw_line(shoulder + Vector2(-16.0, 0.0), shoulder + Vector2(16.0, 0.0),
		Neo.with_alpha(col, 0.9), 5.0)
	# голова
	var head := Vector2(p.x, fy - HEAD_H)
	draw_circle(head, HEAD_R, Color(0.02, 0.0, 0.07, 0.95))
	draw_arc(head, HEAD_R, 0.0, TAU, 28, col, 3.0, true)
	draw_line(head + Vector2(-15.0 * p.facing, -2.0), head + Vector2(15.0 * p.facing, -2.0),
		Neo.with_alpha(col, 0.9), 4.0)
	# рука и клинок
	var wrist := _wrist(p)
	draw_line(shoulder, wrist, Neo.with_alpha(col, 0.85), 5.0)
	var tip := _tip(p)
	var blade_col: Color = Neo.PUCK if p.guard else Color(0.85, 0.95, 1.0)
	draw_line(wrist, tip, Neo.with_alpha(blade_col, 0.14), 22.0)
	draw_line(wrist, tip, Neo.with_alpha(blade_col, 0.55), 11.0)
	draw_line(wrist, tip, blade_col, 4.0)
	draw_circle(tip, 7.0, Neo.with_alpha(blade_col, 0.9))
	draw_circle(tip, 14.0, Neo.with_alpha(blade_col, 0.18))
	# рукоять
	draw_circle(wrist, 9.0, Neo.with_alpha(col, 0.9))
	# стойка: щит над бойцом
	if p.guard:
		draw_arc(Vector2(p.x, fy - CHEST_TOP - 4.0), 66.0, -PI * 0.85, -PI * 0.15, 24,
			Neo.with_alpha(Neo.PUCK, 0.75), 4.0, true)
	# вспышка от попадания
	if p.flash > 0.0:
		draw_circle(Vector2(p.x, fy - 220.0), 110.0 * (1.0 + 0.4 * (1.0 - p.flash)),
			Neo.with_alpha(Color(1.0, 1.0, 1.0), 0.18 * p.flash))
	# подпись и полоса здоровья
	var bar := Rect2(Vector2(p.x - 130.0, fy - CHEST_TOP - 112.0), Vector2(260.0, 16.0))
	draw_rect(bar, Color(0.0, 0.0, 0.0, 0.55))
	var k := clampf(float(p.hp) / float(HP_MAX), 0.0, 1.0)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * k, bar.size.y)), Neo.with_alpha(col, 0.9))
	draw_rect(bar, Neo.with_alpha(col, 0.6), false, 1.0)
	Neo.text(self, p.title.to_upper(), Vector2(p.x, fy - CHEST_TOP - 132.0), Lay.T_SMALL,
		Neo.TEXT if p.hp > 0 else Neo.with_alpha(Neo.TEXT, 0.5))
	# цифры ударов/блоков рядом с полосой
	var info := "удары %d · блоки %d" % [p.hits, p.parries]
	Neo.text(self, info, Vector2(p.x, bar.end.y + 24.0), Lay.T_TINY,
		Neo.with_alpha(Neo.DIM, 0.9))
	if p.stagger > 0.0:
		Neo.text(self, "залип", Vector2(p.x, bar.end.y + 48.0), Lay.T_SMALL, Neo.WARN)


func _draw_sparks() -> void:
	for s in sparks:
		var k: float = clampf(float(s.t) / 0.5, 0.0, 1.0)
		draw_circle(s.pos, 4.0 * k + 1.0, Neo.with_alpha(s.col, 0.85 * k))


func _draw_hud() -> void:
	var t := maxf(time_left, 0.0)
	Lay.header(self, "СВЕТОВЫЕ МЕЧИ",
		"дуэль на двоих · рука вверх — блок · жест — выпад",
		"%d : %d" % [players[0].hits, players[1].hits],
		"раунд %d:%02d · удар −%d из %d" % [int(t) / 60, int(t) % 60, DAMAGE, HP_MAX])
	_draw_status()
	_draw_footer()
	InputHint.draw(self, Lay.SABER_HINT, _active_src(), Time.get_ticks_msec() * 0.001)
	if frozen and state == St.RUN:
		Neo.text(self, "ПАУЗА: ждём игроков в кадре",
			Lay.SABER_ARENA.get_center() - Vector2(0.0, 230.0), Lay.T_H1, Neo.WARN)
	_draw_overlay()
	if debug_ui:
		var y := Lay.FOOT_Y + 100.0
		for p in players:
			Neo.text(self, "%s ax=%+.2f ay=%+.2f hp=%d стойка=%s" % [
				p.title, p.ax, p.ay, p.hp, "да" if p.guard else "нет"],
				Vector2(Lay.W * 0.5, y), Lay.T_TINY, Neo.DIM)
			y += 20.0


func _draw_status() -> void:
	var r := Lay.SABER_STATUS
	Lay.panel(self, r, "состояние")
	var b := Lay.body(r)
	var rows := [
		["ввод", "рука" if _active_src() == "hand" else "лицо"],
		["данные", _age_text()],
		["попаданий", str(hits_total)],
		["блоков", str(parries_total)],
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
	var hint := "рука вверх — стойка (блок) · рука вперёд — клинок в соперника · жест — выпад"
	if demo:
		hint = "демо без трекинга: ← → наклон клинка · ↑ стойка · пробел — удар"
	Neo.text_left(self, hint, Vector2(Lay.M, Lay.FOOT_Y + 36.0), Lay.T_BODY, Neo.DIM)
	Neo.text_left(self, "1..5 — режим ввода · ESC — меню",
		Vector2(Lay.M, Lay.FOOT_Y + 70.0), Lay.T_SMALL, Neo.with_alpha(Neo.DIM, 0.65))


func _draw_overlay() -> void:
	if state == St.RUN:
		return
	# Полоса под полом: там же, где разметка, — текст не перекрывает бойцов.
	var cx := _center_x()
	var fy := _floor_y()
	var back := Rect2(Vector2(cx - 430.0, fy + 14.0), Vector2(860.0, 98.0))
	draw_rect(back, Color(0.01, 0.0, 0.04, 0.82))
	draw_rect(back, Neo.with_alpha(Neo.LINE, 0.45), false, 1.5)
	match state:
		St.WAIT:
			Neo.text(self, "ДВА БОЙЦА ПЕРЕД КАМЕРОЙ", Vector2(cx, fy + 56.0), Lay.T_H1, Neo.TEXT)
			Neo.text(self, "второго соперника возьмёт бот", Vector2(cx, fy + 92.0), Lay.T_H2, Neo.DIM)
		St.READY:
			Neo.text(self, "БОЙ!", Vector2(cx, fy + 60.0), Lay.T_H1, Neo.PUCK)
			Neo.text(self, "поднимите руку — это стойка · жест — выпад",
				Vector2(cx, fy + 94.0), Lay.T_SMALL, Neo.DIM)
		St.RESULT:
			var who := "ничья"
			var col: Color = Neo.TEXT
			if winner >= 0:
				who = "победа: %s" % players[winner].title
				col = players[winner].color
			Neo.text(self, who, Vector2(cx, fy + 56.0), Lay.T_DISPLAY, col)
			Neo.text(self, "здоровье %s · попаданий %d · блоков %d" % [
				_hp_text(), hits_total, parries_total], Vector2(cx, fy + 92.0), Lay.T_SMALL, Neo.TEXT)
		St.OVER:
			Neo.text(self, "возвращаемся в меню…", Vector2(cx, fy + 68.0), Lay.T_H1, Neo.DIM)


# ---------------------------------------------------------------- автотест


func _selftest_tick() -> void:
	st_t += get_process_delta_time()
	match probe_stage:
		0:
			if state != St.RUN:
				return
			# Жест идёт тем же путём, что и от трекера: слот → боец.
			for p in players:
				p.bot_t = 2.0                  # боты не мешают чистой проверке
				p.ay = 0.0                     # клинок в боевое положение
			probe_strikes = players[0].strikes
			_on_gesture_phase(0, -1, "jump", "start", 0.95, 0.0, 0.0)
			probe_stage = 1
			st_t = 0.0
		1:
			if st_t < 0.3:
				return
			var got: int = players[0].strikes - probe_strikes
			probe_strikes = got
			printerr("SABER GESTURE strike=%d" % got)
			if got < 1:
				printerr("SABER SELFTEST FAIL: жест не превратился в удар")
				get_tree().quit(1)
				return
			probe_stage = 2
			st_t = 0.0
		2:
			if state == St.RESULT:
				_finish_selftest()
				return
			if st_t > 30.0:
				printerr("SABER SELFTEST FAIL: бой не закончился (hp=%s)" % _hp_text())
				get_tree().quit(1)


func _finish_selftest() -> void:
	var hp := _hp_text()
	printerr("SABER SELFTEST бойцов=%d попаданий=%d блоков=%d hp=%s победитель=%d" % [
		players.size(), hits_total, parries_total, hp, winner])
	if players.size() != 2:
		printerr("SABER SELFTEST FAIL: бойцов не двое")
		get_tree().quit(1)
		return
	if hits_total < 1:
		printerr("SABER SELFTEST FAIL: удары не доходят")
		get_tree().quit(1)
		return
	if parries_total < 1:
		printerr("SABER SELFTEST FAIL: блок ни разу не сработал")
		get_tree().quit(1)
		return
	if winner < 0:
		printerr("SABER SELFTEST FAIL: победитель не определён")
		get_tree().quit(1)
		return
	printerr("SELFTEST SABER PASS: жест=удар, попаданий %d, блоков %d, победитель «%s»" % [
		hits_total, parries_total, players[winner].title])
	get_tree().quit(0)
