class_name FaceInput
extends RefCounted
## Ввод одного игрока: лицо/голова/корпус -> две оси в -1..1.
##
## Общая модель для всех игр проекта: аэрохоккей, «Трон», меню. Нейтраль
## снимается во время отсчёта, при смене расстояния до камеры переучивается
## сама (иначе после «отошёл и вернулся» ракетка упирается в стену и не
## дотягивается до другой).

const MODES := ["face", "tilt", "lean"]

const RANGE_FACE_REL := 0.25      # полный ход лица = 25% высоты рамки человека
const RANGE_FACE_MIN_PX := 18.0   # минимальный делитель, px (как в документе v3)
const RANGE_TILT_X := 0.20        # поворот головы (в долях межглазного расстояния)
const RANGE_TILT_Y := 0.22        # наклон головы набок, радианы
const RANGE_LEAN := 0.22          # наклон корпуса в долях роста
const RANGE_PROX := 0.18          # изменение body_height (шаг к камере)
const DEADZONE := 0.10            # мёртвая зона для корпуса/головы
const DEADZONE_FACE := 0.06       # у лица меньше: масштаб уже нормирован по человеку
const INPUT_RATE := 25.0          # базовое сглаживание входа (мелкий шум)
const INPUT_RATE_FAST := 300.0    # добавка за крупное смещение — без лага
const INPUT_FAST_REF := 0.12      # смещение за кадр (доли хода), где добавка максимальна
const HEAD_CONF := 0.35           # ниже — считаем голову ненадёжной
const FEET_CONF := 0.30           # ниже — лодыжки ненадёжны
const POINT_CONF := 0.30          # ниже — точка позы ненадёжна
const RECAL_BOX := 0.15           # рамка изменилась на 15% — нейтраль устарела
const NOSE_GAP := 0.3             # нос пропадал дольше — запоминаем нейтраль заново

var mode := "face"
var gain := 1.0
var flip_x := 1.0
var flip_y := 1.0

var rawx := 0.0                   # что пришло: px носа (face) или доли (tilt/lean)
var rawy := 0.0
var nx := 0.0                     # нейтраль в тех же единицах
var ny := 0.0
var range_x := 1.0                # делитель: ход до края
var range_y := 1.0
var dz := DEADZONE_FACE
var ax := 0.0                     # -1..1 по X (вперёд-назад)
var ay := 0.0                     # -1..1 по Y (вверх-вниз)
var have_input := false
var have_neutral := false
var using_fallback := false       # нет позы — считаем по рамке
var legacy := false               # источник без позы вообще
var conf := 0.0
var nose_gap := 0.0               # сколько секунд нос не определялся
var recal_count := 0              # сколько раз менялось расстояние (для лога/тестов)
var nyr := -1.0                   # нейтраль по высоте относительно рамки человека
var box0 := 0.0                   # высота рамки при калибровке, px
var sumx := 0.0
var sumy := 0.0
var samples := 0


func reset_calibration() -> void:
	sumx = 0.0
	sumy = 0.0
	samples = 0
	have_neutral = false
	have_input = false
	rawx = 0.0
	rawy = 0.0
	nx = 0.0
	ny = 0.0
	ax = 0.0
	ay = 0.0
	range_x = 1.0
	range_y = 1.0
	using_fallback = false
	legacy = false
	nose_gap = 0.0
	recal_count = 0
	nyr = -1.0
	box0 = 0.0
	conf = 0.0


func reset_mode(new_mode: String) -> void:
	if MODES.has(new_mode):
		mode = new_mode
	reset_calibration()


func accumulate() -> void:
	# Копим среднее за отсчёт (вызывать каждый кадр отсчёта).
	if have_input:
		sumx += rawx
		sumy += rawy
		samples += 1


func finish_calibration() -> void:
	if samples <= 0:
		return
	nx = sumx / float(samples)
	ny = sumy / float(samples)
	have_neutral = true
	legacy = using_fallback
	_recompute()


func update(p, dt: float, aspect: float, frame_px: Vector2) -> void:
	match mode:
		"tilt":
			if _tilt(p, aspect, dt, frame_px):
				return
			_face(p, dt, aspect, frame_px)
		"lean":
			_lean(p, aspect, dt, frame_px)
		_:
			_face(p, dt, aspect, frame_px)


func recenter() -> void:
	# Мгновенно привязать нейтраль к текущему положению (клавиша перецентровки).
	if have_input:
		nx = rawx
		ny = rawy
		_recompute()


# ---------------------------------------------------------------- режимы


func _face(p, dt: float, _aspect: float, frame_px: Vector2) -> void:
	# Лицо — курсор. Смещение носа в пикселях делим на высоту рамки человека:
	# у близкого и дальнего игрока чувствительность одинаковая (GodotAR-v3).
	var nose = nose_point(p)
	using_fallback = nose == null
	if nose == null:
		nose_gap += dt
		if have_neutral and not legacy:
			return    # поза была, голова пропала — держим последнее значение
		var rect: Rect2 = p.camera_rect_norm
		if rect.size.y <= 0.01:
			return
		legacy = not have_neutral
		var denom_fb := maxf(rect.size.y * frame_px.y * RANGE_FACE_REL, RANGE_FACE_MIN_PX)
		var c := Vector2((rect.position.x + rect.size.x * 0.5) * frame_px.x,
			(rect.position.y + rect.size.y * 0.5) * frame_px.y)
		_feed(c.x, c.y, denom_fb, denom_fb, p.feet_confidence, dt, DEADZONE_FACE, true)
		return
	var box_h: float = maxf(p.camera_rect_norm.size.y * frame_px.y, 24.0)
	var box_top: float = p.camera_rect_norm.position.y * frame_px.y
	var nose_px := Vector2(nose.x, nose.y) * frame_px
	if have_neutral and box_h > 1.0:
		if nyr < 0.0:
			# Запоминаем нейтраль по высоте ОТНОСИТЕЛЬНО рамки человека:
			# тогда она сама пересчитывается, когда игрок отходит или подходит,
			# и ход по-прежнему достаёт от стены до стены.
			nyr = (ny - box_top) / box_h
			box0 = box_h
		elif absf(box_h / maxf(box0, 1.0) - 1.0) > RECAL_BOX:
			recal_count += 1        # расстояние заметно изменилось (для лога/тестов)
			box0 = box_h
		ny = box_top + nyr * box_h
		if nose_gap > NOSE_GAP:
			# нос возвращался после паузы — берём нейтраль заново
			nx = nose_px.x
			nyr = (nose_px.y - box_top) / box_h
			ny = box_top + nyr * box_h
	else:
		nyr = -1.0
	nose_gap = 0.0
	var denom := maxf(box_h * RANGE_FACE_REL, RANGE_FACE_MIN_PX)
	_feed(nose_px.x, nose_px.y, denom, denom,
		float(p.head.get("conf", p.feet_confidence)), dt, DEADZONE_FACE, true)


func _tilt(p, aspect: float, dt: float, _frame_px: Vector2) -> bool:
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
	using_fallback = false
	_feed(yaw, roll, RANGE_TILT_X, RANGE_TILT_Y, float(nose.z), dt)
	return true


func _lean(p, aspect: float, dt: float, _frame_px: Vector2) -> void:
	# Классический вариант: наклон корпуса относительно лодыжек + шаг к камере.
	var have_feet: bool = p.feet_norm.size() == 2 and p.feet_confidence >= FEET_CONF
	var feet_mid := Vector2.ZERO
	if have_feet:
		feet_mid = (p.feet_norm[0] + p.feet_norm[1]) * 0.5
	var bh: float = p.body_height
	var hp = p.head.get("p")
	var head_ok: bool = hp is Vector2 and bh > 0.01 and have_feet \
		and float(p.head.get("conf", 0.0)) >= HEAD_CONF
	using_fallback = not head_ok
	var lean := 0.0
	if head_ok:
		legacy = false
		lean = (hp.x - feet_mid.x) * aspect / bh
	else:
		if have_neutral and not legacy:
			return
		var rect: Rect2 = p.camera_rect_norm
		if rect.size.y <= 0.01:
			return
		legacy = not have_neutral
		bh = rect.size.y
		lean = (rect.position.x + rect.size.x * 0.5) * aspect / bh
	var bh_neutral: float = nx if have_neutral and nx > 0.01 else bh
	_feed(bh, lean, RANGE_PROX * bh_neutral, RANGE_LEAN, p.feet_confidence, dt)


# ---------------------------------------------------------------- внутри


func _feed(rx: float, ry: float, rgx: float, rgy: float, conf_v: float, dt: float,
		dz_v := DEADZONE, reactive := false) -> void:
	# reactive: фильтр «один евро» — мелкий шум гасим, крупное движение
	# пропускаем сразу, иначе сглаживание добавляет десятки миллисекунд лага.
	var k := 1.0 - exp(-INPUT_RATE * dt)
	if reactive:
		var d := maxf(absf(rx - rawx), absf(ry - rawy)) / maxf(rgx, 0.0001)
		k = 1.0 - exp(-(INPUT_RATE + INPUT_RATE_FAST * clampf(d / INPUT_FAST_REF, 0.0, 1.0)) * dt)
	if have_input:
		rawx = lerpf(rawx, rx, k)
		rawy = lerpf(rawy, ry, k)
	else:
		rawx = rx
		rawy = ry
		have_input = true
	range_x = maxf(rgx, 0.0001)
	range_y = maxf(rgy, 0.0001)
	dz = dz_v
	conf = conf_v
	_recompute()


func _recompute() -> void:
	if not have_neutral:
		ax = 0.0
		ay = 0.0
		return
	var rgx := maxf(range_x, 0.0001)
	var rgy := maxf(range_y, 0.0001)
	ax = clampf(_dz(clampf((rawx - nx) / rgx, -1.0, 1.0), dz) * gain * flip_x, -1.0, 1.0)
	ay = clampf(_dz(clampf((rawy - ny) / rgy, -1.0, 1.0), dz) * gain * flip_y, -1.0, 1.0)


static func _dz(v: float, dead: float) -> float:
	return signf(v) * maxf(absf(v) - dead, 0.0) / (1.0 - dead)


static func nose_point(p):
	# Нос из 17 точек позы, иначе середина глаз/носа из поля head.
	var kp: Array = p.keypoints
	if kp.size() > 0 and kp[0] != null and kp[0].z >= POINT_CONF:
		return Vector2(kp[0].x, kp[0].y)
	var hp = p.head.get("p")
	if hp is Vector2 and float(p.head.get("conf", 0.0)) >= HEAD_CONF:
		return hp
	return null


static func nose_screen(p, frame_px: Vector2) -> Vector2:
	# Абсолютное положение носа в долях кадра — курсор для меню.
	var nose = nose_point(p)
	if nose == null:
		var rect: Rect2 = p.camera_rect_norm
		if rect.size.y <= 0.01:
			return Vector2(0.5, 0.5)
		return rect.position + rect.size * 0.5
	return Vector2(nose.x, nose.y)
