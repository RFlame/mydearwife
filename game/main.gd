extends Control
## 应用根：数据层 / 存档 / 页面切换。

var db: ConfigDB
var save: SaveData
var current: Control = null
var _web_smoke_enabled := false
var _web_smoke_seed := 42
var _web_smoke_clock := 0.0
var _web_combo_owner := 0
var _web_combo_last := 0
var _web_combo_peak := 1.0
var _web_combo_pulses := 0
var _web_basket_phase := ""


func _ready() -> void:
	db = ConfigDB.load_all()
	save = SaveData.load_save()
	db.set_preset(save.settings.get("preset", "standard"))
	SFX.enabled = save.settings.get("sfx", true)
	show_home()
	_setup_web_smoke_bridge()


func _switch(page: Control) -> void:
	if current:
		current.queue_free()
	current = page
	add_child(page)


func show_home() -> void:
	_switch(HomeScreen.create(self))


func start_level(level_id: int, seed_value: int = 0) -> void:
	if seed_value == 0 and _web_smoke_enabled:
		seed_value = _web_smoke_seed
	_switch(GameScreen.create(self, level_id, seed_value))


func show_test(options: Dictionary = {}) -> void:
	_switch(TestScreen.create(self, options))


func start_test(options: Dictionary) -> void:
	var test_options := options.duplicate(true)
	test_options["test_mode"] = true
	var level_id := clampi(int(test_options.get("level_id", 1)), 1, db.level_count())
	var seed_value := int(test_options.get("seed_value", 0))
	if seed_value == 0 and _web_smoke_enabled:
		seed_value = _web_smoke_seed
	_switch(GameScreen.create(self, level_id, seed_value, test_options))


func show_result(level_id: int, result: Dictionary) -> void:
	_switch(ResultScreen.create(self, level_id, result))


func show_upgrades() -> void:
	_switch(UpgradeScreen.create(self))


func show_collection() -> void:
	_switch(CollectionScreen.create(self))


func show_customers() -> void:
	_switch(CustomerCollectionScreen.create(self))


## Web 自动化只读桥：仅在 ?smoke=1 时注册，不提供任何修改游戏状态的接口。
func _setup_web_smoke_bridge() -> void:
	if not OS.has_feature("web"):
		return
	_web_smoke_enabled = bool(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('smoke') === '1'"))
	if not _web_smoke_enabled:
		return
	_web_smoke_seed = String(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('seed') || '42'")).to_int()
	JavaScriptBridge.eval("window.godotSmokeState = ''; window.godotSmokeHistory = []; window.godotSmokeUpdate = function(s) { window.godotSmokeState = s; window.godotSmokeHistory.push(s); if (window.godotSmokeHistory.length > 120) window.godotSmokeHistory.shift(); }")
	_publish_web_smoke()
	print("Web smoke bridge registered, seed=", _web_smoke_seed)


func _process(delta: float) -> void:
	if not _web_smoke_enabled:
		return
	# 每帧只读采样短促的连击回弹，避免 0.2 秒快照漏掉峰值。
	if current is GameScreen:
		var gs: GameScreen = current
		var owner := gs.get_instance_id()
		if owner != _web_combo_owner:
			_web_combo_owner = owner
			_web_combo_last = 0
			_web_combo_peak = 1.0
			_web_combo_pulses = 0
			_web_basket_phase = ""
		var combo_value := gs.state.combo.combo
		if combo_value > _web_combo_last and combo_value >= 2:
			_web_combo_pulses += 1
			_web_combo_peak = 1.0
		_web_combo_last = combo_value
		_web_combo_peak = maxf(_web_combo_peak, gs._combo_badge.scale.x)
		# 阶段变化立即采样，确保短促的拿起/侧翻阶段也能被只读自动化可靠观察。
		if gs._basket_phase != _web_basket_phase:
			_web_basket_phase = gs._basket_phase
			_web_smoke_clock = 0.0
			_publish_web_smoke()
			return
	_web_smoke_clock += delta
	if _web_smoke_clock >= 0.2:
		_web_smoke_clock = 0.0
		_publish_web_smoke()


func _publish_web_smoke() -> void:
	var window = JavaScriptBridge.get_interface("window")
	window.godotSmokeUpdate(_web_smoke_snapshot([]))


func _web_smoke_snapshot(_args: Array) -> String:
	var data := {"page": "other"}
	if current is HomeScreen:
		data["page"] = "home"
		data["test_entry"] = _rect_snapshot(current.test_button.get_global_rect())
	elif current is TestScreen:
		data = {"page": "test", "test_options": current.current_options(),
			"start": _rect_snapshot(current.start_button.get_global_rect()),
			"controls": {
				"level": _option_snapshot(current.level_option),
				"preset": _option_snapshot(current.preset_option),
				"random": _rect_snapshot(current.random_check.get_global_rect()),
				"quantity": _rect_snapshot(current.quantity_slider.get_global_rect()),
				"size": _rect_snapshot(current.size_slider.get_global_rect()),
				"giant": _option_snapshot(current.giant_option),
			}}
	elif current is ResultScreen:
		data["page"] = "result"
		data["test_mode"] = current.result.get("test_mode", false)
		data["test_config"] = current.result.get("test_config", {})
		if current.next_button:
			data["next"] = {"x": current.next_button.global_position.x + current.next_button.size.x * 0.5,
				"y": current.next_button.global_position.y + current.next_button.size.y * 0.5}
		if current.retry_button:
			data["retry"] = _rect_snapshot(current.retry_button.get_global_rect())
	elif current is CustomerCollectionScreen:
		var found := 0
		for customer_id in db.customers:
			if save.customers_discovered.has(customer_id):
				found += 1
		data = {"page": "customers", "profiles": current.cards.size(), "found": found, "total": db.customers.size()}
	elif current is GameScreen:
		var gs: GameScreen = current
		var st: GameState = gs.state
		var available: Array = []
		for item in st.basket.top_items():
			var point := st.basket.exposed_point(int(item["uid"]))
			if point.x >= 0:
				var global := gs.table_view.to_global(point)
				available.append({"uid": int(item["uid"]), "snack": String(item["snack"]),
					"size": int(item["size"]), "giant": BasketModel.is_giant(item),
					"package_scale": float(item.get("package_scale", 1.0)),
					"product_scale": float(item.get("product_scale", 1.0)),
					"logical_size": _point_snapshot(BasketModel.hit_size(item)),
					"weight": db.snack_weight(String(item["snack"])) * int(item.get("size", 1)),
					"table_x": float(item["x"]), "table_y": float(item["y"]), "x": global.x, "y": global.y})
		var table_items: Array = []
		for item in st.basket.items:
			if item.get("picked", false):
				continue
			var uid := int(item["uid"])
			var center := Vector2(float(item["x"]), float(item["y"]))
			var global_center := gs.table_view.to_global(center)
			var half := BasketModel.hit_size(item) * 0.5
			var angle := deg_to_rad(float(item["rot"]))
			var corners: Array = []
			for sx in [-1, 1]:
				for sy in [-1, 1]:
					var corner: Vector2 = gs.table_view.to_global(center + Vector2(half.x * sx, half.y * sy).rotated(angle))
					corners.append({"x": corner.x, "y": corner.y})
			var node: SnackView = gs.snack_nodes.get(uid)
			table_items.append({"uid": uid, "snack": String(item["snack"]),
				"size": int(item["size"]), "giant": BasketModel.is_giant(item),
				"package_scale": float(item.get("package_scale", 1.0)),
				"product_scale": float(item.get("product_scale", 1.0)),
				"logical_size": _point_snapshot(BasketModel.hit_size(item)),
				"table_x": center.x, "table_y": center.y,
				"x": global_center.x, "y": global_center.y,
				"rotation": node.rotation if node else 0.0, "flying": node.flying if node else true,
				"global_scale": node.global_scale.x if node else 0.0,
				"parent_table": node.get_parent() == gs.table_view if node else false, "corners": corners})
		var live_baskets := 0
		for child in gs.get_children():
			if child is BasketView and child.is_visible_in_tree():
				live_baskets += 1
		var entries: Array = []
		for item in st.tray.entries:
			var uid := int(item["uid"])
			if gs.snack_nodes.has(uid):
				var node: SnackView = gs.snack_nodes[uid]
				entries.append({"uid": uid, "snack": String(item["snack"]),
					"x": node.global_position.x, "y": node.global_position.y, "flying": node.flying})
		var active_items: Array = []
		for item in st.active_batch:
			active_items.append({"uid": int(item["uid"]), "snack": String(item["snack"])})
		var queued_batches: Array = []
		for batch in st.batch_queue:
			var queued_items: Array = []
			for item in batch["items"]:
				queued_items.append({"uid": int(item["uid"]), "snack": String(item["snack"])})
			queued_batches.append({"snack": String(batch["snack"]), "combo": int(batch["combo"]), "items": queued_items})
		var giant_ids := {}
		var giant_items := 0
		for item in st.basket.items:
			if BasketModel.is_giant(item):
				giant_ids[String(item["snack"])] = true
				giant_items += 1
		data = {
			"page": "game", "state": st.state, "level": gs.level_id,
			"test_mode": st.test_mode, "test_config": st.test_options,
			"package_scale": float(st.cfg.get("package_scale", 1.0)),
			"current_order_items": st.current_order_size(),
			"giant_kinds": giant_ids.size(), "giant_items": giant_items,
			"customer": st.customer_index, "customers": st.customers_total,
			"customer_id": st.current_customer_id(), "customer_name": String(st.current_customer().get("name", "顾客")),
			"customer_discovered": save.customers_discovered.has(st.current_customer_id()),
			"switching": gs._switching_customer, "pouring": gs._pouring,
			"basket_phase": gs._basket_phase, "drag_uid": gs._drag_uid,
			"basket_rotation": gs.basket_view.side_tilt if is_instance_valid(gs.basket_view) else 0.0,
			"basket_tilt": gs.basket_view.side_tilt if is_instance_valid(gs.basket_view) else 0.0,
			"basket_x": gs.basket_view.position.x if is_instance_valid(gs.basket_view) else 0.0,
			"basket_y": gs.basket_view.position.y if is_instance_valid(gs.basket_view) else 0.0,
			"basket_scale": gs.basket_view.scale.x if is_instance_valid(gs.basket_view) else 0.0,
			"basket_view_rotation": gs.basket_view.rotation if is_instance_valid(gs.basket_view) else 0.0,
			"basket_root_rotation": _vector3_snapshot(gs.basket_view.basket_root.rotation if is_instance_valid(gs.basket_view) else Vector3.ZERO),
			"basket_mouth": _point_snapshot(gs.basket_view.mouth_global_position() if is_instance_valid(gs.basket_view) else Vector2.ZERO),
			"spill_origin": _point_snapshot(gs._last_spill_origin),
			"basket_present": is_instance_valid(gs.basket_view) and gs.basket_view.is_visible_in_tree(),
			"basket_alpha": gs.basket_view.modulate.a if is_instance_valid(gs.basket_view) else 0.0,
			"live_basket_count": live_baskets, "table_items": table_items,
			"active_batch": active_items, "batch_queue": queued_batches,
			"batch_phase": st.batch_phase, "batch_timer": st.batch_timer,
			"batch_duration": st.batch_duration, "batch_serial": st.batch_serial,
			"weighed_serial": st.weighed_serial,
			"price_tags": gs._price_tags.size(), "price_tag_serial": gs._price_tag_serial,
			"table_tap": {"seq": gs._table_tap_seq, "uid": gs._last_table_tap_uid,
				"outcome": gs._last_table_tap_outcome, "target_uid": gs._last_table_tap_target_uid,
				"from": _point_snapshot(gs._last_table_tap_from), "to": _point_snapshot(gs._last_table_tap_to)},
			"click_flight_uid": gs._click_flight_uid,
			"queue_ids": st.upcoming_customers(), "tools": _legacy_tool_buttons(gs, []),
			"layout": {
				"pos": _rect_snapshot(gs.pos_view.get_global_rect()),
				"scale": _rect_snapshot(Rect2(gs.scale_view.global_position, Vector2(250, 350))),
				"queue": _rect_snapshot(gs._queue_box.get_global_rect()),
				"stand": _rect_snapshot(gs.device_stand.get_global_rect()),
				"counter": _rect_snapshot(gs.counter_view.get_global_rect()),
				"aisle": _rect_snapshot(gs.aisle_view.get_global_rect()),
				"cashier": _rect_snapshot(gs._cashier_zone.get_global_rect()),
				"table_safe": _rect_snapshot(Rect2(gs.table_view.to_global(BasketModel.TABLE_BOUNDS.position), BasketModel.TABLE_BOUNDS.size * GameScreen.BASKET_SCALE)),
					"drag_bounds": _rect_snapshot(Rect2(gs.table_view.to_global(BasketModel.DRAG_BOUNDS.position), BasketModel.DRAG_BOUNDS.size * GameScreen.BASKET_SCALE)),
					"drag_scale_block": _rect_snapshot(Rect2(gs.table_view.to_global(BasketModel.DRAG_SCALE_BLOCK.position), BasketModel.DRAG_SCALE_BLOCK.size * GameScreen.BASKET_SCALE)),
			},
			"progress": {"value": gs._bag_bar.value, "max": gs._bag_bar.max_value,
				"text": gs._bag_label.text, "rect": _rect_snapshot(gs._bag_bar.get_global_rect()),
				"bag": _rect_snapshot(gs._bag_icon.get_global_rect())},
			"combo": {"value": st.combo.combo, "best": st.combo.best, "text": gs._combo_label.text,
				"scale": gs._combo_badge.scale.x, "pulse_seq": _web_combo_pulses, "peak_scale": _web_combo_peak,
				"rect": _rect_snapshot(gs._combo_badge.get_global_rect())},
			"cashier": {"x": gs.cashier_view.position.x, "y": gs.cashier_view.position.y,
				"idle_y": gs.cashier_view.rig.position.y, "right_arm": gs.cashier_view.right_arm.rotation,
				"action_seq": gs.cashier_view.action_seq},
			"remaining": st.basket.remaining(), "total_items": st.total_items,
			"bagged_items": st.bagged_items, "bagged_groups": st.bagged_groups,
			"tray_weight": st.tray_weight(), "led": gs.scale_view._led.text,
			"led_value": gs.scale_view._led_value, "led_rolling": gs.scale_view._rolling,
			"free_slots": st.tray.free_slots(), "available": available, "tray": entries,
			"pos_mode": gs._pos_mode_label.text,
		}
	data["save_summary"] = {
		"coins": save.coins, "stars": save.stars.duplicate(true), "unlocked": save.unlocked,
		"discovered": save.discovered.size(), "customers_discovered": save.customers_discovered.size(),
		"preset": String(save.settings.get("preset", "standard")),
	}
	return JSON.stringify(data)


func _option_snapshot(option: OptionButton) -> Dictionary:
	var data := _rect_snapshot(option.get_global_rect())
	var popup := option.get_popup()
	data["item_count"] = popup.item_count
	data["popup"] = {"visible": popup.visible,
		"rect": _rect_snapshot(Rect2(Vector2(popup.position), Vector2(popup.size)))}
	return data


func _rect_snapshot(rect: Rect2) -> Dictionary:
	return {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}


func _point_snapshot(point: Vector2) -> Dictionary:
	return {"x": point.x, "y": point.y}


func _vector3_snapshot(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


## 只读查找旧道具按钮；正常页面应为空，不通过桥执行任何按钮命令。
func _legacy_tool_buttons(node: Node, result: Array) -> Array:
	if node is Button:
		var text: String = node.text
		if text.begins_with("吸附") or text == "+台位" or text == "冻结":
			result.append({"text": text, "visible": node.is_visible_in_tree(), "rect": _rect_snapshot(node.get_global_rect())})
	for child in node.get_children():
		_legacy_tool_buttons(child, result)
	return result
