extends SceneTree
## 大篮散布与第 2 关难度的聚焦核心测试，不运行全关卡或其他系统回归。

var _pass := 0
var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var db := ConfigDB.load_all("res://data/")
	var level_two := db.runtime_config(2, {})
	_check(int(level_two["customers"]) == 3 and int(level_two["items"]) == 6 and int(level_two["snack_kinds"]) == 3,
		"level 2 progresses at three customers, six items and three kinds per basket")

	for sample_seed in [42, 99, 2026]:
		var small_cfg := db.runtime_config(1, {})
		var small_a := LevelGenerator.generate(small_cfg, db.snacks, GameRNG.new(sample_seed))
		var small_b := LevelGenerator.generate(small_cfg, db.snacks, GameRNG.new(sample_seed))
		_check(_layout_signature(small_a) == _layout_signature(small_b),
			"small basket seed %d remains deterministic" % sample_seed)

		var large_cfg := level_two.duplicate(true)
		large_cfg["items"] = 100
		large_cfg["snack_kinds"] = 16
		large_cfg["pool"] = db.snacks.keys()
		large_cfg["overlap"] = 0.15
		large_cfg["scatter_width"] = 520
		large_cfg["scatter_height"] = 620
		var large := LevelGenerator.generate(large_cfg, db.snacks, GameRNG.new(sample_seed))
		var repeat_large := LevelGenerator.generate(large_cfg, db.snacks, GameRNG.new(sample_seed))
		_check(large.items.size() == 100, "large fixture seed %d generates exactly 100 snacks" % sample_seed)
		_check(_layout_signature(large) == _layout_signature(repeat_large),
			"large basket seed %d remains deterministic" % sample_seed)

		var all_safe := true
		var exposure_sum := 0.0
		var quadrants := [0, 0, 0, 0]
		var max_depth := 0
		for item in large.items:
			all_safe = all_safe and _item_corners_inside(item)
			exposure_sum += large.exposure(int(item["uid"]))
			var center := Vector2(float(item["x"]), float(item["y"]))
			var quadrant := (1 if center.x >= 300.0 else 0) + (2 if center.y >= 430.0 else 0)
			quadrants[quadrant] += 1
			var depth := 0
			for other in large.items:
				if BasketModel.contains_point(other, center):
					depth += 1
			max_depth = maxi(max_depth, depth)
		var pickable := large.top_items().size()
		var mean_exposure := exposure_sum / float(large.items.size())
		print("scatter seed=", sample_seed, " pickable=", pickable,
			" mean_exposure=", snappedf(mean_exposure, 0.001),
			" max_center_depth=", max_depth, " quadrants=", quadrants)
		_check(all_safe, "large basket seed %d keeps every rotated corner inside the table" % sample_seed)
		_check(pickable >= 95, "large basket seed %d leaves at least 95%% of snacks clickable" % sample_seed)
		# 百件包装总面积约为桌面的 3.06 倍，平均曝光的理论上限约 0.327。
		_check(mean_exposure >= 0.24, "large basket seed %d uses at least 73%% of the geometric exposure limit" % sample_seed)
		_check(max_depth <= 7, "large basket seed %d avoids excessive center pile depth" % sample_seed)
		_check(int(quadrants.min()) >= 12, "large basket seed %d spreads across all four table quadrants" % sample_seed)

	print("scatter smoke: checks=", _pass + _fail, " failed_checks=", _fail)
	quit(0 if _fail == 0 else 1)


func _layout_signature(basket: BasketModel) -> String:
	var parts := PackedStringArray()
	for item in basket.items:
		parts.append("%d:%s:%.2f:%.2f:%.2f:%d" % [int(item["uid"]), String(item["snack"]),
			float(item["x"]), float(item["y"]), float(item["rot"]), int(item["layer"])])
	return "|".join(parts)


func _item_corners_inside(item: Dictionary) -> bool:
	var center := Vector2(float(item["x"]), float(item["y"]))
	var half := BasketModel.hit_size(item) * 0.5
	var angle := deg_to_rad(float(item["rot"]))
	var safe := BasketModel.TABLE_BOUNDS.grow(0.02)
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			var corner: Vector2 = center + Vector2(half.x * sx, half.y * sy).rotated(angle)
			if not safe.has_point(corner):
				return false
	return true


func _check(cond: bool, message: String) -> void:
	if cond:
		_pass += 1
		print("ok - " + message)
	else:
		_fail += 1
		printerr("FAIL - " + message)
