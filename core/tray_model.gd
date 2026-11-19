class_name TrayModel
extends RefCounted
## 称重台模型：按 size 占格；只允许同款手动结算，台上物品可逐件退回。

var slots: int = 7
var entries: Array = []  # 与 basket item 同结构引用


func _init(slot_count: int = 7) -> void:
	slots = slot_count


func used_slots() -> int:
	var n := 0
	for e in entries:
		n += int(e["size"])
	return n


func free_slots() -> int:
	return slots - used_slots()


func can_fit(size: int) -> bool:
	return free_slots() >= size


func add(item: Dictionary) -> void:
	entries.append(item)


func contains(uid: int) -> bool:
	for e in entries:
		if int(e["uid"]) == uid:
			return true
	return false


func remove_uid(uid: int) -> Dictionary:
	for e in entries:
		if int(e["uid"]) == uid:
			entries.erase(e)
			return e
	return {}


func clear() -> void:
	entries.clear()


func count_snack(snack_id: String) -> int:
	var n := 0
	for e in entries:
		if e["snack"] == snack_id:
			n += 1
	return n


func unique_snacks() -> Array:
	var result: Array = []
	for e in entries:
		if not result.has(e["snack"]):
			result.append(e["snack"])
	return result


func is_uniform() -> bool:
	return unique_snacks().size() <= 1


func is_empty() -> bool:
	return entries.is_empty()
