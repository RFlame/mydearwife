class_name GameScreen
extends Control
## 俯视收银工作台：桌面自由聚堆 / 右侧连续称重 / 底部全宽收银员过道。
## 输入只转成 core 命令；聚堆、批次计时、换顾客与结算均由 core 驱动。

const BASKET_STAGE_PIVOT := Vector2(24, 710)
const TABLE_HOME := Vector2(0, 400)
const SCALE_HOME := Vector2(452, 282)
const POS_HOME := Vector2(480, 138)
const QUEUE_HOME := Vector2(190, 250)
const CASHIER_HOME := Vector2(360, 1152)
const CASHIER_ZONE := Rect2(0, 1024, 720, 256)
const BASKET_SCALE := 0.78
const BASKET_LIFT_SCALE := 0.70
const BASKET_LIFT_PIVOT := Vector2(24, 670)
const BASKET_POUR_TIME := 1.20
const BASKET_FIRST_SPILL := 0.12
const DRAG_THRESHOLD := 9.0
const SCALE_RESIDUE_TIME := 0.16

var app = null
var level_id: int = 1
var seed_value: int = 0
var test_options: Dictionary = {}
var test_mode: bool = false
var state: GameState

var basket_view: BasketView
var table_view: Node2D
var tray_view: TrayView
var scale_view: ScaleView
var pos_view: Control
var device_stand: TextureRect
var counter_view: TextureRect
var aisle_view: TextureRect
var cashier_view: CashierView
var _cashier_zone: Panel
var customer_view: CustomerView
var snack_nodes := {}
var _table_tap_seq := 0
var _last_table_tap_uid := -1
var _price_tags: Array = []
var _price_tag_serial := 0

var _coin_label: Label
var _customer_label: Label
var _queue_box: Control
var _pos_detail: Label
var _pos_mode_label: Label
var _settle_hint: Label
var _combo_badge: PanelContainer
var _combo_label: Label
var _combo_tween: Tween = null
var _bag_icon: TextureRect
var _bag_bar: ProgressBar
var _bag_label: Label
var _paused := false
var _switching_customer := false
var _pouring := false
var _basket_phase := "arrive"
var _last_spill_origin := Vector2.ZERO
var _basket_swap_tween: Tween = null
var _drag_uid := -1
var _drag_offset := Vector2.ZERO
var _drag_item_origin := Vector2.ZERO
var _drag_start := Vector2.ZERO
var _dragging := false
var _suppress_release := false
var _last_tap_uid := -1
var _last_tap_snack := ""
var _last_tap_origin := Vector2.ZERO
var _last_tap_pointer := Vector2.ZERO
var _last_tap_msec := -100000
var _idle := 0.0
var _hint_uids: Array = []
var _tex_cache := {}


static func create(p_app, p_level: int, p_seed: int = 0, p_options: Dictionary = {}) -> GameScreen:
	var s := GameScreen.new()
	s.app = p_app
	s.level_id = p_level
	s.seed_value = p_seed
	s.test_options = p_options.duplicate(true)
	s.test_mode = bool(p_options.get("test_mode", false))
	return s


func _ready() -> void:
	state = GameState.new_game(app.db, level_id, app.save.upgrades, seed_value, test_options)
	_build_background()
	_build_hud()
	_build_customer()
	if not test_mode:
		app.save.meet_customer(state.current_customer_id())
	_build_counter()
	_build_cashier()
	_build_basket_area()
	_connect_core()
	_start_basket_pour()
	_refresh_bag()
	_refresh_pos()
	_on_combo(0, 0)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if _drag_uid > 0:
			_finish_table_press()
			get_viewport().set_input_as_handled()
		return
	if _paused or _switching_customer or state == null or state.state != "playing":
		return
	if event is InputEventMouseMotion and _drag_uid > 0:
		_update_table_drag(event.position)
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	# 桌面按下只准备拖动；松开未越阈值时仅播放原地轻跳。
	var table_uid := state.basket.hit_test_assisted(table_view.to_local(event.position))
	if table_uid > 0:
		_drag_uid = table_uid
		_drag_start = event.position
		_dragging = false
		var item := state.basket.get_item(table_uid)
		_drag_item_origin = Vector2(float(item["x"]), float(item["y"]))
		_drag_offset = _drag_item_origin - table_view.to_local(event.position)
		get_viewport().set_input_as_handled()


func _update_table_drag(pointer: Vector2) -> void:
	if not _dragging and pointer.distance_to(_drag_start) < DRAG_THRESHOLD:
		return
	var node: SnackView = snack_nodes.get(_drag_uid)
	if node == null or node.flying:
		_cancel_interaction()
		return
	var just_started := not _dragging
	if just_started:
		_dragging = true
		_clear_hint()
		node.begin_drag()
		node.z_index = 650
	var desired := table_view.to_local(pointer) + _drag_offset
	if state.move_item(_drag_uid, desired, just_started):
		var item := state.basket.get_item(_drag_uid)
		var center := Vector2(float(item["x"]), float(item["y"]))
		node.global_position = table_view.to_global(center)


func _finish_table_press() -> void:
	var uid := _drag_uid
	_drag_uid = -1
	if _dragging:
		_dragging = false
		if snack_nodes.has(uid):
			var item := state.basket.get_item(uid)
			var node: SnackView = snack_nodes[uid]
			node.end_drag(int(item["layer"]) * 2 + 2)
			SFX.play("pick", 0.72)
			state.finish_move(uid, Vector2(float(item["x"]), float(item["y"])))
		_refresh_table_layers()
		return
	_on_snack_clicked(uid)


func _process(delta: float) -> void:
	if _paused or state == null:
		return
	if not _switching_customer:
		state.update(delta)
	customer_view.set_patience(state.clock.ratio(), state.clock.frozen > 0.0)
	_idle += delta
	if not _switching_customer and state.cfg.get("auto_hint", false) and _idle > 3.0 and state.state == "playing":
		_apply_hint()


# ---------------- 俯视工作台布局 ----------------

func _build_background() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://assets/svg/bg_shop.svg")
	bg.size = Vector2(720, 1280)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index = -100
	add_child(bg)
	counter_view = TextureRect.new()
	counter_view.name = "CounterTop"
	counter_view.texture = load("res://assets/svg/counter_top.svg")
	counter_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	counter_view.position = Vector2(0, 320)
	counter_view.size = Vector2(720, 704)
	counter_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	counter_view.z_index = -90
	add_child(counter_view)
	aisle_view = TextureRect.new()
	aisle_view.name = "CashierAisle"
	aisle_view.texture = load("res://assets/svg/cashier_aisle.svg")
	aisle_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	aisle_view.position = CASHIER_ZONE.position
	aisle_view.size = CASHIER_ZONE.size
	aisle_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	aisle_view.z_index = -89
	add_child(aisle_view)


func _build_hud() -> void:
	var hud := UIKit.make_panel(UIKit.PAPER, 22)
	hud.position = Vector2(20, 8)
	hud.size = Vector2(680, 92)
	var hud_style := UIKit.stylebox(UIKit.PAPER, UIKit.BROWN, 3, 22)
	hud_style.content_margin_left = 10
	hud_style.content_margin_right = 10
	hud_style.content_margin_top = 4
	hud_style.content_margin_bottom = 4
	hud.add_theme_stylebox_override("panel", hud_style)
	add_child(hud)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	hud.add_child(rows)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	rows.add_child(top)
	_coin_label = UIKit.make_label("试玩" if test_mode else "¥ %d" % app.save.coins, 22)
	_coin_label.custom_minimum_size.x = 100
	top.add_child(_coin_label)
	var level_label := UIKit.make_label("第 %d 关" % level_id, 22, UIKit.RED)
	level_label.custom_minimum_size.x = 82
	top.add_child(level_label)
	_customer_label = UIKit.make_label("顾客 %d/%d" % [state.customer_index, state.customers_total], 20, UIKit.BLUE)
	_customer_label.custom_minimum_size.x = 104
	top.add_child(_customer_label)
	var pause_btn := UIKit.make_button("暂停", UIKit.GREEN, UIKit.CREAM, 20)
	pause_btn.pressed.connect(_show_pause)
	top.add_child(pause_btn)
	var spring := Control.new()
	spring.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spring)
	_combo_badge = UIKit.make_panel(UIKit.GOLD, 18)
	_combo_badge.custom_minimum_size.x = 148
	_combo_badge.resized.connect(func(): _combo_badge.pivot_offset = _combo_badge.size * 0.5)
	_combo_label = UIKit.make_label("COMBO —", 22)
	_combo_badge.add_child(_combo_label)
	top.add_child(_combo_badge)

	var progress_row := HBoxContainer.new()
	progress_row.add_theme_constant_override("separation", 8)
	rows.add_child(progress_row)
	_bag_icon = TextureRect.new()
	_bag_icon.texture = load("res://assets/svg/bag.svg")
	_bag_icon.custom_minimum_size = Vector2(34, 32)
	_bag_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bag_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_bag_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bag_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress_row.add_child(_bag_icon)
	_bag_label = UIKit.make_label("", 16, UIKit.BROWN, HORIZONTAL_ALIGNMENT_LEFT)
	_bag_label.custom_minimum_size.x = 278
	_bag_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	progress_row.add_child(_bag_label)
	_bag_bar = UIKit.make_bar(UIKit.RED, 18)
	_bag_bar.step = 0.000001
	_bag_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bag_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bag_bar.value = 0
	progress_row.add_child(_bag_bar)


func _build_customer() -> void:
	customer_view = CustomerView.new()
	customer_view.position = Vector2(10, 106)
	add_child(customer_view)
	customer_view.setup(state.current_customer(), state.customer_index)
	_queue_box = Control.new()
	_queue_box.name = "CustomerQueue"
	_queue_box.position = QUEUE_HOME
	_queue_box.size = Vector2(250, 64)
	_queue_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_queue_box)
	_refresh_queue()


func _build_counter() -> void:
	# POS 与承重台同轴上下排列，短支架连接成现实收银台的一体式结构。
	device_stand = TextureRect.new()
	device_stand.name = "ScaleStand"
	device_stand.texture = load("res://assets/svg/scale_stand.svg")
	device_stand.position = Vector2(548, 260)
	device_stand.size = Vector2(58, 58)
	device_stand.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	device_stand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	device_stand.z_index = -1
	add_child(device_stand)
	scale_view = ScaleView.new()
	scale_view.name = "ScalePlatform"
	scale_view.position = SCALE_HOME
	add_child(scale_view)
	tray_view = TrayView.new()
	tray_view.position = scale_view.position
	add_child(tray_view)
	tray_view.build(state.tray.slots)

	pos_view = Control.new()
	pos_view.name = "PosDisplay"
	pos_view.position = POS_HOME
	pos_view.size = Vector2(194, 132)
	pos_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(pos_view)
	var screen := TextureRect.new()
	screen.texture = load("res://assets/svg/pos_screen.svg")
	screen.size = Vector2(194, 132)
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pos_view.add_child(screen)
	var title := UIKit.make_label("收银显示屏", 16, UIKit.BROWN)
	title.position = Vector2(8, 3)
	title.size = Vector2(178, 22)
	pos_view.add_child(title)
	_pos_detail = UIKit.make_label("", 14, Color("B8F5D3"))
	_pos_detail.position = Vector2(12, 29)
	_pos_detail.size = Vector2(170, 44)
	_pos_detail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pos_view.add_child(_pos_detail)
	_pos_mode_label = UIKit.make_label("聚堆自动称重", 18, UIKit.CREAM)
	_pos_mode_label.position = Vector2(12, 82)
	_pos_mode_label.size = Vector2(170, 40)
	_pos_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pos_mode_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pos_view.add_child(_pos_mode_label)

	_settle_hint = UIKit.make_label("同款聚堆 · 异款留隙\n松手自动称重", 18, UIKit.BROWN)
	_settle_hint.position = Vector2(446, 650)
	_settle_hint.size = Vector2(264, 48)
	add_child(_settle_hint)


func _build_cashier() -> void:
	_cashier_zone = Panel.new()
	_cashier_zone.name = "CashierStation"
	_cashier_zone.position = CASHIER_ZONE.position
	_cashier_zone.size = CASHIER_ZONE.size
	_cashier_zone.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cashier_zone.z_index = -60
	_cashier_zone.add_theme_stylebox_override("panel", UIKit.stylebox(
		Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0))
	add_child(_cashier_zone)
	var station_label := UIKit.make_label("收银员过道", 16, Color(UIKit.CREAM, 0.64))
	station_label.position = Vector2(300, 22)
	station_label.size = Vector2(120, 24)
	station_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cashier_zone.add_child(station_label)
	cashier_view = CashierView.new()
	cashier_view.name = "Cashier"
	cashier_view.position = CASHIER_HOME
	cashier_view.z_index = 20
	add_child(cashier_view)


func _build_basket_area() -> void:
	table_view = Node2D.new()
	table_view.name = "SortingTable"
	table_view.position = TABLE_HOME
	table_view.scale = Vector2.ONE * BASKET_SCALE
	add_child(table_view)


# ---------------- core 信号 ----------------

func _connect_core() -> void:
	state.snack_picked.connect(_on_snack_picked)
	state.snack_returned.connect(_on_snack_returned)
	state.snacks_gathered.connect(_on_snacks_gathered)
	state.batch_started.connect(_on_batch_started)
	state.tray_changed.connect(_on_tray_changed)
	state.group_weighed.connect(_on_group_weighed)
	state.blind_revealed.connect(_on_blind_revealed)
	state.pick_rejected.connect(_on_rejected)
	state.checkout_rejected.connect(_on_checkout_rejected)
	state.combo_changed.connect(_on_combo)
	state.customer_served.connect(_on_customer_served)
	state.customer_started.connect(_on_customer_started)
	state.level_completed.connect(_on_completed)
	state.level_failed.connect(_on_failed)


func _texture_for(item: Dictionary) -> Texture2D:
	var svg: String
	if item.get("blind", false) and not item.get("revealed", true):
		svg = "blind.svg"
	elif item.get("gift", false):
		svg = "gift.svg"
	else:
		svg = app.db.snacks.get(item["snack"], {}).get("svg", "blind.svg")
	if not _tex_cache.has(svg):
		_tex_cache[svg] = load("res://assets/svg/" + svg)
	return _tex_cache[svg]


func _make_basket_view() -> BasketView:
	var view := BasketView.new()
	view.position = BASKET_STAGE_PIVOT
	view.scale = Vector2.ONE * BASKET_SCALE
	add_child(view)
	return view


func _spawn_basket_items() -> void:
	for uid in snack_nodes:
		snack_nodes[uid].queue_free()
	snack_nodes.clear()
	var index := 0
	for item in state.basket.items:
		var node := SnackView.create(item, _texture_for(item))
		# 篮内使用紧凑摆位，核心 x/y 只作为倒到桌面后的最终落点。
		node.position = BasketView.packed_position(index)
		node.rotation = deg_to_rad(float(item["rot"]))
		node.z_index = int(item["layer"]) * 2 + 2
		basket_view.content.add_child(node)
		node.hide()
		basket_view.add_snack(node.uid, item, _texture_for(item), index)
		snack_nodes[node.uid] = node
		if BasketModel.is_giant(item):
			node.set_badge("巨")
		elif item.get("gift", false):
			node.set_badge(String(app.db.snacks.get(item["snack"], {}).get("name", "礼")).left(1))
		index += 1


func _on_snack_clicked(uid: int) -> void:
	if _paused or _switching_customer or state.state != "playing":
		return
	_idle = 0.0
	_clear_hint()
	var item := state.basket.get_item(uid)
	if item.is_empty() or item.get("picked", false):
		return
	var node: SnackView = snack_nodes.get(uid)
	if node and not node.flying:
		_table_tap_seq += 1
		_last_table_tap_uid = uid
		node.tap_bounce()
		SFX.play("pick", 0.88)


func _on_snack_picked(item: Dictionary) -> void:
	cashier_view.sort()
	SFX.play("pick", randf_range(0.95, 1.1))
	var node: SnackView = snack_nodes.get(item["uid"])
	if node == null:
		return
	node.z_index = 300 + (state.tray.entries.size() - 1) * 2
	var positions := tray_view.entry_positions(state.tray.entries)
	var target: Vector2 = positions.get(item["uid"], tray_view.to_global(TrayView.PILE_CENTER))
	node.fly_to(target, 0.26, true, TrayView.entry_rotation(item))


func _on_snacks_gathered(_snack_id: String, items: Array, _combo: int) -> void:
	cashier_view.sort()
	SFX.play("ding", 1.08)
	for item in items:
		var node: SnackView = snack_nodes.get(int(item["uid"]))
		if node:
			node.interactive = false
	if app != null and app._web_smoke_enabled:
		app._publish_web_smoke()


func _on_batch_started(_snack_id: String, group: Array, duration: float, flight_time: float, stagger: float, _combo: int) -> void:
	var positions := tray_view.entry_positions(group)
	var theoretical := 0
	for index in group.size():
		var item: Dictionary = group[index]
		theoretical += app.db.snack_weight(String(item["snack"])) * int(item.get("size", 1))
		var node: SnackView = snack_nodes.get(int(item["uid"]))
		if node:
			node.z_index = 600 + index
			node.fly_to(
				positions.get(int(item["uid"]), tray_view.to_global(TrayView.PILE_CENTER)),
				flight_time,
				false,
				TrayView.entry_rotation(item),
				float(index) * stagger
			)
	scale_view.show_weight(theoretical, duration, false)
	SFX.play("magnet", 1.18)
	if app != null and app._web_smoke_enabled:
		app._publish_web_smoke()


func _on_snack_returned(item: Dictionary) -> void:
	SFX.play("pick", 0.85)
	var node: SnackView = snack_nodes.get(item["uid"])
	if node == null:
		return
	node.z_index = 500 + int(item["uid"])
	var target := table_view.to_global(BasketView.home_position(item))
	node.return_to(target, int(item["layer"]) * 2 + 2, deg_to_rad(float(item["rot"])))


func _on_tray_changed() -> void:
	# 自动批次由 batch_started 统一控制飞行，不能提前瞬移到秤上。
	if state.batch_phase == "idle":
		_relayout_tray()
	_refresh_pos()


func _relayout_tray() -> void:
	var positions := tray_view.entry_positions(state.tray.entries)
	for i in state.tray.entries.size():
		var uid := int(state.tray.entries[i]["uid"])
		if not snack_nodes.has(uid):
			continue
		var node: SnackView = snack_nodes[uid]
		# 秤上的视觉层序按拿取先后排列，后放上的零食先响应重叠位置点击。
		node.z_index = 300 + i * 2
		node.move_to(positions[uid])


func _on_group_weighed(_snack_id: String, group: Array, price: Dictionary, weight: int) -> void:
	cashier_view.celebrate()
	var bag_target := _bag_icon.get_global_rect().get_center()
	for index in group.size():
		var item: Dictionary = group[index]
		var uid := int(item["uid"])
		var node: SnackView = snack_nodes.get(uid)
		if node:
			snack_nodes.erase(uid)
			node.z_index = 700 + index
			# 先在秤上短驻留，再独立装袋；后续批次使用其他节点，不等待这段演出。
			node.fly_to(bag_target + Vector2((index % 3 - 1) * 12, 0), 0.18, false, 0.0, SCALE_RESIDUE_TIME)
			var tween := create_tween()
			tween.tween_interval(SCALE_RESIDUE_TIME)
			tween.tween_property(node, "scale", Vector2.ONE * 0.25, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			tween.parallel().tween_property(node, "modulate:a", 0.0, 0.18)
			tween.tween_callback(node.queue_free)
	scale_view.show_weight(weight, float(state.cfg["weigh_anim_time"]))
	_show_price_tag(weight, int(price["total"]))
	_refresh_bag()
	customer_view.celebrate()
	if app != null and app._web_smoke_enabled:
		app._publish_web_smoke()


func _show_price_tag(weight: int, price: int) -> void:
	_price_tag_serial += 1
	var panel := UIKit.make_panel(UIKit.CREAM, 6)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(UIKit.make_label("%dg  ¥%d" % [weight, price], 24))
	add_child(panel)
	var offset := Vector2(0, -18 * mini(_price_tags.size(), 3))
	panel.global_position = scale_view.to_global(Vector2(20, 242)) + offset
	panel.size = panel.get_combined_minimum_size()
	panel.z_index = 800 + _price_tag_serial
	_price_tags.append(panel)
	SFX.play("print")
	var bag_target := _bag_icon.get_global_rect().get_center() - panel.size * 0.5
	var tween := create_tween()
	tween.tween_interval(0.25)
	tween.tween_callback(func(): SFX.play("bag"))
	tween.tween_property(panel, "global_position", bag_target, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(panel, "modulate:a", 0.0, 0.35)
	tween.tween_callback(func():
		_price_tags.erase(panel)
		panel.queue_free())


func _on_blind_revealed(item: Dictionary) -> void:
	var node: SnackView = snack_nodes.get(item["uid"])
	if node:
		node.reveal(_texture_for(item))
	SFX.play("combo", 1.5)


func _on_rejected(uid: int, reason: String) -> void:
	if uid >= 0 and snack_nodes.has(uid):
		snack_nodes[uid].reject()
	SFX.play("pick", 0.6)
	match reason:
		"no_space": UIKit.toast(self, "称重台满了，先结算或退回")
		"mixed": UIKit.toast(self, "请先整理成同一种零食")
		"covered": UIKit.toast(self, "被压住了，先拿走上面的零食")
		"locked": UIKit.toast(self, "同款已集齐，正在排队称重")


func _on_checkout_rejected(reason: String) -> void:
	SFX.play("pick", 0.6)
	UIKit.toast(self, "台上有不同零食，请点选退回" if reason == "mixed" else "请先放入零食")


func _on_combo(combo: int, _best: int) -> void:
	if _combo_tween and _combo_tween.is_valid():
		_combo_tween.kill()
	_combo_tween = null
	_combo_badge.scale = Vector2.ONE
	_combo_label.text = "COMBO ×%d" % combo if combo > 0 else "COMBO —"
	_combo_badge.pivot_offset = _combo_badge.size * 0.5
	if combo >= 2:
		SFX.play_combo(combo)
		_combo_tween = create_tween()
		_combo_tween.tween_property(_combo_badge, "scale", Vector2.ONE * 1.12, 0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_combo_tween.tween_property(_combo_badge, "scale", Vector2.ONE, 0.12)
		_combo_tween.tween_callback(func(): _combo_tween = null)


func _on_customer_served(_idx: int) -> void:
	UIKit.toast(self, "结账完成，下一位顾客")
	SFX.play("ding")


func _on_customer_started(_idx: int, customer_id: String) -> void:
	customer_view.setup(state.current_customer(), state.customer_index)
	if not test_mode:
		app.save.meet_customer(customer_id)
	_refresh_queue()
	_clear_hint()
	if state.customer_index > 1:
		_start_basket_pour()
	_customer_label.text = "顾客 %d/%d" % [state.customer_index, state.customers_total]
	_refresh_bag()
	_refresh_pos()


func _start_basket_pour() -> void:
	_cancel_interaction()
	_switching_customer = true
	_pouring = false
	_set_basket_phase("arrive")
	if is_instance_valid(basket_view):
		var previous := basket_view
		var retire := create_tween()
		retire.set_parallel(true)
		retire.tween_property(previous, "position", previous.position + Vector2(-160, -180), 0.28)
		retire.tween_property(previous, "modulate:a", 0.0, 0.28)
		retire.chain().tween_callback(previous.queue_free)
	basket_view = _make_basket_view()
	var pivot_home := BASKET_STAGE_PIVOT
	basket_view.position = pivot_home + Vector2(-520, 0)
	basket_view.scale = Vector2.ONE * BASKET_SCALE * 0.92
	basket_view.modulate.a = 0.0
	_spawn_basket_items()
	if _basket_swap_tween and _basket_swap_tween.is_valid():
		_basket_swap_tween.kill()
	_basket_swap_tween = create_tween()
	_basket_swap_tween.set_parallel(true)
	_basket_swap_tween.tween_property(basket_view, "position", pivot_home, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_basket_swap_tween.parallel().tween_property(basket_view, "scale", Vector2.ONE * BASKET_SCALE, 0.32)
	_basket_swap_tween.parallel().tween_property(basket_view, "modulate:a", 1.0, 0.22)
	_basket_swap_tween.chain().tween_callback(_lift_basket)
	_refresh_pos()


func _lift_basket() -> void:
	cashier_view.reach_for_basket()
	_set_basket_phase("lift")
	var lifting := basket_view
	_basket_swap_tween = create_tween()
	_basket_swap_tween.set_parallel(true)
	# 左外平行入场后仅作平移；篮体固定侧立 90°，长边与屏幕左缘平行。
	_basket_swap_tween.tween_property(lifting, "position", BASKET_LIFT_PIVOT, 0.38).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_basket_swap_tween.parallel().tween_property(lifting, "scale", Vector2.ONE * BASKET_LIFT_SCALE, 0.38)
	_basket_swap_tween.chain().tween_callback(_begin_pour)


func _begin_pour() -> void:
	_set_basket_phase("pour")
	_pouring = true
	SFX.play("bag", 0.78)
	var pouring := basket_view
	var uids := snack_nodes.keys()
	var stagger := minf(0.30, 0.98 / maxf(1.0, float(uids.size() - 1)))
	var release_end := BASKET_FIRST_SPILL + maxf(0.0, float(uids.size() - 1)) * stagger
	# 篮体保持不动；最后一件离开篮口后，仍等它落地再退出空篮。
	var hold_until := maxf(BASKET_POUR_TIME + 0.18, release_end + 0.60)
	_basket_swap_tween = create_tween()
	_basket_swap_tween.set_parallel(true)
	for i in uids.size():
		_basket_swap_tween.parallel().tween_callback(
			_spill_basket_item.bind(int(uids[i]), pouring)
		).set_delay(BASKET_FIRST_SPILL + float(i) * stagger)
	_basket_swap_tween.tween_interval(hold_until)
	_basket_swap_tween.set_parallel(false)
	_basket_swap_tween.tween_callback(func(): call_deferred("_set_basket_phase", "leave"))
	_basket_swap_tween.tween_property(pouring, "modulate:a", 0.0, 0.22)
	_basket_swap_tween.tween_callback(func():
		if basket_view == pouring:
			basket_view = null
		pouring.hide()
		pouring.queue_free()
		_finish_pour())


func _spill_basket_item(uid: int, pouring: BasketView) -> void:
	if pouring != basket_view or not is_instance_valid(pouring):
		return
	var node: SnackView = snack_nodes.get(uid)
	if node == null:
		return
	var item := state.basket.get_item(uid)
	# 3D 对应物仍在原处隐藏；2D 零食从真实篮口内的确定性位置开始抛物线飞行。
	var release := pouring.release_snack(uid)
	var release_position: Vector2 = release["position"]
	if node.get_parent() == pouring.content:
		node.reparent(table_view, false)
		node.scale = Vector2.ONE * (pouring.scale.x / table_view.scale.x) * float(release["depth_scale"])
		node.rotation = float(release["rotation"])
	node.show()
	_last_spill_origin = release_position
	node.global_position = release_position
	var target := table_view.to_global(BasketView.home_position(item))
	var arc_height := 74.0 + fmod(float(uid * 17), 34.0)
	var spin := 0.38 if uid % 2 == 0 else -0.30
	node.spill_to(target, deg_to_rad(float(item["rot"])), 0.42, 0.0, arc_height, spin)


func _set_basket_phase(phase: String) -> void:
	_basket_phase = phase
	# 只读 Web 桥在阶段赋值当帧留痕；低帧率跨过短阶段时仍可核验，不影响动画。
	if app != null and app._web_smoke_enabled:
		app._publish_web_smoke()


func _finish_pour() -> void:
	if is_instance_valid(basket_view):
		basket_view.hide()
		basket_view.queue_free()
	basket_view = null
	_pouring = false
	_switching_customer = false
	_set_basket_phase("done")
	_refresh_pos()
	state.scan_clusters()


func _cancel_interaction() -> void:
	if _drag_uid > 0 and snack_nodes.has(_drag_uid):
		var item := state.basket.get_item(_drag_uid)
		if not item.is_empty():
			snack_nodes[_drag_uid].end_drag(int(item["layer"]) * 2 + 2)
			if _dragging and not item.get("picked", false):
				state.finish_move(_drag_uid, Vector2(float(item["x"]), float(item["y"])))
	_drag_uid = -1
	_dragging = false
	_suppress_release = false
	_last_tap_uid = -1
	_last_tap_snack = ""
	_last_tap_msec = -100000


func _refresh_table_layers() -> void:
	for uid in snack_nodes:
		var item := state.basket.get_item(uid)
		var node: SnackView = snack_nodes[uid]
		if not item.is_empty() and not item.get("picked", false) and not node.flying:
			node.z_index = int(item["layer"]) * 2 + 2


func _on_completed(result: Dictionary) -> void:
	SFX.play("complete")
	SFX.play("coins")
	if not test_mode:
		app.save.add_result(level_id, result, state.cfg.get("pool", []))
		app.save.save()
	await get_tree().create_timer(1.1).timeout
	app.show_result(level_id, result)


func _on_failed(reason: String) -> void:
	SFX.play("fail")
	_paused = true
	var msg := "顾客等不及走了…" if reason == "patience" else "本次营业失败"
	_show_modal(msg, "再试一次")


func _refresh_bag() -> void:
	_bag_bar.value = float(state.bagged_items) / maxi(1, state.total_items)
	_bag_label.text = "已称重 %d / %d 件 · %d 批" % [state.bagged_items, state.total_items, state.bagged_groups]


func _refresh_pos() -> void:
	if not state.active_batch.is_empty():
		var snack_id := String(state.active_batch[0]["snack"])
		var snack_name := String(app.db.snacks.get(snack_id, {}).get("name", snack_id))
		_pos_detail.text = "%s × %d 件\n连续称重 · 等待 %d 批" % [snack_name, state.active_batch.size(), state.batch_queue.size()]
	elif not state.tray.is_empty():
		_pos_detail.text = "称重台 %d 件\n自动整理结算" % state.tray.entries.size()
	else:
		_pos_detail.text = "同款聚成一堆\n周边异款留空隙"
	if state.batch_phase == "idle":
		scale_view.set_live_weight(state.tray_weight())


func _refresh_queue() -> void:
	for child in _queue_box.get_children():
		child.queue_free()
	var panel := UIKit.make_panel(Color(UIKit.PAPER, 0.94), 12)
	panel.size = Vector2(250, 64)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_queue_box.add_child(panel)
	var title := UIKit.make_label("排队\n等候", 16, UIKit.BROWN)
	title.position = Vector2(8, 8)
	title.size = Vector2(50, 48)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_queue_box.add_child(title)
	var upcoming := state.upcoming_customers()
	if upcoming.is_empty():
		var last := UIKit.make_label("最后一位", 18, UIKit.RED)
		last.position = Vector2(64, 12)
		last.size = Vector2(170, 40)
		last.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_queue_box.add_child(last)
		return
	for i in upcoming.size():
		var avatar := TextureRect.new()
		avatar.texture = load("res://assets/svg/" + String(app.db.customers.get(upcoming[i], {}).get("avatar", "customer_normal.svg")))
		avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		avatar.position = Vector2(64 + i * 58, 4)
		avatar.size = Vector2(42, 42)
		avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_queue_box.add_child(avatar)
		var name_label := UIKit.make_label(String(app.db.customers.get(upcoming[i], {}).get("name", "顾客")), 11, UIKit.BROWN)
		name_label.position = Vector2(61 + i * 58, 46)
		name_label.size = Vector2(52, 16)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_queue_box.add_child(name_label)


# ---------------- 提示 / 暂停 / 弹窗 ----------------

func _apply_hint() -> void:
	_clear_hint()
	var snack := state.hint_snack()
	if snack == "":
		return
	for it in state.basket.top_items():
		if it["snack"] == snack and snack_nodes.has(it["uid"]):
			snack_nodes[it["uid"]].set_highlight(true)
			_hint_uids.append(it["uid"])
	_idle = -2.0


func _clear_hint() -> void:
	for uid in _hint_uids:
		if snack_nodes.has(uid):
			snack_nodes[uid].set_highlight(false)
	_hint_uids.clear()


func _show_pause() -> void:
	_paused = true
	_show_modal("歇一会儿，喝口茶", "继续营业")


func _show_modal(msg: String, primary_text: String) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.size = Vector2(720, 1280)
	dim.z_index = 1100
	add_child(dim)
	var panel := UIKit.make_panel(UIKit.PAPER, 20)
	panel.z_index = 1101
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)
	box.add_child(UIKit.make_label(msg, 32))
	var primary := UIKit.make_button(primary_text, UIKit.RED, UIKit.CREAM, 30)
	box.add_child(primary)
	var home := UIKit.make_button("返回店铺", UIKit.GREEN, UIKit.CREAM, 26)
	box.add_child(home)
	add_child(panel)
	panel.position = Vector2(360, 600) - panel.get_combined_minimum_size() * 0.5
	primary.pressed.connect(func():
		if state.state == "failed":
			if test_mode:
				app.start_test(test_options)
			else:
				app.start_level(level_id)
		else:
			_paused = false
			dim.queue_free()
			panel.queue_free())
	home.pressed.connect(func():
		if test_mode:
			app.show_test(test_options)
		else:
			app.show_home())
