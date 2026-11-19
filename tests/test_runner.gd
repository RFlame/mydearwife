extends SceneTree
## core 单元测试：godot --headless --path . -s tests/test_runner.gd
## 覆盖：二维曝光遮挡 / 单件手动称重 / 混品拒结 / 原位退货 / 顾客队列 / 全关卡可解性。

var _pass := 0
var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func check(cond: bool, test_name: String) -> void:
	if cond:
		_pass += 1
		print("ok - " + test_name)
	else:
		_fail += 1
		printerr("FAIL - " + test_name)


func _run() -> void:
	var db := ConfigDB.load_all("res://data/")
	check(db.level_count() == 20, "20 levels loaded")
	check(db.snacks.size() == 40, "40 snacks loaded")
	check(db.categories.size() == 8, "8 snack categories loaded")
	check(db.customers.size() == 12, "12 individual customers loaded")
	var customer_profiles_valid := true
	var personalities := {}
	var avatars := {}
	for customer_id in db.customers:
		var profile: Dictionary = db.customers[customer_id]
		personalities[profile.get("personality", "")] = true
		avatars[profile.get("avatar", "")] = true
		customer_profiles_valid = customer_profiles_valid and not String(profile.get("name", "")).is_empty() and not profile.get("lines", []).is_empty()
	check(customer_profiles_valid and personalities.size() == 12 and avatars.size() == 12, "customer names, personalities, lines and portraits are individual")
	var five_per_category := true
	for category_id in db.categories:
		var category_items := db.snack_ids_for_categories([category_id])
		five_per_category = five_per_category and category_items.size() == 5
	check(five_per_category, "each category contains five original snacks")
	check(db.runtime_config(2, {})["pool"].size() == 40, "level 2 expands category pool to 40 snacks")
	check(BasketModel.TABLE_BOUNDS == Rect2(24, 60, 552, 740), "sorting table leaves the bottom fifth as cashier aisle")

	# 1. 全关卡顾客数、每篮件数、总件数与逐客推进。
	for lvl in db.levels:
		var lid: int = lvl["id"]
		var g := GameState.new_game(db, lid, {}, 42)
		check(g.customers_total == int(lvl["customers"]), "level %d customer count" % lid)
		var unique_customers := {}
		for customer_id in g._customer_ids:
			unique_customers[customer_id] = true
		check(unique_customers.size() == g._customer_ids.size(), "level %d queue has no duplicate characters" % lid)
		for c in int(lvl["customers"]):
			check(g.basket.remaining() == int(lvl["items"]), "level %d customer %d item count" % [lid, c + 1])
			check(g.total_items == int(lvl["customers"]) * int(lvl["items"]), "level %d full-order total at customer %d" % [lid, c + 1])
			if lid == 2:
				var snack_ids := {}
				var category_ids := {}
				for item in g.basket.items:
					snack_ids[item["snack"]] = true
					category_ids[db.snacks[item["snack"]]["category"]] = true
				check(snack_ids.size() == 16, "level 2 customer %d has 16 snack kinds" % [c + 1])
				check(category_ids.size() == 8, "level 2 customer %d covers all categories" % [c + 1])
				var bottom_safe := true
				for item in g.basket.items:
					var center := Vector2(float(item["x"]), float(item["y"]))
					var half := BasketModel.hit_size(item) * 0.5
					var rotation := deg_to_rad(float(item["rot"]))
					for sx in [-1, 1]:
						for sy in [-1, 1]:
							var corner: Vector2 = center + Vector2(half.x * sx, half.y * sy).rotated(rotation)
							bottom_safe = bottom_safe and BasketModel.TABLE_BOUNDS.has_point(corner)
				check(bottom_safe, "level 2 customer %d poured snacks stay inside table" % [c + 1])
			var all_level_safe := true
			for item in g.basket.items:
				all_level_safe = all_level_safe and _item_corners_inside(item)
			check(all_level_safe, "level %d customer %d rotated corners stay inside enlarged table" % [lid, c + 1])
			serve_current(g)
		check(g.state == "complete", "level %d all customers served" % lid)
		check(g.bagged_items == g.total_items, "level %d all items weighed" % lid)

	# 2. 种子确定性 + 真正的二维散布/旋转。
	var g1 := GameState.new_game(db, 13, {}, 99)
	var g2 := GameState.new_game(db, 13, {}, 99)
	check(JSON.stringify(g1.basket.items) == JSON.stringify(g2.basket.items), "seed determinism")
	check(g1._customer_ids == g2._customer_ids, "customer queue is seed deterministic")
	var queue_a := GameState.new_game(db, 1, {}, 77)
	var queue_b := GameState.new_game(db, 1, {}, 77)
	serve_current(queue_a)
	serve_current_single(queue_b)
	check(JSON.stringify(queue_a.basket.items) == JSON.stringify(queue_b.basket.items), "batch choices do not reroll next customer layout")
	var positions := {}
	var rotated := false
	for it in g1.basket.items:
		positions[Vector2(float(it["x"]), float(it["y"]))] = true
		rotated = rotated or absf(float(it["rot"])) > 0.1
	check(positions.size() == g1.basket.items.size(), "scatter positions are distinct")
	check(rotated, "scatter includes random rotation")

	# 3. 几何曝光：全盖不可点、部分露出可点、拿走上层后解锁。
	var b := BasketModel.new()
	var a := _item(1, "candy", 100.0, 100.0, 0)
	var cover := _item(2, "soda", 100.0, 100.0, 1)
	b.items = [a, cover]
	check(not b.can_pick(1), "fully covered item cannot be picked")
	check(b.can_pick(2), "top item can be picked")
	check(b.hit_test(Vector2(100, 100)) == 2, "overlap hit test returns top item")
	b.pick(2)
	check(b.can_pick(1), "covered item unlocks after top pick")
	check(b.hit_test(Vector2(100, 100)) == 1, "hit test updates after top pick")
	b.restore(2)
	cover["x"] = 150.0
	check(b.can_pick(1), "partially exposed item can be picked")
	check(b.exposure(1) > 0.12 and b.exposure(1) < 1.0, "exposure ratio is partial")
	var assist_basket := BasketModel.new()
	assist_basket.items = [_item(1, "candy", 100.0, 100.0, 0)]
	check(assist_basket.hit_test(Vector2(166, 100)) == -1, "point outside exact snack rect misses")
	check(assist_basket.hit_test_assisted(Vector2(166, 100)) == 1, "assisted input expands effective touch area")
	check(BasketModel.hit_size(assist_basket.items[0]) == Vector2(120, 104), "visual and logical snack size are enlarged together")

	# 4. 桌面拖动、边界、层序与双击半径聚合。
	var drag_model := BasketModel.new()
	drag_model.items = [_item(1, "chips", 180.0, 180.0, 0), _item(2, "candy", 360.0, 360.0, 1)]
	check(drag_model.move_item(1, Vector2(230, 220), true), "table drag updates core position")
	check(int(drag_model.get_item(1)["layer"]) > int(drag_model.get_item(2)["layer"]), "dragged snack rises above overlapping snacks")
	check(drag_model.hit_test(Vector2(230, 220)) == 1, "hit test uses dragged position and layer")
	check(drag_model.move_item(1, Vector2(-999, 999)), "drag can be clamped at table edge")
	var clamped_center := Vector2(float(drag_model.get_item(1)["x"]), float(drag_model.get_item(1)["y"]))
	check(BasketModel.TABLE_BOUNDS.has_point(clamped_center), "dragged snack center remains inside table")
	var large_edge := _item(3, "gift", 300.0, 560.0, 2)
	large_edge["size"] = 2
	large_edge["rot"] = 27.0
	drag_model.items.append(large_edge)
	for edge_point in [Vector2(-999, 560), Vector2(999, 560), Vector2(300, -999), Vector2(300, 1999)]:
		drag_model.move_item(3, edge_point)
		check(_item_corners_inside(drag_model.get_item(3)), "large rotated snack clamps safely at table edge %s" % str(edge_point))
	var gather_model := BasketModel.new()
	gather_model.items = [_item(1, "chips", 100.0, 100.0, 0), _item(2, "chips", 250.0, 100.0, 1),
		_item(3, "chips", 400.0, 100.0, 2), _item(4, "candy", 100.0, 330.0, 3)]
	var nearby := gather_model.nearby_same_at("chips", Vector2(100, 100))
	check(nearby.size() == 2 and int(nearby[0]["uid"]) == 1 and int(nearby[1]["uid"]) == 2, "double-click candidates are nearby, exposed, uniform and ordered")
	var gg := GameState.new_game(db, 1, {}, 5)
	gg.basket = gather_model
	var gathered: Array = gg.gather_nearby(1)
	check(gathered.size() == 2 and gg.tray.entries.size() == 2, "double-click gathers nearby same snacks onto scale")
	check(gg.tray.is_uniform() and gg.basket.remaining() == 2, "double-click leaves far and different snacks on table")
	check(gg.bagged_items == 0 and gg.bagged_groups == 0, "double-click does not auto settle scale")
	var moved_home := Vector2(210, 245)
	gg.return_item(2)
	check(gg.move_item(2, moved_home, true) and gg.pick(2) and gg.return_item(2), "dragged snack can make a scale round trip")
	var restored_center := Vector2(float(gg.basket.get_item(2)["x"]), float(gg.basket.get_item(2)["y"]))
	check(restored_center == moved_home, "scale return uses the dragged table position")
	var capped := GameState.new_game(db, 1, {}, 5)
	capped.basket = BasketModel.new()
	capped.basket.items = gather_model.items.duplicate(true)
	capped.tray.slots = 1
	check(capped.gather_nearby(1).size() == 1 and capped.tray.entries.size() == 1, "double-click respects remaining scale capacity")

	# 5. 单件不会自动称重，点击结算才称重。
	var gw := GameState.new_game(db, 1, {}, 5)
	var weighed := [0]
	gw.group_weighed.connect(func(_s, _i, _p, _w): weighed[0] += 1)
	var first: Dictionary = gw.basket.top_items()[0]
	gw.pick(int(first["uid"]))
	check(weighed[0] == 0, "single pick does not auto weigh")
	check(gw.tray.entries.size() == 1, "picked item stays on scale")
	check(gw.tray_weight() == db.snack_weight(String(first["snack"])) * int(first.get("size", 1)), "live weight updates immediately after pick")
	check(gw.settle_scale(), "single-item manual checkout works")
	check(gw.tray_weight() == 0, "live weight clears after checkout")
	check(weighed[0] == 1 and gw.bagged_items == 1, "manual checkout emits one item")
	check(gw.tray.is_empty(), "scale clears after checkout")
	var ge := GameState.new_game(db, 1, {}, 5)
	check(not ge.settle_scale(), "empty scale cannot checkout")

	# 5. 混品拒结，点击退货后恢复同款并可结算。
	var gm := GameState.new_game(db, 4, {}, 8)
	var mixed := _make_mixed(gm)
	check(mixed.size() == 2, "mixed scale prepared")
	if mixed.size() == 2:
		var before_groups := gm.bagged_groups
		check(not gm.settle_scale(), "mixed snacks cannot checkout")
		check(gm.bagged_groups == before_groups, "rejected checkout has no reward")
		var returned: Dictionary = mixed[1]
		var mixed_weight := gm.tray_weight()
		var returned_weight := db.snack_weight(String(returned["snack"])) * int(returned.get("size", 1))
		var remaining_before := gm.basket.remaining()
		var home := Vector2(float(returned["x"]), float(returned["y"]))
		check(gm.return_item(int(returned["uid"])), "scale item returns to basket")
		check(gm.basket.remaining() == remaining_before + 1, "return restores basket count")
		check(not gm.basket.get_item(int(returned["uid"]))["picked"], "returned item is pickable again")
		check(BasketModel.item_rect(gm.basket.get_item(int(returned["uid"]))).get_center() == home, "return keeps original position")
		check(gm.tray.is_uniform(), "scale uniform after return")
		check(gm.tray_weight() == mixed_weight - returned_weight, "live weight decreases immediately after return")
		check(gm.settle_scale(), "uniform scale checkout after return")

	# 6. 台满不再失败：先结算或退货即可继续。
	var gf := GameState.new_game(db, 18, {}, 7)
	var guard := 0
	while not gf.tray.free_slots() <= 0 and guard < 30:
		guard += 1
		var chosen := {}
		for it in gf.basket.top_items():
			if gf.tray.can_fit(int(it["size"])):
				chosen = it
				break
		if chosen.is_empty():
			break
		gf.pick(int(chosen["uid"]))
	check(gf.tray.free_slots() == 0, "scale filled")
	check(gf.state == "playing", "full scale does not fail level")
	check(not gf.had_tray_full, "intentional full batch keeps perfect bonus")
	var leftover: Dictionary = gf.basket.top_items()[0]
	check(not gf.pick(int(leftover["uid"])), "full scale rejects extra pick")
	var last: Dictionary = gf.tray.entries.back()
	check(gf.return_item(int(last["uid"])) and gf.tray.free_slots() > 0, "return frees full scale")

	# 7. 多顾客队列：每位新篮、总进度累计、道具和耐心恢复。
	var gq := GameState.new_game(db, 1, {}, 11)
	check(gq.upcoming_customers().size() == 1, "queue shows next customer")
	var slots_before: int = gq.tray.slots
	check(gq.use_extra_slot(), "extra slot before next customer")
	serve_current(gq)
	check(gq.customer_index == 2 and gq.state == "playing", "next customer starts")
	check(gq.basket.remaining() == 4, "next customer brings new basket")
	check(gq.total_items == 8, "level total spans customers")
	check(gq.tray.slots == slots_before and gq.use_extra_slot(), "base slots and extra-slot charge reset for next customer")
	check(gq.upcoming_customers().is_empty(), "last customer has empty queue")
	serve_current(gq)
	check(gq.state == "complete", "last customer completes level")
	check(gq.bagged_items == 8, "all customers items weighed")

	# 8. 最后一位：篮空但台上未结算，不能提前过关。
	var gp := GameState.new_game(db, 1, {}, 13)
	while gp.customer_index < gp.customers_total:
		serve_current(gp)
	var last_guard := 0
	while gp.basket.remaining() > 0 and last_guard < 100:
		last_guard += 1
		_auto_step(gp)
		if gp.basket.remaining() == 0:
			break
	check(gp.basket.remaining() == 0 and not gp.tray.is_empty(), "last basket empty with pending scale")
	check(gp.state == "playing", "pending scale blocks completion")
	gp.settle_scale()
	check(gp.state == "complete", "final manual checkout completes level")

	# 9. 全关卡 ×3 种子自动通关（同款成批，但允许单件结算）。
	var completed := 0
	var total := 0
	for lvl in db.levels:
		for seed_value in [1, 7, 42]:
			total += 1
			var g := GameState.new_game(db, lvl["id"], {}, seed_value)
			if auto_play(g):
				completed += 1
			else:
				printerr("  auto_play stuck: level %d seed %d state %s" % [lvl["id"], seed_value, g.state])
	check(completed == total, "auto play all 20 levels x3 seeds (%d/%d)" % [completed, total])

	# 10. 大礼包占 2 格 / 盲袋揭示。
	var g15 := GameState.new_game(db, 15, {}, 42)
	var has_gift := false
	for it in g15.basket.items:
		has_gift = has_gift or int(it["size"]) == 2
	check(has_gift, "level 15 has size-2 gift")
	var gb := GameState.new_game(db, 16, {}, 9)
	var blind := {}
	for it in gb.basket.items:
		if it.get("blind", false):
			blind = it
			break
	check(not blind.is_empty(), "level 16 has blind bag")
	if not blind.is_empty():
		var blind_uid := int(blind["uid"])
		var reveal_guard := 0
		while not gb.basket.can_pick(blind_uid) and reveal_guard < 30:
			reveal_guard += 1
			var blocker: Dictionary = gb.basket.top_items()[0]
			gb.pick(int(blocker["uid"]))
			gb.settle_scale()
		var groups_before: int = gb.bagged_groups
		check(gb.pick(blind_uid), "exposed blind bag can be picked")
		check(blind.get("revealed", false), "blind bag reveals on scale")
		check(gb.bagged_groups == groups_before, "blind reveal does not auto weigh")

	# 11. 吸附同款、容量与混品限制。
	var gmag := GameState.new_game(db, 5, {}, 11)
	var target := String(gmag.basket.items[0]["snack"])
	var available := {}
	for it in gmag.basket.top_items():
		available[int(it["uid"])] = true
	check(gmag.use_magnet(target), "magnet works")
	check(gmag.tray.is_uniform() and not gmag.tray.is_empty(), "magnet keeps scale uniform")
	var magnet_visible_only := true
	for it in gmag.tray.entries:
		magnet_visible_only = magnet_visible_only and available.has(int(it["uid"]))
	check(magnet_visible_only, "magnet only pulls exposed snacks")
	check(gmag.magnet_charges == int(gmag.cfg["magnet_charges"]) - 1, "magnet charge consumed")
	gmag.settle_scale()
	var other := ""
	for it in gmag.basket.top_items():
		if it["snack"] != target:
			other = String(it["snack"])
			break
	if other != "":
		var another := String(gmag.basket.top_items()[0]["snack"])
		gmag.pick(int(gmag.basket.top_items()[0]["uid"]))
		if another != other:
			check(not gmag.use_magnet(other), "magnet cannot mix scale snacks")

	# 12. 连击累计、退货清零与超时清零。
	var gc := GameState.new_game(db, 4, {}, 3)
	gc.pick(int(gc.basket.top_items()[0]["uid"]))
	gc.pick(int(gc.basket.top_items()[0]["uid"]))
	check(gc.combo.combo == 2, "combo accumulates")
	gc.return_item(int(gc.tray.entries.back()["uid"]))
	check(gc.combo.combo == 0, "return resets combo")
	gc.pick(int(gc.basket.top_items()[0]["uid"]))
	var timeout_notified := [false]
	gc.combo_changed.connect(func(c, _b):
		if c == 0:
			timeout_notified[0] = true)
	gc.update(gc.combo.window + 0.5)
	check(gc.combo.combo == 0, "combo resets after window")
	check(timeout_notified[0], "combo timeout emits UI reset notification")

	# 13. 冻结、耐心失败、难度与升级。
	var gs := GameState.new_game(db, 6, {}, 3)
	var left_before: float = gs.clock.left
	check(gs.use_freeze(), "freeze works")
	gs.update(5.0)
	check(is_equal_approx(gs.clock.left, left_before), "patience frozen")
	var gfail := GameState.new_game(db, 6, {}, 3)
	gfail.update(500.0)
	check(gfail.state == "failed", "patience depleted fails")
	var gh := GameState.new_game(db, 9, {}, 4)
	check(is_equal_approx(gh.clock.total, 75.0 * float(gh.current_customer().get("patience_mult", 1.0))), "normal character patience modifier applies once")
	serve_current(gh)
	check(gh.current_customer_type() == "hurried", "queued hurried customer starts")
	check(float(gh.current_customer().get("patience_mult", 1.0)) < 1.0, "hurried character is less patient")
	check(is_equal_approx(gh.clock.total, 75.0 * float(gh.current_customer().get("patience_mult", 1.0))), "hurried character patience modifier applies once")
	check(is_equal_approx(gh.combo.window, float(gh.cfg["combo_window_sec"]) * float(gh.current_customer().get("combo_window_mult", 1.0))), "character combo-window modifier applies")
	check(gh.combo.combo == 0, "combo resets between customers")
	db.set_preset("relax")
	check(int(db.runtime_config(1, {})["tray_slots"]) == 8, "relax preset 8 slots")
	db.set_preset("challenge")
	check(int(db.runtime_config(1, {})["tray_slots"]) == 6, "challenge preset 6 slots")
	db.set_preset("standard")
	var upgraded := db.runtime_config(1, {"tray": 3, "magnet": 3, "scale": 2})
	check(int(upgraded["tray_slots"]) == 9, "tray upgrade +2")
	check(int(upgraded["magnet_charges"]) == 3, "magnet upgrade charges")
	check(is_equal_approx(float(upgraded["weigh_anim_time"]), 0.3), "scale upgrade anim")

	# 14. 批量计价与结算字段。
	var one := ScoreSystem.batch_price(1, 1, 0)
	var many := ScoreSystem.batch_price(1, 4, 0)
	check(int(many["total"]) > int(one["total"]), "larger batch earns more")
	var gwin := GameState.new_game(db, 1, {}, 5)
	auto_play(gwin)
	var result := gwin.settle()
	check(gwin.state == "complete", "level completes")
	check(int(result["stars"]) >= 1, "stars >= 1")
	check(int(result["coins"]) > 0, "coins > 0")
	check(int(result["total_items"]) == 8 and int(result["bagged_items"]) == 8, "result reports item totals")
	check(int(result["total_groups"]) == gwin.bagged_groups, "result reports manual batch count")

	# 15. 顾客发现可立即记录且重复接待不重复解锁；不写测试存档。
	var collection_save := SaveData.new()
	check(collection_save.meet_customer(g1.current_customer_id(), false), "first meeting discovers customer")
	check(collection_save.customers_discovered.has(g1.current_customer_id()), "customer discovery is stored independently from snacks")
	check(not collection_save.meet_customer(g1.current_customer_id(), false), "repeat meeting does not duplicate discovery")

	print("----------------------------------------")
	print("PASS %d  FAIL %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


func _item_corners_inside(item: Dictionary) -> bool:
	var center := Vector2(float(item["x"]), float(item["y"]))
	var half := BasketModel.hit_size(item) * 0.5
	var angle := deg_to_rad(float(item["rot"]))
	var safe := BasketModel.TABLE_BOUNDS.grow(0.02)
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			if not safe.has_point(center + Vector2(half.x * sx, half.y * sy).rotated(angle)):
				return false
	return true


func _item(uid: int, snack: String, x: float, y: float, layer: int) -> Dictionary:
	return {"uid": uid, "snack": snack, "size": 1, "blind": false, "revealed": true,
		"gift": false, "picked": false, "x": x, "y": y, "rot": 0.0, "layer": layer}


func _make_mixed(g: GameState) -> Array:
	for guard in 40:
		if g.tray.is_empty():
			var first: Dictionary = g.basket.top_items()[0]
			g.pick(int(first["uid"]))
		var current := String(g.tray.entries[0]["snack"])
		for it in g.basket.top_items():
			if it["snack"] != current and g.tray.can_fit(int(it["size"])):
				g.pick(int(it["uid"]))
				return [g.tray.entries[0], g.tray.entries.back()]
		g.settle_scale()
		if g.state != "playing" or g.basket.remaining() == 0:
			break
	return []


## 推进一步：台上为空则选一种可点零食；台上同款可继续放；否则手动结算。
func _auto_step(g: GameState) -> void:
	if g.state != "playing":
		return
	if g.basket.remaining() == 0:
		if not g.tray.is_empty():
			g.settle_scale()
		return
	var snack_id := ""
	if not g.tray.is_empty():
		snack_id = String(g.tray.entries[0]["snack"])
	else:
		snack_id = String(g.basket.top_items()[0]["snack"])
	for it in g.basket.top_items():
		if it["snack"] == snack_id and g.tray.can_fit(int(it["size"])):
			g.pick(int(it["uid"]))
			return
	if not g.tray.is_empty():
		g.settle_scale()


func serve_current(g: GameState) -> void:
	var index := g.customer_index
	var guard := 0
	while g.state == "playing" and g.customer_index == index and guard < 1000:
		guard += 1
		_auto_step(g)


func serve_current_single(g: GameState) -> void:
	var index := g.customer_index
	var guard := 0
	while g.state == "playing" and g.customer_index == index and guard < 1000:
		guard += 1
		if not g.tray.is_empty():
			g.settle_scale()
		else:
			g.pick(int(g.basket.top_items()[0]["uid"]))


func auto_play(g: GameState) -> bool:
	var guard := 0
	while g.state == "playing" and guard < 5000:
		guard += 1
		var before := str(g.customer_index, ":", g.basket.remaining(), ":", g.tray.entries.size(), ":", g.bagged_groups)
		_auto_step(g)
		var after := str(g.customer_index, ":", g.basket.remaining(), ":", g.tray.entries.size(), ":", g.bagged_groups)
		if before == after:
			printerr("  no progress at customer %d remaining %d" % [g.customer_index, g.basket.remaining()])
			break
	return g.state == "complete"
