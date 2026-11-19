extends Node
## 新增结算模式聚焦测试：真实按钮切换与任意位置双击，验证手动 FIFO 和恢复自动。

var _failures: Array = []
var _checks := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.25).timeout
	app.start_level(3, 42)
	var gs: GameScreen = app.current
	await _wait_table_ready(gs)
	var st: GameState = gs.state

	await _click(gs._checkout_btn.global_position + gs._checkout_btn.size * 0.5)
	_expect(not gs._auto_settle and not gs._checkout_btn.disabled, "real POS button switches automatic settlement off")
	await _double_click(Vector2(690, 1160))
	_expect(gs._manual_settle_seq == 0 and st.bagged_items == 0, "double click without a complete zone does not settle")

	var by_snack := {}
	for item in st.basket.items:
		if not by_snack.has(item["snack"]):
			by_snack[item["snack"]] = []
		by_snack[item["snack"]].append(item)
	var ids := by_snack.keys()
	ids.sort()
	var a: Array = by_snack[ids[0]]
	var b: Array = by_snack[ids[1]]
	var c: Array = by_snack[ids[2]]
	_expect(a.size() == 2 and b.size() == 2 and c.size() == 2, "level 3 provides three complete pairs for mode testing")
	_expect(st.place_in_zone(int(a[0]["uid"]), 0), "manual A1 enters zone 0")
	_expect(st.place_in_zone(int(a[1]["uid"]), 0), "manual A2 completes zone 0")
	_expect(st.place_in_zone(int(b[0]["uid"]), 1), "manual B1 enters zone 1")
	_expect(st.place_in_zone(int(b[1]["uid"]), 1), "manual B2 completes zone 1")
	_expect(st.zones.queue == [0, 1], "both manually held complete zones are detected in FIFO order")
	await get_tree().create_timer(0.70).timeout
	_expect(st.bagged_items == 0 and st.zones.active_zone == -1 and not gs._zone_pump_running, "disabled automatic mode never flies completed zones onto the scale")
	_expect(st.zones.sections[0].size() == 2 and st.zones.sections[1].size() == 2, "manual waiting leaves both complete groups inside their circles")
	await _shot("settlement_manual_ready")

	var weighed: Array = []
	st.group_weighed.connect(func(id: String, group: Array, _price: Dictionary, _weight: int):
		weighed.append({"snack": id, "count": group.size(), "msec": Time.get_ticks_msec()}))
	await _double_click(Vector2(690, 1160), false)
	_expect(gs._manual_settle_seq == 1 and gs._manual_settle_requested, "two clicks without a native double-click flag trigger one manual settlement command")
	var completed := await _wait_weighed(weighed, 2, 6.0)
	_expect(completed, "one double click drains both ready zones")
	if weighed.size() == 2:
		_expect(weighed[0]["snack"] == String(ids[0]) and weighed[1]["snack"] == String(ids[1]), "manual double click preserves zone FIFO order")
		_expect(int(weighed[1]["msec"]) - int(weighed[0]["msec"]) >= 600, "manual batches occupy the scale serially with a visible interval")
	_expect(st.bagged_items == 4 and st.basket.remaining() == 2 and st.state == "playing", "manual settlement weighs exactly the two complete groups")
	_expect(st.zones.queue.is_empty() and st.zones.active_zone == -1 and st.tray.is_empty(), "manual FIFO leaves no queued or active residue")
	await _shot("settlement_manual_done")

	await _click(gs._checkout_btn.global_position + gs._checkout_btn.size * 0.5)
	_expect(gs._auto_settle, "real POS button restores automatic settlement")
	_expect(st.place_in_zone(int(c[0]["uid"]), 2), "automatic C1 enters zone 2")
	_expect(st.place_in_zone(int(c[1]["uid"]), 2), "automatic C2 completes zone 2")
	completed = await _wait_weighed(weighed, 3, 5.0)
	_expect(completed and gs._manual_settle_seq == 1, "restored automatic mode settles without another double click")
	_expect(st.bagged_items == 6, "all three kinds finish across manual and automatic modes")
	_finish(st)


func _wait_table_ready(gs: GameScreen) -> void:
	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 160:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	_expect(not gs._switching_customer and not is_instance_valid(gs.basket_view), "basket pour finishes before mode input")
	await get_tree().create_timer(0.08).timeout


func _wait_weighed(events: Array, count: int, timeout: float) -> bool:
	var guard := 0
	while events.size() < count and guard < int(timeout / 0.02):
		guard += 1
		await get_tree().create_timer(0.02).timeout
	return events.size() >= count


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
