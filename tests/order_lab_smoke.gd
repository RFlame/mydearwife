extends SceneTree
## 新增订单/尺寸聚焦测试；不运行旧完整 core 自动通关组。

var _checks := 0
var _failures: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var db := ConfigDB.load_all()
	_check_geometry(db)
	_check_level_curve(db)
	_check_random_orders(db)
	_check_fixed_and_gifts(db)
	_check_maximum_order(db)
	print("order lab smoke: checks=", _checks, " failed_checks=", _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _fixed_options(level_id: int, quantity: int = 2, giant_kinds: int = 0, package_scale: float = 1.5) -> Dictionary:
	return {"test_mode": true, "level_id": level_id, "preset": "standard",
		"random_quantity": false, "fixed_quantity": quantity,
		"giant_kinds": giant_kinds, "package_scale": package_scale}


func _check_geometry(db: ConfigDB) -> void:
	_expect(BasketModel.hit_size({"size": 1}) == Vector2(120, 104), "legacy geometry fixtures retain 1.0 package scale")
	_expect(BasketModel.hit_size({"size": 1, "package_scale": 1.5}) == Vector2(180, 156), "normal production packages are exactly 1.5x")
	_expect(BasketModel.hit_size({"size": 2, "package_scale": 1.5}) == Vector2(228, 180), "existing gifts receive the same 1.5x geometry")
	_expect(BasketModel.hit_size({"size": 3, "package_scale": 1.5}) == Vector2(288, 246), "giant size-3 geometry is explicit and scaled once")
	_expect(BasketModel.hit_size({"size": 3, "package_scale": 2.0}) == Vector2(384, 328), "test size slider supports giant 2.0x geometry")
	_expect(BasketModel.is_giant({"size": 3, "giant": false}), "size 3 is the canonical giant classification")
	var product_sized := BasketModel.hit_size({"size": 1, "package_scale": 1.5, "product_scale": 0.8})
	_expect(product_sized.is_equal_approx(Vector2(144, 124.8)), "product scale multiplies both geometry axes once")
	_expect(is_equal_approx(product_sized.x / 120.0, product_sized.y / 104.0), "product scaling preserves the original aspect ratio")
	_expect(BasketModel.hit_size({"size": 1, "package_scale": 1.5}).is_equal_approx(Vector2(180, 156)), "missing product scale keeps legacy fixture geometry")
	var scales_valid := true
	var minimum_scale := INF
	var maximum_scale := -INF
	for snack in db.snacks.values():
		var scale := float(snack.get("product_scale", 0.0))
		scales_valid = scales_valid and scale >= 0.5 and scale <= 1.2
		minimum_scale = minf(minimum_scale, scale)
		maximum_scale = maxf(maximum_scale, scale)
	_expect(scales_valid and db.snacks.size() == 40, "all 40 products carry an explicit reasonable relative size")
	_expect(minimum_scale <= 0.55 and maximum_scale >= 1.15 and maximum_scale - minimum_scale >= 0.59, "real package metadata produces clearly different snack sizes")

	var a := GameState.new_game(db, 2, {}, 71, _fixed_options(2, 2, 0, 1.0))
	var b := GameState.new_game(db, 2, {}, 71, _fixed_options(2, 2, 0, 2.0))
	var same_weight := a.basket.items.size() == b.basket.items.size()
	for index in mini(a.basket.items.size(), b.basket.items.size()):
		var item_a: Dictionary = a.basket.items[index]
		var item_b: Dictionary = b.basket.items[index]
		same_weight = same_weight and item_a["snack"] == item_b["snack"] and item_a["size"] == item_b["size"]
		same_weight = same_weight and db.snack_weight(String(item_a["snack"])) * int(item_a["size"]) == db.snack_weight(String(item_b["snack"])) * int(item_b["size"])
	_expect(same_weight, "package scale changes geometry without multiplying item weight or size-tier cost")
	_expect(a.cfg["tray_slots"] == b.cfg["tray_slots"], "package scale does not alter tray capacity configuration")


func _check_level_curve(db: ConfigDB) -> void:
	var curve_ok := true
	var pools_ok := true
	for level_id in range(1, 21):
		var expected := mini(level_id + 2, 10)
		var cfg := db.runtime_config(level_id, {})
		curve_ok = curve_ok and int(cfg["snack_kinds"]) == expected
		pools_ok = pools_ok and cfg["pool"].size() >= expected
	_expect(curve_ok, "levels increase from 3 through 10 kinds, then remain capped at 10")
	_expect(pools_ok, "every capped kind count has enough unique configured snacks")
	for level_id in [1, 2, 20]:
		var expected := mini(level_id + 2, 10)
		var state := GameState.new_game(db, level_id, {}, 42, _fixed_options(level_id))
		_expect(_kind_counts(state.basket.items).size() == expected, "level %d materializes exactly %d unique kinds" % [level_id, expected])
		_expect(state.total_items == expected * 2 * state.customers_total, "level %d fixed-order total includes every customer" % level_id)

	var options := _fixed_options(3, 2, 2, 1.75)
	options["preset"] = "relax"
	var options_before := JSON.stringify(options)
	db.set_preset("challenge")
	var cfg := db.runtime_config(3, {"tray": 3, "scale": 3, "magnet": 3}, options)
	_expect(db.preset_name == "challenge" and JSON.stringify(options) == options_before, "test overrides do not mutate shared preset or input options")
	_expect(is_equal_approx(float(cfg["package_scale"]), 1.75) and int(cfg["fixed_quantity"]) == 2 and int(cfg["giant_kinds"]) == 2, "order overrides survive preset and upgrade merging")
	_expect(is_equal_approx(float(cfg["patience"]), 0.0) and int(cfg["tray_slots"]) == 9, "selected test preset and upgrades still apply without changing level kind count")
	var clamped := db.runtime_config(2, {}, _fixed_options(2, 11, 0))
	_expect(int(clamped["fixed_quantity"]) == 10, "fixed quantity 11 is finally clamped to the new maximum of 10")


func _check_random_orders(db: ConfigDB) -> void:
	var state := GameState.new_game(db, 20, {}, 123)
	var limits_ok := true
	var scale_ok := true
	var manifest_total := 0
	for order in state._orders:
		manifest_total += order.size()
		var counts := _kind_counts(order)
		var giant_kinds := 0
		for snack_id in counts:
			var entries: Array = counts[snack_id]
			var giant := BasketModel.is_giant(entries[0])
			if giant:
				giant_kinds += 1
			limits_ok = limits_ok and entries.size() >= 1 and entries.size() <= (2 if giant else 10)
			for item in entries:
				scale_ok = scale_ok and is_equal_approx(float(item["package_scale"]), 1.5)
				scale_ok = scale_ok and is_equal_approx(float(item["product_scale"]), float(db.snacks[snack_id]["product_scale"]))
				limits_ok = limits_ok and bool(item["giant"]) == giant
		limits_ok = limits_ok and giant_kinds >= 0 and giant_kinds <= 2
	_expect(limits_ok, "each customer independently keeps normal quantities in 1..10 and giants at 0..2 kinds x 1..2 items")
	_expect(scale_ok, "every order item carries its global package scale and product-specific relative size")
	_expect(state.total_items == manifest_total, "random level total is the sum of all lightweight manifests")
	_expect(JSON.stringify(state._orders[0]) != JSON.stringify(state._orders[1]), "different customers do not reuse one sampled quantity set")

	var cfg := db.runtime_config(20, {})
	var orders_a: Array = []
	var orders_b: Array = []
	var rng_a := GameRNG.new(998)
	var rng_b := GameRNG.new(998)
	for _customer in 4:
		orders_a.append(LevelGenerator.build_order(cfg, db.snacks, rng_a))
		orders_b.append(LevelGenerator.build_order(cfg, db.snacks, rng_b))
	_expect(JSON.stringify(orders_a) == JSON.stringify(orders_b), "fixed order seed reproduces every customer manifest")

	var options := _fixed_options(2, 2, 0)
	var small := GameState.new_game(db, 2, {}, 42, options)
	var actual_total := small.basket.items.size()
	for _customer in range(1, small.customers_total):
		small._next_customer()
		actual_total += small.basket.items.size()
	_expect(actual_total == small.total_items and actual_total == 24, "lazy materialization exactly matches the precomputed 3-customer total")

	var repeat_a := GameState.new_game(db, 2, {}, 2026, options)
	var repeat_b := GameState.new_game(db, 2, {}, 2026, options)
	_expect(JSON.stringify(repeat_a.basket.items) == JSON.stringify(repeat_b.basket.items), "fixed seed also reproduces scaled package positions and rotations")

	var legacy_cfg := db.runtime_config(2, {})
	legacy_cfg["items"] = 6
	legacy_cfg["snack_kinds"] = 3
	var legacy := LevelGenerator.generate(legacy_cfg, db.snacks, GameRNG.new(42))
	_expect(legacy.items.size() == 6 and BasketModel.hit_size(legacy.items[0]) == Vector2(120, 104), "legacy direct generator retains even distribution and 1.0 fixture geometry")


func _check_fixed_and_gifts(db: ConfigDB) -> void:
	var options := _fixed_options(3, 7, 2, 1.5)
	var state := GameState.new_game(db, 3, {}, 88, options)
	var normal_ok := true
	var giant_ok := true
	var giant_kinds := 0
	for snack_id in _kind_counts(state.basket.items):
		var entries: Array = _kind_counts(state.basket.items)[snack_id]
		if BasketModel.is_giant(entries[0]):
			giant_kinds += 1
			giant_ok = giant_ok and entries.size() >= 1 and entries.size() <= 2
		else:
			normal_ok = normal_ok and entries.size() == 7
	_expect(normal_ok, "fixed test quantity applies independently to every normal kind")
	_expect(giant_ok and giant_kinds == 2, "forced test giants remain exactly two kinds with at most two items each")

	var gift_cfg := db.runtime_config(15, {}, _fixed_options(15, 2, 2))
	var plain_cfg := gift_cfg.duplicate(true)
	plain_cfg["features"] = []
	var gifted := LevelGenerator.build_order(gift_cfg, db.snacks, GameRNG.new(515))
	var plain := LevelGenerator.build_order(plain_cfg, db.snacks, GameRNG.new(515))
	var gift_count := gifted.filter(func(item): return bool(item.get("gift", false))).size()
	var gift_valid := gift_count == 1 and gifted.size() == plain.size()
	for item in gifted:
		if item.get("gift", false):
			gift_valid = gift_valid and int(item["size"]) == 2 and not BasketModel.is_giant(item)
	_expect(gift_valid, "manifest gifts are precomputed, non-giant, and never change authoritative item totals")


func _check_maximum_order(db: ConfigDB) -> void:
	var cfg := db.runtime_config(20, {}, _fixed_options(20, 10, 2, 2.0))
	var manifest := LevelGenerator.build_order(cfg, db.snacks, GameRNG.new(991))
	var started := Time.get_ticks_msec()
	var basket := LevelGenerator.generate(cfg, db.snacks, GameRNG.new(555), manifest)
	var elapsed := Time.get_ticks_msec() - started
	var counts := _kind_counts(manifest)
	var giant_kinds := 0
	for entries in counts.values():
		if BasketModel.is_giant(entries[0]):
			giant_kinds += 1
	_expect(counts.size() == 10 and giant_kinds == 2, "maximum fixture contains 10 kinds and exactly two giant kinds")
	_expect(manifest.size() >= 82 and manifest.size() <= 84 and basket.items.size() == manifest.size(), "maximum 2.0x order places every one of its 82..84 items")
	var bounds_ok := true
	for item in basket.items:
		for corner in BasketModel.corners_at(item, float(item["x"]), float(item["y"])):
			bounds_ok = bounds_ok and BasketModel.TABLE_BOUNDS.grow(0.02).has_point(corner)
	_expect(bounds_ok, "every maximum-order rotated package corner remains on the initial table")
	var plain_cfg := db.runtime_config(20, {}, _fixed_options(20, 10, 0, 1.5))
	var plain_manifest := LevelGenerator.build_order(plain_cfg, db.snacks, GameRNG.new(992))
	_expect(plain_manifest.size() == 100, "ten ordinary kinds at fixed quantity ten produce the exact 100-item ceiling")
	print("maximum focused order: items=", basket.items.size(), " layout_ms=", elapsed)

	var placed := basket.items.slice(0, 60)
	var spatial := {}
	for item in placed:
		LevelGenerator._index_scatter_item(spatial, item)
	var candidate: Dictionary = basket.items[60]
	var point := Vector2(float(candidate["x"]), float(candidate["y"]))
	var broadphase := LevelGenerator._overlap_load(candidate, point, spatial)
	var brute := _brute_overlap(candidate, point, placed)
	_expect(is_equal_approx(broadphase, brute), "spatial-grid candidates exactly match brute-force 5x5 overlap scoring")
	var nearest := LevelGenerator._nearest_distance_squared(point, spatial)
	var brute_nearest := INF
	for other in placed:
		brute_nearest = minf(brute_nearest, point.distance_squared_to(Vector2(float(other["x"]), float(other["y"]))))
	_expect(is_equal_approx(nearest, brute_nearest), "ring search returns the exact same nearest-center distance as brute force")


func _brute_overlap(item: Dictionary, point: Vector2, placed: Array) -> float:
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


func _kind_counts(items: Array) -> Dictionary:
	var result := {}
	for item in items:
		var snack_id := String(item["snack"])
		if not result.has(snack_id):
			result[snack_id] = []
		result[snack_id].append(item)
	return result


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	print("ok - " + message if condition else "FAIL - " + message)
	if not condition:
		_failures.append(message)
