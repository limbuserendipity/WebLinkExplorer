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
