extends Node2D
## «РАЗОРТРОН 2000»: неоновая гонка по шоссе в закат. 1–6 игроков.
## Голова уходит влево/вправо — руль, вперёд — ускорение, назад — тормоз.
## На шоссе трафик: столкновение сбрасывает скорость. Кто первым доедет до
## финиша, тот и победил. В одиночку и вдвоём подсаживаются боты.

const Inp := preload("res://core/FaceInput.gd")
const Neo := preload("res://core/Neon.gd")
const Sfx := preload("res://core/Sfx.gd")
const CamView := preload("res://core/CamView.gd")
const InputHint := preload("res://core/InputHint.gd")

const HORIZON := 470.0           # линия горизонта, px
const BOTTOM := 1000.0           # ближний край дороги, px
const VP_X := 960.0              # точка схода
const Z0 := 8.0
const PX_UNIT := 230.0           # пикселей на единицу дороги у ближнего края
const ROAD_HALF := 3.0           # полдороги в единицах: 6 полос по 1.0
const RACE_M := 1200.0           # длина гонки по умолчанию, м
const VMAX := 52.0
const VBOOST := 66.0
const VBRAKE := 24.0
const ACCEL := 16.0
const STEER := 3.2               # единиц дороги в секунду при полном отклонении
const STUN_T := 0.7
const MAX_HUMANS := 6
const STALE := 0.5
const MENU_SCENE := "res://ui/Menu.tscn"

const CAM_RECT := Rect2(24.0, 24.0, 320.0, 180.0)
const HINT_RECT := Rect2(24.0, 222.0, 424.0, 236.0)
const BOARD_RECT := Rect2(1540.0, 24.0, 356.0, 262.0)

enum St { WAIT, READY, RUN, RESULT, OVER }


class Car:
	var id := 0
	var human := false
	var color := Color.WHITE
	var title := "бот"
	var px := 0.0                # поперечная координата, единицы дороги
	var dist := 0.0
	var v := 0.0
	var stun := 0.0
	var place := 1
	var finished := false
	var inp := Inp.new()
	var track_slot := -1
	var track_id := -1
	var bot_wobble := 0.0
	var bot_side := 1.0
	var flash := 0.0


var bridge: Node
var state: int = St.WAIT
var state_t := 0.0
var cars: Array[Car] = []
var traffic: Array = []          # [{dist, px, kind}]
var winner := -1
var race_m := RACE_M
var spawn_dist := 0.0
var frozen := false
var demo := false
var solo := false
var sparks: Array = []
var rng := RandomNumberGenerator.new()
var synth := Sfx.new()
var cam_view = null
var selftest := ""
var input_mode := "auto"
var gain := 1.0
var flip_x := 1.0
var flip_y := 1.0
var debug_ui := false
var no_audio := false
var st_t := 0.0
var st_mark := 0.0
var log_t := 0.0
var frame_px := Vector2(1920.0, 1080.0)
var shake := 0.0
var arrows := {"left": false, "right": false, "up": false, "down": false}


func _ready() -> void:
	bridge = get_node_or_null("/root/GameDirector")
	cam_view = CamView.new()
	cam_view.setup(CAM_RECT)
	cam_view.subtitle = "фильтр: неон"
	add_child(cam_view)
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
		elif arg.begins_with("--dist="):
			race_m = maxf(60.0, float(arg.trim_prefix("--dist=")))
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
	rng.seed = 20000101
	if selftest == "razor" and race_m == RACE_M:
		race_m = 300.0          # автотесту хватает короткого заезда
	_build_cars()
	printerr("RAZOR START players=%d mode=%s dist=%.0f" % [_human_count_hint(), input_mode, race_m])
	_set_state(St.WAIT)
	state_t = 100.0 if selftest == "razor" else 0.0


func _exit_tree() -> void:
	synth.stop()


func _human_count_hint() -> int:
	if demo:
		return 1
	if bridge == null:
		return 0
	return mini(bridge.players().size(), MAX_HUMANS)


# ---------------------------------------------------------------- состав гонки


func _build_cars() -> void:
	cars.clear()
	var humans := _human_count_hint()
	var bots := 0
	if humans < 3:
		bots = 3 - humans
	elif humans < 4:
		bots = 0
	var total := mini(humans + bots, MAX_HUMANS)
	var n := maxi(total, 1)
	for i in n:
		var c := Car.new()
		c.id = i
		c.human = i < humans
		c.color = Neo.player_color(i, Color.WHITE)
		c.px = _lane_center(i, n)
		c.title = "ИГРОК %d" % (i + 1) if c.human else "БОТ %d" % (i + 1 - humans)
		c.inp.mode = input_mode
		c.bot_wobble = rng.randf_range(0.0, TAU)
		c.bot_side = -1.0 if rng.randf() < 0.5 else 1.0
		cars.append(c)
	_bind_humans()
	solo = humans <= 1


func _lane_center(i: int, n: int) -> float:
	if n <= 1:
		return 0.0
	var span := (ROAD_HALF - 0.62) * 2.0
	var step := span / float(maxi(n - 1, 1))
	return -(span * 0.5) + step * float(i)


func _bind_humans() -> void:
	if demo or bridge == null:
		return
	var list: Array = bridge.players()
	var i := 0
	for c in cars:
		if not c.human:
			continue
		if i < list.size():
			var p = list[i]
			c.track_slot = int(p.slot)
			c.track_id = int(p.track_id)
			c.color = p.color
		i += 1


# ---------------------------------------------------------------- цикл


func _process(dt: float) -> void:
	dt = minf(dt, 0.1)
	state_t += dt
	synth.pump()
	shake = maxf(0.0, shake - dt * 2.4)
	for c in cars:
		c.flash = maxf(0.0, c.flash - dt * 2.5)
	_update_sparks(dt)
	_collect_inputs(dt)
	if demo:
		_demo_drive()
	_update_cam()
	var tracking_ok: bool = demo or (bridge != null and bridge.tracking_age() <= STALE)
	match state:
		St.WAIT:
			_tick_waiting(dt, tracking_ok)
		St.READY:
			_tick_ready(dt, tracking_ok)
		St.RUN:
			_tick_run(dt, tracking_ok)
		St.RESULT:
			_tick_result(dt)
		St.OVER:
			_tick_over(dt)
	if selftest != "":
		_selftest_tick()
	queue_redraw()


func _set_state(s: int) -> void:
	state = s
	state_t = 0.0


func _tick_waiting(dt: float, ok: bool) -> void:
	if not ok:
		return
	if bridge != null and not demo:
		_bind_humans()
	if state_t > 0.6:
		_reset_race()
		_set_state(St.READY)
		synth.tone(330.0, 660.0, 0.12, 0.25)


func _reset_race() -> void:
	traffic.clear()
	winner = -1
	spawn_dist = 60.0
	for c in cars:
		c.dist = 0.0
		c.v = 10.0
		c.stun = 0.0
		c.finished = false
		c.place = 1
		c.px = _lane_center(c.id, cars.size())


func _tick_ready(dt: float, ok: bool) -> void:
	var wait := 0.6 if selftest == "razor" else 2.6
	if not ok:
		state_t = 0.0
		return
	if state_t >= wait:
		_set_state(St.RUN)
		synth.tone(220.0, 880.0, 0.2, 0.3)


func _tick_run(dt: float, ok: bool) -> void:
	frozen = not ok
	if frozen:
		return
	_collect_inputs(dt)
	_update_traffic()
	var lead := _lead_dist()
	for c in cars:
		if c.finished:
			continue
		_drive(c, dt, lead)
	for c in cars:
		_collide(c)
		if not c.finished and c.dist >= race_m:
			c.finished = true
			if winner < 0:
				winner = c.id
	if winner >= 0:
		_set_state(St.RESULT)
		synth.tone(660.0, 1320.0, 0.25, 0.3)


func _tick_result(dt: float) -> void:
	if state_t > 2.4:
		_set_state(St.OVER)


func _tick_over(dt: float) -> void:
	if state_t > 1.4:
		if selftest == "razor":
			return
		_load_menu()


func _load_menu() -> void:
	if FileAccess.file_exists("res://ui/Menu.tscn"):
		get_tree().change_scene_to_file(MENU_SCENE)
	else:
		get_tree().quit(0)


# ---------------------------------------------------------------- ввод


func _collect_inputs(dt: float) -> void:
	if demo or bridge == null:
		return
	var players: Array = bridge.players()
	for c in cars:
		if not c.human:
			continue
		var p = null
		for cand in players:
			if int(cand.slot) == c.track_slot and int(cand.track_id) == c.track_id \
					and str(cand.state) == "confirmed":
				p = cand
				break
		if p == null:
			continue
		c.inp.mode = input_mode
		c.inp.gain = gain
		c.inp.flip_x = flip_x
		c.inp.flip_y = flip_y
		c.inp.update(p, dt, _aspect(), _frame_px())
		if not c.inp.have_neutral:
			c.inp.accumulate()
			if c.inp.samples >= 12:
				c.inp.finish_calibration()


func _frame_px() -> Vector2:
	if bridge == null:
		return Vector2(1920.0, 1080.0)
	var px := Vector2(bridge.frame_size)
	if px.x < 1.0 or px.y < 1.0:
		px = Vector2(1920.0, 1080.0)
	return px


func _aspect() -> float:
	if bridge != null and bridge.frame_size.y > 0:
		return float(bridge.frame_size.x) / float(bridge.frame_size.y)
	return 16.0 / 9.0


func _steer_of(c: Car, dt: float) -> float:
	if c.human:
		return c.inp.ax
	# бот: объезжает близкий трафик и слегка виляет
	c.bot_wobble += dt * 1.7
	var look := 0.0
	for o in traffic:
		var dd: float = float(o.dist) - c.dist
		if dd > 0.0 and dd < 34.0 and absf(float(o.px) - c.px) < 1.25:
			look = c.bot_side
			break
	if look == 0.0:
		look = clampf((0.0 - c.px) * 0.25, -0.5, 0.5) + sin(c.bot_wobble) * 0.22
	return look


func _throttle_of(c: Car, lead: float) -> float:
	if c.human:
		if c.inp.ay < -0.55:
			return VBOOST
		if c.inp.ay > 0.65:
			return VBRAKE
		return VMAX
	# боты чуть медленнее человека и подтягиваются, если отстали
	var base := VMAX * 0.95
	if lead - c.dist > 70.0:
		base += 7.0
	return base


# ---------------------------------------------------------------- физика


func _drive(c: Car, dt: float, lead: float) -> void:
	var steer := clampf(_steer_of(c, dt), -1.0, 1.0)
	c.px = clampf(c.px + steer * STEER * dt, -ROAD_HALF + 0.5, ROAD_HALF - 0.5)
	var target := _throttle_of(c, lead)
	if c.stun > 0.0:
		c.stun = maxf(0.0, c.stun - dt)
		target = minf(target, VBRAKE * 0.6)
	c.v = move_toward(c.v, target, ACCEL * dt)
	c.dist += c.v * dt


func _update_traffic() -> void:
	var lead := _lead_dist()
	while spawn_dist < lead + 160.0:
		var n := 1 if rng.randf() < 0.7 else 2
		for i in n:
			var lane := rng.randi_range(0, 5)
			traffic.append({"dist": spawn_dist + rng.randf_range(-4.0, 4.0),
				"px": -ROAD_HALF + 0.5 + float(lane),
				"kind": i})
		spawn_dist += rng.randf_range(26.0, 46.0)
	var keep := []
	for o in traffic:
		if float(o.dist) > lead - 40.0:
			keep.append(o)
	traffic = keep


func _collide(c: Car) -> void:
	if c.stun > 0.0:
		return
	for o in traffic:
		if absf(float(o.dist) - c.dist) < 2.6 and absf(float(o.px) - c.px) < 0.78:
			c.v = maxf(c.v * 0.35, 8.0)
			c.stun = STUN_T
			c.flash = 1.0
			shake = minf(shake + 0.35, 1.0)
			_burst(c.color, 10)
			synth.tone(140.0, 70.0, 0.12, 0.22)
			return


func _lead_dist() -> float:
	var m := 0.0
	for c in cars:
		m = maxf(m, c.dist)
	return m


func _last_dist() -> float:
	var m := 1e9
	for c in cars:
		m = minf(m, c.dist)
	return 0.0 if m == 1e9 else m


func _places() -> Array:
	var order: Array = cars.duplicate()
	order.sort_custom(func(a, b): return a.dist > b.dist)
	for i in order.size():
		order[i].place = i + 1
	return order


# ---------------------------------------------------------------- картинка


func _proj(zd: float, wx: float) -> Vector2:
	var s := Z0 / (maxf(zd, 0.05) + Z0)
	return Vector2(VP_X + wx * PX_UNIT * s, HORIZON + (BOTTOM - HORIZON) * s)


func _zd_of(dz: float) -> float:
	return 5.0 + 2.2 * sqrt(maxf(dz, 0.0))


func _car_zd(c: Car) -> float:
	# камера стоит за последней машиной: лидер — дальше всех
	return _zd_of(c.dist - _last_dist())


func _draw() -> void:
	if shake > 0.0:
		var tm := Time.get_ticks_msec() * 0.001
		draw_set_transform(Vector2(sin(tm * 77.0) * shake * 6.0, cos(tm * 67.0) * shake * 5.0),
			0.0, Vector2.ONE)
	_draw_sky()
	_draw_road()
	_draw_traffic()
	_draw_cars()
	_draw_sparks()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud()


func _draw_sky() -> void:
	var bands := 18
	var top := Color(0.03, 0.0, 0.10)
	var low := Color(0.24, 0.03, 0.34)
	for i in bands:
		var k := float(i) / float(bands - 1)
		var c := top.lerp(low, k * k)
		draw_rect(Rect2(0.0, HORIZON * k, 1920.0, HORIZON / float(bands) + 1.0), c)
	# звёзды
	for i in 70:
		var sx := fmod(float(i) * 271.3, 1900.0) + 10.0
		var sy := fmod(float(i) * 97.7, 330.0) + 12.0
		var tw := 0.35 + 0.35 * sin(Time.get_ticks_msec() * 0.001 * 2.0 + float(i))
		draw_circle(Vector2(sx, sy), 1.4, Color(0.85, 0.9, 1.0, 0.25 + 0.4 * tw))
	# солнце
	var sun_c := Vector2(VP_X, HORIZON - 40.0)
	var rad := 165.0
	draw_circle(sun_c, rad * 1.5, Color(1.0, 0.2, 0.7, 0.05))
	draw_circle(sun_c, rad * 1.2, Color(1.0, 0.3, 0.6, 0.06))
	var slices := 20
	for i in slices:
		var y0 := sun_c.y - rad + (2.0 * rad) * float(i) / float(slices)
		var y1 := sun_c.y - rad + (2.0 * rad) * float(i + 1) / float(slices)
		var dy := clampf(absf((y0 + y1) * 0.5 - sun_c.y), 0.0, rad)
		var half := sqrt(maxf(rad * rad - dy * dy, 0.0))
		if half <= 0.0:
			continue
		var k := float(i) / float(slices - 1)
		var col := Color(1.0, 0.92, 0.45).lerp(Color(1.0, 0.18, 0.62), k)
		# нижние полосы режем — классический закат
		if i > slices / 2 and i % 3 == 0:
			continue
		draw_rect(Rect2(sun_c.x - half, y0, half * 2.0, y1 - y0 + 1.0),
			Color(col.r, col.g, col.b, 0.9))
	# линия горизонта
	draw_line(Vector2(0, HORIZON), Vector2(1920, HORIZON), Color(1.0, 0.25, 0.75, 0.55), 2.0)
	draw_line(Vector2(0, HORIZON + 2.0), Vector2(1920, HORIZON + 2.0),
		Color(0.3, 0.9, 1.0, 0.25), 1.0)


func _draw_road() -> void:
	var near_zd := 0.55
	var far_zd := 420.0
	var nl := _proj(near_zd, -ROAD_HALF)
	var nr := _proj(near_zd, ROAD_HALF)
	var fl := _proj(far_zd, -ROAD_HALF)
	var fr := _proj(far_zd, ROAD_HALF)
	var poly := PackedVector2Array([fl, fr, nr, nl])
	draw_colored_polygon(poly, Color(0.05, 0.02, 0.12, 0.96))
	# обочины
	draw_colored_polygon(PackedVector2Array([fl, nl, _proj(near_zd, -ROAD_HALF - 0.9),
		_proj(far_zd, -ROAD_HALF - 0.9)]), Color(0.10, 0.02, 0.20, 0.9))
	draw_colored_polygon(PackedVector2Array([fr, nr, _proj(near_zd, ROAD_HALF + 0.9),
		_proj(far_zd, ROAD_HALF + 0.9)]), Color(0.10, 0.02, 0.20, 0.9))
	# сетка поперёк дороги, ползёт навстречу
	var scroll := fmod(_lead_dist() * 0.55, 3.0)
	for k in 26:
		var zd0 := 1.0 + k * 3.0 - scroll
		if zd0 < near_zd:
			continue
		var zd1 := zd0 + 1.1
		var a := _proj(zd0, -ROAD_HALF)
		var b := _proj(zd0, ROAD_HALF)
		var k2 := clampf(1.0 - zd0 / 78.0, 0.05, 1.0)
		draw_line(a, b, Color(0.45, 0.35, 1.0, 0.10 * k2), 1.0 + 2.0 * k2)
	# пунктир по полосам
	for lane in range(1, 6):
		var wx := -ROAD_HALF + float(lane)
		for k in 26:
			var zd0 := 1.0 + k * 3.0 - scroll
			if zd0 < near_zd:
				continue
			var k2 := clampf(1.0 - zd0 / 78.0, 0.05, 1.0)
			draw_line(_proj(zd0, wx), _proj(zd0 + 1.5, wx),
				Color(0.55, 0.9, 1.0, 0.35 * k2), 1.0 + 3.0 * k2)
	# края: неоновые линии
	Neo.glow(self, nl, fl, Color(1.0, 0.25, 0.9, 0.85), 2.5)
	Neo.glow(self, nr, fr, Color(0.2, 0.95, 1.0, 0.85), 2.5)
	# столбики вдоль дороги
	for k in 14:
		var zd := 2.0 + k * 4.0 - fmod(_lead_dist() * 0.55, 4.0)
		if zd < near_zd:
			continue
		var k2 := clampf(1.0 - zd / 60.0, 0.1, 1.0)
		var h := 46.0 * k2
		for side in [-1.0, 1.0]:
			var base := _proj(zd, side * (ROAD_HALF + 0.75))
			var col: Color = Color(1.0, 0.3, 0.9, 0.8) if side < 0.0 else Color(0.25, 0.95, 1.0, 0.8)
			draw_line(base, base - Vector2(0.0, h), Color(col.r, col.g, col.b, 0.75 * k2),
				1.0 + 2.0 * k2)
			draw_circle(base - Vector2(0.0, h), 1.5 + 2.5 * k2, col)


func _draw_traffic() -> void:
	var last := _last_dist()
	var items: Array = []
	for o in traffic:
		var zd := _zd_of(float(o.dist) - last)
		if zd > 88.0:
			continue
		items.append([zd, o])
	items.sort_custom(func(a, b): return a[0] > b[0])
	for it in items:
		var zd: float = it[0]
		var o: Dictionary = it[1]
		var p := _proj(zd, float(o.px))
		var s := Z0 / (zd + Z0)
		var w := 16.0 + 74.0 * s
		var h := w * 0.78
		var col: Color = Color(1.0, 0.55, 0.15) if int(o.kind) == 0 else Color(0.55, 0.3, 1.0)
		draw_rect(Rect2(p.x - w * 0.5, p.y - h, w, h), Color(0.05, 0.0, 0.10, 0.92))
		draw_rect(Rect2(p.x - w * 0.5, p.y - h, w, h), Color(col.r, col.g, col.b, 0.85), false,
			1.0 + 2.0 * s)
		draw_circle(Vector2(p.x - w * 0.28, p.y - h * 0.25), 1.5 + 3.0 * s, col)
		draw_circle(Vector2(p.x + w * 0.28, p.y - h * 0.25), 1.5 + 3.0 * s, col)


func _draw_cars() -> void:
	var order: Array = []
	for c in cars:
		order.append([_car_zd(c), c])
	order.sort_custom(func(a, b): return a[0] > b[0])
	for it in order:
		var zd: float = it[0]
		var c: Car = it[1]
		var p := _proj(zd, c.px)
		var s := Z0 / (zd + Z0)
		var w := 20.0 + 96.0 * s
		var h := w * 0.72
		if p.y > BOTTOM + 40.0:
			_arrow_marker(c)
			continue
		var col: Color = c.color if c.stun <= 0.0 else c.color.lerp(Color.WHITE, 0.5)
		# хвост-след
		draw_rect(Rect2(p.x - w * 0.22, p.y - h * 1.6, w * 0.44, h * 1.3),
			Color(col.r, col.g, col.b, 0.16))
		# корпус
		var body := PackedVector2Array([
			Vector2(p.x - w * 0.5, p.y),
			Vector2(p.x - w * 0.34, p.y - h),
			Vector2(p.x + w * 0.34, p.y - h),
			Vector2(p.x + w * 0.5, p.y),
		])
		draw_colored_polygon(body, Color(0.06, 0.02, 0.14, 0.95))
		draw_polyline(PackedVector2Array([body[0], body[1], body[2], body[3], body[0]]),
			col, 2.0 + 2.0 * s, true)
		draw_circle(Vector2(p.x, p.y - h * 0.55), 2.0 + 5.0 * s, Color.WHITE)
		draw_circle(Vector2(p.x, p.y - h * 0.55), 6.0 + 16.0 * s, Color(col.r, col.g, col.b, 0.18))
		if c.flash > 0.0:
			draw_circle(Vector2(p.x, p.y - h * 0.5), (10.0 + 40.0 * s) * c.flash,
				Color(1.0, 0.8, 0.3, 0.5 * c.flash))
		Neo.text(self, c.title, Vector2(p.x, p.y + 16.0 + 10.0 * s), int(10.0 + 8.0 * s), col)


func _arrow_marker(c: Car) -> void:
	var x := VP_X + clampf(c.px, -ROAD_HALF, ROAD_HALF) * 260.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(x, BOTTOM + 8.0), Vector2(x - 12.0, BOTTOM + 30.0), Vector2(x + 12.0, BOTTOM + 30.0)]),
		c.color)
	Neo.text(self, c.title, Vector2(x, BOTTOM + 46.0), 16, c.color)


func _draw_sparks() -> void:
	for s in sparks:
		var k: float = 1.0 - float(s.t) / float(s.life)
		draw_circle(s.p, 3.0 * k + 1.0, Neo.with_alpha(s.c, k))


func _burst(col: Color, n: int) -> void:
	for i in n:
		var a := rng.randf_range(0.0, TAU)
		var sp := rng.randf_range(40.0, 220.0)
		sparks.append({"p": Vector2(VP_X, BOTTOM - 120.0), "v": Vector2(cos(a), sin(a)) * sp,
			"t": 0.0, "life": rng.randf_range(0.3, 0.7), "c": col})


func _update_sparks(dt: float) -> void:
	var keep := []
	for s in sparks:
		s.t = float(s.t) + dt
		if float(s.t) < float(s.life):
			s.p = (s.p as Vector2) + (s.v as Vector2) * dt
			s.v = (s.v as Vector2) * 0.94
			keep.append(s)
	sparks = keep


# ---------------------------------------------------------------- HUD


func _draw_hud() -> void:
	Neo.text(self, "РАЗОРТРОН 2000", Vector2(960, 96), 56, Neo.TEXT)
	var lead := _lead_dist()
	var me := _best_human()
	Neo.text(self, "до финиша %d м · %.0f км/ч" % [
		maxi(int(race_m - (me.dist if me != null else lead)), 0),
		(me.v if me != null else 0.0) * 3.6], Vector2(960, 146), 24, Neo.DIM)
	# полоса прогресса гонки
	var bar := Rect2(560.0, 172.0, 800.0, 10.0)
	draw_rect(bar, Color(1.0, 1.0, 1.0, 0.10))
	for c in cars:
		var k := clampf(c.dist / race_m, 0.0, 1.0)
		draw_circle(Vector2(bar.position.x + bar.size.x * k, bar.position.y + 5.0),
			6.0 if c.human else 4.0, c.color)
		draw_line(Vector2(bar.position.x + bar.size.x * k, bar.position.y - 1.0),
			Vector2(bar.position.x + bar.size.x * k, bar.position.y + 11.0), c.color, 1.0)
	_draw_board()
	_draw_hints()
	_draw_overlay()


func _draw_board() -> void:
	Neo.box(self, BOARD_RECT, Neo.with_alpha(Neo.LINE, 0.5), 1.5, Color(0.02, 0.0, 0.08, 0.72))
	Neo.text_left(self, "ГОНКА", BOARD_RECT.position + Vector2(16, 30), 20,
		Neo.with_alpha(Neo.DIM, 0.9))
	var order := _places()
	var y := BOARD_RECT.position.y + 44.0
	for c in order:
		var r := Rect2(BOARD_RECT.position.x + 10.0, y, BOARD_RECT.size.x - 20.0, 30.0)
		if c.human:
			draw_rect(r, Neo.with_alpha(c.color, 0.10))
		Neo.text_left(self, "%d" % c.place, r.position + Vector2(8, 21), 18, c.color)
		draw_circle(r.position + Vector2(40, 15), 6.0, c.color)
		Neo.text_left(self, c.title, r.position + Vector2(54, 21), 18,
			Neo.TEXT if c.human else Neo.DIM)
		Neo.text_left(self, "%d м" % int(c.dist), r.position + Vector2(r.size.x - 76, 21), 16,
			Neo.with_alpha(Neo.DIM, 0.9))
		y += 34.0
	if y + 20.0 < BOARD_RECT.end.y:
		Neo.text_left(self, "наклон головы — руль, вперёд — газ", BOARD_RECT.position
			+ Vector2(16, BOARD_RECT.size.y - 12.0), 14, Neo.with_alpha(Neo.DIM, 0.6))


func _draw_hints() -> void:
	var h := "наклон головы влево/вправо — руль · голова вперёд — газ · назад — тормоз"
	if demo:
		h = "стрелки ←/→ — руль · ↑ — газ · ↓ — тормоз · пробел — старт"
	Neo.text(self, h, Vector2(1150, 1032), 22, Neo.DIM)
	Neo.text(self, "1..5 — режим ввода · ESC — меню", Vector2(1150, 1064), 20,
		Neo.with_alpha(Neo.DIM, 0.75))
	InputHint.draw(self, HINT_RECT, _active_src(), Time.get_ticks_msec() * 0.001)


func _draw_overlay() -> void:
	match state:
		St.WAIT:
			Neo.text(self, "ВСТАНЬТЕ ПЕРЕД КАМЕРОЙ", Vector2(960, 600), 44, Neo.TEXT)
			Neo.text(self, "от 1 до 6 игроков · гонка до финиша", Vector2(960, 652), 26, Neo.DIM)
		St.READY:
			var k := ceili(2.6 - state_t)
			Neo.text(self, str(maxi(k, 1)), Vector2(960, 620), 140, Neo.PUCK)
			Neo.text(self, "руки на руле", Vector2(960, 690), 26, Neo.DIM)
		St.RESULT:
			var who := "никто" if winner < 0 else cars[winner].title
			var col: Color = Neo.TEXT if winner < 0 else cars[winner].color
			Neo.text(self, "ФИНИШ · %s" % who, Vector2(960, 600), 60, col)
			var order := _places()
			var line := ""
			for i in mini(order.size(), 6):
				line += "%d) %s  " % [order[i].place, order[i].title]
			Neo.text(self, line, Vector2(960, 660), 24, Neo.DIM)
			Neo.text(self, "возвращаемся в меню…", Vector2(960, 700), 22,
				Neo.with_alpha(Neo.DIM, 0.7))
		St.OVER:
			Neo.text(self, "ещё заезд?", Vector2(960, 620), 40, Neo.OK)
	if frozen and state == St.RUN:
		Neo.text(self, "ПАУЗА: ждём игроков в кадре", Vector2(960, 560), 40, Neo.WARN)
	if debug_ui:
		var y := 900.0
		for c in cars:
			if c.human:
				Neo.text_left(self, "%s ax=%+.2f ay=%+.2f %s v=%.0f" % [
					c.title, c.inp.ax, c.inp.ay, c.inp.mode_label(), c.v],
					Vector2(24, y), 16, Neo.DIM)
				y += 20.0


## Машина первого живого игрока (для подписи скорости).
func _best_human() -> Car:
	for c in cars:
		if c.human:
			return c
	return null


func _active_src() -> String:
	for c in cars:
		if c.human and c.inp.have_input:
			return c.inp.active
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


# ---------------------------------------------------------------- клавиши


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := (event as InputEventKey).keycode
		if event.pressed and not event.echo:
			match k:
				KEY_ESCAPE:
					_load_menu()
				KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
					var idx := k - KEY_1
					if idx < Inp.MODES.size():
						input_mode = Inp.MODES[idx]
						for c in cars:
							c.inp.mode = input_mode
						printerr("RAZOR MODE ", input_mode)
				KEY_SPACE:
					if state == St.READY:
						_set_state(St.RUN)
		if demo:
			match k:
				KEY_LEFT, KEY_A:
					arrows.left = event.pressed
				KEY_RIGHT, KEY_D:
					arrows.right = event.pressed
				KEY_UP, KEY_W:
					arrows.up = event.pressed
				KEY_DOWN, KEY_S:
					arrows.down = event.pressed


## Демо без трекинга: клавиши двигают первую машину.
func _demo_drive() -> void:
	if cars.is_empty():
		return
	var c: Car = cars[0]
	var steer := 0.0
	if arrows.left:
		steer -= 1.0
	if arrows.right:
		steer += 1.0
	if steer == 0.0:
		steer = c.inp.ax
	c.px = clampf(c.px + steer * STEER * get_process_delta_time(),
		-ROAD_HALF + 0.5, ROAD_HALF - 0.5)
	if state != St.RUN or c.finished:
		return
	var target := VMAX
	if arrows.up:
		target = VBOOST
	elif arrows.down:
		target = VBRAKE
	c.v = move_toward(c.v, target, ACCEL * get_process_delta_time())


# ---------------------------------------------------------------- автотест


func _selftest_tick() -> void:
	st_t += get_process_delta_time()
	if selftest != "razor":
		return
	if st_t - st_mark > 30.0:
		printerr("SELFTEST RAZOR FAIL: финиш не наступил за 30 с (лидер %.0f м)" % _lead_dist())
		get_tree().quit(1)
		return
	if st_t - log_t > 2.0:
		log_t = st_t
		printerr("RAZOR RACE state=%d lead=%.0f m cars=%d traffic=%d" % [
			state, _lead_dist(), cars.size(), traffic.size()])
	if state == St.RESULT and st_mark == 0.0:
		st_mark = st_t
		var who := "никто" if winner < 0 else cars[winner].title
		printerr("SELFTEST RAZOR PASS: финиш за %.1f с, победил %s" % [st_t, who])
		get_tree().quit(0)
