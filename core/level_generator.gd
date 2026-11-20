class_name LevelGenerator
extends RefCounted
## 关卡生成：逐客轻量订单 × 品种 × 二维散布遮挡 × 特殊物品，全部种子确定。
## 订单阶段决定准确件数与包装档位；布局阶段只补充坐标，不增删物品。

const CENTER := Vector2(300, 430)
const SCATTER_GRID_SIZE := 80.0


class ScatterEntry:
	var center: Vector2
	var half: Vector2
	var cosine: float
	var sine: float
	var bounds: Rect2

	func _init(item: Dictionary) -> void:
		center = Vector2(float(item["x"]), float(item["y"]))
		half = BasketModel.hit_size(item) * 0.5
		var angle := deg_to_rad(float(item.get("rot", 0.0)))
		cosine = cos(angle)
		sine = sin(angle)
		var corners := BasketModel.corners_at(item, center.x, center.y)
		var minimum: Vector2 = corners[0]
		var maximum: Vector2 = corners[0]
		for corner: Vector2 in corners:
			minimum = minimum.min(corner)
			maximum = maximum.max(corner)
		bounds = Rect2(minimum, maximum - minimum)

	func contains(point: Vector2) -> bool:
		if not bounds.has_point(point):
			return false
		var offset := point - center
		var local_x := offset.x * cosine + offset.y * sine
		var local_y := -offset.x * sine + offset.y * cosine
		return absf(local_x) <= half.x and absf(local_y) <= half.y


## 每位顾客独立生成订单。巨大款替换同款普通包装，数量与种类上限互不叠加。
static func build_order(cfg: Dictionary, snacks_db: Dictionary, rng: GameRNG) -> Array:
	var pool: Array = cfg.get("pool", snacks_db.keys()).duplicate()
	rng.shuffle(pool)
	var kinds := mini(int(cfg.get("snack_kinds", 2)), pool.size())
	if kinds <= 0:
		return []
	var chosen := pool.slice(0, kinds)
	if cfg.get("category_diverse", false):
		chosen = _choose_category_diverse(pool, kinds, snacks_db, rng)

	var giant_count := int(cfg.get("giant_kinds", -1))
	if giant_count < 0:
		giant_count = rng.randi_range(0, mini(2, kinds))
	giant_count = clampi(giant_count, 0, mini(2, kinds))
	var giant_pool := chosen.duplicate()
	rng.shuffle(giant_pool)
	var giant_ids := giant_pool.slice(0, giant_count)
	var package_scale := clampf(float(cfg.get("package_scale", 1.5)), 1.0, 2.0)
	var items: Array = []
	for snack_id in chosen:
		var giant := giant_ids.has(snack_id)
		var count := rng.randi_range(1, 2) if giant else rng.randi_range(1, 20)
		if not giant and not bool(cfg.get("random_quantity", true)):
			count = clampi(int(cfg.get("fixed_quantity", 2)), 1, 20)
		for _index in count:
			items.append({
				"snack": snack_id, "size": 3 if giant else 1, "giant": giant,
				"gift": false, "package_scale": package_scale,
			})
	rng.shuffle(items)
	var features: Array = cfg.get("features", [])
	if features.has("gift"):
		var gift_candidates := items.filter(func(item): return not BasketModel.is_giant(item))
		if not gift_candidates.is_empty():
			gift_candidates[0]["size"] = 2
			gift_candidates[0]["gift"] = true
			gift_candidates[0]["giant"] = false
	return items


## 未提供订单清单时保留旧的均匀分配入口，供旧核心夹具直接使用。
static func generate(cfg: Dictionary, snacks_db: Dictionary, rng: GameRNG, manifest: Variant = null) -> BasketModel:
	var basket := BasketModel.new()
	var use_manifest := manifest is Array
	var templates: Array = []
	if use_manifest:
		templates = manifest
	else:
		var pool: Array = cfg.get("pool", snacks_db.keys()).duplicate()
		rng.shuffle(pool)
		var count: int = int(cfg.get("items", 6))
		var kinds: int = mini(int(cfg.get("snack_kinds", 2)), mini(pool.size(), count))
		var chosen := pool.slice(0, kinds)
		if cfg.get("category_diverse", false):
			chosen = _choose_category_diverse(pool, kinds, snacks_db, rng)
		var per: Array = []
		var base: int = count / kinds
		for i in kinds:
			per.append(base)
		var order: Array = range(kinds)
		rng.shuffle(order)
		for i in count - base * kinds:
			per[order[i]] += 1
		for i in kinds:
			for _n in per[i]:
				templates.append({"snack": chosen[i], "size": 1, "package_scale": 1.0})

	var items: Array = []
	for index in templates.size():
		var item: Dictionary = templates[index].duplicate(true)
		item["uid"] = index + 1
		item["size"] = int(item.get("size", 1))
		item["giant"] = BasketModel.is_giant(item)
		item["blind"] = bool(item.get("blind", false))
		item["revealed"] = bool(item.get("revealed", true))
		item["gift"] = bool(item.get("gift", false))
		item["picked"] = false
		item["package_scale"] = float(item.get("package_scale", 1.0))
		item["x"] = 0.0
		item["y"] = 0.0
		item["rot"] = 0.0
		item["layer"] = 0
		items.append(item)
	rng.shuffle(items)

	var features: Array = cfg.get("features", [])
	if not use_manifest and features.has("gift") and not items.is_empty():
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
## 空间网格只缩小精确遮挡评分的候选集；候选数量按订单规模固定，布局仍由种子确定。
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
	# 超大订单仍使用相同抖动网格与精确评分，只减少每件的候选点，避免极限参数长时间阻塞。
	var candidate_count := 12 if items.size() <= 128 else (6 if items.size() <= 256 else 4)
	var spatial: Dictionary = {}
	for index in items.size():
		var it: Dictionary = items[index]
		var row := index / columns
		var column := index % columns
		var row_count := mini(columns, items.size() - row * columns)
		var row_cell_width := (maximum.x - minimum.x) / float(row_count)
		var best_point := CENTER
		var best_score := INF
		var best_clearance := -INF
		for _candidate_index in candidate_count:
			var point := Vector2(
				minimum.x + (float(column) + rng.randf_range(0.18, 0.82)) * row_cell_width,
				minimum.y + (float(row) + rng.randf_range(0.18, 0.82)) * cell_size.y)
			point = Vector2(snappedf(point.x, 0.01), snappedf(point.y, 0.01))
			point = basket.clamp_to_table(it, point)
			var score := _overlap_load(it, point, spatial)
			var clearance := _nearest_distance_squared(point, spatial)
			if score < best_score or (is_equal_approx(score, best_score) and clearance > best_clearance):
				best_point = point
				best_score = score
				best_clearance = clearance
		it["x"] = best_point.x
		it["y"] = best_point.y
		it["layer"] = basket.items.size()
		basket.items.append(it)
		_index_scatter_item(spatial, it)


static func _scatter_cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / SCATTER_GRID_SIZE), floori(point.y / SCATTER_GRID_SIZE))


## 包装进入旋转包围盒覆盖的所有格子，因此巨大包装跨格时也不会漏掉候选。
static func _index_scatter_item(spatial: Dictionary, item: Dictionary) -> void:
	var entry := ScatterEntry.new(item)
	var first := _scatter_cell(entry.bounds.position)
	var last := _scatter_cell(entry.bounds.end)
	for gy in range(first.y, last.y + 1):
		for gx in range(first.x, last.x + 1):
			var cell := Vector2i(gx, gy)
			if not spatial.has(cell):
				spatial[cell] = []
			spatial[cell].append(entry)


## 在候选包装的 5×5 采样点上累计遮挡深度；深堆叠比轻微接触受到更强惩罚。
static func _overlap_load(item: Dictionary, point: Vector2, spatial: Dictionary) -> float:
	var half := BasketModel.hit_size(item) * 0.5
	var rotation := deg_to_rad(float(item.get("rot", 0.0)))
	var score := 0.0
	for gy in 5:
		for gx in 5:
			var local := -half + half * 2.0 * Vector2((gx + 0.5) / 5.0, (gy + 0.5) / 5.0)
			var sample := point + local.rotated(rotation)
			var depth := 0
			var candidates: Array = spatial.get(_scatter_cell(sample), [])
			for entry: ScatterEntry in candidates:
				if entry.contains(sample):
					depth += 1
			score += float(depth * depth)
	return score


## 逐圈查询中心点；当当前最近距离小于下一圈可能的最小距离时即可精确停止。
static func _nearest_distance_squared(point: Vector2, spatial: Dictionary) -> float:
	if spatial.is_empty():
		return INF
	var center_cell := _scatter_cell(point)
	var nearest := INF
	var seen := {}
	# 桌面最多跨越十余个格子；24 圈覆盖全部合法初始散布范围。
	for radius in range(24):
		for gy in range(center_cell.y - radius, center_cell.y + radius + 1):
			for gx in range(center_cell.x - radius, center_cell.x + radius + 1):
				if radius > 0 and maxi(absi(gx - center_cell.x), absi(gy - center_cell.y)) != radius:
					continue
				var candidates: Array = spatial.get(Vector2i(gx, gy), [])
				for entry: ScatterEntry in candidates:
					var instance := entry.get_instance_id()
					if seen.has(instance):
						continue
					seen[instance] = true
					nearest = minf(nearest, point.distance_squared_to(entry.center))
		var outside_distance := float(radius) * SCATTER_GRID_SIZE
		if nearest <= outside_distance * outside_distance:
			break
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
