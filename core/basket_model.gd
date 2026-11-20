class_name BasketModel
extends RefCounted
## 桌面零食模型：购物篮倒出后的二维堆叠、遮挡曝光与拖动整理。
## 类名保留以减少迁移范围；坐标使用桌面局部逻辑像素，与 Node/SceneTree 无关。

# 初始撒落仍使用原安全区，保留各小关卡固定种子的落点。
const TABLE_BOUNDS := Rect2(24, 60, 552, 740)
# 拖动可覆盖整个可见台面，但包装四角不能进入称重平台或底部收银员过道。
const DRAG_BOUNDS := Rect2(16, -92, 888, 892)
const DRAG_SCALE_BLOCK := Rect2(580, -152, 320, 450)
const DRAG_SCALE_GAP := 4.0
const GATHER_RADIUS := 220.0
const CLUSTER_GAP := 18.0
const FOREIGN_GAP := 28.0

var items: Array = []  # {uid, snack, size, blind, revealed, gift, picked, x, y, rot, layer}


static func hit_size(item: Dictionary) -> Vector2:
	return Vector2(152, 120) if int(item.get("size", 1)) == 2 else Vector2(120, 104)


static func item_rect(item: Dictionary) -> Rect2:
	var size := hit_size(item)
	return Rect2(Vector2(float(item["x"]), float(item["y"])) - size * 0.5, size)


static func padded_corners_at(item: Dictionary, x: float, y: float, padding: float) -> Array:
	var half := hit_size(item) * 0.5 + Vector2.ONE * padding
	var center := Vector2(x, y)
	var angle := deg_to_rad(float(item.get("rot", 0.0)))
	var corners: Array = []
	for local in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
		corners.append(center + local.rotated(angle))
	return corners


static func corners_at(item: Dictionary, x: float, y: float) -> Array:
	return padded_corners_at(item, x, y, 0.0)


static func _polygons_intersect(a: Array, b: Array) -> bool:
	for polygon in [a, b]:
		for i in polygon.size():
			var edge: Vector2 = polygon[(i + 1) % polygon.size()] - polygon[i]
			var axis := Vector2(-edge.y, edge.x)
			var min_a := INF
			var max_a := -INF
			var min_b := INF
			var max_b := -INF
			for point: Vector2 in a:
				var projection := point.dot(axis)
				min_a = minf(min_a, projection)
				max_a = maxf(max_a, projection)
			for point: Vector2 in b:
				var projection := point.dot(axis)
				min_b = minf(min_b, projection)
				max_b = maxf(max_b, projection)
			if max_a <= min_b or max_b <= min_a:
				return false
	return true


static func packages_near(a: Dictionary, b: Dictionary, gap: float) -> bool:
	var expanded := padded_corners_at(a, float(a["x"]), float(a["y"]), gap + 0.001)
	return _polygons_intersect(expanded, corners_at(b, float(b["x"]), float(b["y"])))


static func find_ready_clusters(items: Array) -> Array:
	var remaining := items.filter(func(item): return not item.get("picked", false))
	remaining.sort_custom(func(a, b): return int(a["uid"]) < int(b["uid"]))
	var by_snack := {}
	for item in remaining:
		var snack_id := String(item["snack"])
		if not by_snack.has(snack_id):
			by_snack[snack_id] = []
		by_snack[snack_id].append(item)
	var visited := {}
	var ready: Array = []
	for seed in remaining:
		var seed_uid := int(seed["uid"])
		if visited.has(seed_uid):
			continue
		var snack_id := String(seed["snack"])
		var same_kind: Array = by_snack[snack_id]
		var component: Array = []
		var stack: Array = [seed]
		visited[seed_uid] = true
		while not stack.is_empty():
			var current: Dictionary = stack.pop_back()
			component.append(current)
			for candidate in same_kind:
				var uid := int(candidate["uid"])
				if visited.has(uid) or not packages_near(current, candidate, CLUSTER_GAP):
					continue
				visited[uid] = true
				stack.append(candidate)
		if component.size() != same_kind.size():
			continue
		var blocked := false
		for member in component:
			for foreign in remaining:
				if String(foreign["snack"]) == snack_id:
					continue
				if packages_near(member, foreign, FOREIGN_GAP):
					blocked = true
					break
			if blocked:
				break
		if not blocked:
			component.sort_custom(func(a, b): return int(a["uid"]) < int(b["uid"]))
			ready.append({"snack": snack_id, "items": component})
	ready.sort_custom(func(a, b): return int(a["items"][0]["uid"]) < int(b["items"][0]["uid"]))
	return ready

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


## 初始撒落使用原左侧安全区，按当前旋转计算四角的安全范围。
func clamp_to_table(item: Dictionary, point: Vector2) -> Vector2:
	var extent := _rotated_extent(item)
	return Vector2(
		clampf(point.x, TABLE_BOUNDS.position.x + extent.x, TABLE_BOUNDS.end.x - extent.x),
		clampf(point.y, TABLE_BOUNDS.position.y + extent.y, TABLE_BOUNDS.end.y - extent.y))


## 手动整理可使用整张台面；称重台按包装旋转范围扩张后作为禁放区。
func clamp_to_drag(item: Dictionary, point: Vector2) -> Vector2:
	var extent := _rotated_extent(item)
	var allowed := Rect2(DRAG_BOUNDS.position + extent, DRAG_BOUNDS.size - extent * 2.0)
	var clamped := Vector2(
		clampf(point.x, allowed.position.x, allowed.end.x),
		clampf(point.y, allowed.position.y, allowed.end.y))
	var margin := extent + Vector2.ONE * DRAG_SCALE_GAP
	var blocked := DRAG_SCALE_BLOCK.grow_individual(margin.x, margin.y, margin.x, margin.y)
	if not blocked.has_point(clamped):
		return clamped
	var candidates := [
		Vector2(blocked.position.x, clamped.y), Vector2(blocked.end.x, clamped.y),
		Vector2(clamped.x, blocked.position.y), Vector2(clamped.x, blocked.end.y),
	]
	var best := clamped
	var best_distance := INF
	for candidate: Vector2 in candidates:
		if candidate.x < allowed.position.x or candidate.x > allowed.end.x:
			continue
		if candidate.y < allowed.position.y or candidate.y > allowed.end.y:
			continue
		var distance := clamped.distance_squared_to(candidate)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


func _rotated_extent(item: Dictionary) -> Vector2:
	var half := hit_size(item) * 0.5
	var angle := deg_to_rad(float(item.get("rot", 0.0)))
	return Vector2(
		absf(cos(angle)) * half.x + absf(sin(angle)) * half.y,
		absf(sin(angle)) * half.x + absf(cos(angle)) * half.y)


## 拖动是核心命令：更新后续退货与双击距离所用的位置，可选提升到最上层。
func move_item(uid: int, point: Vector2, bring_to_front: bool = false) -> bool:
	var target := get_item(uid)
	if target.is_empty() or target.get("picked", false):
		return false
	var clamped := clamp_to_drag(target, Vector2(snappedf(point.x, 0.01), snappedf(point.y, 0.01)))
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
