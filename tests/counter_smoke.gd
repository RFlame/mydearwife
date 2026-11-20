extends Node
## 本轮聚焦验证：godot --path . tests/counter_smoke.tscn
## 只覆盖左侧篮口撒落、底部过道及受影响的自由拖动/单击输入。

var _failures: Array = []
var _checks := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.25).timeout
	var seed_value := _safe_seed(app, 2)
	app.start_test({"level_id": 2, "preset": "standard", "random_quantity": false,
		"fixed_quantity": 2, "package_scale": 1.5, "giant_kinds": 0, "seed_value": seed_value})
	var gs: GameScreen = app.current
	var st: GameState = gs.state
	_expect(gs._basket_phase == "arrive", "basket starts in arrive phase")
	_expect(gs.basket_view.project_basket_point(Vector2(580, 400)).x < 0 and absf(gs.basket_view.position.y - GameScreen.BASKET_STAGE_PIVOT.y) < 0.1, "basket enters horizontally from fully outside the left screen edge")
	_expect(_table_parent_count(gs) == 0, "no snack leaves basket during arrival")

	if not await _phase(gs, "lift"):
		_finish(st)
		return
	await get_tree().create_timer(0.16).timeout
	_expect(gs._switching_customer and _table_parent_count(gs) == 0, "lift keeps every snack inside the picked-up basket")
	_expect(gs.cashier_view.action_seq > 0, "lifting basket triggers cashier reach animation")
	_expect(gs.basket_view.position.distance_to(GameScreen.BASKET_STAGE_PIVOT) > 30.0, "basket physically lifts from its left-edge staging position")
	_expect(absf(gs.basket_view.rotation) < 0.001 and absf(gs.basket_view.side_tilt - BasketView.MOUTH_TILT) < 0.001, "basket stays parallel to the left table edge while lifting")
	await _shot("counter_lift")

	if not await _phase(gs, "pour"):
		_finish(st)
		return
	await get_tree().create_timer(0.50).timeout
	_expect(gs._pouring and is_instance_valid(gs.basket_view), "basket stays at the left table edge while dispensing snacks")
	_expect(absf(gs.basket_view.rotation) < 0.001 and absf(gs.basket_view.side_tilt - BasketView.MOUTH_TILT) < 0.001 and gs.basket_view.basket_root.transform.basis.is_equal_approx(Basis(Vector3.UP, BasketView.MOUTH_TILT)), "basket and its 3D root never rotate during pouring")
	_expect(gs.basket_view.position.distance_to(GameScreen.BASKET_LIFT_PIVOT) < 0.1, "upright basket keeps its fixed pouring position")
	var mouth: Vector2 = gs.basket_view.mouth_global_position()
	var safe := Rect2(gs.table_view.to_global(BasketModel.TABLE_BOUNDS.position), BasketModel.TABLE_BOUNDS.size * GameScreen.BASKET_SCALE)
	_expect(safe.grow(45.0).has_point(mouth) and mouth.x < safe.get_center().x, "visible basket mouth faces the table from its left side: %s" % mouth)
	_expect(mouth.x < gs.scale_view.global_position.x, "pouring basket stays left of the integrated scale")
	_expect(_table_parent_count(gs) > 0, "snacks spill from the upright basket mouth")
	await _shot("counter_pour")

	var spill_uid := await _first_spilled_uid(gs)
	_expect(spill_uid > 0, "pour phase releases a real snack")
	if spill_uid <= 0:
		_finish(st)
		return
	var basket_origin: Vector2 = gs.basket_view.projected_release_position(spill_uid)
	_expect(gs._last_spill_origin.distance_to(basket_origin) < 0.1, "snack starts at its deterministic position inside the basket mouth: uid=%d origin=%s expected=%s" % [spill_uid, gs._last_spill_origin, basket_origin])
	_expect(safe.grow(45.0).has_point(basket_origin) and basket_origin.x < safe.get_center().x, "snack release origin is over the left table rather than the basket bottom")

	var remaining_locked := st.basket.remaining()
	var clock_locked := st.clock.left
	var locked_item: Dictionary = st.basket.top_items()[0]
	var locked_point := gs.table_view.to_global(BasketView.home_position(locked_item))
	await _click(locked_point)
	_expect(st.basket.remaining() == remaining_locked and st.tray.is_empty() and gs._drag_uid == -1, "real table input stays locked during pouring")
	await get_tree().create_timer(0.12).timeout
	_expect(is_equal_approx(st.clock.left, clock_locked), "patience clock stays paused during the pour")
	var arc_visible := false
	for uid in gs.snack_nodes:
		var node: SnackView = gs.snack_nodes[uid]
		if node.get_parent() == gs.table_view and node.flying and node.sprite.position.y < -10.0:
			arc_visible = true
	_expect(arc_visible, "released snacks visibly toss and scatter above the table")

	var release_guard := 0
	while _table_parent_count(gs) < st.basket.items.size() and release_guard < 100:
		release_guard += 1
		await get_tree().create_timer(0.02).timeout
	_expect(_table_parent_count(gs) == st.basket.items.size() and _flying_count(gs) > 0, "the upright basket waits for the last released snacks to land")
	_expect(gs.basket_view.basket_root.transform.basis.is_equal_approx(Basis(Vector3.UP, BasketView.MOUTH_TILT)), "basket keeps its fixed 90-degree pose through the final release")

	if not await _phase(gs, "leave"):
		_finish(st)
		return
	_expect(_table_parent_count(gs) == st.basket.items.size() and _flying_count(gs) == 0, "every snack lands before the empty basket leaves")
	_expect(is_instance_valid(gs.basket_view) and gs._switching_customer, "empty upright basket remains for its exit fade")
	_expect(absf(gs.basket_view.rotation) < 0.001 and absf(gs.basket_view.side_tilt - BasketView.MOUTH_TILT) < 0.001 and gs.basket_view.basket_root.transform.basis.is_equal_approx(Basis(Vector3.UP, BasketView.MOUTH_TILT)), "empty basket stays at its original angle before disappearing")
	await get_tree().create_timer(0.05).timeout
	await _shot("counter_leave")

	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 100:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(gs._basket_phase == "done" and not gs._switching_customer and not is_instance_valid(gs.basket_view), "empty basket disappears before input unlocks")
	_expect(_table_parent_count(gs) == 6 and _flying_count(gs) == 0 and st.basket.remaining() == 6, "all 6 snacks remain on the table after pouring")
	var scales_restored := true
	for uid in gs.snack_nodes:
		var node: SnackView = gs.snack_nodes[uid]
		scales_restored = scales_restored and node.scale.is_equal_approx(Vector2.ONE)
	_expect(scales_restored, "poured snacks restore standard table scale and matching hit areas")

	_spread_pairs(gs)
	_check_layout(gs)
	_check_generated_bounds(app)
	_check_drag_aisle_boundary(st)
	await _shot("counter_ready")
	var idle_before: float = gs.cashier_view.rig.position.y
	await get_tree().create_timer(0.22).timeout
	_expect(absf(gs.cashier_view.rig.position.y - idle_before) > 0.05, "cashier idle animation produces visible breathing motion")

	# 使用位于 (130,180) 的确定夹具，单击不聚堆，拖到右下也只改变位置。
	var pick_item: Dictionary = {}
	for candidate in st.basket.top_items():
		if Vector2(float(candidate["x"]), float(candidate["y"])).distance_to(Vector2(130, 180)) < 0.1:
			pick_item = candidate
			break
	_expect(not pick_item.is_empty(), "the spread fixture exposes its upper-left snack")
	if pick_item.is_empty():
		_finish(st)
		return
	var pick_point := _exposed_point(gs, int(pick_item["uid"]))
	var action_before: int = gs.cashier_view.action_seq
	var tap_before: int = gs.snack_nodes[int(pick_item["uid"])].tap_seq
	await _click(pick_point)
	_expect(st.tray.is_empty() and st.basket.remaining() == 6 and st.batch_serial == 0, "real table click only bounces without gathering or weighing")
	_expect(gs.snack_nodes[int(pick_item["uid"])].tap_seq == tap_before + 1, "real table click triggers the local hop")
	_expect(gs.cashier_view.action_seq == action_before, "table bounce does not trigger cashier sorting")

	await _drag(pick_point, gs.table_view.to_global(Vector2(820, 740)))
	await get_tree().create_timer(0.10).timeout
	var moved := st.basket.get_item(int(pick_item["uid"]))
	_expect(float(moved["x"]) > BasketModel.TABLE_BOUNDS.end.x and float(moved["y"]) > 600.0, "real drag places a snack on the lower-right tabletop beyond the legacy left safe area")
	_expect(_item_corners_inside(moved, BasketModel.DRAG_BOUNDS), "full-counter real drag keeps every rotated corner above the cashier aisle")
	_expect(st.basket.remaining() == 6 and st.bagged_items == 0 and st.active_batch.is_empty(), "an incomplete kind stays on the table after free placement")
	_expect(gs._pos_mode_label.text == "聚堆自动称重", "POS remains a static automatic-clustering label")
	await _double_click(Vector2(690, 1160))
	_expect(st.batch_serial == 0 and st.bagged_items == 0, "real screen double click does not settle incomplete snacks")
	await _shot("counter_free_drag")
	_finish(st)


func _safe_seed(app, level_id: int) -> int:
	for candidate in range(42, 200):
		var generated := GameState.new_game(app.db, level_id, {}, candidate, {"test_mode": true,
			"preset": "standard", "random_quantity": false, "fixed_quantity": 2,
			"package_scale": 1.5, "giant_kinds": 0})
		if BasketModel.find_ready_clusters(generated.basket.items).is_empty():
			return candidate
	_expect(false, "a deterministic non-ready initial layout exists")
	return 42


func _spread_pairs(gs: GameScreen) -> void:
	var groups := {}
	for item in gs.state.basket.items:
		if not groups.has(item["snack"]):
			groups[item["snack"]] = []
		groups[item["snack"]].append(item)
	var ids := groups.keys()
	ids.sort()
	var points := [Vector2(130, 180), Vector2(130, 560), Vector2(520, 400), Vector2(520, 680), Vector2(800, 400), Vector2(800, 680)]
	var index := 0
	for snack_id in ids:
		for item in groups[snack_id]:
			var uid := int(item["uid"])
			item["rot"] = 0.0
			gs.snack_nodes[uid].rotation = 0.0
			gs.state.move_item(uid, points[index], true)
			gs.snack_nodes[uid].global_position = gs.table_view.to_global(points[index])
			index += 1
	gs._refresh_table_layers()


func _check_layout(gs: GameScreen) -> void:
	var pos := gs.pos_view.get_global_rect()
	var scale := Rect2(gs.scale_view.global_position, Vector2(250, 350))
	var stand := gs.device_stand.get_global_rect()
	var queue := gs._queue_box.get_global_rect()
	var customer_info := Rect2(gs.customer_view.global_position + Vector2(185, 10), Vector2(270, 128))
	var cashier := gs._cashier_zone.get_global_rect()
	var safe := Rect2(gs.table_view.to_global(BasketModel.TABLE_BOUNDS.position), BasketModel.TABLE_BOUNDS.size * GameScreen.BASKET_SCALE)
	_expect(pos.position == GameScreen.POS_HOME and scale.position == GameScreen.SCALE_HOME, "POS and weighing platform use the new compact positions")
	_expect(is_equal_approx(pos.get_center().x, scale.get_center().x), "POS and weighing platform are coaxial")
	_expect(is_equal_approx(scale.position.y - pos.end.y, 12.0), "compact POS-to-platform gap is 12 pixels")
	_expect(is_equal_approx(stand.get_center().x, pos.get_center().x) and stand.position.y <= pos.end.y and stand.end.y >= scale.position.y, "short stand visibly bridges POS and weighing platform")
	_expect(not pos.intersects(queue) and not pos.intersects(customer_info), "POS does not overlap queue or narrowed customer details")
	_expect(is_equal_approx(gs.counter_view.get_global_rect().end.y, 1024.0), "countertop ends exactly above the bottom fifth")
	_expect(cashier == Rect2(0, 1024, 720, 256) and gs.aisle_view.get_global_rect() == cashier, "full-width cashier aisle reserves exactly 256 pixels")
	_expect(is_equal_approx(safe.end.y, cashier.position.y) and safe.end.y <= 1024.1, "sorting safe area stops at the aisle boundary")
	_expect(is_equal_approx(gs.cashier_view.position.x, 360.0) and is_equal_approx(cashier.get_center().x, 360.0), "cashier and aisle are centered on the screen")
	var body := Rect2(gs.cashier_view.global_position - Vector2(90, 110), Vector2(180, 220))
	_expect(cashier.encloses(body), "top-down cashier body stands fully inside the bottom aisle")


func _check_generated_bounds(app) -> void:
	# 仅生成并检查落点，不执行全关卡自动通关；三种子覆盖新的散布中心与第 2 关纵向范围。
	for level in app.db.levels:
		var all_safe := true
		for sample_seed in [42, 99, 2026]:
			var generated: GameState = GameState.new_game(app.db, int(level["id"]), {}, sample_seed, {
				"test_mode": true, "preset": "standard", "random_quantity": false,
				"fixed_quantity": 2, "package_scale": 1.5, "giant_kinds": 2})
			for item in generated.basket.items:
				all_safe = all_safe and _item_corners_inside(item)
		_expect(all_safe, "level %d generated corners stay above the cashier aisle for three seeds" % int(level["id"]))


func _check_drag_aisle_boundary(st: GameState) -> void:
	var edge_item: Dictionary = st.basket.items[0].duplicate(true)
	edge_item["size"] = 2
	edge_item["rot"] = 27.0
	var model := BasketModel.new()
	model.items = [edge_item]
	model.move_item(int(edge_item["uid"]), Vector2(300, 1999), true)
	_expect(_item_corners_inside(model.items[0], BasketModel.DRAG_BOUNDS), "large rotated snack cannot be dragged into the cashier aisle")
	model.move_item(int(edge_item["uid"]), Vector2(840, 680), true)
	_expect(float(model.items[0]["x"]) > BasketModel.TABLE_BOUNDS.end.x, "core drag permits the newly available right-hand tabletop")
	_expect(_item_corners_inside(model.items[0], BasketModel.DRAG_BOUNDS), "right-hand drag target keeps the whole package on the countertop")
	model.move_item(int(edge_item["uid"]), Vector2(740, 100), true)
	_expect(_item_corners_outside_scale(model.items[0]), "dragging onto the scale pushes the whole package outside the weighing platform")


func _item_corners_outside_scale(item: Dictionary) -> bool:
	var center := Vector2(float(item["x"]), float(item["y"]))
	var half := BasketModel.hit_size(item) * 0.5
	var angle := deg_to_rad(float(item["rot"]))
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			var corner: Vector2 = center + Vector2(half.x * sx, half.y * sy).rotated(angle)
			if BasketModel.DRAG_SCALE_BLOCK.has_point(corner):
				return false
	return true


func _item_corners_inside(item: Dictionary, bounds: Rect2 = BasketModel.TABLE_BOUNDS) -> bool:
	var center := Vector2(float(item["x"]), float(item["y"]))
	var half := BasketModel.hit_size(item) * 0.5
	var angle := deg_to_rad(float(item["rot"]))
	var safe := bounds.grow(0.02)
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			var corner: Vector2 = center + Vector2(half.x * sx, half.y * sy).rotated(angle)
			if not safe.has_point(corner):
				return false
	return true


func _phase(gs: GameScreen, wanted: String) -> bool:
	var guard := 0
	while gs._basket_phase != wanted and guard < 150:
		guard += 1
		await get_tree().create_timer(0.02).timeout
	_expect(gs._basket_phase == wanted, "basket reaches %s phase" % wanted)
	return gs._basket_phase == wanted


func _first_spilled_uid(gs: GameScreen) -> int:
	var guard := 0
	while guard < 100:
		var found := -1
		for uid in gs.snack_nodes:
			var node: SnackView = gs.snack_nodes[uid]
			if node.get_parent() == gs.table_view:
				found = int(uid)
		if found > 0:
			return found
		guard += 1
		await get_tree().process_frame
	return -1


func _table_parent_count(gs: GameScreen) -> int:
	var count := 0
	for uid in gs.snack_nodes:
		var node: SnackView = gs.snack_nodes[uid]
		if node.get_parent() == gs.table_view:
			count += 1
	return count


func _flying_count(gs: GameScreen) -> int:
	var count := 0
	for uid in gs.snack_nodes:
		var node: SnackView = gs.snack_nodes[uid]
		if node.flying:
			count += 1
	return count


func _exposed_point(gs: GameScreen, uid: int) -> Vector2:
	var st: GameState = gs.state
	var item := st.basket.get_item(uid)
	if item.is_empty() or not st.basket.can_pick(uid):
		return Vector2(-1, -1)
	var size := BasketModel.hit_size(item)
	var center := BasketView.home_position(item)
	var rotation := deg_to_rad(float(item["rot"]))
	for gy in 9:
		for gx in 9:
			var local := -size * 0.5 + size * Vector2((gx + 0.5) / 9.0, (gy + 0.5) / 9.0)
			var point := center + local.rotated(rotation)
			if st.basket.hit_test(point) == uid:
				return gs.table_view.to_global(point)
	return Vector2(-1, -1)


func _click(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = pos
		event.global_position = pos
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
	await get_tree().process_frame


func _drag(start: Vector2, end: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = start
	motion.global_position = start
	Input.parse_input_event(motion)
	var pressed := InputEventMouseButton.new()
	pressed.position = start
	pressed.global_position = start
	pressed.button_index = MOUSE_BUTTON_LEFT
	pressed.pressed = true
	Input.parse_input_event(pressed)
	await get_tree().process_frame
	for i in range(1, 9):
		var point := start.lerp(end, float(i) / 8.0)
		var move := InputEventMouseMotion.new()
		move.position = point
		move.global_position = point
		move.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(move)
		await get_tree().create_timer(0.025).timeout
	var released := InputEventMouseButton.new()
	released.position = end
	released.global_position = end
	released.button_index = MOUSE_BUTTON_LEFT
	released.pressed = false
	Input.parse_input_event(released)
	await get_tree().process_frame


func _double_click(pos: Vector2) -> void:
	for click_index in 2:
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = pos
			event.global_position = pos
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = pressed
			event.double_click = click_index == 1
			Input.parse_input_event(event)
		await get_tree().process_frame


func _expect(cond: bool, message: String) -> void:
	_checks += 1
	print("ok - " + message if cond else "FAIL - " + message)
	if not cond:
		_failures.append(message)


func _finish(st: GameState) -> void:
	print("counter smoke: phase checks=", _checks, " failed_checks=", _failures.size(), " state=", st.state)
	get_tree().quit(0 if _failures.is_empty() else 1)


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_tree().root.get_texture().get_image()
	img.save_png("res://docs/images/dev_%s.png" % tag)
	print("shot dev_%s.png" % tag)
