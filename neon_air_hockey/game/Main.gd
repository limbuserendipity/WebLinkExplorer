extends Node2D
## Neon Air Hockey — тестовая motion-игра для Godot AR API v1 (2 игрока).
##
## Управление "головой": в API v1 нет ключевых точек головы, поэтому используется
## прокси — верхняя центральная точка рамки силуэта (camera_rect_norm).
##   * наклон/шаг влево-вправо (голова по X кадра)  -> ракетка вверх-вниз по столу;
##   * присед/выпрямление (голова по Y кадра)       -> ракетка вперёд-назад.
## Нейтральное положение калибруется во время обратного отсчёта перед раундом.
## Жесты (jump/lean) в управлении не участвуют — только вспышка кольца (проверка сигнала).
##
## Слева в кадре — игрок 1 (голубая ракетка, левые ворота), справа — игрок 2 (розовая).
## Идентичность игрока — пара (slot, track_id). Матч до 5 голов.
##
## Без трекинга (обычный запуск Godot) включается демо-режим:
##   P1 — WASD, P2 — стрелки, Пробел — старт/реванш.
##
## Автотесты (аргументы после "--"):
##   --selftest=waiting   — ожидание без источника трекинга;
##   --selftest=physics   — демо-матч со скриптовыми ракетками, проверяется гол;
##   --selftest=protocol  — работа с эмулятором трекинга (2 игрока, калибровка,
##                          движение ракетки за головой, сигнал gesture).

var win_score := 5                 # матч до N голов (--win-score=N)
const TABLE := Rect2(210.0, 260.0, 1500.0, 700.0)
const GOAL_HALF := 130.0          # половина высоты створа ворот
const PUCK_R := 24.0
const PAD_R := 46.0
const STEP := 1.0 / 120.0         # подшаг физики (против туннелирования)
const PUCK_MAX_SPEED := 2400.0
const PUCK_FRICTION := 0.10       # экспоненциальное затухание в секунду
const WALL_BOUNCE := 0.92
const HIT_BOUNCE := 0.86
const PAD_RATE := 14.0            # скорость сглаживания ракетки
const INPUT_RATE := 12.0          # сглаживание входа
const RANGE_FACE_X := 0.14        # ход лица по X до края половины (доли высоты кадра)
const RANGE_FACE_Y := 0.08        # ход лица по Y (наклон/шаг головой)
const RANGE_TILT_X := 0.20        # поворот головы (в долях расстояния между глазами)
const RANGE_TILT_Y := 0.22        # наклон головы набок, радианы
const RANGE_LEAN := 0.22          # наклон корпуса в долях роста
const RANGE_PROX := 0.18          # изменение body_height (шаг к камере)
const DEADZONE := 0.10            # мёртвая зона в долях полного отклонения
const HEAD_CONF := 0.35           # ниже — считаем голову ненадёжной
const FEET_CONF := 0.30           # ниже — лодыжки ненадёжны
const POINT_CONF := 0.30          # ниже — точка позы ненадёжна
const CONTROL_MODES := ["face", "tilt", "lean"]
const GESTURE_CONF := 0.75        # порог уверенности жеста (как в документе)
const PUSH_TIME := 0.35           # спад толчка после жеста, с
const PUSH_DIST := 95.0           # насколько вперёд выдвигается ракетка толчком, px
const FALLBACK_ASPECT := 16.0 / 9.0   # если frame_size не пришёл
const STALE := 0.5                # порог устаревания трекинга, с
const LOST_GRACE := 8.0           # сколько ждём пропавшего игрока, с

const C_BG := Color(0.020, 0.0, 0.078)
const C_GRID := Color(0.45, 0.25, 0.95, 0.07)
const C_LINE := Color(0.541, 0.361, 1.0)
const C_LEFT := Color(0.0, 0.918, 1.0)
const C_RIGHT := Color(1.0, 0.239, 0.949)
const C_PUCK := Color(1.0, 0.953, 0.690)
const C_TEXT := Color(0.88, 0.92, 1.0)
const C_DIM := Color(0.62, 0.66, 0.92, 0.85)
const C_TENTATIVE := Color(1.0, 0.73, 0.25)

const STATE_NAMES := {
	St.WAITING: "WAITING", St.READY: "READY", St.PLAY: "PLAY",
	St.GOAL: "GOAL", St.PAUSED: "PAUSED", St.OVER: "OVER",
}

enum St { WAITING, READY, PLAY, GOAL, PAUSED, OVER }

## Сегменты семисегментных цифр: a-верх, b-правый верх, c-правый низ,
## d-низ, e-левый низ, f-левый верх, g-середина.
const SEG := {
	0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc",
	5: "afgcd", 6: "afgecd", 7: "abc", 8: "abcdefg", 9: "abcdfg",
}


class Paddle:
	var slot := -1
	var track_id := -1
	var dir := 1.0                 # +1: левый игрок (вперёд = вправо), -1: правый
	var team_color: Color = Color.WHITE
	# вход: две оси в своих единицах, нейтраль снимается в отсчёт
	var rawx := 0.0
	var rawy := 0.0
	var nx := 0.0
	var ny := 0.0
	var range_x := 0.14
	var range_y := 0.08
	var ax := 0.0                  # -1..1, по X (вперёд-назад по столу)
	var ay := 0.0                  # -1..1, по Y (вверх-вниз по столу)
	var have_input := false
	var sumx := 0.0
	var sumy := 0.0
	var samples := 0
	var have_neutral := false
	var using_fallback := false    # нет головы — считаем по рамке
	var legacy := false            # источник без позы: вход только по рамке
	var blind_t := 0.0             # сколько секунд нет точки головы
	var conf := 0.0
	var push := 0.0                # 0..1, спад после жеста jump
	var last_reacq := -1           # последний обработанный reacquired_sample_id
	var target := Vector2.ZERO
	var pos := Vector2.ZERO
	var prev_pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var flash := 0.0

	func reset_calibration() -> void:
		sumx = 0.0
		sumy = 0.0
		samples = 0
		have_neutral = false
		have_input = false
		rawx = 0.0
		rawy = 0.0
		ax = 0.0
		ay = 0.0
		using_fallback = false
		legacy = false
		blind_t = 0.0
		conf = 0.0


## Ретро-синтезатор: прямоугольные волны через AudioStreamGenerator, без ассетов.
class Synth:
	var player: AudioStreamPlayer
	var pb: AudioStreamGeneratorPlayback
	var tones: Array = []
	var ok := false

	func setup(parent: Node) -> void:
		player = AudioStreamPlayer.new()
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = 22050.0
		gen.buffer_length = 0.25
		player.stream = gen
		player.volume_db = -14.0
		parent.add_child(player)
		player.play()
		pb = player.get_stream_playback() as AudioStreamGeneratorPlayback
		ok = pb != null

	func stop() -> void:
		# Без этого Godot ругается "ObjectDB instances leaked at exit":
		# генератор держит AudioStreamGeneratorPlayback до самого выхода.
		tones.clear()
		pb = null
		if player != null:
			player.stop()
			player.stream = null

	func tone(f0: float, f1: float, dur: float, amp: float, delay := 0.0) -> void:
		if ok:
			tones.append({"f0": f0, "f1": f1, "t": -delay, "dur": dur, "amp": amp})

	func pump() -> void:
		if not ok:
			return
		var n := pb.get_frames_available()
		if n <= 0:
			return
		var dt := 1.0 / 22050.0
		for i in n:
			var s := 0.0
			var j := tones.size() - 1
			while j >= 0:
				var tn: Dictionary = tones[j]
				tn.t += dt
				if tn.t >= tn.dur:
					tones.remove_at(j)
				elif tn.t >= 0.0:
					var k: float = tn.t / tn.dur
					var f: float = lerpf(tn.f0, tn.f1, k)
					var square := 1.0 if fmod(f * tn.t, 1.0) < 0.5 else -1.0
					s += square * tn.amp * (1.0 - k)
				j -= 1
			pb.push_frame(Vector2(s, s))


var bridge: Node
var state: int = St.WAITING
var state_t := 0.0
var ready_dur := 3.0
var sides: Array[Paddle] = []
var scores := [0, 0]
var puck_pos := Vector2.ZERO
var puck_vel := Vector2.ZERO
var trail: Array[Vector2] = []
var sparks: Array = []
var goal_side := -1
var goal_flash := 0.0
var pause_reason := ""
var pause_grace := 0.0
var next_serve := 0
var last_count := -1
var demo := false
var selftest := ""
var input_mode := "face"          # face | tilt | lean (--control=)
var gain := 1.0                   # множитель чувствительности (--gain=)
var flip_x := 1.0
var flip_y := 1.0
var debug_ui := false             # --debug: панель с числами ввода
var record_path := ""             # --record=файл.jsonl: запись трассы ввода
var record_file: FileAccess
var record_t0 := 0.0
var record_events: Array = []
var record_last: Dictionary = {}
var st_t := 0.0
var st_stage := 0
var st_ref := 0.0
var st_mark := 0.0
var gesture_count := 0
var phase_count := 0
var push_count := 0
var acc := 0.0
var shake := 0.0
var stall_t := 0.0
var last_serve := 0
var rebind_pending := false
var rng := RandomNumberGenerator.new()
var synth := Synth.new()


func _ready() -> void:
	bridge = get_node("/root/GameDirector")
	bridge.gesture.connect(_on_gesture)
	bridge.gesture_phase.connect(_on_gesture_phase)
	rng.randomize()
	if not OS.get_cmdline_user_args().has("--no-audio"):
		synth.setup(self)
	var has_port := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			has_port = true
		elif arg.begins_with("--selftest="):
			selftest = arg.trim_prefix("--selftest=")
		elif arg.begins_with("--win-score="):
			win_score = maxi(1, int(arg.trim_prefix("--win-score=")))
		elif arg.begins_with("--control="):
			input_mode = arg.trim_prefix("--control=").to_lower()
		elif arg.begins_with("--gain="):
			gain = clampf(float(arg.trim_prefix("--gain=")), 0.1, 5.0)
		elif arg.begins_with("--record="):
			record_path = arg.trim_prefix("--record=")
		elif arg == "--flip-x":
			flip_x = -1.0
		elif arg == "--flip-y":
			flip_y = -1.0
		elif arg == "--debug":
			debug_ui = true
	demo = not has_port
	if not CONTROL_MODES.has(input_mode):
		input_mode = "face"
	if record_path != "":
		record_file = FileAccess.open(record_path, FileAccess.WRITE)
		record_t0 = Time.get_ticks_msec() * 0.001
		if record_file == null:
			printerr("не смог открыть файл записи: ", record_path)
		else:
			printerr("пишу трассу ввода в ", record_path)
	puck_pos = TABLE.position + TABLE.size * 0.5
	if selftest == "physics":
		_start_demo_match()


func _exit_tree() -> void:
	synth.stop()
	if record_file != null:
		record_file.flush()
		record_file = null


func _record_event(e: Dictionary) -> void:
	if record_file != null:
		record_events.append(e)


func _record_tick() -> void:
	if record_file == null:
		return
	var players := []
	for p in bridge.all_players():
		if p.age_ticks > 90:
			continue
		if int(record_last.get(p.track_id, -99999)) == p.sample_id:
			continue
		record_last[p.track_id] = p.sample_id
		var kp := []
		for k in p.keypoints:
			kp.append(null if k == null else [k.x, k.y, k.z])
		var head := []
		if not p.head.is_empty():
			head = [p.head.p.x, p.head.p.y, p.head.conf]
		var feet := []
		for f in p.feet_norm:
			feet.append([f.x, f.y])
		players.append({
			"slot": p.slot, "track_id": p.track_id, "state": p.state,
			"color": [p.color.r, p.color.g, p.color.b],
			"rect": [p.camera_rect_norm.position.x, p.camera_rect_norm.position.y,
				p.camera_rect_norm.size.x, p.camera_rect_norm.size.y],
			"head": head, "feet": feet, "feet_confidence": p.feet_confidence,
			"body_height": p.body_height, "keypoints": kp,
		})
	if players.is_empty() and record_events.is_empty():
		return
	record_file.store_line(JSON.stringify({
		"t": Time.get_ticks_msec() * 0.001 - record_t0,
		"players": players, "events": record_events,
	}))
	record_events = []
	record_file.flush()


func _on_gesture(slot: int, action: String, confidence: float) -> void:
	_record_event({"slot": slot, "track_id": -1, "action": action,
		"phase": "start", "confidence": confidence})
	if action != "jump" or confidence < GESTURE_CONF:
		return
	gesture_count += 1
	for s in sides:
		if s.slot == slot:
			s.flash = 1.0


func _on_gesture_phase(slot: int, track_id: int, action: String, phase: String,
		confidence: float, _at: float, duration: float) -> void:
	_record_event({"slot": slot, "track_id": track_id, "action": action,
		"phase": phase, "confidence": confidence})
	if action != "jump" or confidence < GESTURE_CONF:
		return
	phase_count += 1
	if selftest == "log":
		printerr("PHASE %-4s %s conf=%.2f dur=%.2f" % [action, phase, confidence, duration])
	if phase != "start":
		return
	for s in sides:
		if s.slot != slot or (track_id >= 0 and s.track_id != track_id):
			continue
		if s.push > 0.5:
			return  # не наказываем за дребезг удержания
		s.push = 1.0
		s.flash = 1.0
		push_count += 1
		if selftest == "log":
			printerr("PUSH slot=%d" % slot)
		synth.tone(520.0, 900.0, 0.08, 0.3)


func _unhandled_key_input(event: InputEvent) -> void:
	# Клавиши оператора (Tab/Esc/N/Shift+Esc) не трогаем — их обрабатывает адаптер.
	if not demo:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				if state == St.WAITING or state == St.OVER:
					_start_demo_match()
			KEY_1, KEY_2, KEY_3:
				_set_input_mode(CONTROL_MODES[[KEY_1, KEY_2, KEY_3].find(event.keycode)])
			KEY_F1:
				debug_ui = not debug_ui


# ---------------------------------------------------------------- состояния


func _set_input_mode(mode: String) -> void:
	if not CONTROL_MODES.has(mode):
		return
	input_mode = mode
	for s in sides:
		s.reset_calibration()
	if not demo and not sides.is_empty():
		ready_dur = 1.5        # короткий отсчёт: режим сменился — нейтраль заново
		_set_state(St.READY)
	printerr("режим ввода: ", mode)


func _set_state(s: int) -> void:
	state = s
	state_t = 0.0
	acc = 0.0
	last_count = -1
	if selftest == "log":
		printerr("STATE %-7s score=%d:%d" % [STATE_NAMES.get(s, "?"), scores[0], scores[1]])


func _to_waiting() -> void:
	sides.clear()
	rebind_pending = false
	scores = [0, 0]
	trail.clear()
	puck_vel = Vector2.ZERO
	puck_pos = TABLE.position + TABLE.size * 0.5
	_set_state(St.WAITING)


func _start_demo_match() -> void:
	sides.clear()
	var s0 := Paddle.new()
	s0.dir = 1.0
	s0.team_color = C_LEFT
	var s1 := Paddle.new()
	s1.dir = -1.0
	s1.team_color = C_RIGHT
	sides.append(s0)
	sides.append(s1)
	for s in sides:
		s.pos = _side_base(s)
		s.target = s.pos
	scores = [0, 0]
	next_serve = 0 if selftest == "physics" else rng.randi_range(0, 1)
	ready_dur = 1.5
	_set_state(St.READY)


func _assign_sides(left, right) -> void:
	sides.clear()
	var s0 := Paddle.new()
	s0.slot = left.slot
	s0.track_id = left.track_id
	s0.dir = 1.0
	s0.team_color = C_LEFT
	var s1 := Paddle.new()
	s1.slot = right.slot
	s1.track_id = right.track_id
	s1.dir = -1.0
	s1.team_color = C_RIGHT
	sides.append(s0)
	sides.append(s1)
	for s in sides:
		s.pos = _side_base(s)
		s.target = s.pos
	scores = [0, 0]
	next_serve = rng.randi_range(0, 1)
	ready_dur = 3.0
	_set_state(St.READY)


func _pause(reason: String) -> void:
	pause_reason = reason
	if selftest == "log":
		printerr("PAUSE \"%s\"" % reason)
	pause_grace = LOST_GRACE
	synth.tone(300.0, 150.0, 0.2, 0.3)
	_set_state(St.PAUSED)


func _both_ready() -> bool:
	for s in sides:
		if not _side_ready(s):
			return false
	return true


func _side_ready(s: Paddle) -> bool:
	var p = _fresh_pair(s)
	return p != null and str(p.state) == "confirmed"


func _sync_sides(allow_rebind: bool) -> bool:
	# Если в том же слоте появился другой track_id — это новый человек:
	# принимаем его и сбрасываем устаревшее состояние стороны.
	var ok := true
	for s in sides:
		if _fresh_pair(s) != null:
			continue
		var adopted := false
		if allow_rebind:
			for p in bridge.players():
				if p.slot == s.slot and p.track_id != s.track_id:
					s.track_id = p.track_id
					s.have_head = false
					s.reset_calibration()
					synth.tone(880.0, 660.0, 0.12, 0.25)
					rebind_pending = true
					adopted = true
					break
		if not adopted:
			ok = false
	return ok


func _tick_blind(dt: float) -> void:
	# Точка головы пропала, хотя поза в пакете есть (нос/глаза на месте): играем
	# «слепо» 2 с, потом пауза. Считаем в READY/PLAY/GOAL — иначе гол успевает
	# сбросить окно и потеря головы остаётся незамеченной.
	if demo or state == St.WAITING or state == St.PAUSED or state == St.OVER:
		return
	for s in sides:
		if not s.have_input:
			continue
		var p = _fresh_pair(s)
		var headless: bool = p != null and not s.legacy 			and not p.keypoints.is_empty() and p.head.is_empty()
		if not headless:
			s.blind_t = 0.0
			continue
		s.blind_t += dt
		if s.blind_t > 2.0:
			_pause("Игрок %d: потеряна точка головы" % (s.slot + 1))
			return


func _fresh_pair(s: Paddle):
	for p in bridge.players():
		if p.slot == s.slot and p.track_id == s.track_id:
			return p
	return null


func _pos_x(p) -> float:
	var r: Rect2 = p.camera_rect_norm
	if r.size.x > 0.001:
		return r.position.x + r.size.x * 0.5
	if p.feet_norm.size() == 2:
		return (p.feet_norm[0].x + p.feet_norm[1].x) * 0.5
	return -1.0


func _tick_waiting(_dt: float, tracking_ok: bool) -> void:
	bridge.rotation_checkpoint()
	if demo or not tracking_ok:
		return
	var usable: Array = []
	for p in bridge.players():
		if _pos_x(p) >= 0.0:
			usable.append(p)
	if usable.size() < 2:
		return
	usable.sort_custom(func(a, b): return _pos_x(a) < _pos_x(b))
	_assign_sides(usable[0], usable[usable.size() - 1])


func _tick_ready(dt: float, tracking_ok: bool) -> void:
	bridge.rotation_checkpoint()
	if not demo:
		if not tracking_ok:
			_pause("Потерян сигнал трекинга")
			return
		_sync_sides(true)
		for i in sides.size():
			var s = sides[i]
			var p = _fresh_pair(s)
			if p == null:
				_pause("Игрок %d пропал из кадра" % (i + 1))
				return
			if str(p.state) != "confirmed":
				_pause("Игрок %d: трек потерян" % (i + 1))
				return
			_update_side_input(s, p, dt)
			if s.have_input:
				s.sumx += s.rawx
				s.sumy += s.rawy
				s.samples += 1
	for s in sides:
		s.target = _side_base(s)
		s.pos = s.pos.lerp(s.target, 1.0 - exp(-PAD_RATE * dt))
	var c := ceili(ready_dur - state_t)
	if c != last_count and c > 0:
		last_count = c
		synth.tone(660.0, 660.0, 0.07, 0.3)
	if state_t >= ready_dur:
		if not demo:
			for s in sides:
				if s.samples < 5 or not s.have_input:
					_to_waiting()
					return
				s.nx = s.sumx / float(s.samples)
				s.ny = s.sumy / float(s.samples)
				s.have_neutral = true
				s.legacy = s.using_fallback
				_update_axes(s)
				if selftest == "log":
					printerr("CALIB slot=%d mode=%s nx=%.4f ny=%.4f fallback=%s" % [
						s.slot, input_mode, s.nx, s.ny, s.using_fallback])
		synth.tone(990.0, 990.0, 0.15, 0.35)
		_serve(next_serve)
		_set_state(St.PLAY)


func _tick_play(dt: float, tracking_ok: bool) -> void:
	if not demo:
		if not tracking_ok:
			_pause("Потерян сигнал трекинга")
			return
		_sync_sides(true)
		if rebind_pending:
			_pause("Новый игрок в кадре")
			return
		for i in sides.size():
			var s = sides[i]
			var p = _fresh_pair(s)
			if p == null:
				_pause("Игрок %d пропал из кадра" % (i + 1))
				return
			if str(p.state) != "confirmed":
				_pause("Игрок %d: трек потерян" % (i + 1))
				return
			if p.reacquired and p.reacquired_sample_id != s.last_reacq:
				s.last_reacq = p.reacquired_sample_id
				_pause("Игрок %d вернулся в кадр" % (i + 1))
				return
			_update_side_input(s, p, dt)
			s.target = _side_target(s)
	elif selftest == "physics":
		# Скриптовый матч: левый бьёт вперёд, правый уходит в угол.
		sides[0].target = Vector2(_side_bounds(sides[0]).end.x, TABLE.position.y + TABLE.size.y * 0.5)
		sides[1].target = Vector2(_side_bounds(sides[1]).end.x, TABLE.position.y + PAD_R + 8.0)
	else:
		_demo_control(dt)
	stall_t += dt
	if stall_t > 8.0 and state == St.PLAY:
		_synth_restart()
	acc += dt
	while acc >= STEP and state == St.PLAY:
		_physics_step(STEP)
		acc -= STEP
	trail.append(puck_pos)
	if trail.size() > 16:
		trail.pop_front()


func _tick_goal(_dt: float, tracking_ok: bool) -> void:
	bridge.rotation_checkpoint()
	if state_t < 2.0:
		return
	if demo or (tracking_ok and _sync_sides(true) and _both_ready()):
		for s in sides:
			s.reset_calibration()
		ready_dur = 2.0
		_set_state(St.READY)
	else:
		_to_waiting()


func _tick_paused(dt: float, tracking_ok: bool) -> void:
	bridge.rotation_checkpoint()
	pause_grace -= dt
	if tracking_ok and _sync_sides(true) and _both_ready():
		rebind_pending = false
		for s in sides:
			s.reset_calibration()
		ready_dur = 1.5
		_set_state(St.READY)
	elif pause_grace <= 0.0:
		_to_waiting()


func _tick_over(_dt: float, tracking_ok: bool) -> void:
	bridge.rotation_checkpoint()
	if state_t < 8.0:
		return
	if demo:
		return  # реванш по Пробелу
	if tracking_ok and _sync_sides(true) and _both_ready():
		scores = [0, 0]
		for s in sides:
			s.reset_calibration()
		next_serve = rng.randi_range(0, 1)
		ready_dur = 3.0
		_set_state(St.READY)
	else:
		_to_waiting()


func _process(dt: float) -> void:
	dt = minf(dt, 0.1)
	state_t += dt
	goal_flash = maxf(0.0, goal_flash - dt * 1.4)
	shake = maxf(0.0, shake - dt * 2.2)
	for s in sides:
		s.flash = maxf(0.0, s.flash - dt * 3.0)
	_update_sparks(dt)
	synth.pump()
	var tracking_ok: bool = demo or bridge.tracking_age() <= STALE
	match state:
		St.WAITING:
			_tick_waiting(dt, tracking_ok)
		St.READY:
			_tick_ready(dt, tracking_ok)
		St.PLAY:
			_tick_play(dt, tracking_ok)
		St.GOAL:
			_tick_goal(dt, tracking_ok)
		St.PAUSED:
			_tick_paused(dt, tracking_ok)
		St.OVER:
			_tick_over(dt, tracking_ok)
	_tick_blind(dt)
	_record_tick()
	if selftest == "log" and Engine.get_process_frames() % 30 == 0:
		for s in sides:
			if s.have_input:
				printerr("INPUT slot=%d mode=%s raw=(%+.4f, %+.4f) neutral=(%+.4f, %+.4f) range=(%.4f, %.4f) ax=%+.2f ay=%+.2f fallback=%s conf=%.2f pos=(%.0f, %.0f)" % [
					s.slot, input_mode, s.rawx, s.rawy, s.nx, s.ny, s.range_x, s.range_y,
					s.ax, s.ay, s.using_fallback, s.conf, s.pos.x, s.pos.y])
	if selftest != "":
		_selftest_tick()
	queue_redraw()


# ---------------------------------------------------------------- управление


func _aspect() -> float:
	# Точки нормированы отдельно по ширине и высоте кадра, поэтому X нужно
	# приводить к единицам высоты. frame_size может быть нулевым у старого источника.
	if bridge.frame_size.y > 0:
		return float(bridge.frame_size.x) / float(bridge.frame_size.y)
	return FALLBACK_ASPECT


func _update_side_input(s: Paddle, p, dt: float) -> void:
	var aspect := _aspect()
	if input_mode == "tilt" and _input_tilt(s, p, aspect, dt):
		return
	if input_mode == "lean":
		_input_lean(s, p, aspect, dt)
	else:
		_input_face(s, p, aspect, dt)


func _update_axes(s: Paddle) -> void:
	if not s.have_neutral:
		s.ax = 0.0
		s.ay = 0.0
		return
	var rgx := maxf(s.range_x, 0.0001)
	var rgy := maxf(s.range_y, 0.0001)
	s.ax = clampf(_dz(clampf((s.rawx - s.nx) / rgx, -1.0, 1.0)) * gain * flip_x, -1.0, 1.0)
	s.ay = clampf(_dz(clampf((s.rawy - s.ny) / rgy, -1.0, 1.0)) * gain * flip_y, -1.0, 1.0)


func _feed(s: Paddle, rx: float, ry: float, rgx: float, rgy: float,
		conf: float, dt: float) -> void:
	var k := 1.0 - exp(-INPUT_RATE * dt)
	if s.have_input:
		s.rawx = lerpf(s.rawx, rx, k)
		s.rawy = lerpf(s.rawy, ry, k)
	else:
		s.rawx = rx
		s.rawy = ry
		s.have_input = true
	s.range_x = maxf(rgx, 0.0001)
	s.range_y = maxf(rgy, 0.0001)
	s.conf = conf
	_update_axes(s)


func _nose_point(p):
	# Нос из 17 точек позы, иначе середина глаз/носа из поля head.
	var kp: Array = p.keypoints
	if kp.size() > 0 and kp[0] != null and kp[0].z >= POINT_CONF:
		return Vector2(kp[0].x, kp[0].y)
	var hp = p.head.get("p")
	if hp is Vector2 and float(p.head.get("conf", 0.0)) >= HEAD_CONF:
		return hp
	return null


func _input_face(s: Paddle, p, aspect: float, dt: float) -> void:
	# Лицо — это курсор: положение носа в кадре относительно калибровки.
	var nose = _nose_point(p)
	s.using_fallback = nose == null
	if nose == null:
		if s.have_neutral and not s.legacy:
			return    # поза была, голова пропала — держим последнее значение
		var rect: Rect2 = p.camera_rect_norm
		if rect.size.y <= 0.01:
			return
		s.legacy = not s.have_neutral
		_feed(s, (rect.position.x + rect.size.x * 0.5) * aspect, rect.position.y,
			RANGE_FACE_X, RANGE_FACE_Y, p.feet_confidence, dt)
		return
	_feed(s, nose.x * aspect, nose.y, RANGE_FACE_X, RANGE_FACE_Y,
		float(p.head.get("conf", p.feet_confidence)), dt)


func _input_tilt(s: Paddle, p, aspect: float, dt: float) -> bool:
	# Наклон головы набок (roll) и поворот (yaw) по точкам глаз и носа.
	var kp: Array = p.keypoints
	if kp.size() < 5:
		return false
	var nose = kp[0]
	var eye_l = kp[1]
	var eye_r = kp[2]
	for pt in [nose, eye_l, eye_r]:
		if pt == null or pt.z < POINT_CONF:
			return false
	var a := Vector2(eye_l.x * aspect, eye_l.y)
	var b := Vector2(eye_r.x * aspect, eye_r.y)
	var n := Vector2(nose.x * aspect, nose.y)
	var axis := b - a
	var d := axis.length()
	if d < 0.006:
		return false   # лицо слишком мелкое в кадре — шум
	var roll := atan2(axis.y, axis.x)
	var mid := (a + b) * 0.5
	var yaw := (n - mid).dot(axis / d) / d
	s.using_fallback = false
	_feed(s, yaw, roll, RANGE_TILT_X, RANGE_TILT_Y, float(nose.z), dt)
	return true


func _input_lean(s: Paddle, p, aspect: float, dt: float) -> void:
	# Классический вариант: наклон корпуса относительно лодыжек + шаг к камере.
	var have_feet: bool = p.feet_norm.size() == 2 and p.feet_confidence >= FEET_CONF
	var feet_mid := Vector2.ZERO
	if have_feet:
		feet_mid = (p.feet_norm[0] + p.feet_norm[1]) * 0.5
	var bh: float = p.body_height
	var hp = p.head.get("p")
	var head_ok: bool = hp is Vector2 and bh > 0.01 and have_feet \
		and float(p.head.get("conf", 0.0)) >= HEAD_CONF
	s.using_fallback = not head_ok
	var lean := 0.0
	if head_ok:
		s.legacy = false
		lean = (hp.x - feet_mid.x) * aspect / bh
	else:
		if s.have_neutral and not s.legacy:
			return
		var rect: Rect2 = p.camera_rect_norm
		if rect.size.y <= 0.01:
			return
		s.legacy = not s.have_neutral
		bh = rect.size.y
		lean = (rect.position.x + rect.size.x * 0.5) * aspect / bh
	# rawx здесь — высота тела, поэтому её нейтраль лежит в nx (а не в ny, как в старом коде).
	var bh_neutral: float = s.nx if s.have_neutral and s.nx > 0.01 else bh
	_feed(s, bh, lean, RANGE_PROX * bh_neutral, RANGE_LEAN, p.feet_confidence, dt)


func _dz(v: float) -> float:
	return signf(v) * maxf(absf(v) - DEADZONE, 0.0) / (1.0 - DEADZONE)


func _side_bounds(s: Paddle) -> Rect2:
	var t := TABLE.position.y + PAD_R + 6.0
	var h := TABLE.size.y - 2.0 * (PAD_R + 6.0)
	var cx := TABLE.position.x + TABLE.size.x * 0.5
	if s.dir > 0.0:
		var x0 := TABLE.position.x + PAD_R + 6.0
		return Rect2(x0, t, cx - PAD_R - 4.0 - x0, h)
	var x1 := cx + PAD_R + 4.0
	return Rect2(x1, t, TABLE.end.x - PAD_R - 6.0 - x1, h)


func _side_base(s: Paddle) -> Vector2:
	var b := _side_bounds(s)
	return Vector2(b.position.x + b.size.x * 0.5, TABLE.position.y + TABLE.size.y * 0.5)


func _side_target(s: Paddle) -> Vector2:
	var base := _side_base(s)
	if not s.have_neutral or not s.have_input:
		return base
	var b := _side_bounds(s)
	# ax — вперёд/назад (X стола), ay — вверх/вниз (Y стола).
	# Лицом и наклоном головы управляем «как курсором»: вправо по экрану = вправо.
	var sx := s.dir if input_mode == "lean" else 1.0
	var t := base
	t.x += s.ax * sx * (b.size.x * 0.5 - 4.0) + s.push * PUSH_DIST * s.dir
	t.y += s.ay * (TABLE.size.y * 0.5 - PAD_R - 8.0)
	return Vector2(clampf(t.x, b.position.x, b.end.x), clampf(t.y, b.position.y, b.end.y))


func _demo_control(dt: float) -> void:
	var sp := 900.0 * dt
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		v.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		v.x += 1.0
	if Input.is_key_pressed(KEY_W):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		v.y += 1.0
	var b0 := _side_bounds(sides[0])
	sides[0].target += v * sp
	sides[0].target = Vector2(
		clampf(sides[0].target.x, b0.position.x, b0.end.x),
		clampf(sides[0].target.y, b0.position.y, b0.end.y))
	v = Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		v.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		v.y += 1.0
	var b1 := _side_bounds(sides[1])
	sides[1].target += v * sp
	sides[1].target = Vector2(
		clampf(sides[1].target.x, b1.position.x, b1.end.x),
		clampf(sides[1].target.y, b1.position.y, b1.end.y))


# ---------------------------------------------------------------- физика


func _serve(toward: int) -> void:
	puck_pos = TABLE.position + TABLE.size * 0.5
	var ang := rng.randf_range(-0.35, 0.35)
	if selftest == "physics":
		ang = 0.0
	var dirx := -1.0 if toward == 0 else 1.0
	puck_vel = Vector2(dirx, 0.0).rotated(ang) * 460.0
	last_serve = toward
	stall_t = 0.0
	trail.clear()


func _physics_step(h: float) -> void:
	for s in sides:
		s.prev_pos = s.pos
		s.pos = s.pos.lerp(s.target, 1.0 - exp(-PAD_RATE * h))
		s.vel = (s.pos - s.prev_pos) / h
		s.push = maxf(0.0, s.push - h / PUSH_TIME)
	puck_pos += puck_vel * h
	puck_vel *= exp(-PUCK_FRICTION * h)
	if puck_vel.length() < 14.0:
		puck_vel = Vector2.ZERO
	var l := TABLE.position.x
	var r := TABLE.end.x
	var t := TABLE.position.y
	var b := TABLE.end.y
	var cy := t + TABLE.size.y * 0.5
	if puck_pos.y - PUCK_R < t:
		puck_pos.y = t + PUCK_R
		puck_vel.y = absf(puck_vel.y) * WALL_BOUNCE
		_wall_fx()
	elif puck_pos.y + PUCK_R > b:
		puck_pos.y = b - PUCK_R
		puck_vel.y = -absf(puck_vel.y) * WALL_BOUNCE
		_wall_fx()
	var in_mouth := absf(puck_pos.y - cy) < GOAL_HALF - PUCK_R * 0.25
	if not in_mouth:
		if puck_pos.x - PUCK_R < l:
			puck_pos.x = l + PUCK_R
			puck_vel.x = absf(puck_vel.x) * WALL_BOUNCE
			_wall_fx()
		elif puck_pos.x + PUCK_R > r:
			puck_pos.x = r - PUCK_R
			puck_vel.x = -absf(puck_vel.x) * WALL_BOUNCE
			_wall_fx()
	else:
		if puck_pos.x + PUCK_R < l - 4.0:
			_goal(1)
			return
		if puck_pos.x - PUCK_R > r + 4.0:
			_goal(0)
			return
	for s in sides:
		var d := puck_pos - s.pos
		var dist := d.length()
		var min_d := PUCK_R + PAD_R
		if dist < min_d:
			var n := d / maxf(dist, 0.001)
			puck_pos = s.pos + n * (min_d + 0.5)
			var vn := (puck_vel - s.vel).dot(n)
			if vn < 0.0:
				puck_vel -= n * vn * (1.0 + HIT_BOUNCE)
			puck_vel += n * 30.0
			if puck_vel.length() > PUCK_MAX_SPEED:
				puck_vel = puck_vel.normalized() * PUCK_MAX_SPEED
			stall_t = 0.0
			_hit_fx(s.team_color, clampf(-vn / 900.0, 0.15, 1.0))


func _synth_restart() -> void:
	# Диск застрял (никто не касался 8 с) — перебрасываем с центра.
	_serve(1 - last_serve)
	synth.tone(520.0, 780.0, 0.12, 0.25)


func _goal(scorer: int) -> void:
	scores[scorer] += 1
	goal_side = scorer
	goal_flash = 1.0
	shake = 0.5
	next_serve = 1 - scorer
	var cy := TABLE.position.y + TABLE.size.y * 0.5
	var gx := TABLE.position.x if scorer == 1 else TABLE.end.x
	_burst(Vector2(gx, cy), C_LEFT if scorer == 0 else C_RIGHT, 26)
	synth.tone(220.0, 880.0, 0.35, 0.5)
	synth.tone(440.0, 1760.0, 0.35, 0.3, 0.05)
	trail.clear()
	if scores[scorer] >= win_score:
		synth.tone(523.0, 523.0, 0.18, 0.4, 0.4)
		synth.tone(659.0, 659.0, 0.18, 0.4, 0.52)
		synth.tone(784.0, 784.0, 0.18, 0.4, 0.64)
		synth.tone(1046.0, 1046.0, 0.3, 0.4, 0.76)
		_set_state(St.OVER)
	else:
		_set_state(St.GOAL)


func _wall_fx() -> void:
	synth.tone(120.0, 70.0, 0.06, 0.22)
	_burst(puck_pos, C_LINE, 4)


func _hit_fx(c: Color, impact: float) -> void:
	synth.tone(180.0 + impact * 300.0, 90.0, 0.09, 0.2 + 0.4 * impact)
	_burst(puck_pos, c, 10)
	shake = maxf(shake, impact * 0.2)


func _burst(p: Vector2, c: Color, n: int) -> void:
	for i in n:
		var a := rng.randf_range(0.0, TAU)
		var sp := rng.randf_range(120.0, 520.0)
		sparks.append({"p": p, "v": Vector2.RIGHT.rotated(a) * sp, "t": 0.0,
			"life": rng.randf_range(0.25, 0.6), "c": c})


func _update_sparks(dt: float) -> void:
	var i := sparks.size() - 1
	while i >= 0:
		var sp: Dictionary = sparks[i]
		sp.t += dt
		if sp.t >= sp.life:
			sparks.remove_at(i)
		else:
			sp.p += sp.v * dt
			sp.v *= exp(-3.0 * dt)
		i -= 1


# ---------------------------------------------------------------- автотесты


func _selftest_tick() -> void:
	st_t += get_process_delta_time()
	match selftest:
		"waiting":
			if st_t > 1.0:
				if state == St.WAITING and bridge.players().is_empty() \
						and is_inf(bridge.frame_age()) and is_inf(bridge.tracking_age()):
					print("SELFTEST WAITING PASS: сцена ожидания без источника трекинга")
					get_tree().quit(0)
				else:
					print("SELFTEST WAITING FAIL: state=", state)
					get_tree().quit(1)
		"physics":
			if scores[0] >= 1 or scores[1] >= 1:
				print("SELFTEST PHYSICS PASS: гол засчитан, счёт=", scores, " state=", state)
				get_tree().quit(0)
			if st_t > 20.0:
				print("SELFTEST PHYSICS FAIL: гола нет за 20 с, state=", state, " puck=", puck_pos)
				get_tree().quit(1)
		"protocol":
			match st_stage:
				0:
					if bridge.players().size() >= 2:
						print("ST protocol: подтверждены 2 игрока")
						st_stage = 1
				1:
					if state == St.PLAY:
						print("ST protocol: калибровка завершена, READY->PLAY")
						st_stage = 2
						st_ref = sides[0].target.y
						st_mark = st_t
				2:
					if st_t - st_mark > 1.5:
						if absf(sides[0].target.y - st_ref) > 15.0:
							print("ST protocol: ракетка следует за головой (Δ=%.0f px)" % absf(sides[0].target.y - st_ref))
							st_stage = 3
						else:
							st_ref = sides[0].target.y
							st_mark = st_t
				3:
					if gesture_count > 0 and push_count > 0:
						print("SELFTEST PROTOCOL PASS: жесты получены (", gesture_count,
							", фаз ", phase_count, ", толчков ", push_count, ")")
						get_tree().quit(0)
			if st_t > 30.0:
				print("SELFTEST PROTOCOL FAIL: этап ", st_stage, " state=", state)
				get_tree().quit(1)


# ---------------------------------------------------------------- отрисовка


func _neon_line(a: Vector2, b: Vector2, c: Color, w: float) -> void:
	draw_line(a, b, Color(c.r, c.g, c.b, 0.10), w * 5.0, true)
	draw_line(a, b, Color(c.r, c.g, c.b, 0.22), w * 2.4, true)
	draw_line(a, b, c, w, true)


func _neon_circle(p: Vector2, r: float, c: Color, w: float) -> void:
	draw_arc(p, r, 0.0, TAU, 48, Color(c.r, c.g, c.b, 0.12), w * 5.0, true)
	draw_arc(p, r, 0.0, TAU, 48, Color(c.r, c.g, c.b, 0.25), w * 2.2, true)
	draw_arc(p, r, 0.0, TAU, 48, c, w, true)


func _text(s: String, pos: Vector2, size: int, c: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var p := pos - Vector2(w * 0.5, 0.0)
	draw_string(font, p + Vector2(1.5, 1.5), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(c.r, c.g, c.b, 0.3))
	draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)


func _digit(p: Vector2, size: Vector2, d: int, c: Color) -> void:
	var w := size.x
	var h := size.y
	var pts := {
		"a": [Vector2(0, 0), Vector2(w, 0)],
		"b": [Vector2(w, 0), Vector2(w, h * 0.5)],
		"c": [Vector2(w, h * 0.5), Vector2(w, h)],
		"d": [Vector2(0, h), Vector2(w, h)],
		"e": [Vector2(0, h * 0.5), Vector2(0, h)],
		"f": [Vector2(0, 0), Vector2(0, h * 0.5)],
		"g": [Vector2(0, h * 0.5), Vector2(w, h * 0.5)],
	}
	var segs: String = SEG.get(d, "")
	for k in pts:
		if segs.contains(k):
			_neon_line(p + pts[k][0], p + pts[k][1], c, 7.0)


func _draw() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), C_BG)
	var gx := 0.0
	while gx <= 1920.0:
		draw_line(Vector2(gx, 0), Vector2(gx, 1080), C_GRID, 1.0)
		gx += 120.0
	var gy := 0.0
	while gy <= 1080.0:
		draw_line(Vector2(0, gy), Vector2(1920, gy), C_GRID, 1.0)
		gy += 120.0
	if shake > 0.0:
		var tm := Time.get_ticks_msec() * 0.001
		draw_set_transform(Vector2(sin(tm * 71.0) * shake * 9.0, cos(tm * 63.0) * shake * 7.0), 0.0, Vector2.ONE)
	_draw_table()
	_draw_puck_and_pads()
	_draw_sparks()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud()
	_draw_message()
	# CRT-сканлайны
	var sy := 0.0
	while sy < 1080.0:
		draw_line(Vector2(0, sy), Vector2(1920, sy), Color(0, 0, 0, 0.10), 2.0)
		sy += 6.0


func _draw_table() -> void:
	var l := TABLE.position.x
	var r := TABLE.end.x
	var t := TABLE.position.y
	var b := TABLE.end.y
	var cx := l + TABLE.size.x * 0.5
	var cy := t + TABLE.size.y * 0.5
	# внутренняя подсветка стола
	draw_rect(TABLE, Color(0.09, 0.03, 0.22, 0.55))
	# борта
	_neon_line(Vector2(l, t), Vector2(r, t), C_LINE, 4.0)
	_neon_line(Vector2(l, b), Vector2(r, b), C_LINE, 4.0)
	_neon_line(Vector2(l, t), Vector2(l, cy - GOAL_HALF), C_LINE, 4.0)
	_neon_line(Vector2(l, cy + GOAL_HALF), Vector2(l, b), C_LINE, 4.0)
	_neon_line(Vector2(r, t), Vector2(r, cy - GOAL_HALF), C_LINE, 4.0)
	_neon_line(Vector2(r, cy + GOAL_HALF), Vector2(r, b), C_LINE, 4.0)
	# центр
	_neon_circle(Vector2(cx, cy), 90.0, C_LINE, 3.0)
	var dy := t + 12.0
	while dy < b - 12.0:
		_neon_line(Vector2(cx, dy), Vector2(cx, minf(dy + 24.0, b - 12.0)), Color(0.54, 0.36, 1.0, 0.8), 3.0)
		dy += 44.0
	# ворота-лунки
	_draw_goal(l, cy, C_LEFT, -1.0)
	_draw_goal(r, cy, C_RIGHT, 1.0)
	if goal_flash > 0.0:
		var fc := C_LEFT if goal_side == 0 else C_RIGHT
		var fr := Rect2(0, 0, 1920, 1080)
		draw_rect(fr, Color(fc.r, fc.g, fc.b, 0.10 * goal_flash))


func _draw_goal(x: float, cy: float, c: Color, outward: float) -> void:
	var pocket := Rect2(x - 36.0 if outward < 0.0 else x, cy - GOAL_HALF, 36.0, GOAL_HALF * 2.0)
	draw_rect(pocket, Color(0, 0, 0, 0.6))
	_neon_line(Vector2(x, cy - GOAL_HALF), Vector2(x, cy + GOAL_HALF), c, 5.0)
	_neon_line(Vector2(x + outward * 36.0, cy - GOAL_HALF), Vector2(x + outward * 36.0, cy + GOAL_HALF), c, 3.0)
	_neon_line(Vector2(x, cy - GOAL_HALF), Vector2(x + outward * 36.0, cy - GOAL_HALF), c, 3.0)
	_neon_line(Vector2(x, cy + GOAL_HALF), Vector2(x + outward * 36.0, cy + GOAL_HALF), c, 3.0)
	var hy := cy - GOAL_HALF + 22.0
	while hy < cy + GOAL_HALF - 10.0:
		draw_line(Vector2(x + outward * 4.0, hy), Vector2(x + outward * 32.0, hy), Color(c.r, c.g, c.b, 0.35), 2.0)
		hy += 26.0


func _draw_puck_and_pads() -> void:
	var n := trail.size()
	for i in n:
		var k := float(i + 1) / float(n)
		draw_circle(trail[i], PUCK_R * (0.3 + 0.6 * k), Color(C_PUCK.r, C_PUCK.g, C_PUCK.b, 0.04 + 0.10 * k))
	if state == St.PLAY or state == St.PAUSED or state == St.READY:
		draw_circle(puck_pos, PUCK_R * 2.1, Color(C_PUCK.r, C_PUCK.g, C_PUCK.b, 0.08))
		draw_circle(puck_pos, PUCK_R * 1.4, Color(C_PUCK.r, C_PUCK.g, C_PUCK.b, 0.18))
		draw_circle(puck_pos, PUCK_R, C_PUCK)
		draw_circle(puck_pos, PUCK_R * 0.45, Color(1, 1, 1))
	for s in sides:
		draw_circle(s.pos, PAD_R, Color(0.02, 0.01, 0.08, 0.9))
		_neon_circle(s.pos, PAD_R, s.team_color, 4.0)
		_neon_circle(s.pos, PAD_R * 0.45, s.team_color, 3.0)
		if s.flash > 0.0:
			draw_arc(s.pos, PAD_R + 12.0 + (1.0 - s.flash) * 16.0, 0.0, TAU, 40, Color(1, 1, 1, 0.6 * s.flash), 3.0, true)


func _draw_sparks() -> void:
	for sp in sparks:
		var a: float = 1.0 - sp.t / sp.life
		var c: Color = sp.c
		draw_line(sp.p, sp.p - sp.v * 0.03, Color(c.r, c.g, c.b, a), 3.0, true)


func _draw_hud() -> void:
	_digit(Vector2(350, 42), Vector2(86, 124), clampi(scores[0], 0, 9), C_LEFT)
	_digit(Vector2(1484, 42), Vector2(86, 124), clampi(scores[1], 0, 9), C_RIGHT)
	_text("ИГРОК 1", Vector2(393, 205), 24, C_LEFT)
	_text("ИГРОК 2", Vector2(1527, 205), 24, C_RIGHT)
	_text("МАТЧ ДО %d" % win_score, Vector2(960, 228), 22, C_DIM)
	# мини-превью камеры с рамками игроков
	var pr := Rect2(810, 22, 300, 169)
	draw_rect(pr, Color(0, 0, 0, 0.5))
	var tex = bridge.camera_texture
	if tex != null and bridge.frame_age() < 1.5:
		draw_texture_rect(tex, pr, false)
		for p in bridge.all_players():
			if p.age_ticks >= 30:
				continue
			var rr: Rect2 = p.camera_rect_norm
			if rr.size.x <= 0.001:
				continue
			var box := Rect2(pr.position + Vector2(rr.position.x * pr.size.x, rr.position.y * pr.size.y),
				Vector2(rr.size.x * pr.size.x, rr.size.y * pr.size.y))
			draw_rect(box, p.color, false, 2.0)
			draw_circle(Vector2(box.position.x + box.size.x * 0.5, box.position.y), 3.0, p.color)
	else:
		_text("НЕТ ВИДЕО", pr.position + pr.size * 0.5 + Vector2(0, 8), 22, C_DIM)
	draw_rect(pr, Color(C_LINE.r, C_LINE.g, C_LINE.b, 0.6), false, 2.0)
	# подсказки
	if demo:
		_text("ДЕМО БЕЗ ТРЕКИНГА:  P1 — WASD,  P2 — стрелки,  Пробел — старт,  1/2/3 — режим ввода", Vector2(960, 1010), 24, C_DIM)
	else:
		_text(_hint_line(), Vector2(960, 1010), 24, C_DIM)
		_text("в отсчёт стойте ровно, смотрите в камеру — снимается нейтраль", Vector2(960, 1044), 22, Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.6))
	_draw_input_sticks()
	_draw_debug_panel()
	var st: Dictionary = bridge.tracking_stats()
	var lat: Dictionary = st.get("latency_ms", {})
	var jit: Dictionary = st.get("jitter_ms", {})
	if not lat.is_empty():
		_text("задержка входа p95 %.0f мс · джиттер %.1f мс · кадр %dx%d" % [
			float(lat.get("p95", 0.0)), float(jit.get("p95", 0.0)),
			bridge.frame_size.x, bridge.frame_size.y], Vector2(960, 972), 20,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.55))


func _hint_line() -> String:
	match input_mode:
		"tilt":
			return "Наклон головы набок — ракетка вверх/вниз · поворот головы — вперёд/назад · прыжок — толчок"
		"lean":
			return "Наклон корпуса — ракетка вверх/вниз · шаг к камере — вперёд/назад · прыжок — толчок"
		_:
			return "Лицо — курсор в своей половине: двигайте лицом вверх/вниз и влево/вправо · прыжок — толчок"


func _draw_input_sticks() -> void:
	# Квадрат на каждого игрока: точка = текущее положение входа по двум осям.
	var i := 0
	for s in sides:
		var origin := Vector2(250.0 if i == 0 else 1670.0, 360.0)
		var half := 38.0
		var col: Color = s.team_color
		if s.using_fallback:
			col = Color(1.0, 1.0, 1.0, 0.55)   # вход по рамке, а не по позе
		var box := Rect2(origin - Vector2(half, half), Vector2(half, half) * 2.0)
		draw_rect(box, Color(0.0, 0.0, 0.0, 0.35))
		draw_rect(box, Color(col.r, col.g, col.b, 0.35), false, 2.0)
		draw_line(origin - Vector2(half, 0.0), origin + Vector2(half, 0.0),
			Color(col.r, col.g, col.b, 0.18), 1.0)
		draw_line(origin - Vector2(0.0, half), origin + Vector2(0.0, half),
			Color(col.r, col.g, col.b, 0.18), 1.0)
		draw_circle(origin + Vector2(s.ax, s.ay) * half, 7.0, col)
		i += 1
	_text("вход: %s · усиление %.1f%s" % [input_mode, gain,
		" · фолбэк по рамке" if _any_fallback() else ""], Vector2(960, 944), 20,
		Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.6))


func _any_fallback() -> bool:
	for s in sides:
		if s.using_fallback:
			return true
	return false


func _draw_debug_panel() -> void:
	if not debug_ui:
		return
	var y := 860.0
	for s in sides:
		_text("slot %d: raw=(%+.3f, %+.3f) нейтраль=(%+.3f, %+.3f) оси=(%+.2f, %+.2f) conf=%.2f" % [
			s.slot, s.rawx, s.rawy, s.nx, s.ny, s.ax, s.ay, s.conf], Vector2(960, y), 18,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.75))
		y += 22.0


func _draw_message() -> void:
	var mid := Vector2(TABLE.position.x + TABLE.size.x * 0.5, TABLE.position.y + TABLE.size.y * 0.5)
	match state:
		St.WAITING:
			_text("ВСТАНЬТЕ ВДВОЁМ ПЕРЕД КАМЕРОЙ", mid + Vector2(0, -40), 44, C_TEXT)
			_text("кто левее в кадре — игрок 1 (голубой), кто правее — игрок 2 (розовый)", mid + Vector2(0, 10), 26, C_DIM)
			var tent: Array = bridge.tentative_players()
			if not tent.is_empty():
				_text("человека видно, подтверждаю трек…", mid + Vector2(0, 52), 26, C_TENTATIVE)
			if demo:
				_text("или нажмите Пробел для демо-матча на клавиатуре", mid + Vector2(0, 84), 26, C_DIM)
		St.READY:
			var c := clampi(ceili(ready_dur - state_t), 1, 9)
			_digit(mid + Vector2(-35, -130), Vector2(70, 110), c, C_TEXT)
			_text("ПРИГОТОВЬТЕСЬ", mid + Vector2(0, 30), 36, C_TEXT)
			_text("стойте ровно, голова прямо — идёт калибровка", mid + Vector2(0, 72), 24, C_DIM)
		St.GOAL:
			var gc := C_LEFT if goal_side == 0 else C_RIGHT
			_text("ГОЛ!", mid + Vector2(0, -20), 96, gc)
			_text("Игрок %d забивает!" % (goal_side + 1), mid + Vector2(0, 50), 34, C_TEXT)
		St.PAUSED:
			_text("ПАУЗА", mid + Vector2(0, -50), 64, C_TEXT)
			_text(pause_reason, mid + Vector2(0, 6), 30, C_DIM)
			_text("ждём возвращения… %.0f" % maxf(pause_grace, 0.0), mid + Vector2(0, 48), 26, C_DIM)
		St.OVER:
			var winner := 0 if scores[0] > scores[1] else 1
			var wc := C_LEFT if winner == 0 else C_RIGHT
			_text("ИГРОК %d ПОБЕДИЛ!" % (winner + 1), mid + Vector2(0, -40), 64, wc)
			_text("Счёт  %d : %d" % [scores[0], scores[1]], mid + Vector2(0, 16), 34, C_TEXT)
			if demo:
				_text("Пробел — реванш", mid + Vector2(0, 60), 26, C_DIM)
			else:
				_text("реванш через %.0f с — оставайтесь в кадре" % maxf(8.0 - state_t, 0.0), mid + Vector2(0, 60), 26, C_DIM)
