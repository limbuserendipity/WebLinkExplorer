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

const DWELL := 1.2                # сколько держать лицо на плитке для голоса
const COUNTDOWN := 2.5            # отсчёт перед запуском
const CARDS := [
	{"id": "air", "title": "АЭРОХОККЕЙ", "who": "ровно 2 игрока", "min": 2, "max": 2,
		"scene": "res://game/Main.tscn",
		"hint": "ракетки в своих половинах · лицо — курсор"},
	{"id": "tron", "title": "ТРОН", "who": "1–4 игрока", "min": 1, "max": 4,
		"scene": "res://game/Tron.tscn",
		"hint": "световой след · кто дольше живёт"},
	{"id": "soon", "title": "СКОРО", "who": "—", "min": 99, "max": 99,
		"scene": "", "hint": "место для следующей игры"},
]
const CARD_W := 420.0
const CARD_H := 380.0
const CARD_Y := 300.0
const CARD_GAP := 60.0

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
var msg := ""
var msg_t := 0.0


func _ready() -> void:
	bridge = get_node_or_null("/root/GameDirector")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--selftest="):
			selftest = arg.trim_prefix("--selftest=")
		elif arg.begins_with("--game="):
			forced = arg.trim_prefix("--game=")
		elif arg == "--no-audio":
			no_audio = true
		elif arg.begins_with("--port="):
			demo = false
	var has_port := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			has_port = true
	demo = not has_port
	if not no_audio and selftest == "":
		synth.setup(self)
	# Существующие автотесты запускают игру сразу: меню их не задерживает.
	if forced != "":
		_load_game(forced)
	elif selftest != "" and selftest != "menu":
		_load_game("tron" if selftest == "tron" else "air")


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
	var total := CARDS.size() * CARD_W + (CARDS.size() - 1) * CARD_GAP
	var x0 := 960.0 - total * 0.5
	return Rect2(x0 + i * (CARD_W + CARD_GAP), CARD_Y, CARD_W, CARD_H)


# ---------------------------------------------------------------- игроки


func _collect_players() -> void:
	players.clear()
	cursor_pos.clear()
	if bridge == null:
		return
	frame_px = Vector2(bridge.frame_size)
	if frame_px.x < 1.0 or frame_px.y < 1.0:
		frame_px = Vector2(1920.0, 1080.0)
	var list: Array = bridge.players()
	list.sort_custom(func(a, b): return a.camera_rect_norm.position.x < b.camera_rect_norm.position.x)
	var i := 0
	for p in list:
		if str(p.state) != "confirmed":
			continue
		var nose := Inp.nose_screen(p, frame_px)
		var col: Color = p.color if p.color is Color else Neo.player_color(i)
		players.append({"slot": p.slot, "track_id": p.track_id, "color": col,
			"nose": nose, "name": "игрок %d" % (i + 1)})
		cursor_pos[p.track_id] = Vector2(nose.x * 1920.0, nose.y * 1080.0)
		i += 1
		if i >= 4:
			break
	# забываем тех, кто ушёл
	for key in votes.keys():
		if not _has_track(key):
			votes.erase(key)
			dwell.erase(key)
			hover.erase(key)


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
	if selftest == "menu":
		_selftest_vote(dt)
	if players.size() > 0:
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
	Neo.grid_bg(self, Vector2(1920, 1080))
	Neo.text(self, "NEON ARCADE", Vector2(960, 150), 78, Neo.TEXT)
	Neo.text(self, "наведите лицо на игру и задержите — это ваш голос", Vector2(960, 205), 26, Neo.DIM)
	for i in CARDS.size():
		_draw_card(i)
	_draw_players()
	_draw_cursors()
	var hint := "1 / 2 / 3 — выбрать, Enter — начать"
	if demo:
		hint = "демо без трекинга: 1 / 2 / 3 — запустить игру"
	Neo.text(self, hint, Vector2(960, 1010), 24, Neo.DIM)
	if msg_t > 0.0:
		Neo.text(self, msg, Vector2(960, 1050), 22, Neo.WARN)
	if players.is_empty():
		Neo.text(self, "встаньте перед камерой", Vector2(960, 780), 32, Neo.WARN)
	Neo.scanlines(self, Vector2(1920, 1080))


func _draw_card(i: int) -> void:
	var c: Dictionary = CARDS[i]
	var r := _card_rect(i)
	var avail := _available(i)
	var col: Color = Neo.player_color(i) if avail else Neo.with_alpha(Neo.DIM, 0.5)
	var fill := Color(0.05, 0.01, 0.16, 0.85)
	draw_rect(r, fill)
	draw_rect(r, Neo.with_alpha(col, 0.25), false, 8.0)
	Neo.box(self, r, col, 2.0)
	Neo.text(self, c.title, Vector2(r.get_center().x, r.position.y + 90.0), 40,
		Neo.TEXT if avail else Neo.with_alpha(Neo.DIM, 0.6))
	Neo.text(self, c.who, Vector2(r.get_center().x, r.position.y + 140.0), 26,
		col if avail else Neo.with_alpha(Neo.DIM, 0.5))
	Neo.text(self, c.hint, Vector2(r.get_center().x, r.position.y + 195.0), 19,
		Neo.with_alpha(Neo.DIM, 0.85 if avail else 0.4))
	# кто уже голосует за эту плитку
	var y := r.position.y + 250.0
	var n := 0
	for id in votes.keys():
		var v: Dictionary = votes[id]
		if int(v.card) != i:
			continue
		var pcol := _color_of(id)
		draw_circle(Vector2(r.position.x + 60.0 + n * 46.0, y), 15.0, pcol)
		n += 1
	if n > 0:
		Neo.text(self, "%d голос%s" % [n, "" if n == 1 else "а"],
			Vector2(r.get_center().x, y + 52.0), 24, Neo.TEXT)
	if not avail and c.scene != "":
		var why := "нужно ровно 2 игрока" if c.id == "air" else "нет игроков"
		Neo.text(self, why, Vector2(r.get_center().x, r.end.y - 30.0), 20,
			Neo.with_alpha(Neo.WARN, 0.8))
	elif c.scene == "":
		Neo.text(self, "в разработке", Vector2(r.get_center().x, r.end.y - 30.0), 20,
			Neo.with_alpha(Neo.DIM, 0.5))


func _color_of(track_id: int) -> Color:
	for p in players:
		if p.track_id == track_id:
			return p.color
	return Neo.DIM


func _draw_players() -> void:
	var n := players.size()
	var x0 := 960.0 - 260.0 * maxf(n - 1, 0) * 0.5
	for i in n:
		var p: Dictionary = players[i]
		var pos := Vector2(x0 + 260.0 * i, 870.0)
		draw_circle(pos - Vector2(70, 0), 14.0, p.color)
		Neo.text(self, p.name, pos, 26, Neo.TEXT)
		var voted := "не голосовал"
		if votes.has(p.track_id):
			voted = CARDS[int(votes[p.track_id].card)].id.to_upper()
		Neo.text(self, voted, pos + Vector2(0, 34), 20, Neo.DIM)


func _draw_cursors() -> void:
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
	if countdown >= 0.0:
		var k := ceili(countdown)
		Neo.text(self, str(maxi(k, 1)), Vector2(960, 760), 96, Neo.PUCK)
