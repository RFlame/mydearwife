class_name ZoneModel
extends RefCounted
## 四角集货区：保存区内物品、完整性判定与自动称重队列。
## 坐标和动画均由表现层负责；已排队的区域不可再退货，避免并发批次争抢物品。

const ZONE_COUNT := 4

var sections: Array = [[], [], [], []]
var queue: Array = []
var active_zone := -1


func add_item(zone_index: int, item: Dictionary) -> void:
	sections[zone_index].append(item)


func remove_uid(uid: int) -> Dictionary:
	var zone_index := zone_for_uid(uid)
	if zone_index < 0:
		return {}
	for item in sections[zone_index]:
		if int(item["uid"]) == uid:
			sections[zone_index].erase(item)
			return item
	return {}


func zone_for_uid(uid: int) -> int:
	for zone_index in ZONE_COUNT:
		for item in sections[zone_index]:
			if int(item["uid"]) == uid:
				return zone_index
	return -1


func is_locked(zone_index: int) -> bool:
	return active_zone == zone_index or queue.has(zone_index)


## 整个区域必须是同款，且当前顾客该款式全部位于这一区。
## 同款散落在桌面、其他区或称重台时都不算集齐。
func complete_snack(zone_index: int, basket: BasketModel) -> String:
	if zone_index < 0 or zone_index >= ZONE_COUNT or sections[zone_index].is_empty():
		return ""
	var snack_id := String(sections[zone_index][0]["snack"])
	for item in sections[zone_index]:
		if String(item["snack"]) != snack_id:
			return ""
	for item in basket.items:
		if String(item["snack"]) != snack_id:
			continue
		if not item.get("picked", false) or zone_for_uid(int(item["uid"])) != zone_index:
			return ""
	return snack_id


## 返回本轮新入队区域；调用方可据此发出锁定与演出信号。
func refresh_queue(basket: BasketModel) -> Array:
	var added: Array = []
	for zone_index in ZONE_COUNT:
		if is_locked(zone_index):
			continue
		if not complete_snack(zone_index, basket).is_empty():
			queue.append(zone_index)
			added.append(zone_index)
	return added


func take_next_batch() -> Dictionary:
	if active_zone >= 0 or queue.is_empty():
		return {}
	active_zone = int(queue.pop_front())
	var items: Array = sections[active_zone].duplicate()
	sections[active_zone].clear()
	return {"zone": active_zone, "items": items}


func finish_batch() -> void:
	active_zone = -1


func is_clear() -> bool:
	if active_zone >= 0 or not queue.is_empty():
		return false
	for section in sections:
		if not section.is_empty():
			return false
	return true
