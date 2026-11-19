class_name LevelGenerator
extends RefCounted
## 关卡生成：顾客单篮物品 × 品种 × 二维散布遮挡 × 特殊物品，全部种子确定。
## 不再生成三件一组；同款任意数量都可由玩家手动称重结算。

const CENTER := Vector2(300, 430)


static func generate(cfg: Dictionary, snacks_db: Dictionary, rng: GameRNG) -> BasketModel:
	var basket := BasketModel.new()
	var pool: Array = cfg.get("pool", snacks_db.keys()).duplicate()
	rng.shuffle(pool)
	var count: int = int(cfg.get("items", 6))
	var kinds: int = mini(int(cfg.get("snack_kinds", 2)), mini(pool.size(), count))
	var chosen := pool.slice(0, kinds)
	if cfg.get("category_diverse", false):
		chosen = _choose_category_diverse(pool, kinds, snacks_db, rng)

	# 数量尽量均匀分配到品种，不要求 3 的倍数。
	var per: Array = []
	var base: int = count / kinds
	for i in kinds:
		per.append(base)
	var order: Array = range(kinds)
	rng.shuffle(order)
	for i in count - base * kinds:
		per[order[i]] += 1

	var items: Array = []
	var uid := 1
	for i in kinds:
		for n in per[i]:
			items.append({
				"uid": uid, "snack": chosen[i], "size": 1,
				"blind": false, "revealed": true, "gift": false, "picked": false,
				"x": 0.0, "y": 0.0, "rot": 0.0, "layer": 0,
			})
			uid += 1
	rng.shuffle(items)

	var features: Array = cfg.get("features", [])
	if features.has("gift") and not items.is_empty():
		items[0]["size"] = 2
		items[0]["gift"] = true
	if features.has("blind"):
		var candidates := items.filter(func(it): return not it["gift"])
		rng.shuffle(candidates)
		for k in mini(2, candidates.size()):
			candidates[k]["blind"] = true
			candidates[k]["revealed"] = false

	# 大篮不再向中心吸附；小篮保留原固定种子的生成路径和 RNG 调用顺序。
	if items.size() > 12:
		_scatter_large_basket(basket, items, cfg, rng)
		return basket

	# 模拟整篮倒下： triangular 分布偏向桌面中心，近几次落点互相靠拢形成接触与遮挡。
	var overlap := clampf(float(cfg.get("overlap", 0.35)), 0.0, 1.0)
	var half_width := float(cfg.get("scatter_width", 500.0)) * 0.5 * (1.0 - overlap * 0.28)
	var half_height := float(cfg.get("scatter_height", 680.0)) * 0.5 * (1.0 - overlap * 0.28)
	for i in items.size():
		var it: Dictionary = items[i]
		var point := Vector2(
			CENTER.x + (rng.randf_range(0.0, 1.0) + rng.randf_range(0.0, 1.0) - 1.0) * half_width,
			CENTER.y + (rng.randf_range(0.0, 1.0) + rng.randf_range(0.0, 1.0) - 1.0) * half_height)
		if i > 0:
			var anchor_index := maxi(0, i - 1 - rng.randi_range(0, mini(4, i - 1)))
			var anchor: Dictionary = items[anchor_index]
			var angle := rng.randf_range(0.0, TAU)
			var distance := rng.randf_range(32.0, 94.0) * (1.12 - overlap * 0.30)
			var contact := Vector2(float(anchor["x"]), float(anchor["y"])) + Vector2.from_angle(angle) * distance
			point = point.lerp(contact, 0.72)
		it["rot"] = snappedf(rng.randf_range(-28.0, 28.0) * (0.65 + overlap * 0.5), 0.01)
		point = Vector2(snappedf(point.x, 0.01), snappedf(point.y, 0.01))
		point = basket.clamp_to_table(it, point)
		it["x"] = point.x
		it["y"] = point.y
		it["layer"] = i
		basket.items.append(it)
	return basket


## 大篮使用带随机抖动的全桌面网格：先保证落点覆盖范围，再在单元内减少重叠。
## 仍按旋转后的真实四角夹回桌面，避免散开后侵入收银员过道。
static func _scatter_large_basket(basket: BasketModel, items: Array, cfg: Dictionary, rng: GameRNG) -> void:
	var overlap := clampf(float(cfg.get("overlap", 0.35)), 0.0, 1.0)
	var half_width := float(cfg.get("scatter_width", 500.0)) * 0.5 * (1.0 - overlap * 0.28)
	var half_height := float(cfg.get("scatter_height", 680.0)) * 0.5 * (1.0 - overlap * 0.28)
	var max_extent := Vector2.ZERO
	for it in items:
		it["rot"] = snappedf(rng.randf_range(-28.0, 28.0) * (0.65 + overlap * 0.5), 0.01)
		var half := BasketModel.hit_size(it) * 0.5
		var angle := deg_to_rad(float(it["rot"]))
		max_extent.x = maxf(max_extent.x, absf(cos(angle)) * half.x + absf(sin(angle)) * half.y)
		max_extent.y = maxf(max_extent.y, absf(sin(angle)) * half.x + absf(cos(angle)) * half.y)
	var minimum := Vector2(
		maxf(CENTER.x - half_width, BasketModel.TABLE_BOUNDS.position.x + max_extent.x),
		maxf(CENTER.y - half_height, BasketModel.TABLE_BOUNDS.position.y + max_extent.y))
	var maximum := Vector2(
		minf(CENTER.x + half_width, BasketModel.TABLE_BOUNDS.end.x - max_extent.x),
		minf(CENTER.y + half_height, BasketModel.TABLE_BOUNDS.end.y - max_extent.y))
	var columns := ceili(sqrt(float(items.size())))
	var rows := ceili(float(items.size()) / float(columns))
	var cell_size := (maximum - minimum) / Vector2(columns, rows)
	for index in items.size():
		var it: Dictionary = items[index]
		var row := index / columns
		var column := index % columns
		var row_count := mini(columns, items.size() - row * columns)
		var row_cell_width := (maximum.x - minimum.x) / float(row_count)
		var best_point := CENTER
		var best_score := INF
		var best_clearance := -INF
		for _candidate_index in 12:
			var point := Vector2(
				minimum.x + (float(column) + rng.randf_range(0.18, 0.82)) * row_cell_width,
				minimum.y + (float(row) + rng.randf_range(0.18, 0.82)) * cell_size.y)
			point = Vector2(snappedf(point.x, 0.01), snappedf(point.y, 0.01))
			point = basket.clamp_to_table(it, point)
			var score := _overlap_load(it, point, basket.items)
			var clearance := _nearest_distance_squared(point, basket.items)
			if score < best_score or (is_equal_approx(score, best_score) and clearance > best_clearance):
				best_point = point
				best_score = score
				best_clearance = clearance
		it["x"] = best_point.x
		it["y"] = best_point.y
		it["layer"] = basket.items.size()
		basket.items.append(it)


## 在候选包装的 5×5 采样点上累计遮挡深度；深堆叠比轻微接触受到更强惩罚。
static func _overlap_load(item: Dictionary, point: Vector2, placed: Array) -> float:
	var half := BasketModel.hit_size(item) * 0.5
	var rotation := deg_to_rad(float(item.get("rot", 0.0)))
	var score := 0.0
	for gy in 5:
		for gx in 5:
			var local := -half + half * 2.0 * Vector2((gx + 0.5) / 5.0, (gy + 0.5) / 5.0)
			var sample := point + local.rotated(rotation)
			var depth := 0
			for other in placed:
				if BasketModel.contains_point(other, sample):
					depth += 1
			score += float(depth * depth)
	return score


static func _nearest_distance_squared(point: Vector2, placed: Array) -> float:
	var nearest := INF
	for other in placed:
		nearest = minf(nearest, point.distance_squared_to(Vector2(float(other["x"]), float(other["y"]))))
	return nearest


## 按品类轮流抽取，保证大篮子先覆盖所有品类，再补充同品类的其他商品。
static func _choose_category_diverse(pool: Array, kinds: int, snacks_db: Dictionary, rng: GameRNG) -> Array:
	var by_category := {}
	for snack_id in pool:
		var category := String(snacks_db.get(snack_id, {}).get("category", "other"))
		if not by_category.has(category):
			by_category[category] = []
		by_category[category].append(snack_id)
	var categories := by_category.keys()
	rng.shuffle(categories)
	var chosen: Array = []
	var round_index := 0
	while chosen.size() < kinds:
		var added := false
		for category in categories:
			var options: Array = by_category[category]
			if round_index < options.size():
				chosen.append(options[round_index])
				added = true
				if chosen.size() == kinds:
					break
		if not added:
			break
		round_index += 1
	return chosen
