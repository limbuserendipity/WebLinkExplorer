class_name NeonSfx
extends RefCounted
## Ретро-синтезатор: прямоугольные волны через AudioStreamGenerator, без ассетов.

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
