extends Node
## 连续自动称重聚焦测试：FIFO、连击快照、零冷却、大 delta 与并行表现反馈。

var _failures: Array = []
var _checks := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var db := ConfigDB.load_all()
	db.set_preset("standard")
	_check_core(db)

	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.25).timeout
	app.start_level(3, _safe_seed(app, 3))
	var gs: GameScreen = app.current
	await _wait_table_ready(gs)
	var st: GameState = gs.state
	_expect(gs._pos_mode_label.text == "聚堆自动称重", "POS is a static automatic-clustering display")
	await _double_click(Vector2(690, 1160), false)
	_expect(st.batch_serial == 0 and st.bagged_items == 0, "screen double click has no hidden settlement command")

	var groups := _connected_groups(gs)
	var ids := groups.keys()
	ids.sort()
	_expect(ids.size() == 3, "scene fixture provides three isolated complete pairs")
	var all_nodes: Dictionary = gs.snack_nodes.duplicate()
	var started: Array = []
	var weighed: Array = []
	var old_bagging_nodes: Array = []
	var overlap_flight := [false]
	var led_at_start: Array = []
	var customer_feedback := [{"seen": false, "led": 0.0, "tags": 0}]
	st.group_weighed.connect(func(id: String, group: Array, price: Dictionary, _weight: int):
		weighed.append({"snack": id, "price": int(price["total"]), "msec": Time.get_ticks_msec()})
		for item in group:
			old_bagging_nodes.append(all_nodes[int(item["uid"])]))
	st.batch_started.connect(func(id: String, group: Array, duration: float, _flight: float, _stagger: float, combo: int):
		started.append({"snack": id, "combo": combo, "duration": duration, "msec": Time.get_ticks_msec()})
		led_at_start.append(gs.scale_view._led_value)
		if not old_bagging_nodes.is_empty():
			var old_flying := false
			for node in old_bagging_nodes:
				old_flying = old_flying or (is_instance_valid(node) and node.flying)
			var new_flying := true
			for item in group:
				new_flying = new_flying and all_nodes[int(item["uid"])].flying
			overlap_flight[0] = overlap_flight[0] or (old_flying and new_flying))
	st.customer_started.connect(func(index: int, _customer_id: String):
		if index == 2:
			customer_feedback[0] = {"seen": true, "led": gs.scale_view._led_value, "tags": gs._price_tags.size()})

	_expect(st.scan_clusters() == 3 and st.active_batch.size() == 2 and st.batch_queue.size() == 2, "one scan queues all ready groups in deterministic FIFO order")
	var max_tags := 0
	var guard := 0
	while st.customer_index == 1 and guard < 100:
		guard += 1
		max_tags = maxi(max_tags, gs._price_tags.size())
		await get_tree().create_timer(0.02).timeout
	_expect(weighed.size() == 3 and started.size() == 3, "all three scene batches finish without manual input")
	if weighed.size() == 3 and started.size() == 3:
		var expected_ids := ids.duplicate()
		expected_ids.sort_custom(func(left, right): return int(groups[left][0]["uid"]) < int(groups[right][0]["uid"]))
		_expect(started[0]["snack"] == expected_ids[0] and started[1]["snack"] == expected_ids[1] and started[2]["snack"] == expected_ids[2], "scene batches preserve UID FIFO order")
		_expect(started[0]["combo"] == 2 and started[1]["combo"] == 4 and started[2]["combo"] == 6, "each scene batch keeps its own combo snapshot")
		var second_gap := int(started[1]["msec"]) - int(started[0]["msec"])
		var third_gap := int(started[2]["msec"]) - int(started[1]["msec"])
		_expect(second_gap < 450 and third_gap < 450, "successive batches have no legacy 600ms scale cooldown")
	_expect(overlap_flight[0], "previous bagging flight overlaps the next batch's scale flight")
	_expect(max_tags >= 2, "multiple independent price tags coexist during continuous weighing")
	_expect(led_at_start.size() == 3 and float(led_at_start[1]) > 0.0 and float(led_at_start[2]) > 0.0, "LED starts later batches from its current nonzero value")
	_expect(bool(customer_feedback[0]["seen"]) and float(customer_feedback[0]["led"]) > 0.0 and int(customer_feedback[0]["tags"]) >= 1, "customer change preserves the previous LED tail and price tags")
	_expect(st.bagged_items == 6 and st.basket.remaining() == 6 and st.customer_index == 2, "the next customer starts only after all prior batches settle")
	await _shot("settlement_continuous")
	_finish(st)


func _check_core(db: ConfigDB) -> void:
	var st := _core_fixture(db)
	var started: Array = []
	var weighed: Array = []
	st.batch_started.connect(func(id: String, _items: Array, _duration: float, _flight: float, _stagger: float, combo: int):
		started.append({"snack": id, "combo": combo}))
	st.group_weighed.connect(func(id: String, _items: Array, price: Dictionary, _weight: int):
		weighed.append({"snack": id, "price": int(price["total"])}))
	st.scan_clusters()
	_expect(String(st.active_batch[0]["snack"]) == "a" and st.batch_queue.size() == 2, "core starts UID-first batch and queues the other two")
	_expect(st.active_combo == 2 and int(st.batch_queue[0]["combo"]) == 4 and int(st.batch_queue[1]["combo"]) == 6, "combo is accumulated per item and snapshotted per batch")
	var first_duration := st.batch_duration
	st.update(maxf(0.0, first_duration - 0.001))
	_expect(weighed.is_empty() and st.batch_phase == "flying", "arrival flight must finish before weighing")
	st.combo.combo = 99
	st.update(st.batch_timer)
	_expect(weighed.size() == 1 and started.size() == 2 and String(st.active_batch[0]["snack"]) == "b", "the exact flight-end update settles A and starts B with no idle cooldown")
	_expect(weighed.size() == 1 and int(weighed[0]["price"]) == int(ScoreSystem.batch_price(3, 2, 2)["total"]), "later live combo changes do not alter batch A pricing")
	st.update(st.batch_duration)
	_expect(weighed.size() == 2 and int(weighed[1]["price"]) == int(ScoreSystem.batch_price(3, 2, 4)["total"]), "batch B uses its own combo-4 price snapshot")

	var large := _core_fixture(db)
	large.scan_clusters()
	large.update(2.0)
	_expect(large.weighed_serial == 3 and large.bagged_items == 6 and large.state == "complete", "one large delta advances across every batch and completes the customer")
	_expect(large.batches_clear() and large.tray.is_empty(), "large-delta completion leaves no active or queued residue")

	var ignored := _core_fixture(db)
	ignored.basket.items = [_item(1, "a", Vector2(100, 100)), _item(2, "a", Vector2(238, 100)), _item(3, "a", Vector2(500, 100))]
	ignored.scan_clusters()
	_expect(ignored.batch_serial == 0 and ignored.batch_queue.is_empty(), "split same-kind components do not enter the FIFO")


func _core_fixture(db: ConfigDB) -> GameState:
	var st := GameState.new_game(db, 3, {}, 42)
	st.customers_total = 1
	st.total_items = 6
	st.basket.items = [
		_item(1, "a", Vector2(100, 100)), _item(2, "a", Vector2(238, 100)),
		_item(3, "b", Vector2(100, 400)), _item(4, "b", Vector2(238, 400)),
		_item(5, "c", Vector2(500, 650)), _item(6, "c", Vector2(638, 650)),
	]
	return st


func _item(uid: int, snack: String, point: Vector2) -> Dictionary:
	return {"uid": uid, "snack": snack, "size": 1, "blind": false, "revealed": true,
		"gift": false, "picked": false, "x": point.x, "y": point.y, "rot": 0.0, "layer": uid}


func _safe_seed(app, level_id: int) -> int:
	for candidate in range(42, 200):
		var generated := GameState.new_game(app.db, level_id, {}, candidate)
		if BasketModel.find_ready_clusters(generated.basket.items).is_empty():
			return candidate
	_expect(false, "a deterministic non-ready initial layout exists")
	return 42


func _connected_groups(gs: GameScreen) -> Dictionary:
	var groups := {}
	for item in gs.state.basket.items:
		if not groups.has(item["snack"]):
			groups[item["snack"]] = []
		groups[item["snack"]].append(item)
	var ids := groups.keys()
	ids.sort()
	var origins := [Vector2(100, 100), Vector2(100, 400), Vector2(500, 650)]
	for index in ids.size():
		var pair: Array = groups[ids[index]]
		for member in pair.size():
			var point: Vector2 = origins[index] + Vector2(member * 138.0, 0)
			var uid := int(pair[member]["uid"])
			pair[member]["rot"] = 0.0
			gs.snack_nodes[uid].rotation = 0.0
			gs.state.move_item(uid, point, true)
			gs.snack_nodes[uid].global_position = gs.table_view.to_global(point)
	gs._refresh_table_layers()
	return groups


func _wait_table_ready(gs: GameScreen) -> void:
	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 160:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(not gs._switching_customer and not is_instance_valid(gs.basket_view), "basket pour finishes before continuous-batch input")
	await get_tree().create_timer(0.08).timeout


func _double_click(pos: Vector2, native: bool = true) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	for click_index in 2:
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = pos
			event.global_position = pos
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = pressed
			event.double_click = native and click_index == 1
			Input.parse_input_event(event)
		await get_tree().process_frame


func _expect(cond: bool, message: String) -> void:
	_checks += 1
	print("ok - " + message if cond else "FAIL - " + message)
	if not cond:
		_failures.append(message)


func _finish(st: GameState) -> void:
	print("settlement mode smoke: checks=", _checks, " failed_checks=", _failures.size(), " state=", st.state)
	get_tree().quit(0 if _failures.is_empty() else 1)


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_tree().root.get_texture().get_image()
	img.save_png("res://docs/images/dev_%s.png" % tag)
	print("shot dev_%s.png" % tag)
