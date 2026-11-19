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
