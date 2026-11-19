class_name BasketModel
extends RefCounted
## 桌面零食模型：购物篮倒出后的二维堆叠、遮挡曝光与拖动整理。
## 类名保留以减少迁移范围；坐标使用桌面局部逻辑像素，与 Node/SceneTree 无关。

# 局部底边 800 经桌面 0.78 缩放后对应屏幕 y=1024，底部 1/5 仅作收银员过道。
const TABLE_BOUNDS := Rect2(24, 60, 552, 740)
const GATHER_RADIUS := 220.0

var items: Array = []  # {uid, snack, size, blind, revealed, gift, picked, x, y, rot, layer}


static func hit_size(item: Dictionary) -> Vector2:
	return Vector2(152, 120) if int(item.get("size", 1)) == 2 else Vector2(120, 104)


static func item_rect(item: Dictionary) -> Rect2:
	var size := hit_size(item)
	return Rect2(Vector2(float(item["x"]), float(item["y"])) - size * 0.5, size)


## 与 SnackView 的旋转 RectangleShape2D 共用同一套局部坐标。
static func contains_point(item: Dictionary, point: Vector2, padding: float = 0.0) -> bool:
	var center := Vector2(float(item["x"]), float(item["y"]))
	var local := (point - center).rotated(-deg_to_rad(float(item.get("rot", 0.0))))
	var half := hit_size(item) * 0.5 + Vector2.ONE * padding
	return absf(local.x) <= half.x and absf(local.y) <= half.y


## 逆层序命中：重叠点永远只返回最上层零食，下层只能从露出区域点中。
func hit_test(point: Vector2) -> int:
	var ordered := items.duplicate()
	ordered.sort_custom(func(a, b): return int(a["layer"]) > int(b["layer"]))
	for it in ordered:
		if not it.get("picked", false) and contains_point(it, point):
			return int(it["uid"])
	return -1


## 精细命中未命中时再给可拾取物品一圈输入余量；不会穿透高层或选中完全遮挡物。
## 核心曝光与视觉热区保持不变，只有表现层的鼠标/触摸入口使用该辅助命中。
func hit_test_assisted(point: Vector2, padding: float = 14.0) -> int:
	var exact := hit_test(point)
	if exact > 0:
		return exact
	var ordered := items.duplicate()
	ordered.sort_custom(func(a, b): return int(a["layer"]) > int(b["layer"]))
	for it in ordered:
		var uid := int(it["uid"])
		if not it.get("picked", false) and can_pick(uid) and contains_point(it, point, padding):
			return uid
	return -1


## 返回一个实际不被高层覆盖的篮内局部点击点；无合法点时返回 (-1,-1)。
func exposed_point(uid: int) -> Vector2:
	var target := get_item(uid)
	if target.is_empty() or not can_pick(uid):
		return Vector2(-1, -1)
	var size := hit_size(target)
	var center := Vector2(float(target["x"]), float(target["y"]))
	var rotation := deg_to_rad(float(target.get("rot", 0.0)))
	for gy in 9:
		for gx in 9:
			var local := -size * 0.5 + size * Vector2((gx + 0.5) / 9.0, (gy + 0.5) / 9.0)
			var point := center + local.rotated(rotation)
			if hit_test(point) == uid:
				return point
	return Vector2(-1, -1)


## 把拖动后的中心点限制在左侧桌面内，按当前旋转计算四角的安全范围。
func clamp_to_table(item: Dictionary, point: Vector2) -> Vector2:
	var half := hit_size(item) * 0.5
	var angle := deg_to_rad(float(item.get("rot", 0.0)))
	var extent := Vector2(
		absf(cos(angle)) * half.x + absf(sin(angle)) * half.y,
		absf(sin(angle)) * half.x + absf(cos(angle)) * half.y)
	return Vector2(
		clampf(point.x, TABLE_BOUNDS.position.x + extent.x, TABLE_BOUNDS.end.x - extent.x),
		clampf(point.y, TABLE_BOUNDS.position.y + extent.y, TABLE_BOUNDS.end.y - extent.y))


## 拖动是核心命令：更新后续退货与双击距离所用的位置，可选提升到最上层。
func move_item(uid: int, point: Vector2, bring_to_front: bool = false) -> bool:
	var target := get_item(uid)
	if target.is_empty() or target.get("picked", false):
		return false
	var clamped := clamp_to_table(target, Vector2(snappedf(point.x, 0.01), snappedf(point.y, 0.01)))
	target["x"] = clamped.x
	target["y"] = clamped.y
	if bring_to_front:
		var highest := -1
		for it in items:
			highest = maxi(highest, int(it["layer"]))
		target["layer"] = highest + 1
		_normalize_layers()
	return true


## 归一化层号，避免长期拖动让视觉 z_index 无限增长。
func _normalize_layers() -> void:
	var ordered := items.duplicate()
	ordered.sort_custom(func(a, b):
		if int(a["layer"]) == int(b["layer"]):
			return int(a["uid"]) < int(b["uid"])
		return int(a["layer"]) < int(b["layer"]))
	for i in ordered.size():
		ordered[i]["layer"] = i


## 距离从零食中心计算；只返回可实际点到的同款，顺序固定为近到远、UID 从小到大。
func nearby_same_at(snack_id: String, origin: Vector2, radius: float = GATHER_RADIUS) -> Array:
	var result: Array = []
	for it in items:
		if it.get("picked", false) or String(it["snack"]) != snack_id or not can_pick(int(it["uid"])):
			continue
		var center := Vector2(float(it["x"]), float(it["y"]))
		if center.distance_to(origin) <= radius:
			result.append(it)
	result.sort_custom(func(a, b):
		var da := Vector2(float(a["x"]), float(a["y"])).distance_squared_to(origin)
		var db := Vector2(float(b["x"]), float(b["y"])).distance_squared_to(origin)
		if is_equal_approx(da, db):
			return int(a["uid"]) < int(b["uid"])
		return da < db)
	return result


func get_item(uid: int) -> Dictionary:
	for it in items:
		if int(it["uid"]) == uid:
			return it
	return {}


## 用 5×5 采样估算露出面积；采样点随自身旋转，高层物品按同一旋转热区遮挡。
## 部分露出的物品可从露出位置点击，完全/几乎盖住的物品不可分拣。
func exposure(uid: int) -> float:
	var target := get_item(uid)
	if target.is_empty() or target.get("picked", false):
		return 0.0
	var size := hit_size(target)
	var center := Vector2(float(target["x"]), float(target["y"]))
	var rotation := deg_to_rad(float(target.get("rot", 0.0)))
	var higher: Array = []
	for it in items:
		if not it.get("picked", false) and int(it["layer"]) > int(target["layer"]):
			higher.append(it)
	var exposed := 0
	for gy in 5:
		for gx in 5:
			var local := -size * 0.5 + size * Vector2((gx + 0.5) / 5.0, (gy + 0.5) / 5.0)
			var point := center + local.rotated(rotation)
			var covered := false
			for other in higher:
				if contains_point(other, point):
					covered = true
					break
			if not covered:
				exposed += 1
	return float(exposed) / 25.0


func is_covered(uid: int) -> bool:
	return not can_pick(uid)


func can_pick(uid: int) -> bool:
	var target := get_item(uid)
	if target.is_empty() or target.get("picked", false):
		return false
	return exposure(uid) >= 0.12


## 标记拾取/退回。合法性校验由 GameState 负责；吸附可无视遮挡直接调用 pick。
func pick(uid: int) -> Dictionary:
	var target := get_item(uid)
	if not target.is_empty():
		target["picked"] = true
	return target


func restore(uid: int) -> Dictionary:
	var target := get_item(uid)
	if not target.is_empty():
		target["picked"] = false
	return target


func remaining() -> int:
	var n := 0
	for it in items:
		if not it.get("picked", false):
			n += 1
	return n


## 当前存在可点击露出区域的物品，不等于只有最高层一件。
func top_items() -> Array:
	var result: Array = []
	for it in items:
		if can_pick(int(it["uid"])):
			result.append(it)
	return result


func find_snack_items(snack_id: String, include_covered: bool = false) -> Array:
	var result: Array = []
	for it in items:
		if it.get("picked", false) or it["snack"] != snack_id:
			continue
		if not include_covered and not can_pick(int(it["uid"])):
			continue
		result.append(it)
	return result
