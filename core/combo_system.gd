class_name ComboSystem
extends RefCounted
## 连击：窗口期内连续成功分拣累加，超时清零。

var window: float = 3.0
var combo: int = 0
var best: int = 0
var _timer: float = 0.0


func _init(window_sec: float = 3.0) -> void:
	window = window_sec


func register_pick() -> void:
	combo = combo + 1 if _timer > 0.0 and combo > 0 else 1
	_timer = window
	best = maxi(best, combo)


func update(delta: float) -> void:
	if _timer > 0.0:
		_timer = maxf(0.0, _timer - delta)
		if _timer <= 0.0:
			combo = 0


func reset() -> void:
	combo = 0
	_timer = 0.0


func bonus_ratio() -> float:
	return minf(combo * 0.05, 0.5)
