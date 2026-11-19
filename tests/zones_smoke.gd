extends Node
## 四角集货聚焦测试：真实拖动/点击 + 双区域同时集齐的串行自动称重。

var _failures: Array = []
var _checks := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.25).timeout
	app.start_level(1, 42)
	var gs: GameScreen = app.current
	await _wait_table_ready(gs)
	var st: GameState = gs.state

	_expect(gs.zone_views.size() == 4, "four sorting zones are created")
	var zones_inside := true
	var zones_disjoint := true
	var zones_upper := true
	for i in GameScreen.ZONE_RECTS.size():
		var rect: Rect2 = GameScreen.ZONE_RECTS[i]
		zones_inside = zones_inside and BasketModel.DRAG_BOUNDS.encloses(rect)
		zones_upper = zones_upper and rect.end.y <= 316.0
		for j in range(i + 1, GameScreen.ZONE_RECTS.size()):
			zones_disjoint = zones_disjoint and not rect.intersects(GameScreen.ZONE_RECTS[j])
	_expect(zones_inside, "all four zones stay inside the expanded drag-safe tabletop")
	_expect(zones_disjoint, "corner drop regions do not overlap")
	_expect(zones_upper, "all four sorting circles move into two upper rows")
	var ellipse_hit_ok := true
	var corner_miss_ok := true
	for rect in GameScreen.ZONE_RECTS:
		ellipse_hit_ok = ellipse_hit_ok and gs._zone_at_table_point(rect.get_center()) >= 0
		for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.position + Vector2(0, rect.size.y), rect.end]:
			corner_miss_ok = corner_miss_ok and not GameScreen.zone_contains_point(0, corner) and not GameScreen.zone_contains_point(1, corner) and not GameScreen.zone_contains_point(2, corner) and not GameScreen.zone_contains_point(3, corner)
	_expect(ellipse_hit_ok, "each elliptical zone accepts its center")
	_expect(corner_miss_ok, "bounding-box corners outside every ellipse are not drop targets")
	_expect(not gs._checkout_btn.disabled and gs._auto_settle, "settlement mode button starts enabled with automatic settlement on")
	await _shot("zones_ready")

	# 桌面单击只跳动，不进入区域或称重台。
	var first: Dictionary = st.basket.top_items()[0]
	var first_uid := int(first["uid"])
	var snack_id := String(first["snack"])
	var original := Vector2(float(first["x"]), float(first["y"]))
	var first_node: SnackView = gs.snack_nodes[first_uid]
	var tap_before := first_node.tap_seq
	await _click(_exposed_point(gs, first_uid))
	_expect(first_node.tap_seq == tap_before + 1 and gs._table_tap_seq == 1, "real table click triggers local tap feedback")
	_expect(st.basket.remaining() == 4 and st.tray.is_empty() and st.zones.is_clear(), "table click does not pick, sort or settle")
	_expect(Vector2(float(first["x"]), float(first["y"])) == original, "table click leaves the logical position unchanged")
	var bounce_seen := false
	for sample in 8:
		bounce_seen = bounce_seen or first_node.sprite.position.y < -2.0
		await get_tree().create_timer(0.02).timeout
	_expect(bounce_seen, "clicked snack visibly hops in place")
	await get_tree().create_timer(0.18).timeout
	_expect(absf(first_node.sprite.position.y) < 0.01, "tap bounce returns to its original sprite height")

	# 真实拖入、区内单击退回。
	await _drag_available_snack(gs, snack_id, 0)
	await get_tree().create_timer(0.34).timeout
	_expect(st.zones.sections[0].size() == 1 and st.basket.remaining() == 3, "real drag drops one snack into the first zone")
	_expect(st.bagged_items == 0 and st.zones.queue.is_empty(), "partial snack kind does not auto-settle")
	await _shot("zones_single")
	if st.zones.sections[0].size() != 1:
		print("drag failure: sections=", st.zones.sections, " remaining=", st.basket.remaining())
		_finish(st)
		return
	var zoned_uid := int(st.zones.sections[0][0]["uid"])
	_expect(GameScreen.zone_contains_point(0, gs.table_view.to_local(gs.snack_nodes[zoned_uid].global_position)), "zoned snack lands inside the central ellipse rather than its bounding corner")
	await _click(gs.snack_nodes[zoned_uid].global_position)
	await get_tree().create_timer(0.32).timeout
	_expect(st.zones.sections[0].is_empty() and st.basket.remaining() == 4, "real zone click returns the snack to the table")
	_expect(not st.basket.get_item(zoned_uid).get("picked", true), "returned snack becomes table-pickable again")
	var returned := st.basket.get_item(zoned_uid)
	_expect(Vector2(float(returned["x"]), float(returned["y"])) == original, "zone return restores the pre-drag table position")
	_expect(gs.snack_nodes[zoned_uid].global_position.distance_to(gs.table_view.to_global(original)) < 1.0, "returned snack visual reaches its original table position")

	# 同款两件全部进入同一区后，无需 POS 点击即称重。
	var weighed: Array = []
	st.group_weighed.connect(func(id: String, group: Array, _price: Dictionary, _weight: int):
		weighed.append({"snack": id, "count": group.size(), "msec": Time.get_ticks_msec()}))
	await _drag_available_snack(gs, snack_id, 0)
	await get_tree().create_timer(0.32).timeout
	await _drag_available_snack(gs, snack_id, 0)
	_expect(st.zones.queue == [0], "complete kind queues its zone exactly once")
	_expect(st.bagged_items == 0, "arrival flight finishes before auto weighing")
	_expect(gs._manual_settle_seq == 0 and gs._auto_settle, "automatic mode does not require a manual settlement command")
	var completed := await _wait_weighed(weighed, 1, 5.0)
	_expect(completed, "complete zone automatically weighs without a POS command")
	_expect(weighed.size() == 1 and weighed[0]["snack"] == snack_id and weighed[0]["count"] == 2, "auto settlement contains the whole snack kind")
	_expect(st.bagged_items == 2 and st.bagged_groups == 1 and st.basket.remaining() == 2, "progress updates after the complete automatic batch")
	_expect(st.zones.sections[0].is_empty() and st.tray.is_empty(), "settled zone and scale clear for further sorting")
	await _shot("zones_auto")

	# 构造混放与跨区分拆：两者都不能误触发；退货后两个区域在同一等待窗内集齐。
	app.start_level(3, 42)
	gs = app.current
	await _wait_table_ready(gs)
	st = gs.state
	var by_snack := {}
	var points := [Vector2(110, 340), Vector2(300, 340), Vector2(490, 340), Vector2(110, 700), Vector2(300, 700), Vector2(490, 700)]
	for index in st.basket.items.size():
		var item: Dictionary = st.basket.items[index]
		st.move_item(int(item["uid"]), points[index], true)
		if not by_snack.has(item["snack"]):
			by_snack[item["snack"]] = []
		by_snack[item["snack"]].append(item)
	var ids := by_snack.keys()
	ids.sort()
	var a: Array = by_snack[ids[0]]
	var b: Array = by_snack[ids[1]]
	_expect(a.size() == 2 and b.size() == 2, "level 3 fixture has two complete pairs")
	_expect(st.place_in_zone(int(a[0]["uid"]), 0), "first A enters mixed zone")
	_expect(st.place_in_zone(int(b[0]["uid"]), 0), "first B enters the same mixed zone")
	_expect(st.place_in_zone(int(a[1]["uid"]), 0), "second A completes A count but zone remains mixed")
	_expect(st.place_in_zone(int(b[1]["uid"]), 1), "second B is split across another zone")
	_expect(st.zones.queue.is_empty() and st.bagged_items == 0, "mixed zone and cross-zone split never auto-settle")
	_expect(st.return_zone_item(int(b[0]["uid"])), "returning the mixed B unlocks a uniform complete A zone")
	_expect(st.zones.queue == [0], "return reevaluates completeness and queues A")
	_expect(st.place_in_zone(int(b[0]["uid"]), 1), "returned B can join its pair while A is waiting")
	_expect(st.zones.queue == [0, 1], "two simultaneously ready zones retain deterministic queue order")
	_expect(not st.return_zone_item(int(a[0]["uid"])), "queued zone cannot return an item during the race window")

	weighed.clear()
	st.group_weighed.connect(func(id: String, group: Array, _price: Dictionary, _weight: int):
		weighed.append({"snack": id, "count": group.size(), "msec": Time.get_ticks_msec()}))
	var uniform_only := true
	var active_seen: Array = []
	var guard := 0
	while weighed.size() < 2 and guard < 250:
		guard += 1
		if not st.tray.is_empty():
			uniform_only = uniform_only and st.tray.is_uniform()
		if st.zones.active_zone >= 0 and not active_seen.has(st.zones.active_zone):
			active_seen.append(st.zones.active_zone)
		await get_tree().create_timer(0.02).timeout
	_expect(weighed.size() == 2, "both queued zones automatically finish")
	if weighed.size() == 2:
		_expect(weighed[0]["snack"] == String(ids[0]) and weighed[1]["snack"] == String(ids[1]), "queued batches weigh in FIFO order")
		_expect(int(weighed[1]["msec"]) - int(weighed[0]["msec"]) >= 600, "successive scale occupations have a real time gap")
	_expect(active_seen == [0, 1], "only one queued zone owns the scale at a time")
	_expect(uniform_only, "concurrent zone input never mixes an active scale batch")
	_expect(st.bagged_items == 4 and st.basket.remaining() == 2 and st.state == "playing", "other table kinds remain playable after both batches")
	_expect(st.zones.queue.is_empty() and st.zones.active_zone == -1 and st.tray.is_empty(), "queue drains cleanly without duplicate settlement")
	await _shot("zones_queue")
	_finish(st)


func _drag_available_snack(gs: GameScreen, snack_id: String, zone_index: int) -> void:
	for item in gs.state.basket.top_items():
		if String(item["snack"]) != snack_id:
			continue
		var start := _exposed_point(gs, int(item["uid"]))
		if start.x >= 0:
			await _drag(start, gs.table_view.to_global(GameScreen.ZONE_RECTS[zone_index].get_center()))
			return
	_expect(false, "an exposed %s is available for dragging" % snack_id)


func _wait_weighed(events: Array, count: int, timeout: float) -> bool:
	var guard := 0
	while events.size() < count and guard < int(timeout / 0.02):
		guard += 1
		await get_tree().create_timer(0.02).timeout
	return events.size() >= count


func _wait_table_ready(gs: GameScreen) -> void:
	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 160:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(not gs._switching_customer and not is_instance_valid(gs.basket_view), "basket pour finishes before zone input")
	await get_tree().create_timer(0.08).timeout


func _exposed_point(gs: GameScreen, uid: int) -> Vector2:
	var point := gs.state.basket.exposed_point(uid)
	return gs.table_view.to_global(point) if point.x >= 0 else Vector2(-1, -1)


func _click(pos: Vector2) -> void:
	if pos.x < 0:
		_expect(false, "real input has a valid click point")
		return
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
	if start.x < 0:
		_expect(false, "real drag has an exposed start point")
		return
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
