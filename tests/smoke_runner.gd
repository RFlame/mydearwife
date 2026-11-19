extends Node
## 自动冒烟 + 截图：godot --path . tests/smoke.tscn
## 首页 → 俯视工作台 → 混品拒结 → 台上退货 → 手动称重 → 下一位顾客 → 结算。

var _app: Control


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(_app)
	await get_tree().create_timer(0.6).timeout
	await _shot("home")

	_app.start_level(1, 42)
	var gs: GameScreen = _app.current
	await get_tree().create_timer(0.46).timeout
	await _shot("pour")
	await _wait_ready(gs)
	await _shot("game")

	var st: GameState = gs.state
	var mixed := await _make_mixed(st)
	if mixed.size() != 2:
		printerr("smoke failed: could not prepare mixed scale")
		get_tree().quit(1)
		return
	await get_tree().create_timer(0.3).timeout
	await _shot("mixed")
	var rejected := not st.settle_scale() and st.tray.entries.size() == 2

	var returned: Dictionary = mixed[1]
	var remaining_before := st.basket.remaining()
	st.return_item(int(returned["uid"]))
	await get_tree().create_timer(0.35).timeout
	var return_ok := st.basket.remaining() == remaining_before + 1 and st.tray.is_uniform()
	await _shot("return")

	# 通过 POS 按钮信号走与真实点击相同的结算链路。
	gs._checkout_btn.pressed.emit()
	await get_tree().create_timer(0.16).timeout
	await _shot("weigh")

	var next_shot := false
	var scale_reset_ok := false
	var swap_started := false
	var swap_finished := false
	var guard := 0
	while st.state == "playing" and guard < 100:
		guard += 1
		var old_customer := st.customer_index
		var old_basket_id := gs.basket_view.get_instance_id() if is_instance_valid(gs.basket_view) else 0
		_auto_step(st)
		await get_tree().create_timer(0.3).timeout
		if st.customer_index != old_customer and not next_shot:
			next_shot = true
			swap_started = gs._switching_customer and is_instance_valid(gs.basket_view) and gs.basket_view.get_instance_id() != old_basket_id
			var pour_guard := 0
			while not gs._pouring and pour_guard < 20:
				pour_guard += 1
				await get_tree().create_timer(0.05).timeout
			swap_started = swap_started and gs._pouring
			await _shot("next_customer")
			scale_reset_ok = gs.scale_view._led.text == "0 g"
			await _wait_ready(gs)
			swap_finished = not gs._switching_customer and not is_instance_valid(gs.basket_view) and gs.table_view.position.is_equal_approx(GameScreen.TABLE_HOME)
	await get_tree().create_timer(1.5).timeout
	await _shot("result")
	var result_ok: bool = st.state == "complete" and st.customer_index == st.customers_total and _app.current is ResultScreen
	print("smoke done, state=", st.state, " customers=", st.customer_index, "/", st.customers_total,
		" mixed_rejected=", rejected, " return_ok=", return_ok, " scale_reset=", scale_reset_ok,
		" result_ok=", result_ok)
	get_tree().quit(0 if rejected and return_ok and scale_reset_ok and result_ok and next_shot and swap_started and swap_finished else 1)


func _make_mixed(st: GameState) -> Array:
	for guard in 30:
		if st.tray.is_empty():
			var first: Dictionary = st.basket.top_items()[0]
			st.pick(int(first["uid"]))
			await get_tree().create_timer(0.3).timeout
		var current := String(st.tray.entries[0]["snack"])
		for it in st.basket.top_items():
			if it["snack"] != current and st.tray.can_fit(int(it["size"])):
				st.pick(int(it["uid"]))
				return [st.tray.entries[0], st.tray.entries.back()]
		st.settle_scale()
		await get_tree().create_timer(0.3).timeout
		if st.state != "playing" or st.basket.remaining() == 0:
			break
	return []


func _auto_step(st: GameState) -> void:
	if st.state != "playing":
		return
	if st.basket.remaining() == 0:
		if not st.tray.is_empty():
			st.settle_scale()
		return
	var snack_id := String(st.tray.entries[0]["snack"]) if not st.tray.is_empty() else String(st.basket.top_items()[0]["snack"])
	for it in st.basket.top_items():
		if it["snack"] == snack_id and st.tray.can_fit(int(it["size"])):
			st.pick(int(it["uid"]))
			return
	if not st.tray.is_empty():
		st.settle_scale()


func _wait_ready(gs: GameScreen) -> void:
	var guard := 0
	while (gs._switching_customer or is_instance_valid(gs.basket_view)) and guard < 160:
		guard += 1
		await get_tree().create_timer(0.05).timeout


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_tree().root.get_texture().get_image()
	img.save_png("res://docs/images/dev_%s.png" % tag)
	print("shot dev_%s.png" % tag)
