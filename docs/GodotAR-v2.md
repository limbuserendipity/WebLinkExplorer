# Godot AR API v2

Интерфейс для **motion-based игр** в Godot 4.5.1. Игра получает список людей в кадре, события движения и, при необходимости, видео. Камеру открывает система трекинга. Приложение игры работает отдельным процессом.

Для работы понадобятся этот документ и Godot 4.5.1. Для проверки с имитацией движений понадобится также Python 3.10 или новее. Передайте разработчику отдельное описание правил вашей игры и список нужных входных данных. Документ задаёт способ подключения и критерии технической проверки.

## 1. Выберите данные для вашей игры

| Задача | Ввод |
|---|---|
| Прыжок или наклон управляет персонажем | Сигнал `gesture` |
| Нужно знать, сколько людей видит камера | Метод `players()` |
| Нужно показать рамки людей поверх превью | `camera_texture` и `camera_rect_norm` |
| Стопы управляют объектами на размеченном полу | `feet_norm`, уверенность и отдельная калибровка площадки |
| Нужно рисовать элементы за людьми или скрывать их | Профиль `arena`, маска силуэтов и восстановленный фон |

Встроенные жесты — `jump` (прыжок), `lean_left` (наклон влево) и `lean_right` (наклон вправо). Направление задано относительно полученного изображения. Для отдельных пальцев, глубины в метрах, предметов и геометрии комнаты потребуется расширение интерфейса. Версия манифеста остаётся `api: 1`.

## 2. Публичный интерфейс GDScript

Узел `/root/GameDirector` регистрируется как autoload. Обновляйте игровое состояние в своём `_process()`, подписывайтесь на сигнал один раз в `_ready()`.

| API | Что возвращает или делает |
|---|---|
| `players() -> Array` | Подтверждённые игроки с возрастом измерения меньше 0,5 с (15 условных тиков). При пустом кадре или устаревании возвращает пустой массив. |
| `all_players() -> Array` | Последний полученный список слотов, включая удерживаемые и устаревшие. Проверяйте возраст каждого измерения. |
| `tentative_players() -> Array` | Неподтверждённые треки без игрового слота. Каждый элемент — словарь с `track_id`, `state = "tentative"`, `sample_id` и `camera_rect_norm`. |
| `gesture(slot: int, action: String, confidence: float)` | Событие начала жеста. Уверенность от 0 до 1. Игра выбирает порог. |
| `gesture_phase(slot: int, track_id: int, action: String, phase: String, confidence: float, at: float, duration: float)` | Фазы `start`, `hold`, `end`. Удержание сообщается примерно раз в 0,1 с при свежих измерениях. `at` — время источника, `duration` — секунды от начала жеста. Уверенность фаз относится к измерению, запустившему жест. Для прекращения удержания по тайм-ауту проверяйте свежесть трека. При подписке на оба сигнала начало придёт в обоих. |
| `frame_age() -> float` | Возраст последнего видео в секундах. До первого кадра возвращает `INF`. |
| `tracking_age() -> float` | Возраст данных трекинга в секундах. До первого пакета возвращает `INF`. |
| `rotation_checkpoint() -> void` | Разрешает закрыть игру, если таймер автосмены уже истёк. Вызывайте в ожидании и между раундами. Если автосмена выключена, вызов ничего не меняет. |
| `tracking_stats() -> Dictionary` | `samples`, `latency_ms` и `jitter_ms` с p50/p95 по последним 180 измерениям. Задержка оценена до отправки пакета. Джиттер — абсолютное расхождение интервалов захвата и приёма. До накопления данных словари пусты. |

`capabilities` перечисляет возможности потока: `pose`, `track_state`, `gesture_phases`, `video`, `seg`. Наличие возможности не означает, что конкретное измерение пригодно. `frame_size: Vector2i` содержит исходные ширину и высоту кадра, в том числе в режиме без видео. `capture_time` и `tracking_time` — монотонные секунды источника. Используйте их для интервалов внутри потока. Для времени в процессе Godot используйте `measured_at` и функции возраста.

### Данные одного человека

| Поле | Тип | Значение |
|---|---|---|
| `slot` | `int` | Номер 0–11, пригоден для цвета и интерфейса. Может перейти другому участнику. |
| `track_id` | `int` | Временный идентификатор человека. Для счёта и голосов проверяйте пару `slot, track_id`. |
| `color` | `Color` | Цвет участника. |
| `camera_rect_norm` | `Rect2` | Рамка в координатах изображения от 0 до 1, начало в левом верхнем углу. Может быть пустой. |
| `feet_norm` | `Array` | Две точки лодыжек `Vector2` в тех же координатах или пустой массив. Это 2D-точки. Для метров нужна привязка плоскости пола. |
| `feet_confidence` | `float` | Уверенность пары лодыжек от 0 до 1. |
| `sample_id` | `int` | Номер измерения игрока. Для фильтра и оценки скорости используйте каждое значение один раз. |
| `measured_at` | `float` | Приблизительное время измерения на монотонных часах Godot в секундах. |
| `age_ticks` | `int` | Текущий возраст измерения в единицах 1/30 с. Это единица времени, частота потока может отличаться. |
| `mask_slot` | `int` | Индекс силуэта для измерения игрока. 0 означает отсутствие силуэта. |
| `head` | `Dictionary` | `p: Vector2` и `conf: float`. Точка вычисляется по глазам или носу. При отсутствии уверенной точки словарь пуст. |
| `body_height` | `float` | Вертикальное расстояние от головы до средней точки лодыжек в долях высоты исходного кадра. 0 при отсутствии надёжного измерения. |
| `shoulders`, `hips`, `wrists`, `ankles` | `Array` | Пары точек, левая и правая стороны тела участника. Каждая точка — `Vector3(x, y, confidence)` или `null`. Старый пакет может дать пустой массив. |
| `keypoints` | `Array` | 17 точек COCO в порядке: нос, глаза Л/П, уши Л/П, плечи Л/П, локти Л/П, запястья Л/П, бёдра Л/П, колени Л/П, лодыжки Л/П. Формат как у пар. |
| `state`, `lost_since` | `String`, `float` | `confirmed` или `lost`. При временной потере сохраняется последнее измерение, а `lost_since` указывает время первого пропуска по часам источника. Значение −1 означает, что потеря не зафиксирована. При остановке самого потока используйте возраст. |
| `reacquired`, `reacquired_sample_id` | `bool`, `int` | Возврат того же трека до освобождения слота. Обрабатывайте один раз по номеру измерения возврата. При смене `track_id` участник для игры новый. |

Подтверждение игрока требует трёх последовательных измерений. Слот освобождается примерно через 0,5 с в `preview` и через 2 с в `arena`. При исчезновении входа приостановите зачёт спорных действий. Для видео, позы и истории игрока проверяйте свежесть отдельно.

**Пример управления наклоном.** Для бокового наклона вычтите X средней точки лодыжек из X головы. Чтобы измерить наклон в долях роста, умножьте разницу на отношение ширины кадра к высоте и разделите на `body_height`. При первом устойчивом измерении запомните нейтральное значение и затем вычитайте его. Отношение текущего `body_height` к нейтральному может служить грубой оценкой шага ближе или дальше. Приседание тоже меняет эту величину. Деление `feet_mid.y - head.y` на текущий `body_height` всегда даёт 1, поэтому использовать его как вторую ось нельзя.

### Видео и композиция

- `camera_texture: ImageTexture` — изображение с камеры, до 640 px по ширине и до 10 обновлений в секунду в `preview`. В `arena` ширина до 1280 px и до 20 обновлений в секунду. Блок изображений свыше 384 КиБ пропускается, точки всё равно отправляются. В `points` видео не кодируется. Видео и состояние в профилях с видео идут по одному TCP-соединению.
- `person_labels: ImageTexture` и `clean_room_texture: ImageTexture` — индексная маска и приближённый восстановленный фон в профиле `arena`. При отсутствии масок обе текстуры могут быть `null`.
- `image_owners: Dictionary` связывает индекс маски с `track_id` конкретного видеокадра. `image_mask_slots: Array` содержит целые индексы силуэтов в этом кадре. `image_frame_id: int` идентифицирует набор изображений `arena`. Для сопоставления маски с человеком пользуйтесь этой картой: последнее измерение позы может быть новее кадра.
- Сэмплируйте маску с `filter_nearest`. Индекс равен `round(red * 255.0)`, значение 0 соответствует фону. Нормализованные координаты относятся к изображению. Если оставляете поля по краям телевизора, рассчитывайте их относительно прямоугольника видео.
- Перед использованием текстур проверьте наличие и `frame_age()`. При потере силуэта оставьте нейтральный экран или отложите решение раунда.

## 3. Соберите проверочный проект

Создайте папку с такой структурой: `project.godot`, `godotar.json`, `game/Main.tscn`, `game/Main.gd` и папкой `shared/` с двумя скриптами из раздела 6.

### `project.godot`

```ini
config_version=5

[application]
config/name="Motion Demo"
run/main_scene="res://game/Main.tscn"
config/features=PackedStringArray("4.5", "GL Compatibility")

[autoload]
GameDirector="*res://shared/GameDirector.gd"

[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/stretch/mode="canvas_items"
window/stretch/aspect="keep"

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
```

### `godotar.json`

```json
{
  "api": 1,
  "id": "motion_demo",
  "name": "Проверка движения",
  "scene": "res://game/Main.tscn",
  "tracking": "preview"
}
```

Ключ `api` задаёт версию манифеста. `id` должен быть уникальным и начинаться с латинской строчной буквы. Остальные символы — строчные латинские буквы, цифры и подчёркивания, общая длина до 48. `name` — уникальное название до 80 символов. `scene` — путь к существующей сцене внутри проекта. Для `tracking` выберите `points` для позы и жестов без видео, `preview` для маленькой картинки камеры или `arena` для полноэкранного AR. По умолчанию используется `preview`.

### `game/Main.tscn`

```ini
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://game/Main.gd" id="1"]

[node name="Main" type="Label"]
offset_left = 40.0
offset_top = 36.0
theme_override_font_sizes/font_size = 36
script = ExtResource("1")
```

### `game/Main.gd`

```gdscript
extends Label

@onready var bridge := get_node("/root/GameDirector")
var jumps := 0

func _ready() -> void:
	bridge.gesture.connect(_on_gesture)

func _process(_delta: float) -> void:
	if bridge.tracking_age() > 0.5 or bridge.players().is_empty():
		text = "Встаньте перед камерой"
		bridge.rotation_checkpoint()
	else:
		text = "Прыгните! Счёт: %d" % jumps

func _on_gesture(slot: int, action: String, confidence: float) -> void:
	if action != "jump" or confidence < 0.75 or bridge.tracking_age() > 0.5:
		return
	for player in bridge.players():
		if player.slot == slot:
			jumps += 1
			return
```

## 4. Передайте проект для подключения

Передайте папку Godot с манифестом, сценами и ресурсами. Если используются импортируемые изображения, модели или звук, выполните импорт ресурсов в Godot 4.5.1 перед передачей. Оператор выбирает **Tab → Игры → Добавить игру → godotar.json**. Затем нажимает название в списке. Хаб сохраняет ссылку на папку, поэтому держите проект по постоянному пути. После переноса папку можно зарегистрировать снова.

Системные клавиши адаптера: **Tab** возвращает в меню, **Esc** закрывает игру, **N** переключает тему, **Shift+Esc** завершает хаб. Оставьте эти клавиши доступными оператору. При закрытии TCP-соединения адаптер завершает игру.

## 5. Проверьте движение без камеры

Откройте проект обычным запуском Godot и убедитесь, что отображается «Встаньте перед камерой». Для имитации трекинга запустите следующий скрипт Python. Он напечатает команду запуска для выбранного порта. Выполните её во втором терминале из корня проверочного проекта. Счётчик на экране должен расти примерно раз в секунду.

```python
import json
import socket
import struct
import time

with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    print(f"godot --path . -- --port={port}", flush=True)
    connection, _ = server.accept()
    with connection:
        n = 0
        try:
            while True:
                events = []
                if n % 30 == 15:
                    events = [{"id": n, "slot": 0, "track_id": 42,
                               "action": "jump", "confidence": 0.95}]
                packet = {
                    "frame_id": n,
                    "tracking_age": 0.0,
                    "frame_age": None,
                    "players": [{"slot": 0, "track_id": 42, "age_ticks": 0,
                                 "color": [0.1, 0.8, 1.0], "rect": [0.3, 0.2, 0.4, 0.7],
                                 "feet": [[0.4, 0.86], [0.55, 0.86]],
                                 "feet_confidence": 0.92, "mask_slot": 0, "sample_id": n}],
                    "gestures": events,
                }
                body = json.dumps(packet).encode("utf-8")
                connection.sendall(struct.pack("!II", len(body), 0) + body)
                n += 1
                time.sleep(1 / 30)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
```

Замените `godot` в напечатанной команде на путь к Godot 4.5.1, если он отсутствует в PATH. Для собственного теста меняйте список игроков, типы жестов и значения уверенности. В примере видео отсутствует. Игры с `arena` проверяйте также с тестовыми кадрами и масками. Проверьте вход и уход человека, потерю сигнала посреди раунда и повторное назначение слота.

### Критерии готовности проекта

| Проверка | Ожидаемый результат |
|---|---|
| Обычный запуск игры без источника трекинга | Сцена открывается без ошибок Godot и показывает состояние ожидания игрока. |
| Запуск с тестовым источником | Игра переходит из ожидания в игровой режим. В проверочной сцене первый прыжок увеличивает счёт ровно на один. Для вашей игры доведите тест до результата первого раунда. |
| Жест с уверенностью ниже порога игры | Счёт и состояние действия остаются прежними. Для примера из этого документа подайте `confidence: 0.5`. |
| Пустой массив `players` при работающем соединении | Игра обрабатывает уход человека без ошибки. Если прекратить отправлять пакеты, игра замечает устаревание данных. Если закрыть соединение, окно завершается. |
| Один и тот же `slot` с новым `track_id` | Новый участник получает собственное игровое состояние. |
| Игра использует профиль `arena` | На подготовленных кадрах подтверждены вывод камеры, чтение индексов масок и корректное поведение при пропаже одной из текстур. |
| Проект перенесён в пустую папку с другим путём | Сцена открывается в Godot. Пути к ресурсам используют `res://`. Манифест указывает на существующую сцену, оба файла адаптера лежат в `shared/`. |

При передаче приложите список выполненных проверок с результатами и короткую инструкцию запуска. Для приёмки подключите полученную папку через «Добавить игру», дождитесь первого результата с живой камерой и проверьте возврат в меню по Tab. Так проверяются также то, что зависит от установки: ракурс, свет, точность распознавания, калибровка и скорость вывода на телевизор.

### Формат потока для собственного источника

Система трекинга слушает `127.0.0.1`, игре передаётся аргумент `--port=ЧИСЛО` после разделителя Godot `--`. Игра подключается как TCP-клиент. Для каждого сообщения идут два беззнаковых 32-битных целых в сетевом порядке: размер JSON в байтах и общий размер изображений. Затем идут UTF-8 JSON и изображения. Границы чтения TCP могут не совпадать с границами сообщений. Максимумы адаптера: 128 КиБ для JSON и 4 МиБ для изображений.

Поля JSON показаны в примере. Поля v2 добавляются поверх них. В JSON `head.p` — массив `[x, y]`, точки COCO — массивы `[x, y, conf]` или `null`. `frame_size` — `[ширина, высота]`. `gestures` содержит события начала для совместимости. `gesture_phases` содержит только `hold` и `end`. У обоих списков общее возрастающее пространство `id`. Элементы содержат `id`, `slot`, `track_id`, `action`, `phase`, `confidence`, `at`, `duration`. Отсутствие новой информации о точке передавайте как `null`, отсутствие пары лодыжек — как пустой `feet`.

Для `preview` блок изображений содержит один JPEG. Для `arena` блок содержит последовательно JPEG камеры, PNG индексной маски и JPEG фона. Размеры частей задаёт `image_parts`, индексы присутствующих силуэтов задаёт `mask_slots`. Без нового изображения длина блока ноль, `frame_age` равен `null`. С адаптером ниже игре достаточно публичного API из раздела 2.

### Записи для разработчика

Если вы получили `packets.jsonl`, каждая строка содержит `offset` в секундах от начала записи, `packet` с исходными полями и `images` с относительным именем файла изображений либо `null`. Для воспроизведения используйте те же интервалы и заголовок TCP. При отсутствии файла изображений отправьте нулевую длину, `frame_age: null` и опустите `image_parts`/ `mask_slots`.

Владелец зеркала может включить запись переменной окружения `GODOT_AR_RECORD` с путём к папке. Запись по умолчанию содержит данные позы. Если нужны кадры, дополнительно задайте `GODOT_AR_RECORD_IMAGES=1`. Для разработки достаточно передать запись и файлы кадров, если они используются. В комплекте хаба также есть `tracker_replay.py` для воспроизведения записи или генерации игроков с заданными ростом, расстоянием и шумом. Формат проверяется схемой `tracker_packet.schema.json`. Раздел 5 позволяет начать тест без этих дополнительных файлов.

## 6. Готовые файлы адаптера Godot

Сохраните скрипты ниже в указанных путях. Они обслуживают подключение, декодирование, привязку данных к слотам и операторские клавиши. Для своей игры изменяйте игровой скрипт и сцены.

### `shared/VirtualPlayer.gd`

```gdscript
extends RefCounted

var slot: int
var track_id: int
var color: Color
var camera_rect_norm: Rect2
var measured_at: float
var feet_norm: Array = []
var feet_confidence: float = 0.0
var mask_slot: int = 0
var sample_id: int = -1
var head: Dictionary = {}
var body_height: float = 0.0
var keypoints: Array = []
var shoulders: Array = []
var hips: Array = []
var wrists: Array = []
var ankles: Array = []
var state: String = "confirmed"
var lost_since: float = -1.0
var reacquired: bool = false
var reacquired_sample_id: int = -1

var age_ticks: int:
	get:
		return maxi(0, floori((Time.get_ticks_usec() * 0.000001 - measured_at) * 30.0))
```

### `shared/GameDirector.gd`

```gdscript
extends Node

signal gesture(slot: int, action: String, confidence: float)
signal gesture_phase(slot: int, track_id: int, action: String, phase: String, confidence: float, at: float, duration: float)
const Player = preload("res://shared/VirtualPlayer.gd")
const MAX_JSON := 131072
const MAX_JPEG := 4194304
var camera_texture: ImageTexture
var person_labels: ImageTexture
var clean_room_texture: ImageTexture
var image_owners: Dictionary = {}
var image_mask_slots: Array = []
var image_frame_id := -1
var capabilities: Array = []
var capture_time: float = -1.0
var tracking_time: float = -1.0
var frame_size := Vector2i.ZERO
var _tentative_players: Array = []
var _latencies: Array[float] = []
var _jitters: Array[float] = []
var _last_received := -1.0
var _peer := StreamPeerTCP.new()
var _connected := false
var _port := 0
var _buffer := PackedByteArray()
var _players: Array = []
var _tracking_time := -INF
var _frame_time := -INF
var _last_event := -1
var _rotation_seconds := 0.0
var _started_at := 0.0

func _ready() -> void:
	process_priority = -100
	_started_at = Time.get_ticks_msec() * 0.001
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			_port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--rotation-seconds="):
			_rotation_seconds = float(arg.trim_prefix("--rotation-seconds="))
	if _port > 0:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		if DisplayServer.get_name() != "headless":
			get_window().borderless = true
		if _peer.connect_to_host("127.0.0.1", _port) != OK:
			get_tree().quit(2)

func frame_age() -> float:
	return Time.get_ticks_usec() * 0.000001 - _frame_time

func tracking_age() -> float:
	return Time.get_ticks_usec() * 0.000001 - _tracking_time

func players() -> Array:
	return _players.filter(func(p): return p.age_ticks < 15)

func all_players() -> Array:
	return _players.duplicate()

func tentative_players() -> Array:
	return _tentative_players.duplicate(true)

func tracking_stats() -> Dictionary:
	return {"samples": _latencies.size(), "latency_ms": _percentiles(_latencies),
		"jitter_ms": _percentiles(_jitters)}

func _percentiles(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted := values.duplicate()
	sorted.sort()
	return {"p50": sorted[ceili(sorted.size() * 0.50) - 1],
		"p95": sorted[ceili(sorted.size() * 0.95) - 1]}

func rotation_checkpoint() -> void:
	if _rotation_seconds > 0.0 and Time.get_ticks_msec() * 0.001 - _started_at >= _rotation_seconds:
		get_tree().quit(10)

func _u32(offset: int) -> int:
	return (_buffer[offset] << 24) | (_buffer[offset+1] << 16) | (_buffer[offset+2] << 8) | _buffer[offset+3]

func _process(_delta: float) -> void:
	if _port == 0:
		return
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_connected = true
		StreamPeerTCP.STATUS_CONNECTING:
			return
		_:
			get_tree().quit(0 if _connected else 2)
			return
	var size := mini(_peer.get_available_bytes(), MAX_JSON + MAX_JPEG + 8)
	if size > 0:
		var read := _peer.get_partial_data(size)
		if read[0] != OK:
			get_tree().quit(2)
			return
		_buffer.append_array(read[1])
	var offset := 0
	var jpeg := PackedByteArray()
	var jpeg_time := -INF
	var parts: Array = []
	var jpeg_info := {}
	while _buffer.size() - offset >= 8:
		var n := _u32(offset)
		var m := _u32(offset+4)
		if n <= 0 or n > MAX_JSON or m > MAX_JPEG:
			get_tree().quit(2)
			return
		if _buffer.size() - offset < 8+n+m:
			break
		offset += 8
		var info = JSON.parse_string(_buffer.slice(offset, offset+n).get_string_from_utf8())
		offset += n
		if info is Dictionary:
			var now := Time.get_ticks_usec() * 0.000001
			_accept(info, now)
			if m > 0 and info.get("frame_age") != null:
				jpeg = _buffer.slice(offset, offset+m)
				jpeg_time = now - float(info.frame_age)
				parts = info.get("image_parts", [])
				jpeg_info = info
		offset += m
	if offset > 0:
		_buffer = _buffer.slice(offset)
	if not jpeg.is_empty():
		var camera_bytes := jpeg
		if parts.size() == 3:
			var a := int(parts[0])
			var b := int(parts[1])
			var c := int(parts[2])
			if a <= 0 or b < 0 or c < 0 or a + b + c != jpeg.size():
				return
			camera_bytes = jpeg.slice(0, a)
			var labels := Image.new()
			var room := Image.new()
			if b > 0 and c > 0 and labels.load_png_from_buffer(jpeg.slice(a, a+b)) == OK and room.load_jpg_from_buffer(jpeg.slice(a+b)) == OK:
				person_labels = _update_texture(person_labels, labels)
				clean_room_texture = _update_texture(clean_room_texture, room)
			else:
				person_labels = null
				clean_room_texture = null
			image_owners.clear()
			# JSON numbers arrive as floats, but gameplay checks integer mask IDs.
			# Normalize here; Array.has() uses strict Variant type equality.
			image_mask_slots.clear()
			for mask in jpeg_info.get("mask_slots", []):
				image_mask_slots.append(int(mask))
			for row in jpeg_info.get("players", []):
				if int(row.get("mask_slot", 0)) > 0:
					image_owners[int(row.mask_slot)] = int(row.track_id)
			image_frame_id = int(jpeg_info.get("frame_id", -1))
		var image := Image.new()
		if image.load_jpg_from_buffer(camera_bytes) == OK:
			camera_texture = _update_texture(camera_texture, image)
			_frame_time = jpeg_time

func _update_texture(texture: ImageTexture, image: Image) -> ImageTexture:
	if texture and texture.get_size() == Vector2(image.get_size()) and texture.get_format() == image.get_format():
		texture.update(image)
		return texture
	return ImageTexture.create_from_image(image)

func _accept(info: Dictionary, now: float) -> void:
	_tracking_time = now - float(info.tracking_age)
	capabilities = info.get("capabilities", [])
	_tentative_players.clear()
	for row in info.get("tentative_players", []):
		var r: Array = row.get("rect", [])
		_tentative_players.append({"track_id": int(row.track_id), "state": "tentative",
			"sample_id": int(row.sample_id),
			"camera_rect_norm": Rect2(r[0], r[1], r[2], r[3]) if r.size() == 4 else Rect2()})
	var size_px = info.get("frame_size")
	if size_px is Array and size_px.size() == 2:
		frame_size = Vector2i(int(size_px[0]), int(size_px[1]))
	if info.get("capture_time") != null:
		capture_time = float(info.capture_time)
	if info.get("tracking_time") != null:
		var sample_time := float(info.tracking_time)
		if sample_time != tracking_time:
			_latencies.append(float(info.tracking_age) * 1000.0)
			if tracking_time >= 0 and sample_time > tracking_time and _last_received >= 0:
				_jitters.append(absf((now - _last_received) - (sample_time - tracking_time)) * 1000.0)
			if _latencies.size() > 180:
				_latencies.pop_front()
			if _jitters.size() > 180:
				_jitters.pop_front()
			tracking_time = sample_time
			_last_received = now
	var owners := {}
	_players.clear()
	for row in info.players:
		var p := Player.new()
		p.slot = int(row.slot)
		p.track_id = int(row.track_id)
		p.measured_at = now - float(row.age_ticks) / 30.0
		p.color = Color(row.color[0], row.color[1], row.color[2])
		var box = row.get("rect")
		if box is Array and box.size() == 4:
			p.camera_rect_norm = Rect2(box[0], box[1], box[2], box[3])
		var feet = row.get("feet", [])
		if feet is Array and feet.size() == 2:
			p.feet_norm = [Vector2(feet[0][0], feet[0][1]), Vector2(feet[1][0], feet[1][1])]
		p.feet_confidence = float(row.get("feet_confidence", 0.0))
		p.mask_slot = int(row.get("mask_slot", 0))
		p.sample_id = int(row.get("sample_id", -1))
		var head = row.get("head")
		if head is Dictionary and head.get("p") is Array and head.p.size() == 2:
			p.head = {"p": Vector2(head.p[0], head.p[1]), "conf": float(head.conf)}
		if row.get("body_height") != null:
			p.body_height = float(row.body_height)
		p.keypoints = _pose_points(row.get("keypoints", []))
		p.shoulders = _pose_points(row.get("shoulders", []))
		p.hips = _pose_points(row.get("hips", []))
		p.wrists = _pose_points(row.get("wrists", []))
		p.ankles = _pose_points(row.get("ankles", []))
		p.state = str(row.get("state", "confirmed"))
		if row.get("lost_since") != null:
			p.lost_since = float(row.lost_since)
		p.reacquired = bool(row.get("reacquired", false))
		p.reacquired_sample_id = int(row.get("reacquired_sample_id", -1))
		_players.append(p)
		owners[p.slot] = p.track_id
	var events: Array = info.get("gestures", []) + info.get("gesture_phases", [])
	events.sort_custom(func(a, b): return int(a.id) < int(b.id))
	for event in events:
		var event_id := int(event.id)
		if event_id <= _last_event:
			continue
		_last_event = event_id
		var phase := str(event.get("phase", "start"))
		var matches: bool = owners.get(int(event.slot)) == int(event.track_id)
		if phase == "end" or (tracking_age() < 0.4 and matches):
			if phase == "start":
				gesture.emit(int(event.slot), str(event.action), float(event.confidence))
			gesture_phase.emit(int(event.slot), int(event.track_id), str(event.action), phase,
				float(event.confidence), float(event.get("at", -1.0)), float(event.get("duration", 0.0)))

func _pose_points(points: Array) -> Array:
	var result := []
	for point in points:
		result.append(Vector3(point[0], point[1], point[2]) if point is Array and point.size() == 3 else null)
	return result

# Клавиши оператора закрывают отдельное окно и возвращают управление зеркалу.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				get_tree().quit(11)
			KEY_N:
				get_tree().quit(10)
			KEY_ESCAPE:
				get_tree().quit(12 if event.shift_pressed else 0)
```
