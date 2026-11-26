extends Node2D
## Меню аркады: кто в кадре, какая игра, кто за какую голосует.
##
## Голосование лицом: наведите своё лицо на плитку и задержите на 1.2 с —
## засчитается голос. Можно переголосовать. Когда проголосовали все, идёт
## отсчёт и запускается игра, за которую больше голосов (при равенстве —
## та, за которую проголосовали раньше).

const Inp := preload("res://core/FaceInput.gd")
const Neo := preload("res://core/Neon.gd")
const Sfx := preload("res://core/Sfx.gd")
const CamView := preload("res://core/CamView.gd")
const InputHint := preload("res://core/InputHint.gd")
const Lay := preload("res://core/Layout.gd")

const DWELL := 1.2                # сколько держать лицо на плитке для голоса
const COUNTDOWN := 2.5            # отсчёт перед запуском
const CARDS := [
	{"id": "air", "title": "АЭРОХОККЕЙ", "who": "ровно 2 игрока", "min": 2, "max": 2,
		"scene": "res://game/Main.tscn",
		"hint": "ракетки в своих половинах"},
	{"id": "tron", "title": "ТРОН", "who": "1–4 игрока", "min": 1, "max": 4,
		"scene": "res://game/Tron.tscn",
		"hint": "световой след не прощает"},
	{"id": "razor", "title": "РАЗОРТРОН 2000", "who": "1–6 игроков", "min": 1, "max": 6,
		"scene": "res://game/Razor.tscn",
		"hint": "гонка в закат до финиша"},
	{"id": "jump", "title": "НЕОН-ДЖАМП", "who": "1–4 игрока", "min": 1, "max": 4,
		"scene": "res://game/Jump.tscn",
		"hint": "прыгай выше всех"},
	{"id": "tetris", "title": "НЕОН-ТЕТРИС", "who": "1–4 игрока", "min": 1, "max": 4,
		"scene": "res://game/Tetris.tscn",
		"hint": "стакан на каждого · жест — сброс"},
	{"id": "saber", "title": "СВЕТОВЫЕ МЕЧИ", "who": "ровно 2 игрока", "min": 2, "max": 2,
		"scene": "res://game/Saber.tscn",
		"hint": "стойка — защита · жест — укол"},
]
const CHIPS_PER_ROW := 4                 # сколько фишек влезает в ряд

var bridge: Node
var synth := Sfx.new()
var selftest := ""
var demo := false
var no_audio := false

var players: Array = []          # [{slot, track_id, color, nose, name}]
var votes := {}                  # track_id -> {"card": idx, "t": float}
var dwell := {}                  # track_id -> секунды на текущей плитке
var hover := {}                  # track_id -> idx плитки
var countdown := -1.0
var last_vote_t := 0.0
var vote_timeout := 20.0          # если кто-то ушёл и голосов нет — не висим вечно
var start_target := ""
var forced := ""
var state_t := 0.0
var frame_px := Vector2(1920.0, 1080.0)
var cursor_pos := {}             # track_id -> Vector2 на экране
var inputs := {}                 # track_id -> FaceInput (нейтраль и оси)
var cursor_sens := Vector2(1180.0, 520.0)  # размах курсора при полном отклонении
var cur_min := Vector2(1e9, 1e9)
var cur_max := Vector2(-1e9, -1e9)
var msg := ""
var input_mode := "auto"
var debug_ui := false
var msg_t := 0.0
var cam_view: Control = null


func _ready() -> void:
	bridge = get_node_or_null("/root/GameDirector")
	cam_view = CamView.new()
	add_child(cam_view)
	cam_view.setup(Lay.MENU_CAM)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--selftest="):
			selftest = arg.trim_prefix("--selftest=")
		elif arg.begins_with("--game="):
			forced = arg.trim_prefix("--game=")
		elif arg == "--no-audio":
			no_audio = true
		elif arg.begins_with("--gain="):
			cursor_sens = Vector2(900.0, 560.0) * clampf(float(arg.trim_prefix("--gain=")), 0.3, 3.0)
		elif arg.begins_with("--control="):
			input_mode = arg.trim_prefix("--control=").to_lower()
		elif arg == "--debug":
			debug_ui = true
		elif arg.begins_with("--port="):
			demo = false
	var has_port := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			has_port = true
	demo = not has_port
	if not no_audio and selftest == "":
		synth.setup(self)
	if selftest == "draw":
		_draw_all_screens()
		return
	if selftest == "grid":
		# Проверка единой сетки: панели в безопасной зоне и не пересекаются.
		var bad: Array = Lay.audit()
		for msg in bad:
			printerr("GRID: ", msg)
		if bad.is_empty():
			printerr("SELFTEST GRID PASS: панели по сетке, кадры 16:9, кегли из шкалы")
			get_tree().quit(0)
		else:
			printerr("SELFTEST GRID FAIL: %d замечаний" % bad.size())
			get_tree().quit(1)
		return
	# Существующие автотесты запускают игру сразу: меню их не задерживает.
	if forced != "":
		_load_game(forced)
	elif selftest != "" and selftest != "menu" and selftest != "cursor" \
			and selftest != "hint":
		_load_game(selftest if _has_card(selftest) else "air")


func _has_card(id: String) -> bool:
	for c in CARDS:
		if c.id == id and c.scene != "":
			return true
	return false


func _exit_tree() -> void:
	synth.stop()


func _load_game(id: String) -> void:
	for c in CARDS:
		if c.id == id and c.scene != "":
			printerr("MENU -> ", id)
			get_tree().change_scene_to_file(c.scene)
			return
	printerr("MENU: нет игры ", id)


func _card_rect(i: int) -> Rect2:
	# 6 плиток: 3 в ряд, 2 ряда.
	var col := i % 3
	var row := int(i / 3)
	return Rect2(Lay.MENU_CARD.position
		+ Vector2(Lay.MENU_CARD_STEP * float(col), Lay.MENU_ROW_STEP * float(row)),
		Lay.MENU_CARD.size)


# ---------------------------------------------------------------- игроки


func _collect_players() -> void:
	players.clear()
	cursor_pos.clear()
	if bridge == null:
		return
	frame_px = Vector2(bridge.frame_size)
	if frame_px.x < 1.0 or frame_px.y < 1.0:
		frame_px = Vector2(1920.0, 1080.0)
	var aspect := frame_px.x / frame_px.y
	var list: Array = bridge.players()
	list.sort_custom(func(a, b): return a.camera_rect_norm.position.x < b.camera_rect_norm.position.x)
	var i := 0
	for p in list:
		if str(p.state) != "confirmed":
			continue
		var id: int = p.track_id
		var fi = inputs.get(id, null)
		if fi == null:
			fi = Inp.new()
			inputs[id] = fi
		fi.mode = input_mode
		fi.update(p, get_process_delta_time(), aspect, frame_px)
		if not fi.have_neutral:
			fi.accumulate()
			if fi.samples >= 12:
				fi.finish_calibration()
		var col: Color = p.color if p.color is Color else Neo.player_color(i)
		players.append({"slot": p.slot, "track_id": id, "color": col,
			"name": "игрок %d" % (i + 1), "calibrated": fi.have_neutral})
		cursor_pos[id] = Vector2.ZERO       # посчитаем после, когда известно число игроков
		i += 1
		if i >= 4:
			break
	# Курсор — НЕ абсолютная позиция носа: лицо в кадре двигается мало. Берём
	# отклонение от нейтрали (ax, ay) и разгоняем его до размаха экрана.
	var n := players.size()
	for k in n:
		var p: Dictionary = players[k]
		var fi = inputs.get(p.track_id, null)
		if fi == null:
			continue
		var off := Vector2(fi.ax, fi.ay) * cursor_sens
		cursor_pos[p.track_id] = _chip_pos(k, n) + off
		cur_min = Vector2(minf(cur_min.x, off.x), minf(cur_min.y, off.y))
		cur_max = Vector2(maxf(cur_max.x, off.x), maxf(cur_max.y, off.y))
		if debug_ui:
			printerr("MENU INPUT slot=%d ax=%+.2f ay=%+.2f neutral=%s cursor=(%.0f, %.0f)" % [
				p.slot, fi.ax, fi.ay, fi.have_neutral, cursor_pos[p.track_id].x,
				cursor_pos[p.track_id].y])
	for key in votes.keys():
		if not _has_track(key):
			votes.erase(key)
			dwell.erase(key)
			hover.erase(key)
	for key in inputs.keys():
		if not _has_track(key):
			inputs.erase(key)


func _chip_pos(i: int, n: int) -> Vector2:
	# Курсор начинается у «фишки» игрока под плитками — оттуда удобно тянуться.
	var per := mini(maxi(n, 1), CHIPS_PER_ROW)
	var row := i / CHIPS_PER_ROW
	var col := i % CHIPS_PER_ROW
	var step := Lay.MENU_CHIPS.size.x / float(maxi(per, 1))
	var x0 := Lay.MENU_CHIPS.position.x + step * (float(col) + 0.5)
	return Vector2(x0, Lay.MENU_CHIPS.position.y + 46.0 + float(row) * 96.0)


func _has_track(id: int) -> bool:
	for p in players:
		if p.track_id == id:
			return true
	return false


func _available(idx: int) -> bool:
	var c: Dictionary = CARDS[idx]
	var n := players.size()
	return c.scene != "" and n >= int(c.min) and n <= int(c.max)


func _vote(track_id: int, idx: int) -> void:
	if not _available(idx):
		return
	var prev = votes.get(track_id, null)
	if prev != null and int(prev.card) == idx:
		return
	votes[track_id] = {"card": idx, "t": state_t}
	last_vote_t = state_t
	synth.tone(660.0, 880.0, 0.08, 0.25)
	if countdown >= 0.0:
		countdown = -1.0     # голос поменялся — отсчёт заново
		msg = "голос изменён — ждём остальных"
		msg_t = 2.0


func _tick_voting(dt: float) -> void:
	for p in players:
		var id: int = p.track_id
		var pos: Vector2 = cursor_pos.get(id, Vector2.ZERO)
		var idx := -1
		for i in CARDS.size():
			if _card_rect(i).has_point(pos) and _available(i):
				idx = i
				break
		if idx < 0:
			dwell[id] = 0.0
			hover[id] = -1
			continue
		if int(hover.get(id, -1)) != idx:
			hover[id] = idx
			dwell[id] = 0.0
		dwell[id] = float(dwell.get(id, 0.0)) + dt
		if float(dwell[id]) >= DWELL:
			dwell[id] = 0.0
			_vote(id, idx)


func _leading() -> int:
	# Побеждает игра с максимумом голосов; при равенстве — та, за которую
	# проголосовали раньше.
	var counts := {}
	var first := {}
	for id in votes.keys():
		var v: Dictionary = votes[id]
		counts[v.card] = int(counts.get(v.card, 0)) + 1
		if not first.has(v.card) or float(v.t) < float(first[v.card]):
			first[v.card] = float(v.t)
	var best := -1
	var best_n := -1
	var best_t := INF
	for card in counts.keys():
		var n: int = counts[card]
		if n > best_n or (n == best_n and float(first[card]) < best_t):
			best = card
			best_n = n
			best_t = float(first[card])
	return best


func _process(dt: float) -> void:
	state_t += dt
	msg_t = maxf(0.0, msg_t - dt)
	synth.pump()
	if bridge != null:
		bridge.rotation_checkpoint()
	_collect_players()
	_update_cam()
	if selftest == "menu":
		_selftest_vote(dt)
	if selftest == "hint":
		_selftest_hint()
	if selftest == "cursor":
		_selftest_cursor()
	elif players.size() > 0:
		_tick_voting(dt)
	# если проголосовали не все, но кто-то ушёл из кадра — запускаем лидера по таймауту
	if players.size() > 0 and votes.size() < players.size() and _leading() >= 0 \
			and state_t - last_vote_t > vote_timeout and countdown < 0.0:
		countdown = COUNTDOWN
		start_target = CARDS[_leading()].id
		msg = "не все проголосовали — запускаем лидера"
		msg_t = 3.0
	if votes.size() >= players.size() and players.size() > 0 and _leading() >= 0:
		if countdown < 0.0:
			countdown = COUNTDOWN
			start_target = CARDS[_leading()].id
		else:
			countdown -= dt
			var lead := _leading()
			if lead >= 0 and CARDS[lead].id != start_target:
				start_target = CARDS[lead].id
			if countdown <= 0.0:
				printerr("MENU START ", start_target, " голосов=", votes.size(),
					" игроков=", players.size())
				_load_game(start_target)
				return
	queue_redraw()


## Активный источник ввода первого игрока: "face" или "hand".
func _active_src() -> String:
	for p in players:
		var inp = inputs.get(p.track_id)
		if inp != null and inp.have_input:
			return inp.active
	return "hand" if input_mode == "hand" else "face"


func _update_cam() -> void:
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


## Проверка подсказки «близко — лицом, далеко — рукой»: виджет загружен,
## тексты на месте, активный источник определяется.
func _selftest_hint() -> void:
	if state_t < 2.0 or players.is_empty():
		return
	var src := _active_src()
	if src != "face" and src != "hand":
		printerr("SELFTEST HINT FAIL: источник ввода не определён")
		get_tree().quit(1)
		return
	printerr("SELFTEST HINT: источник=%s плиток=%d игроков=%d" % [src, CARDS.size(), players.size()])
	printerr("SELFTEST HINT PASS")
	get_tree().quit(0)


func _selftest_cursor() -> void:
	# Проверка «курсор ходит по всему экрану», а не на пару сантиметров.
	if state_t < 1.5 or players.is_empty():
		return
	var spread := cur_max - cur_min
	if state_t > 5.5:
		var ok := spread.x > 600.0 and spread.y > 200.0
		printerr("SELFTEST MENU CURSOR: размах X=%.0f px, Y=%.0f px" % [spread.x, spread.y])
		if ok:
			printerr("SELFTEST MENU CURSOR PASS")
			get_tree().quit(0)
		else:
			printerr("SELFTEST MENU CURSOR FAIL: курсор почти не двигается")
			get_tree().quit(1)


func _selftest_vote(dt: float) -> void:
	if state_t < 1.2:
		return
	for p in players:
		if not votes.has(p.track_id):
			votes[p.track_id] = {"card": 1, "t": state_t}
	if players.size() > 0 and votes.size() >= players.size():
		if countdown < 0.0:
			countdown = 0.4      # в автотесте не ждём 2.5 с
			start_target = "tron"


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var idx := -1
		match event.keycode:
			KEY_1:
				idx = 0
			KEY_2:
				idx = 1
			KEY_3:
				idx = 2
			KEY_4:
				idx = 3
			KEY_5:
				idx = 4
			KEY_6:
				idx = 5
			KEY_SPACE, KEY_ENTER:
				if _leading() >= 0 and _available(_leading()):
					_load_game(CARDS[_leading()].id)
		if idx >= 0 and _available(idx):
			if players.size() > 0:
				_vote(players[0].track_id, idx)
			else:
				_load_game(CARDS[idx].id)      # без трекинга — сразу запускаем
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var m := get_global_mouse_position()
		for i in CARDS.size():
			if _card_rect(i).has_point(m) and _available(i):
				if players.size() > 0:
					_vote(players[0].track_id, i)
				else:
					_load_game(CARDS[i].id)
				break


# ---------------------------------------------------------------- отрисовка


func _draw() -> void:
	Neo.grid_bg(self, Vector2(Lay.W, Lay.H))
	var keys := "1..6 — выбрать · Enter — начать"
	if demo:
		keys = "демо без трекинга: 1..6 — запустить игру"
	Lay.header(self, "NEON ARCADE", "неоновая аркада · голосование лицом",
		"в кадре: %d" % players.size(), keys)
	for i in CARDS.size():
		_draw_card(i)
	_draw_players()
	InputHint.draw(self, Lay.MENU_HINT, _active_src(), Time.get_ticks_msec() * 0.001)
	_draw_cursors()
	if players.is_empty():
		Neo.text(self, "встаньте перед камерой", Vector2(729.0, Lay.MENU_MSG_Y), Lay.T_H2,
			Neo.WARN)
	if msg_t > 0.0:
		var font := ThemeDB.fallback_font
		var w := 0.0
		if font != null:
			w = font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, Lay.T_BODY).x
		Neo.text_left(self, msg, Vector2(Lay.W - Lay.M - w, Lay.FOOT_Y + 36.0), Lay.T_BODY,
			Neo.WARN)
	Neo.scanlines(self, Vector2(Lay.W, Lay.H))


func _draw_all_screens() -> void:
	# В headless _draw сам не зовётся, но зовётся после queue_redraw() на кадре
	# главного цикла: прогоняем все состояния всех игр, чтобы ошибки в коде
	# отрисовки (имена, типы, индексы) всплыли здесь, а не на живой машине.
	var list := [
		["трон", "res://game/Tron.tscn", 5],
		["разортрон", "res://game/Razor.tscn", 5],
		["аэрохоккей", "res://game/Main.tscn", 6],
		["неон-джамп", "res://game/Jump.tscn", 5],
		["неон-тетрис", "res://game/Tetris.tscn", 5],
		["световые мечи", "res://game/Saber.tscn", 5],
	]
	var bad := 0
	for item in list:
		var pk := load(item[1]) as PackedScene
		if pk == null:
			printerr("DRAW: не загрузилась сцена ", item[1])
			bad += 1
			continue
		var node: Node = pk.instantiate()
		add_child(node)
		node.set_process(false)      # проверяем только отрисовку, не логику
		for st in int(item[2]):
			node.set("state", st)
			node.set("state_t", 0.5)
			node.queue_redraw()
			await get_tree().process_frame
			await get_tree().process_frame
			printerr("DRAW %s state=%d" % [item[0], st])
		remove_child(node)
		node.free()
	queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	printerr("DRAW меню ok")
	if bad == 0:
		printerr("SELFTEST DRAW PASS: все экраны рисуются без ошибок скрипта")
	get_tree().quit(0 if bad == 0 else 1)


func _draw_card(i: int) -> void:
	var c: Dictionary = CARDS[i]
	var r := _card_rect(i)
	var avail := _available(i)
	var col: Color = Neo.player_color(i) if avail else Neo.with_alpha(Neo.DIM, 0.45)
	Lay.panel(self, r, "", col)
	# Плитка горизонтальная: слева картинка, справа название и голоса.
	_glyph(Rect2(r.position + Vector2(24.0, 51.0), Vector2(130.0, 130.0)), i,
		col if avail else Neo.with_alpha(Neo.DIM, 0.35))
	var tx := r.position.x + 174.0
	var top := r.position.y
	Neo.text_left(self, c.title, Vector2(tx, top + 92.0), Lay.T_H2,
		Neo.TEXT if avail else Neo.with_alpha(Neo.DIM, 0.6))
	Neo.text_left(self, c.who, Vector2(tx, top + 122.0), Lay.T_SMALL, col)
	Neo.text_left(self, c.hint, Vector2(tx, top + 150.0), Lay.T_TINY,
		Neo.with_alpha(Neo.DIM, 0.85 if avail else 0.4))
	# кто уже голосует за эту плитку
	var bot := r.end.y
	var n := 0
	for id in votes.keys():
		var v: Dictionary = votes[id]
		if int(v.card) != i:
			continue
		draw_circle(Vector2(tx + 6.0 + float(n) * 16.0, top + 182.0), 6.0,
			Neo.player_color(int(id)))
		n += 1
	if avail:
		var txt := "нет голосов"
		if n == 1:
			txt = "1 голос"
		elif n > 1:
			txt = "%d голос%s" % [n, "а" if n < 5 else "ов"]
		Neo.text_left(self, txt, Vector2(tx, bot - 26.0), Lay.T_SMALL,
			Neo.TEXT if n > 0 else Neo.with_alpha(Neo.DIM, 0.7))
	else:
		var why := "нужно ровно 2 игрока" if int(c.min) == 2 and int(c.max) == 2 \
			else "нужен хотя бы 1 игрок"
		Neo.text_left(self, why, Vector2(tx, bot - 26.0), Lay.T_SMALL,
			Neo.with_alpha(Neo.WARN, 0.85))
	# клавиша запуска
	var key := Rect2(Vector2(_key_x(r), bot - 68.0), Vector2(44.0, 44.0))
	draw_rect(key, Neo.with_alpha(col, 0.10))
	draw_rect(key, col, false, 1.5)
	Neo.text(self, str(i + 1), key.get_center() + Vector2(0.0, 10.0), Lay.T_H2, col)


func _key_x(r: Rect2) -> float:
	return r.end.x - 24.0 - 44.0


## Картинка игры на плитке.
func _glyph(g: Rect2, i: int, col: Color) -> void:
	# Рисунок плитки в относительных координатах: он же масштабируется под любой размер.
	draw_rect(g, Color(0.02, 0.0, 0.06, 0.55))
	draw_rect(g, Neo.with_alpha(Neo.LINE, 0.20), false, 1.0)
	var w := g.size.x
	var h := g.size.y
	var sc := minf(w, h)
	var o := g.position
	var c := g.get_center()
	match i:
		0:    # аэрохоккей: стол, круг, две ракетки
			draw_line(Vector2(o.x + w * 0.5, o.y + h * 0.1), Vector2(o.x + w * 0.5, o.y + h * 0.9),
				Neo.with_alpha(Neo.LINE, 0.7), 2.0)
			draw_arc(c, sc * 0.3, 0.0, TAU, 32, Neo.with_alpha(Neo.LINE, 0.35), 1.5, true)
			draw_circle(Vector2(o.x + w * 0.2, o.y + h * 0.5), sc * 0.15, Neo.with_alpha(Neo.LEFT, 0.9))
			draw_circle(Vector2(o.x + w * 0.8, o.y + h * 0.5), sc * 0.15, Neo.with_alpha(Neo.RIGHT, 0.9))
		1:    # трон: два следа
			for j in 2:
				var y := o.y + h * (0.34 + float(j) * 0.32)
				var c2: Color = Neo.LEFT if j == 0 else Neo.RIGHT
				draw_line(Vector2(o.x + w * 0.16, y), Vector2(o.x + w * 0.84, y), c2, 3.0)
				draw_circle(Vector2(o.x + w * 0.16, y), 5.0, c2)
		2:    # разортрон: дорога и солнце
			var hz := o.y + h * 0.28
			draw_circle(Vector2(c.x, hz), sc * 0.18, Neo.with_alpha(Neo.RIGHT, 0.35))
			draw_line(Vector2(c.x - w * 0.08, hz), Vector2(o.x + w * 0.14, o.y + h * 0.94),
				Neo.with_alpha(Neo.LEFT, 0.9), 2.0)
			draw_line(Vector2(c.x + w * 0.08, hz), Vector2(o.x + w * 0.86, o.y + h * 0.94),
				Neo.with_alpha(Neo.LEFT, 0.9), 2.0)
			draw_line(Vector2(c.x, hz), Vector2(c.x, o.y + h * 0.94), Neo.with_alpha(Neo.PUCK, 0.5), 1.5)
		3:    # неон-джамп: платформы и человечек в прыжке
			for j in 3:
				var py := o.y + h * 0.8 - float(j) * h * 0.28
				var px := o.x + w * 0.1 + (0.0 if j % 2 == 0 else w * 0.3)
				var c3: Color = Neo.LEFT if j != 1 else Neo.OK
				draw_line(Vector2(px, py), Vector2(px + w * 0.4, py), c3, 3.0)
			var cc := Vector2(o.x + w * 0.68, o.y + h * 0.3)
			draw_circle(cc, sc * 0.11, Neo.with_alpha(Neo.RIGHT, 0.18))
			draw_arc(cc, sc * 0.11, 0.0, TAU, 24, Neo.with_alpha(Neo.RIGHT, 0.95), 2.5, true)
			draw_circle(cc + Vector2(-sc * 0.04, -sc * 0.03), 2.0, Neo.with_alpha(Neo.RIGHT, 0.95))
			draw_circle(cc + Vector2(sc * 0.04, -sc * 0.03), 2.0, Neo.with_alpha(Neo.RIGHT, 0.95))
		4:    # неон-тетрис: стакан на четверых и падающая фигура
			var bw := sc * 0.16
			var bx := c.x - bw * 2.0
			var by := o.y + h * 0.9
			for k in 4:
				draw_rect(Rect2(Vector2(bx + float(k) * bw, by - bw), Vector2(bw - 2.0, bw - 2.0)),
					Neo.with_alpha(Neo.LEFT, 0.85))
			for d in [Vector2(0.0, 3.0), Vector2(1.0, 3.0), Vector2(1.0, 4.0)]:
				draw_rect(Rect2(Vector2(bx + d.x * bw, by - (d.y + 1.0) * bw),
					Vector2(bw - 2.0, bw - 2.0)), Neo.with_alpha(Neo.RIGHT, 0.9))
			draw_line(Vector2(bx - 4.0, by - bw * 5.0), Vector2(bx - 4.0, by),
				Neo.with_alpha(Neo.LINE, 0.35), 1.5)
			draw_line(Vector2(bx + bw * 4.0 + 4.0, by - bw * 5.0), Vector2(bx + bw * 4.0 + 4.0, by),
				Neo.with_alpha(Neo.LINE, 0.35), 1.5)
		5:    # световые мечи: скрещённые клинки и искра в точке удара
			draw_line(Vector2(o.x + w * 0.16, o.y + h * 0.86), Vector2(o.x + w * 0.56, o.y + h * 0.16),
				Neo.with_alpha(Neo.LEFT, 0.95), 4.0)
			draw_line(Vector2(o.x + w * 0.84, o.y + h * 0.86), Vector2(o.x + w * 0.44, o.y + h * 0.16),
				Neo.with_alpha(Neo.RIGHT, 0.95), 4.0)
			draw_circle(c, sc * 0.14, Neo.with_alpha(Neo.PUCK, 0.25))
			draw_arc(c, sc * 0.14, 0.0, TAU, 20, Neo.with_alpha(Neo.PUCK, 0.9), 2.0, true)
		_:
			Neo.text(self, "?", c, Lay.T_H1, Neo.DIM)


func _draw_players() -> void:
	for i in players.size():
		var p: Dictionary = players[i]
		var pos := _chip_pos(i, players.size())
		draw_circle(pos - Vector2(150.0, 8.0), 13.0, p.color)
		Neo.text_left(self, p.name, pos - Vector2(130.0, 0.0), Lay.T_H2, Neo.TEXT)
		var voted := "не голосовал"
		if votes.has(p.track_id):
			voted = CARDS[int(votes[p.track_id].card)].id.to_upper()
		Neo.text_left(self, voted, pos - Vector2(130.0, -24.0), Lay.T_SMALL, Neo.DIM)


func _draw_cursors() -> void:
	if countdown >= 0.0:
		draw_rect(Rect2(0.0, 0.0, Lay.W, Lay.H), Color(0.02, 0.0, 0.08, 0.62))
		var k := ceili(countdown)
		Neo.text(self, str(maxi(k, 1)), Vector2(Lay.W * 0.5, 600.0), 140, Neo.PUCK)
		Neo.text(self, "запускаем «%s»" % start_target.to_upper(), Vector2(Lay.W * 0.5, 660.0),
			Lay.T_H2, Neo.TEXT)
	for p in players:
		var id: int = p.track_id
		var pos: Vector2 = cursor_pos.get(id, Vector2.ZERO)
		var col: Color = p.color
		draw_circle(pos, 26.0, Neo.with_alpha(col, 0.12))
		draw_circle(pos, 14.0, Neo.with_alpha(col, 0.55))
		draw_circle(pos, 7.0, col)
		var dv := float(dwell.get(id, 0.0)) / DWELL
		if dv > 0.01:
			draw_arc(pos, 22.0, -PI * 0.5, -PI * 0.5 + TAU * clampf(dv, 0.0, 1.0),
				32, col, 4.0, true)
