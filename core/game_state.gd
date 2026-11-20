class_name GameState
extends RefCounted
## 核心状态机：桌面自由聚堆 / 连续自动称重 / 连击 / 顾客队列。
## 不依赖任何 Node：时间由表现层 update(delta) 驱动，演出全部走信号。

const BATCH_FLIGHT_TIME := 0.18
const BATCH_STAGGER_MAX := 0.08

signal snack_picked(item: Dictionary)
signal snack_returned(item: Dictionary)
signal snacks_gathered(snack_id: String, items: Array, combo: int)
signal batch_started(snack_id: String, items: Array, duration: float, flight_time: float, stagger: float, combo: int)
signal pick_rejected(uid: int, reason: String)
signal checkout_rejected(reason: String)
signal blind_revealed(item: Dictionary)
signal tray_changed
signal group_weighed(snack_id: String, items: Array, price: Dictionary, weight: int)
signal combo_changed(combo: int, best: int)
signal customer_served(customer_index: int)
signal customer_started(customer_index: int, customer_id: String)
signal level_completed(result: Dictionary)
signal level_failed(reason: String)
signal magnet_used(charges_left: int)
signal slot_added(slots: int)
signal freeze_used(seconds: float)

var db: ConfigDB
var cfg: Dictionary
var rng: GameRNG
var layout_rng: GameRNG
var customer_rng: GameRNG
var basket: BasketModel
var tray: TrayModel
var combo: ComboSystem
var clock: PatienceClock

var state: String = "playing"  # playing / complete / failed
var elapsed: float = 0.0
var coins_earned: float = 0.0
var bagged_groups: int = 0  # 实际手动称重批次数，由玩家决定批量大小
var bagged_items: int = 0
var total_items: int = 0
var customer_index: int = 0
var customers_total: int = 1
var magnet_charges: int = 0
var had_tray_full: bool = false
var return_count: int = 0
var _extra_slot_used: bool = false
var _freeze_used: bool = false
var _customer_ids: Array = []
var batch_queue: Array = []
var active_batch: Array = []
var active_combo: int = 0
var batch_phase: String = "idle"
var batch_timer: float = 0.0
var batch_duration: float = 0.0
var batch_serial: int = 0
var weighed_serial: int = 0


static func new_game(p_db: ConfigDB, level_id: int, upgrades: Dictionary, seed_value: int = 0) -> GameState:
	var g := GameState.new()
	g.db = p_db
	g.cfg = p_db.runtime_config(level_id, upgrades)
	g.rng = GameRNG.new(seed_value)
	g.layout_rng = GameRNG.new(seed_value)
	g.customer_rng = GameRNG.new(seed_value + 7919)
	g.tray = TrayModel.new(int(g.cfg["tray_slots"]))
	g.combo = ComboSystem.new(float(g.cfg["combo_window_sec"]))
	g.magnet_charges = int(g.cfg["magnet_charges"])
	g.customers_total = int(g.cfg.get("customers", 1))
	g._build_customer_queue()
	g.clock = PatienceClock.new(0.0)
	g._next_customer()
	return g


func level_id() -> int:
	return int(cfg.get("id", 1))


func _build_customer_queue() -> void:
	var featured := String(cfg.get("customer", "normal"))
	var used := {}
	for i in customers_total:
		# 保留关卡原有的普通/急性子/豪爽队列节奏，再从该类型中抽独立角色。
		var kind := "normal"
		if i == customers_total - 1:
			kind = featured
		elif featured == "rich" and i % 3 == 1:
			kind = "rich"
		elif featured == "hurried" and i % 2 == 1:
			kind = "hurried"
		var candidates: Array = []
		for customer_id in db.customers:
			if String(db.customers[customer_id].get("base_type", "normal")) == kind and not used.has(customer_id):
				candidates.append(customer_id)
		if candidates.is_empty():
			for customer_id in db.customers:
				if String(db.customers[customer_id].get("base_type", "normal")) == kind:
					candidates.append(customer_id)
		if candidates.is_empty():
			_customer_ids.append("legacy_" + kind)
			continue
		customer_rng.shuffle(candidates)
		var customer_id := String(candidates[0])
		used[customer_id] = true
		_customer_ids.append(customer_id)


func current_customer_id() -> String:
	if customer_index <= 0 or _customer_ids.is_empty():
		return "legacy_" + String(cfg.get("customer", "normal"))
	return String(_customer_ids[mini(customer_index - 1, _customer_ids.size() - 1)])


func current_customer() -> Dictionary:
	var fallback := {
		"id": current_customer_id(), "name": "顾客", "personality": "随和",
		"base_type": String(cfg.get("customer", "normal")), "avatar": "customer_normal.svg",
		"lines": ["今天也要零食自由！"], "patience_mult": 1.0, "combo_window_mult": 1.0,
	}
	return db.customers.get(current_customer_id(), fallback)


## 兼容关卡和测试使用的行为类型；显示、台词和图鉴一律使用独立角色 ID。
func current_customer_type() -> String:
	return String(current_customer().get("base_type", "normal"))


## 返回后续角色 ID，供队列头像使用；同一队列尽量不重复人物。
func upcoming_customers() -> Array:
	var result: Array = []
	for i in range(customer_index, mini(customers_total, customer_index + 3)):
		result.append(_customer_ids[i])
	return result


func _next_customer() -> void:
	customer_index += 1
	basket = LevelGenerator.generate(cfg, db.snacks, layout_rng)
	batch_queue.clear()
	active_batch.clear()
	active_combo = 0
	batch_phase = "idle"
	batch_timer = 0.0
	batch_duration = 0.0
	tray.clear()
	if customer_index == 1:
		total_items = basket.remaining() * customers_total
	var profile := current_customer()
	clock.reset(float(cfg.get("patience", 0.0)) * float(profile.get("patience_mult", 1.0)))
	# 新顾客：恢复基础台位、耐心与一次性道具，连击不可跨客延续。
	tray.slots = int(cfg["tray_slots"])
	magnet_charges = int(cfg["magnet_charges"])
	_extra_slot_used = false
	_freeze_used = false
	combo.reset()
	combo.window = float(cfg.get("combo_window_sec", 3.0)) * float(profile.get("combo_window_mult", 1.0))
	combo_changed.emit(combo.combo, combo.best)
	customer_started.emit(customer_index, current_customer_id())


func update(delta: float) -> void:
	if state != "playing":
		return
	elapsed += delta
	var combo_before := combo.combo
	combo.update(delta)
	if combo_before > 0 and combo.combo == 0:
		combo_changed.emit(0, combo.best)
	clock.update(delta)
	if clock.depleted():
		_fail("patience")
		return
	_update_batch(delta)

func pick(uid: int) -> bool:
	if state != "playing":
		return false
	if not basket.can_pick(uid):
		pick_rejected.emit(uid, "covered")
		return false
	var item := basket.get_item(uid)
	if not tray.can_fit(int(item["size"])):
		pick_rejected.emit(uid, "no_space")
		had_tray_full = true
		return false

	basket.pick(uid)
	if item.get("blind", false) and not item.get("revealed", true):
		item["revealed"] = true
		blind_revealed.emit(item)
	tray.add(item)
	combo.register_pick()
	combo_changed.emit(combo.combo, combo.best)
	snack_picked.emit(item)
	tray_changed.emit()
	return true


## 桌面拖动只改变位置/层序，不拣入、不结算；后续退货回到整理后的位置。
func move_item(uid: int, point: Vector2, bring_to_front: bool = false) -> bool:
	if state != "playing":
		return false
	return basket.move_item(uid, point, bring_to_front)


## 松手是完整桌面命令：先更新位置，再统一检测所有合格连通堆。
func finish_move(uid: int, point: Vector2, bring_to_front: bool = false) -> bool:
	var moved := move_item(uid, point, bring_to_front)
	if moved:
		scan_clusters()
	return moved


func scan_clusters() -> int:
	if state != "playing":
		return 0
	var ready := BasketModel.find_ready_clusters(basket.items)
	for group in ready:
		var snack_id := String(group["snack"])
		var group_items: Array = group["items"]
		for item in group_items:
			basket.pick(int(item["uid"]))
			if item.get("blind", false) and not item.get("revealed", true):
				item["revealed"] = true
				blind_revealed.emit(item)
			combo.register_pick()
		combo_changed.emit(combo.combo, combo.best)
		batch_queue.append({"snack": snack_id, "items": group_items, "combo": combo.combo})
		snacks_gathered.emit(snack_id, group_items, combo.combo)
	if batch_phase == "idle":
		begin_next_batch()
	return ready.size()


func begin_next_batch() -> Array:
	if state != "playing" or batch_phase != "idle" or batch_queue.is_empty():
		return []
	var batch: Dictionary = batch_queue.pop_front()
	active_batch = batch["items"]
	active_combo = int(batch["combo"])
	batch_phase = "flying"
	var stagger := minf(0.025, BATCH_STAGGER_MAX / maxf(1.0, float(active_batch.size() - 1)))
	batch_duration = BATCH_FLIGHT_TIME + stagger * float(active_batch.size() - 1)
	batch_timer = batch_duration
	tray.clear()
	for item in active_batch:
		tray.add(item)
	batch_serial += 1
	batch_started.emit(String(batch["snack"]), active_batch, batch_duration, BATCH_FLIGHT_TIME, stagger, active_combo)
	tray_changed.emit()
	return active_batch


func _settle_active_batch() -> bool:
	if batch_phase != "flying" or active_batch.is_empty():
		return false
	var customer_before := customer_index
	var group := active_batch.duplicate()
	var snack_id := String(group[0]["snack"])
	var price := ScoreSystem.batch_price(level_id(), group.size(), active_combo)
	var weight := int(tray_weight() * rng.randf_range(0.95, 1.05))
	tray.clear()
	bagged_groups += 1
	bagged_items += group.size()
	coins_earned += float(price["total"])
	active_batch.clear()
	active_combo = 0
	batch_phase = "idle"
	batch_timer = 0.0
	batch_duration = 0.0
	weighed_serial += 1
	group_weighed.emit(snack_id, group, price, weight)
	tray_changed.emit()
	_check_end()
	if state == "playing" and customer_index == customer_before:
		begin_next_batch()
	return true


func _update_batch(delta: float) -> void:
	var remaining := delta
	var customer_before := customer_index
	if batch_phase == "idle":
		begin_next_batch()
	while batch_phase == "flying" and remaining > 0.0 and state == "playing" and customer_index == customer_before:
		if batch_timer > remaining:
			batch_timer -= remaining
			return
		remaining -= batch_timer
		batch_timer = 0.0
		_settle_active_batch()


func batches_clear() -> bool:
	return active_batch.is_empty() and batch_queue.is_empty()


## 双击聚拢：以桌面位置为中心，只收半径内、实际露出的同款，受台位限制且不自动结算。
func gather_nearby(uid: int, radius: float = BasketModel.GATHER_RADIUS) -> Array:
	var target := basket.get_item(uid)
	if target.is_empty():
		return []
	return gather_nearby_at(String(target["snack"]), Vector2(float(target["x"]), float(target["y"])), radius)


func gather_nearby_at(snack_id: String, origin: Vector2, radius: float = BasketModel.GATHER_RADIUS) -> Array:
	var gathered: Array = []
	if state != "playing":
		return gathered
	for item in basket.nearby_same_at(snack_id, origin, radius):
		if not pick(int(item["uid"])):
			break
		gathered.append(int(item["uid"]))
	return gathered


## 点击称重台上的物品：退回原购物篮、原位置和原层序，不判失败。
func return_item(uid: int) -> bool:
	if state != "playing" or not tray.contains(uid):
		return false
	var item := tray.remove_uid(uid)
	basket.restore(uid)
	return_count += 1
	combo.reset()
	combo_changed.emit(combo.combo, combo.best)
	snack_returned.emit(item)
	tray_changed.emit()
	return true


## 收银屏“结算”：台上为空或混品时拒绝；同款 1 件也允许称重。
func settle_scale() -> bool:
	if state != "playing":
		return false
	if tray.is_empty():
		checkout_rejected.emit("empty")
		return false
	if not tray.is_uniform():
		checkout_rejected.emit("mixed")
		return false
	var group := tray.entries.duplicate()
	var snack_id := String(group[0]["snack"])
	var price := ScoreSystem.batch_price(level_id(), group.size(), combo.combo)
	var weight := tray_weight()
	weight = int(weight * rng.randf_range(0.95, 1.05))
	tray.clear()
	bagged_groups += 1
	bagged_items += group.size()
	coins_earned += float(price["total"])
	group_weighed.emit(snack_id, group, price, weight)
	tray_changed.emit()
	_check_end()
	return true


## 当前台上理论重量：每次拣入、退货和吸附后都可直接查询，不等待结算动画。
func tray_weight() -> int:
	var weight := 0
	for item in tray.entries:
		weight += db.snack_weight(String(item["snack"])) * int(item.get("size", 1))
	return weight


func _check_end() -> void:
	if state != "playing" or basket.remaining() != 0 or not tray.is_empty() or not batches_clear():
		return
	if customer_index < customers_total:
		customer_served.emit(customer_index)
		_next_customer()
	else:
		state = "complete"
		level_completed.emit(settle())


## 吸附：只吸当前露出的同款，受台上容量限制，不自动称重。
func use_magnet(snack_id: String) -> bool:
	if state != "playing" or magnet_charges <= 0:
		return false
	if not tray.is_empty() and (not tray.is_uniform() or String(tray.entries[0]["snack"]) != snack_id):
		pick_rejected.emit(-1, "mixed")
		return false
	var targets := basket.find_snack_items(snack_id)
	var selected: Array = []
	var free := tray.free_slots()
	for item in targets:
		var size := int(item["size"])
		if free >= size:
			selected.append(item)
			free -= size
	if selected.is_empty():
		pick_rejected.emit(-1, "no_space")
		return false
	magnet_charges -= 1
	combo.register_pick()
	combo_changed.emit(combo.combo, combo.best)
	for item in selected:
		basket.pick(int(item["uid"]))
		if item.get("blind", false) and not item.get("revealed", true):
			item["revealed"] = true
			blind_revealed.emit(item)
		tray.add(item)
		snack_picked.emit(item)
	magnet_used.emit(magnet_charges)
	tray_changed.emit()
	return true


func use_extra_slot() -> bool:
	if state != "playing" or _extra_slot_used:
		return false
	_extra_slot_used = true
	tray.slots += 1
	slot_added.emit(tray.slots)
	return true


func use_freeze() -> bool:
	if state != "playing" or _freeze_used or clock.unlimited:
		return false
	_freeze_used = true
	clock.freeze(10.0)
	freeze_used.emit(10.0)
	return true


## 台上同款优先；混品时提示玩家先退货，不再推荐新物品。
func hint_snack() -> String:
	if not tray.is_empty():
		if not tray.is_uniform():
			return ""
		var snack_id := String(tray.entries[0]["snack"])
		if not basket.find_snack_items(snack_id).is_empty():
			return snack_id
	var counts := {}
	for it in basket.top_items():
		counts[it["snack"]] = int(counts.get(it["snack"], 0)) + 1
	var best_snack := ""
	var best_count := 0
	for snack_id in counts:
		if int(counts[snack_id]) > best_count:
			best_count = int(counts[snack_id])
			best_snack = String(snack_id)
	return best_snack


func settle() -> Dictionary:
	return ScoreSystem.settle({
		"completed": state == "complete",
		"coins_earned": coins_earned,
		"best_combo": combo.best,
		"had_tray_full": had_tray_full,
		"patience_unlimited": clock.unlimited,
		"patience_ratio": clock.ratio(),
		"time_used": elapsed,
		"total_items": total_items,
		"bagged_items": bagged_items,
		"bagged_groups": bagged_groups,
		"return_count": return_count,
		"tip_mult": float(cfg.get("tip_mult", 1.0)),
	})


func _fail(reason: String) -> void:
	if state != "playing":
		return
	state = "failed"
	level_failed.emit(reason)
