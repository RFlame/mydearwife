extends Node
## 真实输入回归：godot --path . tests/input_smoke.tscn
## 不调用 core.pick/return_item，直接注入鼠标事件验证旋转热区、遮挡、退货和 POS。

var _failures: Array = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.3).timeout
	# 仅在测试内存中临时解锁，分段检查全部 40 款包装；随后恢复，不写存档。
	var saved_discovered: Dictionary = app.save.discovered.duplicate()
	for snack_id in app.db.snacks:
		app.save.discovered[snack_id] = true
	app.show_collection()
	await get_tree().create_timer(0.35).timeout
	var collection_scroll: ScrollContainer = app.current.get_node("SnackScroll")
	var collection_tags := ["collection_top", "collection_1", "collection_2", "collection_3", "collection_4", "collection_bottom"]
	for step in collection_tags.size():
		var max_scroll := collection_scroll.get_v_scroll_bar().max_value
		collection_scroll.scroll_vertical = int(max_scroll * float(step) / float(collection_tags.size() - 1))
		await get_tree().create_timer(0.15).timeout
		await _shot(collection_tags[step])
	_expect(collection_scroll.get_v_scroll_bar().max_value > collection_scroll.size.y, "collection scroll contains all catalog categories")
	app.save.discovered = saved_discovered

	# 主页真实点击进入顾客图鉴，分别检查未发现剪影与全部 12 位角色。
	var saved_customers: Dictionary = app.save.customers_discovered.duplicate()
	app.save.customers_discovered.clear()
	app.show_home()
	await get_tree().create_timer(0.25).timeout
	await _click(Vector2(442, 1166))
	await get_tree().create_timer(0.3).timeout
	_expect(app.current is CustomerCollectionScreen, "home button opens customer collection")
	var customer_page: CustomerCollectionScreen = app.current
	_expect(customer_page.cards.size() == 12, "customer collection lists all 12 profiles")
	await _shot("customers_locked")
	for customer_id in app.db.customers:
		app.save.customers_discovered[customer_id] = true
	app.show_customers()
	await get_tree().create_timer(0.3).timeout
	customer_page = app.current
	var customer_scroll: ScrollContainer = customer_page.get_node("CustomerScroll")
	for step in 3:
		customer_scroll.scroll_vertical = int(customer_scroll.get_v_scroll_bar().max_value * float(step) / 2.0)
		await get_tree().create_timer(0.15).timeout
		await _shot("customers_%d" % step)
	_expect(customer_scroll.get_v_scroll_bar().max_value > customer_scroll.size.y, "customer collection scrolls through every character")
	app.save.customers_discovered = saved_customers

	app.start_level(2, 42)
	var gs: GameScreen = app.current
	var initial_pour_guard := 0
	while gs._basket_phase != "pour" and initial_pour_guard < 60:
		initial_pour_guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(gs._basket_phase == "pour", "basket is positioned before mouth pouring starts")
	await get_tree().create_timer(0.42).timeout
	_expect(gs._pouring and is_instance_valid(gs.basket_view) and absf(gs.basket_view.side_tilt - BasketView.MOUTH_TILT) < 0.001 and gs.basket_view.basket_root.transform.basis.is_equal_approx(Basis(Vector3.UP, BasketView.MOUTH_TILT)), "basket pours from a fixed 90-degree left-side mouth without flipping")
	await _shot("basket_pour")
	await _wait_table_ready(gs)
	_expect(not is_instance_valid(gs.basket_view), "empty basket is released after pouring")
	_expect(gs.scale_view.position == Vector2(452, 282), "weighing platform keeps its elevated position")
	_expect(gs.pos_view.position == Vector2(480, 138), "POS sits coaxially above the platform")
	_expect(gs._queue_box.position == Vector2(190, 250), "queue stays below narrowed customer details")
	_expect(is_equal_approx(gs.pos_view.get_global_rect().get_center().x, gs.scale_view.global_position.x + 125.0), "integrated POS and platform share a center axis")
	_expect(gs.device_stand.get_global_rect().position.y <= gs.pos_view.get_global_rect().end.y and gs.device_stand.get_global_rect().end.y >= gs.scale_view.global_position.y, "short stand connects POS and platform")
	_expect(gs._cashier_zone.get_global_rect() == Rect2(0, 1024, 720, 256) and gs.cashier_view.position.x == 360, "cashier stands in the centered full-width aisle")
	_expect(TrayView.PILE_CENTER == Vector2(125, 124), "snack pile is centered on cropped platform")
	_expect(not gs.pos_view.get_global_rect().intersects(Rect2(gs.scale_view.global_position, Vector2(250, 350))), "POS and weighing platform do not overlap")
	_expect(gs._bag_bar.get_global_rect().position.y < 100 and gs._bag_label.text == "已称重 0 / 300 件 · 0 批", "weighing progress moves into top HUD")
	_expect(gs._combo_badge.get_global_rect().position.x > 500 and gs._combo_badge.get_global_rect().position.y < 60, "animated combo badge sits at top right")
	_expect(_legacy_tool_count(gs) == 0, "magnet, extra-slot and freeze controls are absent")
	var st: GameState = gs.state
	_expect(st.customers_total == 3, "level 2 has three customers")
	_expect(app.save.customers_discovered.has(st.current_customer_id()), "first visible customer is discovered immediately")
	_expect(st.basket.remaining() == 100 and st.total_items == 300, "level 2 starts with 100 of 300 items")
	var snack_ids := {}
	var category_ids := {}
	for item in st.basket.items:
		snack_ids[item["snack"]] = true
		category_ids[app.db.snacks[item["snack"]]["category"]] = true
	_expect(snack_ids.size() == 16 and category_ids.size() == 8, "level 2 basket contains 16 kinds across 8 categories")
	await _shot("bulk_level2")
	var bulk_item: Dictionary = {}
	for candidate in st.basket.top_items():
		if bulk_item.is_empty() or float(candidate["y"]) > float(bulk_item["y"]):
			bulk_item = candidate
	_expect(float(bulk_item.get("y", 0.0)) > 620.0, "lower table above the aisle exposes a snack for real click testing")
	var bulk_point := _exposed_point(gs, int(bulk_item["uid"]))
	_expect(bulk_point.x >= 0, "bulk basket exposes a real click point")
	if bulk_point.x < 0:
		_finish(st)
		return
	var expected_weight: int = app.db.snack_weight(String(bulk_item["snack"])) * int(bulk_item.get("size", 1))
	await _click(bulk_point)
	_expect(st.tray.entries.size() == 1 and st.tray_weight() == expected_weight, "bulk pick updates logical weight immediately")
	_expect(gs.scale_view._led.text == "%d g" % expected_weight, "bulk pick updates LED immediately")
	_expect(st.basket.remaining() == 99, "bulk real click removes exactly one item")
	await get_tree().create_timer(0.35).timeout
	await _shot("bulk_live_weight")
	await _click(gs.snack_nodes[int(bulk_item["uid"])].global_position)
	_expect(st.tray_weight() == 0 and gs.scale_view._led.text == "0 g", "bulk return immediately clears live weight")
	_expect(st.basket.remaining() == 100, "bulk return restores all 100 items")

	var assisted_uid := -1
	var assisted_point := Vector2(-1, -1)
	for candidate in st.basket.top_items():
		assisted_point = _assisted_click_point(gs, int(candidate["uid"]))
		if assisted_point.x >= 0:
			assisted_uid = int(candidate["uid"])
			break
	_expect(assisted_uid > 0, "real input finds expanded edge-only touch area")
	if assisted_uid > 0:
		await _click(assisted_point)
		_expect(st.tray.entries.size() == 1 and int(st.tray.entries[0]["uid"]) == assisted_uid, "real click just outside sprite picks assisted target")
		await get_tree().create_timer(0.3).timeout
		await _click(gs.snack_nodes[assisted_uid].global_position)
		_expect(st.tray.is_empty() and st.basket.remaining() == 100, "assisted pick can return normally")

	# 真实拖动只整理桌面，不进入称重台；核心位置和最高层同步更新。
	var drag_item: Dictionary = st.basket.top_items()[0]
	var drag_uid := int(drag_item["uid"])
	var drag_origin := Vector2(float(drag_item["x"]), float(drag_item["y"]))
	var drag_start := _exposed_point(gs, drag_uid)
	await _drag(drag_start, gs.table_view.to_global(Vector2(300, 700)))
	var dragged := st.basket.get_item(drag_uid)
	var dragged_center := Vector2(float(dragged["x"]), float(dragged["y"]))
	_expect(dragged_center.distance_to(drag_origin) > 20.0 and dragged_center.y > 600.0, "real mouse drag uses the lower sorting area above the aisle")
	_expect(_item_corners_inside(dragged), "dragged snack corners stay inside enlarged safe table")
	_expect(st.tray.is_empty() and st.basket.remaining() == 100, "drag rearranges without picking or weighing")
	var highest_layer := -1
	for item in st.basket.items:
		highest_layer = maxi(highest_layer, int(item["layer"]))
	_expect(int(dragged["layer"]) == highest_layer and gs._drag_uid == -1, "drag raises snack to top layer and releases cleanly")
	await _shot("table_drag")

	# 找一对半径内同款，第一次点击入一件，第二次双击连续聚合附近同款。
	var double_item: Dictionary = {}
	for candidate in st.basket.top_items():
		var origin := Vector2(float(candidate["x"]), float(candidate["y"]))
		var nearby := st.basket.nearby_same_at(String(candidate["snack"]), origin)
		if nearby.size() >= 2:
			double_item = candidate
			break
	_expect(not double_item.is_empty(), "bulk table has a nearby same-snack double-click pair")
	if not double_item.is_empty():
		await _double_click(_exposed_point(gs, int(double_item["uid"])))
		await get_tree().create_timer(0.65).timeout
		_expect(gs._last_double_count >= 2 and st.tray.entries.size() >= 2, "real double-click gathers multiple nearby snacks")
		_expect(st.tray.is_uniform() and st.bagged_items == 0, "double-click batch stays uniform and awaits manual weighing")
		await _shot("double_gather")
		while not st.tray.is_empty():
			var entry: Dictionary = st.tray.entries.back()
			await _click(gs.snack_nodes[int(entry["uid"])].global_position)
			await get_tree().create_timer(0.30).timeout
		_expect(st.basket.remaining() == 100 and st.tray_weight() == 0, "double-click batch can all return to dragged table layout")
		await _double_click(_exposed_point(gs, int(double_item["uid"])), false)
		await get_tree().create_timer(0.65).timeout
		_expect(gs._last_double_count >= 2 and st.tray.entries.size() >= 2, "double-click fallback works without native platform flag")
		_expect(st.tray.is_uniform() and st.bagged_items == 0, "fallback double-click also awaits manual weighing")
		while not st.tray.is_empty():
			var entry: Dictionary = st.tray.entries.back()
			await _click(gs.snack_nodes[int(entry["uid"])].global_position)
			await get_tree().create_timer(0.30).timeout
		_expect(st.basket.remaining() == 100 and st.tray_weight() == 0, "fallback double-click batch returns cleanly")

	app.start_level(20, 42)
	gs = app.current
	await _wait_table_ready(gs)
	st = gs.state
	await _shot("input_topdown")

	# 点被盖零食的中心，命中的是该点最上层零食，而不是穿透选中下层。
	var covered_case := false
	for item in st.basket.items:
		var uid := int(item["uid"])
		var home := BasketView.home_position(item)
		var expected := st.basket.hit_test(home)
		if expected > 0 and expected != uid:
			covered_case = true
			await _click(gs.snack_nodes[uid].global_position)
			await get_tree().create_timer(0.35).timeout
			_expect(st.basket.get_item(expected).get("picked", false), "overlap click picks top item")
			_expect(not st.basket.get_item(uid).get("picked", false), "overlap click does not pierce cover")
			break
	_expect(covered_case, "covered-center fixture exists")

	app.start_level(20, 42)
	gs = app.current
	await _wait_table_ready(gs)
	st = gs.state

	# 两次真实单击触发顶部连击回弹；随后等待核心超时，标签也必须同步清零。
	var combo_first: Dictionary = st.basket.top_items()[0]
	var combo_first_point := _exposed_point(gs, int(combo_first["uid"]))
	await _click(combo_first_point)
	await get_tree().create_timer(0.12).timeout
	var combo_second_point := Vector2(-1, -1)
	for candidate in st.basket.top_items():
		var point := _exposed_point(gs, int(candidate["uid"]))
		if point.x >= 0 and point.distance_to(combo_first_point) > 40.0:
			combo_second_point = point
			break
	_expect(combo_second_point.x >= 0, "combo fixture has a second exposed snack")
	await _click(combo_second_point)
	_expect(st.combo.combo == 2 and gs._combo_label.text == "COMBO ×2", "top-right combo updates after real picks")
	var combo_pulse_seen := false
	for sample in 14:
		await get_tree().create_timer(0.02).timeout
		combo_pulse_seen = combo_pulse_seen or gs._combo_badge.scale.x > 1.01
	_expect(combo_pulse_seen, "combo badge visibly pulses during real input")
	_expect(gs._combo_badge.scale.is_equal_approx(Vector2.ONE), "combo pulse returns to normal scale without tween stacking")
	await get_tree().create_timer(st.combo.window + 0.10).timeout
	_expect(st.combo.combo == 0 and gs._combo_label.text == "COMBO —", "combo timeout clears both core value and visible label")
	while not st.tray.is_empty():
		var entry: Dictionary = st.tray.entries.back()
		await _click(gs.snack_nodes[int(entry["uid"])].global_position)
		await get_tree().create_timer(0.30).timeout

	# 重开同一种子，用真实露出点制造 A+B 混品。
	app.start_level(20, 42)
	gs = app.current
	await _wait_table_ready(gs)
	st = gs.state
	var mixed := await _prepare_mixed(gs)
	_expect(mixed.size() == 2, "real clicks prepare mixed scale")
	if mixed.size() != 2:
		_finish(st)
		return
	_expect(st.tray.unique_snacks().size() == 2, "scale contains two snack kinds")
	_expect(gs._checkout_btn.disabled, "mixed checkout button is disabled")
	await _shot("input_mixed")

	var groups_before := st.bagged_groups
	await _click(_checkout_center(gs))
	await get_tree().create_timer(0.2).timeout
	_expect(st.bagged_groups == groups_before and st.tray.entries.size() == 2, "disabled POS cannot settle mixed scale")

	# 两件台上零食的热区真实重叠时，重叠点只退回后放上的 B，保留下层 A。
	var returned: Dictionary = mixed[1]
	var remaining_before := st.basket.remaining()
	var overlap_point := _tray_overlap_point(gs, int(returned["uid"]), int(mixed[0]["uid"]))
	_expect(overlap_point.x >= 0, "mixed scale has overlapping hit areas")
	if overlap_point.x < 0:
		_finish(st)
		return
	await _click(overlap_point)
	await get_tree().create_timer(0.35).timeout
	_expect(not st.basket.get_item(int(returned["uid"])).get("picked", true), "overlapping scale click returns top item")
	_expect(st.basket.get_item(int(mixed[0]["uid"])).get("picked", false), "overlapping scale click keeps lower item")
	_expect(st.basket.remaining() == remaining_before + 1, "real return restores basket count")
	_expect(st.tray.is_uniform() and st.tray.entries.size() == 1, "one uniform item remains on scale")
	_expect(not gs._checkout_btn.disabled, "uniform checkout button enabled")

	var items_before := st.bagged_items
	await _click(_checkout_center(gs))
	await get_tree().create_timer(0.35).timeout
	_expect(st.bagged_items == items_before + 1 and st.tray.is_empty(), "POS click settles one item")
	_expect(gs._bag_label.text == "已称重 %d / %d 件 · %d 批" % [st.bagged_items, st.total_items, st.bagged_groups] and is_equal_approx(gs._bag_bar.value, float(st.bagged_items) / st.total_items), "top progress updates immediately after POS checkout: text=%s value=%.6f expected=%.6f" % [gs._bag_label.text, gs._bag_bar.value, float(st.bagged_items) / st.total_items])

	# 继续全部用真实鼠标操作，直到第一位顾客结账并换第二位。
	var guard := 0
	var swap_seen := false
	var swap_finished := false
	var swap_input_locked := false
	var swap_clock_paused := false
	while st.customer_index == 1 and st.state == "playing" and guard < 60:
		guard += 1
		var old_basket_id := gs.basket_view.get_instance_id() if is_instance_valid(gs.basket_view) else 0
		var before := str(st.basket.remaining(), ":", st.bagged_groups, ":", st.customer_index)
		var progressed := await _auto_click_step(gs)
		await get_tree().create_timer(0.31).timeout
		var after := str(st.basket.remaining(), ":", st.bagged_groups, ":", st.customer_index)
		if st.customer_index == 2 and not swap_seen:
			swap_seen = gs._switching_customer and is_instance_valid(gs.basket_view) and gs.basket_view.get_instance_id() != old_basket_id
			_expect(swap_seen, "customer change creates a new basket for pouring")
			var pour_guard := 0
			while not gs._pouring and pour_guard < 20:
				pour_guard += 1
				await get_tree().create_timer(0.05).timeout
			_expect(gs._pouring, "next customer also pours snacks onto table")
			await _shot("basket_swap")
			if not st.basket.top_items().is_empty():
				var locked_uid := int(st.basket.top_items()[0]["uid"])
				var locked_point := _exposed_point(gs, locked_uid)
				var remaining_locked := st.basket.remaining()
				var clock_locked := st.clock.left
				await _click(locked_point)
				swap_input_locked = st.tray.is_empty() and st.basket.remaining() == remaining_locked
				await get_tree().create_timer(0.16).timeout
				swap_clock_paused = is_equal_approx(st.clock.left, clock_locked)
			await _wait_table_ready(gs)
			swap_finished = not gs._switching_customer and not is_instance_valid(gs.basket_view) and gs.table_view.position.is_equal_approx(GameScreen.TABLE_HOME) and _legacy_tool_count(gs) == 0
		if not progressed or before == after:
			_expect(false, "real-input auto step makes progress at guard %d" % guard)
			break
	_expect(st.customer_index == 2 and st.state == "playing", "real clicks serve customer and advance queue")
	_expect(swap_input_locked, "real click is ignored during basket swap")
	_expect(swap_clock_paused, "patience clock pauses during basket swap")
	_expect(swap_finished, "incoming basket settles at workbench and input unlocks")
	_finish(st)


func _prepare_mixed(gs: GameScreen) -> Array:
	var st: GameState = gs.state
	for guard in 30:
		if st.tray.is_empty():
			var first: Dictionary = st.basket.top_items()[0]
			var point := _exposed_point(gs, int(first["uid"]))
			if point.x < 0:
				return []
			await _click(point)
			await get_tree().create_timer(0.31).timeout
		if st.tray.is_empty():
			continue
		var current := String(st.tray.entries[0]["snack"])
		# 新商品池会改变 UID 与落点；逐个试放异类，只保留热区确实重叠的组合。
		var candidates := st.basket.top_items()
		for it in candidates:
			if it["snack"] == current or not st.tray.can_fit(int(it["size"])):
				continue
			var point := _exposed_point(gs, int(it["uid"]))
			if point.x < 0:
				continue
			await _click(point)
			await get_tree().create_timer(0.31).timeout
			if st.tray.entries.size() != 2:
				continue
			var upper_uid := int(st.tray.entries.back()["uid"])
			var lower_uid := int(st.tray.entries[0]["uid"])
			if _tray_overlap_point(gs, upper_uid, lower_uid).x >= 0:
				return st.tray.entries.duplicate()
			await _click(gs.snack_nodes[upper_uid].global_position)
			await get_tree().create_timer(0.31).timeout
		if not st.tray.is_empty():
			await _click(_checkout_center(gs))
			await get_tree().create_timer(0.31).timeout
		if st.state != "playing" or st.basket.remaining() == 0:
			break
	return []


func _auto_click_step(gs: GameScreen) -> bool:
	var st: GameState = gs.state
	if st.basket.remaining() == 0:
		if not st.tray.is_empty():
			await _click(_checkout_center(gs))
			return true
		return false
	var snack_id := String(st.tray.entries[0]["snack"]) if not st.tray.is_empty() else String(st.basket.top_items()[0]["snack"])
	for it in st.basket.top_items():
		if it["snack"] == snack_id and st.tray.can_fit(int(it["size"])):
			var point := _exposed_point(gs, int(it["uid"]))
			if point.x >= 0:
				await _click(point)
				return true
	if not st.tray.is_empty():
		await _click(_checkout_center(gs))
		return true
	return false


## 在自身旋转热区内找一个不被任何高层热区覆盖的真实点击点。
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


## 精细热区未命中、辅助热区恰好命中同一物品的边缘点。
func _assisted_click_point(gs: GameScreen, uid: int) -> Vector2:
	var st: GameState = gs.state
	var item := st.basket.get_item(uid)
	if item.is_empty() or not st.basket.can_pick(uid):
		return Vector2(-1, -1)
	var center := BasketView.home_position(item)
	var half := BasketModel.hit_size(item) * 0.5
	var rotation := deg_to_rad(float(item["rot"]))
	var offsets := [Vector2(half.x + 8, 0), Vector2(-half.x - 8, 0), Vector2(0, half.y + 8), Vector2(0, -half.y - 8)]
	for offset in offsets:
		var point: Vector2 = center + offset.rotated(rotation)
		if st.basket.hit_test(point) == -1 and st.basket.hit_test_assisted(point) == uid:
			return gs.table_view.to_global(point)
	return Vector2(-1, -1)


## 在上层零食的缩放旋转热区内，寻找同时落入下层热区的真实全局坐标。
func _tray_overlap_point(gs: GameScreen, upper_uid: int, lower_uid: int) -> Vector2:
	var upper: SnackView = gs.snack_nodes[upper_uid]
	var lower: SnackView = gs.snack_nodes[lower_uid]
	var upper_size := BasketModel.hit_size(upper.item) * SnackView.TRAY_SCALE
	var lower_half := BasketModel.hit_size(lower.item) * SnackView.TRAY_SCALE * 0.5
	for gy in 13:
		for gx in 13:
			var local := -upper_size * 0.5 + upper_size * Vector2((gx + 0.5) / 13.0, (gy + 0.5) / 13.0)
			var point := upper.to_global(local)
			var lower_local := lower.to_local(point)
			if absf(lower_local.x) <= lower_half.x and absf(lower_local.y) <= lower_half.y:
				return point
	return Vector2(-1, -1)


func _checkout_center(gs: GameScreen) -> Vector2:
	return gs._checkout_btn.global_position + gs._checkout_btn.size * 0.5


func _item_corners_inside(item: Dictionary) -> bool:
	var center := Vector2(float(item["x"]), float(item["y"]))
	var half := BasketModel.hit_size(item) * 0.5
	var rotation := deg_to_rad(float(item["rot"]))
	var safe := BasketModel.TABLE_BOUNDS.grow(0.02)
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			if not safe.has_point(center + Vector2(half.x * sx, half.y * sy).rotated(rotation)):
				return false
	return true


func _legacy_tool_count(node: Node) -> int:
	var count := 0
	if node is Button and (node.text.begins_with("吸附") or node.text == "+台位" or node.text == "冻结"):
		count += 1
	for child in node.get_children():
		count += _legacy_tool_count(child)
	return count


func _wait_table_ready(gs: GameScreen) -> void:
	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 160:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(not gs._switching_customer and not is_instance_valid(gs.basket_view), "basket disappears before table input unlocks")
	var nodes_ready := true
	for uid in gs.snack_nodes:
		var node: SnackView = gs.snack_nodes[uid]
		nodes_ready = nodes_ready and node.get_parent() == gs.table_view and not node.flying
	_expect(nodes_ready, "all poured snacks land on sorting table before input unlocks")
	await get_tree().create_timer(0.08).timeout


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


func _double_click(point: Vector2, native_flag: bool = true) -> void:
	await _click(point)
	await get_tree().create_timer(0.06).timeout
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.double_click = pressed and native_flag
		Input.parse_input_event(event)
	await get_tree().process_frame


func _expect(cond: bool, message: String) -> void:
	print("ok - " + message if cond else "FAIL - " + message)
	if not cond:
		_failures.append(message)


func _finish(st: GameState) -> void:
	print("input smoke: customer=", st.customer_index, " remaining=", st.basket.remaining(),
		" state=", st.state, " failed_checks=", _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_tree().root.get_texture().get_image()
	img.save_png("res://docs/images/dev_%s.png" % tag)
	print("shot dev_%s.png" % tag)


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
