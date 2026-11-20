extends Node
## 自由聚堆聚焦测试：旋转包装 SAT、完整连通堆、异款阻断与真实松手输入。

var _failures: Array = []
var _checks := 0
var _pointer := Vector2.ZERO


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_geometry()
	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.25).timeout
	var seed_value := _safe_seed(app, 2)
	app.start_test({"level_id": 2, "preset": "standard", "random_quantity": false,
		"fixed_quantity": 2, "package_scale": 1.5, "giant_kinds": 0, "seed_value": seed_value})
	var gs: GameScreen = app.current
	await _wait_table_ready(gs)
	var st: GameState = gs.state
	_expect(st.batch_serial == 0 and st.basket.remaining() == 8, "safe seed leaves every snack on the table after pouring")

	var groups := _spread_pairs(gs)
	_expect(groups.size() == 4, "level 2 test fixture contains four complete snack pairs")
	var ids := groups.keys()
	ids.sort()
	var a: Array = groups[ids[0]]
	var b: Array = groups[ids[1]]
	var c: Array = groups[ids[2]]
	var weighed: Array = []
	st.group_weighed.connect(func(id: String, group: Array, _price: Dictionary, _weight: int):
		weighed.append({"snack": id, "count": group.size()}))

	# 最后一段鼠标移动已经到位，但尚未松手时不能提前扫描或脱手。
	var uid := int(a[0]["uid"])
	var target := Vector2(float(a[1]["x"]) + 138.0, float(a[1]["y"]))
	var start_local := st.basket.exposed_point(uid)
	var origin := Vector2(float(a[0]["x"]), float(a[0]["y"]))
	var release_pointer := gs.table_view.to_global(target + start_local - origin)
	await _press(gs.table_view.to_global(start_local))
	await _move(release_pointer)
	_expect(gs._dragging and st.batch_serial == 0 and st.basket.remaining() == 8, "drag motion alone never scans or removes a ready cluster")
	await _release(release_pointer)
	_expect(st.active_batch.size() == 2 and String(st.active_batch[0]["snack"]) == ids[0], "real release gathers the complete connected pair")
	_expect(st.basket.remaining() == 6 and st.bagged_items == 0 and st.batch_phase == "flying", "release starts one flight before its settlement")
	_expect(gs.snack_nodes[int(a[0]["uid"])].flying and gs.snack_nodes[int(a[1]["uid"])].flying, "both actual table nodes fly into the scale")
	var completed := await _wait_weighed(weighed, 1, 2.0)
	_expect(completed and st.bagged_items == 2 and st.batch_phase == "idle", "the released pair weighs automatically without a POS command")
	await _shot("cluster_release")

	# B 已完整连通，但 C1 与 B1 实际重叠；移出接触后必须重扫整张桌。
	_place(st, gs, int(b[0]["uid"]), Vector2(140, 350))
	var b_width := BasketModel.hit_size(b[0]).x
	_place(st, gs, int(b[1]["uid"]), Vector2(140 + b_width + 10.0, 350))
	var contact_y := 350.0 + (BasketModel.hit_size(b[0]).y + BasketModel.hit_size(c[0]).y) * 0.5
	_place(st, gs, int(c[0]["uid"]), Vector2(140, contact_y - 0.02))
	_expect(st.scan_clusters() == 0 and st.active_batch.is_empty(), "a foreign package overlapping by 0.02px blocks a complete pair")
	_expect(st.basket.remaining() == 6 and st.bagged_items == 2, "blocked snacks stay draggable on the table")
	await _shot("cluster_blocked")
	var foreign_uid := int(c[0]["uid"])
	await _drag(_exposed_point(gs, foreign_uid), gs.table_view.to_global(Vector2(450, 560)))
	_expect(st.active_batch.size() == 2 and String(st.active_batch[0]["snack"]) == ids[1], "moving a foreign snack to positive clearance rescans and releases the blocked pair")
	completed = await _wait_weighed(weighed, 2, 2.0)
	_expect(completed and st.bagged_items == 4 and st.basket.remaining() == 4, "only the unblocked pair settles; the split foreign kinds remain")
	_expect(st.batch_queue.is_empty() and st.tray.is_empty(), "completed real-input batches leave no stale queue or scale entries")
	_finish(st)


func _check_geometry() -> void:
	var near_a := _item(1, "a", Vector2(100, 100))
	var near_b := _item(2, "a", Vector2(238, 100))
	_expect(BasketModel.packages_near(near_a, near_b, 18.0), "packages exactly 18px apart are connected")
	near_b["x"] = 238.02
	_expect(not BasketModel.packages_near(near_a, near_b, 18.0), "packages beyond the 18px surface gap are disconnected")
	near_b["x"] = 238.0
	var chain := [near_a, near_b, _item(3, "a", Vector2(376, 100))]
	_expect(BasketModel.find_ready_clusters(chain).size() == 1, "transitive same-kind connections form one complete component")
	chain[2]["x"] = 500.0
	_expect(BasketModel.find_ready_clusters(chain).is_empty(), "a split same-kind component never auto-settles")

	var boundary := [near_a.duplicate(), near_b.duplicate(), _item(3, "b", Vector2(100, 203.98))]
	_expect(not _has_snack(BasketModel.find_ready_clusters(boundary), "a"), "a foreign package overlapping by 0.02px blocks the pair")
	boundary[2]["y"] = 204.0
	_expect(not _has_snack(BasketModel.find_ready_clusters(boundary), "a"), "exact foreign package contact still blocks the pair")
	boundary[2]["y"] = 204.02
	_expect(_has_snack(BasketModel.find_ready_clusters(boundary), "a"), "a positive 0.02px surface gap unblocks the pair")
	boundary[2]["y"] = 205.0
	_expect(_has_snack(BasketModel.find_ready_clusters(boundary), "a"), "a positive 1px surface gap unblocks the pair")
	boundary[2]["y"] = 232.0
	_expect(_has_snack(BasketModel.find_ready_clusters(boundary), "a"), "the old 28px separation is no longer required")

	var gift_a := _item(10, "gift_kind", Vector2(260, 300), 45.0, 2)
	var gift_b := _item(11, "gift_kind", Vector2(260, 300) + Vector2(0, 138.02).rotated(deg_to_rad(45.0)), 45.0, 2)
	_expect(not BasketModel.packages_near(gift_a, gift_b, 18.0), "rotated large gift boxes use SAT rather than an axis-aligned box")
	gift_b["x"] = 260.0 + Vector2(0, 138.0).rotated(deg_to_rad(45.0)).x
	gift_b["y"] = 300.0 + Vector2(0, 138.0).rotated(deg_to_rad(45.0)).y
	_expect(BasketModel.find_ready_clusters([gift_a, gift_b]).size() == 1, "the rotated gift pair connects at the exact package-surface threshold")

	var click_model := BasketModel.new()
	click_model.items = [_item(30, "click", Vector2(100, 100)), _item(31, "click", Vector2(300, 100)),
		_item(32, "click", Vector2(500, 100)), _item(33, "click", Vector2(800, 100))]
	var click_target := click_model.find_click_target(30)
	_expect(int(click_target.get("uid", -1)) == 32, "click target skips nearby same-kind items and chooses the nearest distant one")
	click_model.items = [_item(30, "click", Vector2(100, 100)), _item(31, "click", Vector2(320, 100))]
	_expect(click_model.find_click_target(30).is_empty(), "a same-kind item exactly 220px away remains inside the excluded vicinity")
	click_model.items[1]["x"] = 320.02
	_expect(int(click_model.find_click_target(30).get("uid", -1)) == 31, "a same-kind item just beyond 220px becomes a valid target")
	click_model.items = [_item(50, "tie", Vector2(0, 0)), _item(52, "tie", Vector2(-300, 0)), _item(51, "tie", Vector2(300, 0))]
	_expect(int(click_model.find_click_target(50).get("uid", -1)) == 51, "equal-distance click targets use ascending UID as the deterministic tie breaker")
	click_model.items = [_item(60, "local", Vector2(100, 100)), _item(61, "local", Vector2(220, 100))]
	_expect(click_model.find_click_target(60).is_empty(), "no distant same-kind target produces the bounce fallback")

	var covered_model := BasketModel.new()
	covered_model.items = [_item(20, "covered", Vector2(200, 200)), _item(21, "covered", Vector2(200, 200))]
	_expect(covered_model.exposure(20) < 0.12, "the lower fixture is genuinely covered")
	_expect(BasketModel.find_ready_clusters(covered_model.items).size() == 1, "covered same-kind items still participate in cluster completeness")

	var edge_model := BasketModel.new()
	edge_model.items = [_item(70, "target", Vector2.ZERO), _item(71, "cover", Vector2(-7.1667, -12.0))]
	var robust_point := edge_model.exposed_point(70)
	_expect(edge_model.hit_test(robust_point) == 70 and edge_model.hit_test(robust_point - Vector2(1, 0)) == 70,
		"exposed helper keeps a one-pixel horizontal tolerance near the occlusion edge")


func _item(uid: int, snack: String, point: Vector2, rot: float = 0.0, size: int = 1) -> Dictionary:
	return {"uid": uid, "snack": snack, "size": size, "blind": false, "revealed": true,
		"gift": size == 2, "picked": false, "x": point.x, "y": point.y, "rot": rot, "layer": uid}


func _has_snack(ready: Array, snack_id: String) -> bool:
	for group in ready:
		if String(group["snack"]) == snack_id:
			return true
	return false


func _safe_seed(app, level_id: int) -> int:
	for candidate in range(42, 200):
		var generated := GameState.new_game(app.db, level_id, {}, candidate, {"test_mode": true,
			"preset": "standard", "random_quantity": false, "fixed_quantity": 2,
			"package_scale": 1.5, "giant_kinds": 0})
		if BasketModel.find_ready_clusters(generated.basket.items).is_empty():
			return candidate
	_expect(false, "a deterministic non-ready initial layout exists")
	return 42


func _spread_pairs(gs: GameScreen) -> Dictionary:
	var groups := {}
	for item in gs.state.basket.items:
		if not groups.has(item["snack"]):
			groups[item["snack"]] = []
		groups[item["snack"]].append(item)
	var ids := groups.keys()
	ids.sort()
	var points := [Vector2(130, 180), Vector2(130, 560), Vector2(520, 400), Vector2(520, 680),
		Vector2(800, 180), Vector2(800, 560), Vector2(800, 740), Vector2(500, 180)]
	var index := 0
	for snack_id in ids:
		for item in groups[snack_id]:
			item["rot"] = 0.0
			gs.snack_nodes[int(item["uid"])].rotation = 0.0
			_place(gs.state, gs, int(item["uid"]), points[index])
			index += 1
	gs._refresh_table_layers()
	return groups


func _place(st: GameState, gs: GameScreen, uid: int, point: Vector2) -> void:
	st.move_item(uid, point, true)
	gs.snack_nodes[uid].global_position = gs.table_view.to_global(point)


func _wait_table_ready(gs: GameScreen) -> void:
	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 160:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(not gs._switching_customer and not is_instance_valid(gs.basket_view), "basket pour finishes before cluster input")
	await get_tree().create_timer(0.08).timeout


func _wait_weighed(events: Array, count: int, timeout: float) -> bool:
	var guard := 0
	while events.size() < count and guard < int(timeout / 0.02):
		guard += 1
		await get_tree().create_timer(0.02).timeout
	return events.size() >= count


func _exposed_point(gs: GameScreen, uid: int) -> Vector2:
	var point := gs.state.basket.exposed_point(uid)
	return gs.table_view.to_global(point) if point.x >= 0 else Vector2(-1, -1)


func _press(pos: Vector2) -> void:
	_expect(pos.x >= 0, "real drag starts at an exposed package point")
	_pointer = pos
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	var event := InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame


func _move(end: Vector2) -> void:
	var start := _pointer
	for i in range(1, 9):
		var point := start.lerp(end, float(i) / 8.0)
		_pointer = point
		var move := InputEventMouseMotion.new()
		move.position = point
		move.global_position = point
		move.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(move)
		await get_tree().create_timer(0.025).timeout


func _release(end: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = end
	event.global_position = end
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame


func _drag(start: Vector2, end: Vector2) -> void:
	await _press(start)
	await _move(end)
	await _release(end)


func _expect(cond: bool, message: String) -> void:
	_checks += 1
	print("ok - " + message if cond else "FAIL - " + message)
	if not cond:
		_failures.append(message)


func _finish(st: GameState) -> void:
	print("zones smoke: checks=", _checks, " failed_checks=", _failures.size(), " state=", st.state)
	get_tree().quit(0 if _failures.is_empty() else 1)


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_tree().root.get_texture().get_image()
	img.save_png("res://docs/images/dev_%s.png" % tag)
	print("shot dev_%s.png" % tag)
