class_name GameRNG
extends RefCounted
## 固定种子随机：同一关卡同一种子生成内容完全一致，支持回放与单测。

var _r := RandomNumberGenerator.new()


func _init(seed_value: int = 0) -> void:
	if seed_value == 0:
		_r.randomize()
	else:
		_r.seed = seed_value


func randi_range(from: int, to: int) -> int:
	return _r.randi_range(from, to)


func randf_range(from: float, to: float) -> float:
	return _r.randf_range(from, to)


func pick(arr: Array):
	return arr[_r.randi_range(0, arr.size() - 1)]


func shuffle(arr: Array) -> void:
	# Fisher-Yates，保证种子确定性（不用全局 shuffle）
	for i in range(arr.size() - 1, 0, -1):
		var j := _r.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
