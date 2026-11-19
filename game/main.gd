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
	elif current is ResultScreen:
		data["page"] = "result"
		if current.next_button:
			data["next"] = {"x": current.next_button.global_position.x + current.next_button.size.x * 0.5,
				"y": current.next_button.global_position.y + current.next_button.size.y * 0.5}
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
					"size": int(item["size"]), "weight": db.snack_weight(String(item["snack"])) * int(item.get("size", 1)),
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
			table_items.append({"uid": uid, "x": global_center.x, "y": global_center.y,
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
		var zone_snapshots: Array = []
		for zone_index in ZoneModel.ZONE_COUNT:
			var zone_items: Array = []
			for item in st.zones.sections[zone_index]:
				var uid := int(item["uid"])
				var node: SnackView = gs.snack_nodes.get(uid)
				zone_items.append({"uid": uid, "snack": String(item["snack"]),
					"x": node.global_position.x if node else 0.0,
					"y": node.global_position.y if node else 0.0,
					"flying": node.flying if node else true,
					"interactive": node.interactive if node else false})
			var zone_rect: Rect2 = GameScreen.ZONE_RECTS[zone_index]
			zone_snapshots.append({"index": zone_index, "items": zone_items,
				"count": zone_items.size(), "queued": st.zones.queue.has(zone_index),
				"active": st.zones.active_zone == zone_index,
				"complete": st.zones.complete_snack(zone_index, st.basket),
				"rect": _rect_snapshot(Rect2(gs.table_view.to_global(zone_rect.position), zone_rect.size * gs.table_view.scale))})
		data = {
			"page": "game", "state": st.state, "level": gs.level_id,
			"customer": st.customer_index, "customers": st.customers_total,
			"customer_id": st.current_customer_id(), "customer_name": String(st.current_customer().get("name", "顾客")),
			"customer_discovered": save.customers_discovered.has(st.current_customer_id()),
			"switching": gs._switching_customer, "pouring": gs._pouring,
			"basket_phase": gs._basket_phase, "drag_uid": gs._drag_uid, "last_double_count": gs._last_double_count,
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
			"zones": zone_snapshots, "zone_queue": st.zones.queue.duplicate(),
			"zone_active": st.zones.active_zone, "zone_pump_running": gs._zone_pump_running,
			"auto_settle": gs._auto_settle, "manual_settle_requested": gs._manual_settle_requested,
			"manual_settle_seq": gs._manual_settle_seq,
			"table_tap": {"seq": gs._table_tap_seq, "uid": gs._last_table_tap_uid},
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
			"free_slots": st.tray.free_slots(), "available": available, "tray": entries,
			"checkout": {"x": gs._checkout_btn.global_position.x + gs._checkout_btn.size.x * 0.5,
				"y": gs._checkout_btn.global_position.y + gs._checkout_btn.size.y * 0.5,
				"enabled": not gs._checkout_btn.disabled},
		}
	return JSON.stringify(data)


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
