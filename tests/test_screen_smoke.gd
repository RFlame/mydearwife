extends Node
## 测试入口真实输入、巨大包装表现与测试局存档隔离聚焦验证。

var _checks := 0
var _failures: Array = []
var _pointer := Vector2.ZERO


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.25).timeout
	app.save = SaveData.new()
	app.save.coins = 123
	app.save.stars = {"1": 2}
	app.save.unlocked = 4
	app.save.discovered = {"chips": true}
	app.save.customers_discovered = {"existing": true}
	app.save.settings["preset"] = "challenge"
	app.db.set_preset("challenge")
	var save_before := _save_signature(app.save)
	var home: HomeScreen = app.current
	_expect(home.test_button.is_visible_in_tree(), "home exposes a visible gameplay-test entry")
	await _click(_center(home.test_button))
	_expect(app.current is TestScreen, "real home-button input opens the test screen")
	if not app.current is TestScreen:
		_finish()
		return
	var screen: TestScreen = app.current
	await _shot("test_lab_screen")
	var level_curve_ok := true
	for index in screen.level_option.get_item_count():
		var level_id := index + 1
		level_curve_ok = level_curve_ok and screen.level_option.get_item_text(index) == "第 %d 关 · %d 款" % [level_id, mini(level_id + 2, 10)]
	_expect(level_curve_ok, "test level options display the actual 3-through-10 kind curve")
	_expect(screen.random_check.text == "每款随机 1～10 件" and screen.quantity_slider.max_value == 10, "quantity controls advertise and enforce the new ten-item ceiling")

	await _choose_option(screen.level_option, 2)
	_expect(screen.current_options()["level_id"] == 3, "real option input selects level 3")
	await _choose_option(screen.preset_option, 2)
	_expect(screen.current_options()["preset"] == "challenge", "real option input selects challenge difficulty")
	await _choose_option(screen.preset_option, 1)
	_expect(screen.current_options()["preset"] == "standard", "difficulty can be changed back without touching player settings")
	await _click(_center(screen.random_check))
	_expect(not screen.current_options()["random_quantity"], "real check-button input switches from random to fixed quantities")
	await _click(_slider_point(screen.quantity_slider, 7))
	await _key(KEY_END)
	_expect(int(screen.current_options()["fixed_quantity"]) == 10 and screen.quantity_value.text == "10 件", "real slider input reaches the exact ten-item maximum")
	await _click(_slider_point(screen.quantity_slider, 7))
	_expect(int(screen.current_options()["fixed_quantity"]) == 7, "real slider input adjusts fixed per-kind quantity")
	await _click(_slider_point(screen.quantity_slider, 2))
	await _key(KEY_HOME)
	await _key(KEY_RIGHT)
	_expect(int(screen.current_options()["fixed_quantity"]) == 2, "fixed quantity returns to a small deterministic gameplay fixture")
	await _click(_slider_point(screen.size_slider, 1.75))
	_expect(is_equal_approx(float(screen.current_options()["package_scale"]), 1.75), "real slider input adjusts package scale")
	await _click(_slider_point(screen.size_slider, 1.5))
	_expect(is_equal_approx(float(screen.current_options()["package_scale"]), 1.5), "package scale returns to the new normal 1.5x default")
	await _choose_option(screen.giant_option, 0)
	_expect(int(screen.current_options()["giant_kinds"]) == 0, "test screen can disable giant packages")
	await _choose_option(screen.giant_option, 2)
	_expect(int(screen.current_options()["giant_kinds"]) == 2, "test screen can force two giant kinds for acceptance")

	var fixture := {"test_mode": true, "level_id": 3, "preset": "standard",
		"random_quantity": false, "fixed_quantity": 2, "package_scale": 1.5, "giant_kinds": 2}
	screen.initial_options["seed_value"] = _safe_seed(app, fixture)
	await _click(_center(screen.start_button))
	_expect(app.current is GameScreen, "real start-button input launches the configured test game")
	if not app.current is GameScreen:
		_finish()
		return
	var gs: GameScreen = app.current
	await _wait_table_ready(gs)
	var st: GameState = gs.state
	_expect(st.test_mode and st.level_id() == 3 and st.current_order_size() == st.basket.items.size(), "launched game preserves test mode, level, and exact current manifest size")
	if st.level_id() != 3:
		_finish()
		return
	_expect(is_equal_approx(float(st.cfg["package_scale"]), 1.5) and app.db.preset_name == "challenge", "test preset and scale apply without mutating shared difficulty")
	_expect(st.batch_serial == 0 and st.basket.remaining() == st.current_order_size(), "safe fixed seed leaves the enlarged test order ready for manual input")
	var groups := _kind_counts(st.basket.items)
	var giant_kinds := 0
	var giant_items := 0
	var normal_ok := true
	var giant_ok := true
	for snack_id in groups:
		var entries: Array = groups[snack_id]
		if BasketModel.is_giant(entries[0]):
			giant_kinds += 1
			giant_items += entries.size()
			giant_ok = giant_ok and entries.size() >= 1 and entries.size() <= 2
		else:
			normal_ok = normal_ok and entries.size() == 2
	_expect(giant_kinds == 2 and giant_items >= 2 and giant_items <= 4 and giant_ok, "launched order contains exactly two giant kinds with one or two items each")
	_expect(normal_ok, "all launched normal kinds use the selected fixed quantity")
	var geometry_ok := true
	var badge_ok := true
	var minimum_product_scale := INF
	var maximum_product_scale := -INF
	for item in st.basket.items:
		var node: SnackView = gs.snack_nodes[int(item["uid"])]
		var shape: RectangleShape2D = node._area.get_child(0).shape
		var expected_size := BasketModel.hit_size(item)
		geometry_ok = geometry_ok and (node._base_scale * 120.0).is_equal_approx(expected_size)
		geometry_ok = geometry_ok and node.sprite.scale.is_equal_approx(node._base_scale) and node._shadow.scale.is_equal_approx(node._base_scale)
		geometry_ok = geometry_ok and shape.size.is_equal_approx(expected_size)
		var product_scale := float(item.get("product_scale", 0.0))
		geometry_ok = geometry_ok and is_equal_approx(product_scale, float(app.db.snacks[String(item["snack"])]["product_scale"]))
		minimum_product_scale = minf(minimum_product_scale, product_scale)
		maximum_product_scale = maxf(maximum_product_scale, product_scale)
		if not BasketModel.is_giant(item):
			continue
		var has_badge := false
		for child in node.get_children():
			if child is Label and child.text == "巨":
				has_badge = true
		badge_ok = badge_ok and has_badge
	_expect(geometry_ok, "every snack SVG, shadow, product scale and precise collision shape equals the unified hit size")
	_expect(maximum_product_scale - minimum_product_scale > 0.05, "the launched order contains visibly different product-relative package sizes")
	_expect(badge_ok, "giant packages display a non-interactive giant badge without replacing snack identity")
	await _shot("test_lab_giant_scatter")
	_expect(_save_signature(app.save) == save_before, "entering and pouring the first test customer writes no progression or discovery")

	var spread := _spread_for_cluster(gs)
	if spread.is_empty():
		_finish()
		return
	var giant_uid := int(spread["giant_uid"])
	var giant_node: SnackView = gs.snack_nodes[giant_uid]
	var giant_center := gs.table_view.to_global(Vector2(300, 80))
	_expect(giant_node.contains_global_point(giant_center), "giant view hit test uses the same enlarged logical center as core")
	_expect(st.basket.remaining() == 6 and BasketModel.find_ready_clusters(st.basket.items).is_empty(), "isolated normal-pair fixtures begin with six items and no ready cluster")

	var click_pair: Array = spread["click_pair"]
	var click_uid := int(click_pair[0]["uid"])
	var click_origin := Vector2(float(click_pair[0]["x"]), float(click_pair[0]["y"]))
	await _click(gs.table_view.to_global(st.basket.exposed_point(click_uid)))
	_expect(gs._last_table_tap_outcome == "fly" and gs.snack_nodes[click_uid].flying and st.batch_serial == 0, "real normal-package click begins migration without weighing before arrival")
	var flying_item := st.basket.get_item(click_uid)
	_expect(Vector2(float(flying_item["x"]), float(flying_item["y"])) == click_origin, "test-lab click also keeps the authoritative origin during desktop flight")
	await get_tree().create_timer(0.08).timeout
	await _shot("test_lab_click_flight")
	var click_guard := 0
	while st.weighed_serial == 0 and click_guard < 100:
		click_guard += 1
		await get_tree().create_timer(0.02).timeout
	_expect(st.weighed_serial == 1 and st.bagged_items == 2 and st.basket.remaining() == 4, "test-lab click migration settles exactly its complete distant pair")

	var bounce_pair: Array = spread["bounce_pair"]
	var bounce_uid := int(bounce_pair[0]["uid"])
	var bounce_origin := Vector2(float(bounce_pair[0]["x"]), float(bounce_pair[0]["y"]))
	var bounce_node: SnackView = gs.snack_nodes[bounce_uid]
	var tap_before := bounce_node.tap_seq
	await _click(gs.table_view.to_global(st.basket.exposed_point(bounce_uid)))
	var bounce_after := st.basket.get_item(bounce_uid)
	_expect(gs._last_table_tap_outcome == "bounce" and bounce_node.tap_seq == tap_before + 1 and st.batch_serial == 1, "nearby disconnected same-kind packages retain the real bounce fallback")
	_expect(Vector2(float(bounce_after["x"]), float(bounce_after["y"])) == bounce_origin, "bounce fallback leaves the normal package at its authoritative position")

	var pair: Array = spread["pair"]
	var first: Dictionary = pair[0]
	var second: Dictionary = pair[1]
	var uid := int(first["uid"])
	var start_local := st.basket.exposed_point(uid)
	var origin := Vector2(float(first["x"]), float(first["y"]))
	var threshold_distance := (BasketModel.hit_size(first).x + BasketModel.hit_size(second).x) * 0.5 + BasketModel.CLUSTER_GAP
	var target := Vector2(float(second["x"]) - threshold_distance, float(second["y"]))
	var release_pointer := gs.table_view.to_global(target + start_local - origin)
	await _press(gs.table_view.to_global(start_local))
	await _move(release_pointer)
	_expect(gs._dragging and st.batch_serial == 1, "dragging a product-scaled normal package does not scan before release")
	await _release(release_pointer)
	_expect(st.active_batch.size() == 2 and String(st.active_batch[0]["snack"]) == String(first["snack"]), "real release at the product-sized 18px surface threshold settles the complete pair")
	var drag_guard := 0
	while st.weighed_serial < 2 and drag_guard < 100:
		drag_guard += 1
		await get_tree().create_timer(0.02).timeout
	_expect(st.weighed_serial == 2 and st.bagged_items == 4 and _save_signature(app.save) == save_before, "both automatic weighing flows update only the test session and never the formal save")

	await _complete_customer(gs)
	_expect(st.customer_index == 2 and _save_signature(app.save) == save_before, "customer transition does not discover the next test customer")
	await _wait_table_ready(gs)
	await _complete_customer(gs)
	var guard := 0
	while not app.current is ResultScreen and guard < 80:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(app.current is ResultScreen, "actual core completion signal reaches the test result page")
	if not app.current is ResultScreen:
		_finish()
		return
	var result_screen: ResultScreen = app.current
	var saved_result: Dictionary = result_screen.result.duplicate(true)
	_expect(bool(saved_result.get("test_mode", false)) and result_screen.next_button.text == "返回测试设置", "test completion is marked no-save and never offers formal next-level progression")
	_expect(_save_signature(app.save) == save_before, "test completion leaves coins, stars, unlocks, both collections, and settings unchanged")
	await _click(_center(result_screen.next_button))
	await get_tree().create_timer(0.05).timeout
	_expect(app.current is TestScreen and int(app.current.current_options()["fixed_quantity"]) == 2, "result return preserves the test configuration")

	# 直接重建同一结果页，仅聚焦“按此配置再试”的导航分支。
	app.show_result(3, saved_result)
	await get_tree().process_frame
	result_screen = app.current
	await _click(_center(result_screen.retry_button))
	_expect(app.current is GameScreen and app.current.test_mode and int(app.current.test_options["fixed_quantity"]) == 2, "result retry starts the same isolated test instead of a formal level")
	gs = app.current
	gs.state._fail("patience")
	await get_tree().process_frame
	var retry_failed := _find_button(gs, "再试一次")
	_expect(retry_failed != null, "failed test presents a retry action")
	if retry_failed:
		await _click(_center(retry_failed))
	_expect(app.current is GameScreen and app.current.test_mode and int(app.current.test_options["giant_kinds"]) == 2, "failure retry also retains every test option")
	gs = app.current
	var pause := _find_button(gs, "暂停")
	if pause:
		await _click(_center(pause))
	var exit := _find_button(gs, "返回店铺")
	if exit:
		await _click(_center(exit))
	_expect(app.current is TestScreen and is_equal_approx(float(app.current.current_options()["package_scale"]), 1.5), "pause exit returns to test settings with the original package scale")
	_expect(_save_signature(app.save) == save_before, "all test retry and exit paths keep the original save byte-for-byte in memory")
	_finish()


func _safe_seed(app, options: Dictionary) -> int:
	for candidate in range(42, 200):
		var generated := GameState.new_game(app.db, 3, {}, candidate, options)
		if BasketModel.find_ready_clusters(generated.basket.items).is_empty():
			return candidate
	_expect(false, "a deterministic non-ready enlarged test fixture exists")
	return 42


func _spread_for_cluster(gs: GameScreen) -> Dictionary:
	var groups := _kind_counts(gs.state.basket.items)
	var normal_ids: Array = []
	var giant_uid := -1
	for snack_id in groups:
		if BasketModel.is_giant(groups[snack_id][0]):
			if giant_uid < 0:
				giant_uid = int(groups[snack_id][0]["uid"])
		else:
			normal_ids.append(snack_id)
	normal_ids.sort()
	_expect(normal_ids.size() == 3 and giant_uid > 0, "level 3 with two giant kinds provides three isolated normal pairs")
	if normal_ids.size() != 3 or giant_uid < 0:
		return {}
	var click_pair: Array = groups[normal_ids[0]]
	var bounce_pair: Array = groups[normal_ids[1]]
	var drag_pair: Array = groups[normal_ids[2]]

	# 巨大款已在上方检查图片与热区；此夹具暂时拣出，只隔离三种普通款交互。
	for item in gs.state.basket.items:
		var uid := int(item["uid"])
		if BasketModel.is_giant(item):
			gs.state.basket.pick(uid)
			gs.snack_nodes[uid].hide()
			continue
		item["rot"] = 0.0
		gs.snack_nodes[uid].rotation = 0.0

	var placements := {
		int(click_pair[0]["uid"]): Vector2(140, 160),
		int(click_pair[1]["uid"]): Vector2(140, 560),
		int(bounce_pair[0]["uid"]): Vector2(400, 360),
		int(drag_pair[0]["uid"]): Vector2(720, 420),
		int(drag_pair[1]["uid"]): Vector2(720, 700),
	}
	var nearby_distance := minf(214.0, (BasketModel.hit_size(bounce_pair[0]).y + BasketModel.hit_size(bounce_pair[1]).y) * 0.5 + 20.0)
	placements[int(bounce_pair[1]["uid"])] = Vector2(400, 360) + Vector2(0, nearby_distance)
	for item in [click_pair[0], click_pair[1], bounce_pair[0], bounce_pair[1], drag_pair[0], drag_pair[1]]:
		var uid := int(item["uid"])
		gs.state.move_item(uid, placements[uid], true)
		gs.snack_nodes[uid].global_position = gs.table_view.to_global(Vector2(float(item["x"]), float(item["y"])))
	# 保留一个可见巨大节点用于统一中心热区检查，但不参与上述核心夹具。
	var giant_node: SnackView = gs.snack_nodes[giant_uid]
	giant_node.global_position = gs.table_view.to_global(Vector2(300, 80))
	gs._refresh_table_layers()
	return {"click_pair": click_pair, "bounce_pair": bounce_pair, "pair": drag_pair, "giant_uid": giant_uid}


func _complete_customer(gs: GameScreen) -> void:
	for item in gs.state.basket.items:
		item["picked"] = true
	gs.state.batch_queue.clear()
	gs.state.active_batch.clear()
	gs.state.tray.clear()
	gs.state.batch_phase = "idle"
	gs.state._check_end()
	await get_tree().process_frame


func _kind_counts(items: Array) -> Dictionary:
	var result := {}
	for item in items:
		var snack_id := String(item["snack"])
		if not result.has(snack_id):
			result[snack_id] = []
		result[snack_id].append(item)
	return result


func _save_signature(save: SaveData) -> String:
	return JSON.stringify([save.coins, save.stars, save.unlocked, save.upgrades,
		save.discovered, save.customers_discovered, save.settings])


func _center(control: Control) -> Vector2:
	return control.get_global_rect().get_center()


func _slider_point(slider: HSlider, value: float) -> Vector2:
	var rect := slider.get_global_rect()
	var ratio := (value - slider.min_value) / (slider.max_value - slider.min_value)
	return rect.position + Vector2(rect.size.x * ratio, rect.size.y * 0.5)


func _choose_option(option: OptionButton, index: int) -> void:
	await _click(_center(option))
	var popup := option.get_popup()
	var popup_guard := 0
	while not popup.visible and popup_guard < 12:
		popup_guard += 1
		await get_tree().process_frame
	_expect(popup.visible, "option button opens its real popup menu")
	if not popup.visible:
		return
	var point := Vector2(popup.position) + Vector2(popup.size.x * 0.5,
		popup.size.y * (float(index) + 0.5) / float(popup.get_item_count()))
	await _click(point)
	await get_tree().create_timer(0.04).timeout


func _key(keycode: Key) -> void:
	var press := InputEventKey.new()
	press.keycode = keycode
	press.pressed = true
	Input.parse_input_event(press)
	await get_tree().process_frame
	var release := InputEventKey.new()
	release.keycode = keycode
	release.pressed = false
	Input.parse_input_event(release)
	await get_tree().process_frame


func _click(point: Vector2) -> void:
	await _press(point)
	await _release(point)


func _press(point: Vector2) -> void:
	_pointer = point
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame


func _move(end: Vector2) -> void:
	var start := _pointer
	for index in range(1, 9):
		var point := start.lerp(end, float(index) / 8.0)
		_pointer = point
		var motion := InputEventMouseMotion.new()
		motion.position = point
		motion.global_position = point
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(motion)
		await get_tree().create_timer(0.025).timeout


func _release(point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame


func _wait_table_ready(gs: GameScreen) -> void:
	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 240:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(not gs._switching_customer and not is_instance_valid(gs.basket_view), "basket pour finishes before test input")
	await get_tree().create_timer(0.08).timeout


func _find_button(node: Node, text: String) -> Button:
	if node is Button and node.text == text and node.is_visible_in_tree():
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found:
			return found
	return null


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_tree().root.get_texture().get_image()
	image.save_png("res://docs/images/dev_%s.png" % tag)
	print("shot dev_%s.png" % tag)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	print("ok - " + message if condition else "FAIL - " + message)
	if not condition:
		_failures.append(message)


func _finish() -> void:
	print("test screen smoke: checks=", _checks, " failed_checks=", _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)
