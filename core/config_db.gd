class_name ConfigDB
extends RefCounted
## 数据层入口：加载 JSON 配置，合并关卡 + 难度预设 + 升级为运行时配置。

var difficulty: Dictionary = {}
var levels: Array = []
var snacks: Dictionary = {}
var categories: Dictionary = {}
var customers: Dictionary = {}
var upgrades: Dictionary = {}
var preset_name: String = ""


static func load_all(base_path: String = "res://data/") -> ConfigDB:
	var db := ConfigDB.new()
	db.difficulty = _read_json(base_path + "difficulty.json")
	db.levels = _read_json(base_path + "levels.json").get("levels", [])
	var snack_data := _read_json(base_path + "snacks.json")
	for c in snack_data.get("categories", []):
		db.categories[c["id"]] = c
	for s in snack_data.get("snacks", []):
		db.snacks[s["id"]] = s
	var customer_data := _read_json(base_path + "customers.json")
	for customer in customer_data.get("customers", []):
		db.customers[customer["id"]] = customer
	db.upgrades = _read_json(base_path + "upgrades.json")
	db.preset_name = db.difficulty.get("active_preset", "standard")
	return db


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("ConfigDB missing: " + path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func set_preset(p_name: String) -> void:
	if difficulty.get("presets", {}).has(p_name):
		preset_name = p_name


func get_preset() -> Dictionary:
	var p: Dictionary = difficulty.get("presets", {}).get(preset_name, {}).duplicate(true)
	p["tray_slots"] = int(p.get("tray_slots", 7))
	p["patience_scale"] = float(p.get("patience_scale", 1.0))
	p["combo_window_sec"] = float(p.get("combo_window_sec", 3.0))
	p["magnet_charges"] = int(p.get("magnet_charges", 1))
	p["auto_hint"] = bool(p.get("auto_hint", false))
	p["deadlock_protection"] = bool(p.get("deadlock_protection", false))
	return p


func get_level(level_id: int) -> Dictionary:
	for l in levels:
		if int(l.get("id", 0)) == level_id:
			return l.duplicate(true)
	return {}


func level_count() -> int:
	return levels.size()


func snack_weight(snack_id: String) -> int:
	return int(snacks.get(snack_id, {}).get("weight", 50))


func snack_ids_for_categories(category_ids: Array) -> Array:
	var result: Array = []
	for snack_id in snacks:
		if category_ids.has(snacks[snack_id].get("category", "")):
			result.append(snack_id)
	return result


## 合并出本局运行时配置：关卡 × 难度预设 × 设备升级 × 顾客修正。
func runtime_config(level_id: int, upgrades_owned: Dictionary) -> Dictionary:
	var cfg := get_level(level_id)
	if cfg.is_empty():
		return cfg
	var preset := get_preset()
	var tray_lv := int(upgrades_owned.get("tray", 1))
	var magnet_lv := int(upgrades_owned.get("magnet", 1))
	var scale_lv := int(upgrades_owned.get("scale", 1))

	cfg["tray_slots"] = mini(preset["tray_slots"] + tray_lv - 1, 9)
	cfg["patience"] = float(cfg.get("patience", 0)) * preset["patience_scale"]
	cfg["combo_window_sec"] = preset["combo_window_sec"]
	cfg["magnet_charges"] = preset["magnet_charges"] + magnet_lv - 1
	cfg["auto_hint"] = preset["auto_hint"]
	cfg["deadlock_protection"] = preset["deadlock_protection"]
	var anim_times: Array = upgrades.get("scale", {}).get("anim_times", [0.4, 0.3, 0.2])
	cfg["weigh_anim_time"] = float(anim_times[clampi(scale_lv - 1, 0, anim_times.size() - 1)])
	if cfg.has("pool_categories"):
		cfg["pool"] = snack_ids_for_categories(cfg["pool_categories"])
	elif not cfg.has("pool"):
		cfg["pool"] = snacks.keys()
	if not cfg.has("customers"):
		cfg["customers"] = int(cfg.get("baskets", 1))
	# 小费沿用关卡主题；耐心按当前顾客在 GameState 中只修正一次。
	cfg["tip_mult"] = 1.0
	match String(cfg.get("customer", "normal")):
		"hurried":
			cfg["tip_mult"] = 1.5
		"rich":
			cfg["tip_mult"] = 2.0
	return cfg
