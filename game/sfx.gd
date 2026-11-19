extends Node
## 音效池（autoload: SFX）。连击用五声音阶升调，解压核心反馈。

const SOUNDS := {
	"pick": "res://assets/sfx/pick.wav",
	"beep": "res://assets/sfx/beep.wav",
	"print": "res://assets/sfx/print.wav",
	"bag": "res://assets/sfx/bag.wav",
	"ding": "res://assets/sfx/ding.wav",
	"coins": "res://assets/sfx/coins.wav",
	"combo": "res://assets/sfx/combo.wav",
	"complete": "res://assets/sfx/complete.wav",
	"fail": "res://assets/sfx/fail.wav",
	"magnet": "res://assets/sfx/magnet.wav",
}
const SCALE_PENTA := [1.0, 1.125, 1.25, 1.5, 1.667, 2.0, 2.25, 2.5, 3.0, 3.333, 4.0, 4.5]

var enabled: bool = true
var _players: Array[AudioStreamPlayer] = []
var _streams := {}


func _ready() -> void:
	for i in 10:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	for key in SOUNDS:
		if ResourceLoader.exists(SOUNDS[key]):
			_streams[key] = load(SOUNDS[key])


func play(key: String, pitch: float = 1.0) -> void:
	if not enabled or not _streams.has(key):
		return
	for p in _players:
		if not p.playing:
			p.stream = _streams[key]
			p.pitch_scale = pitch
			p.play()
			return


func play_combo(combo: int) -> void:
	var idx := clampi(combo - 1, 0, SCALE_PENTA.size() - 1)
	play("combo", SCALE_PENTA[idx])
