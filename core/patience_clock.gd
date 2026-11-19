class_name PatienceClock
extends RefCounted
## 顾客耐心：由 GameState.update(delta) 驱动，支持冻结与无限模式。

var total: float = 0.0
var left: float = 0.0
var frozen: float = 0.0
var unlimited: bool = false


func _init(seconds: float = 0.0) -> void:
	reset(seconds)


func reset(seconds: float) -> void:
	total = maxf(0.0, seconds)
	left = total
	frozen = 0.0
	unlimited = total <= 0.0


func update(delta: float) -> void:
	if unlimited or left <= 0.0:
		return
	if frozen > 0.0:
		frozen = maxf(0.0, frozen - delta)
		return
	left = maxf(0.0, left - delta)


func freeze(seconds: float) -> void:
	frozen = maxf(frozen, seconds)


func ratio() -> float:
	return 1.0 if unlimited else (left / total if total > 0.0 else 0.0)


func depleted() -> bool:
	return not unlimited and left <= 0.0
