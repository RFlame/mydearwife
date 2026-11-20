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

	await _choose_option(screen.level_option, 2)
	_expect(screen.current_options()["level_id"] == 3, "real option input selects level 3")
	await _choose_option(screen.preset_option, 2)
	_expect(screen.current_options()["preset"] == "challenge", "real option input selects challenge difficulty")
	await _choose_option(screen.preset_option, 1)
	_expect(screen.current_options()["preset"] == "standard", "difficulty can be changed back without touching player settings")
	await _click(_center(screen.random_check))
	_expect(not screen.current_options()["random_quantity"], "real check-button input switches from random to fixed quantities")
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
	_expect(normal_ok, "launched normal kinds both use the selected fixed quantity")
	var geometry_ok := true
	var badge_ok := true
	for item in st.basket.items:
		if not BasketModel.is_giant(item):
			continue
		var node: SnackView = gs.snack_nodes[int(item["uid"])]
		var shape: RectangleShape2D = node._area.get_child(0).shape
		geometry_ok = geometry_ok and node._base_scale * 120.0 == BasketModel.hit_size(item)
		geometry_ok = geometry_ok and shape.size == BasketModel.hit_size(item)
		var has_badge := false
		for child in node.get_children():
			if child is Label and child.text == "巨":
				has_badge = true
		badge_ok = badge_ok and has_badge
	_expect(geometry_ok, "giant SVG dimensions and precise collision shape both equal the unified hit size")
	_expect(badge_ok, "giant packages display a non-interactive giant badge without replacing snack identity")
	await _shot("test_lab_giant_scatter")
	_expect(_save_signature(app.save) == save_before, "entering and pouring the first test customer writes no progression or discovery")

	var spread := _spread_for_cluster(gs)
	var giant_uid := int(spread["giant_uid"])
	var giant_point := st.basket.exposed_point(giant_uid)
	_expect(giant_point.x >= 0, "top-layer giant exposes a real input point")
	var giant_node: SnackView = gs.snack_nodes[giant_uid]
	var giant_global := gs.table_view.to_global(giant_point)
	_expect(giant_node.contains_global_point(giant_global), "giant view hit test contains the same exposed logical point as core")
	var tap_before := giant_node.tap_seq
	await _click(giant_global)
	_expect(giant_node.tap_seq == tap_before + 1 and st.batch_serial == 0, "real giant-package click uses the enlarged heat area without auto-settling")

	var pair: Array = spread["pair"]
	var first: Dictionary = pair[0]
	var second: Dictionary = pair[1]
	var uid := int(first["uid"])
	var start_local := st.basket.exposed_point(uid)
	var origin := Vector2(float(first["x"]), float(first["y"]))
	var target := Vector2(float(second["x"]) - 198.0, float(second["y"]))
	var release_pointer := gs.table_view.to_global(target + start_local - origin)
	await _press(gs.table_view.to_global(start_local))
	await _move(release_pointer)
	_expect(gs._dragging and st.batch_serial == 0, "dragging an enlarged normal package does not scan before release")
	await _release(release_pointer)
	_expect(st.active_batch.size() == 2 and String(st.active_batch[0]["snack"]) == String(first["snack"]), "real release at the 18px surface threshold settles the complete enlarged pair")
	await get_tree().create_timer(0.45).timeout
	_expect(st.bagged_items == 2 and _save_signature(app.save) == save_before, "automatic weighing updates only the test session and never the formal save")

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
	for snack_id in groups:
		if not BasketModel.is_giant(groups[snack_id][0]):
			normal_ids.append(snack_id)
	normal_ids.sort()
	var pair: Array = groups[normal_ids[0]]
	var selected := {int(pair[0]["uid"]): true, int(pair[1]["uid"]): true}
	var giant_uid := -1
	for item in gs.state.basket.items:
		if BasketModel.is_giant(item) and giant_uid < 0:
			giant_uid = int(item["uid"])
	for item in gs.state.basket.items:
		var uid := int(item["uid"])
		var point := Vector2(300, 260)
		if selected.has(uid):
			point = Vector2(140, 700) if uid == int(pair[0]["uid"]) else Vector2(420, 700)
		item["x"] = point.x
		item["y"] = point.y
		item["rot"] = 0.0
		item["layer"] = 500 if uid == giant_uid else uid
		var node: SnackView = gs.snack_nodes[uid]
		node.rotation = 0.0
		node.global_position = gs.table_view.to_global(point)
		node.z_index = int(item["layer"]) * 2 + 2
	return {"pair": pair, "giant_uid": giant_uid}


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
	await get_tree().process_frame
	var popup := option.get_popup()
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
