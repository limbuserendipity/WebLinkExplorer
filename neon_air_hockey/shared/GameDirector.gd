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
