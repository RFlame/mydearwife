class_name SaveData
extends RefCounted
## 本地存档：金币 / 星级 / 解锁 / 升级 / 图鉴 / 设置（user://save.json）。

const PATH := "user://save.json"

var coins: int = 0
var stars: Dictionary = {}
var unlocked: int = 1
var upgrades: Dictionary = {"tray": 1, "scale": 1, "magnet": 1}
var discovered: Dictionary = {}
var customers_discovered: Dictionary = {}
var settings: Dictionary = {"sfx": true, "music": true, "vibrate": true, "preset": "standard"}


static func load_save() -> SaveData:
	var s := SaveData.new()
	if not FileAccess.file_exists(PATH):
		return s
	var data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if data is Dictionary:
		s.coins = int(data.get("coins", 0))
		s.stars = data.get("stars", {})
		s.unlocked = int(data.get("unlocked", 1))
		for k in s.upgrades:
			s.upgrades[k] = int(data.get("upgrades", {}).get(k, 1))
		s.discovered = data.get("discovered", {})
		s.customers_discovered = data.get("customers_discovered", {})
		for k in s.settings:
			s.settings[k] = data.get("settings", {}).get(k, s.settings[k])
	return s


func save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"coins": coins, "stars": stars, "unlocked": unlocked,
			"upgrades": upgrades, "discovered": discovered,
			"customers_discovered": customers_discovered, "settings": settings,
		}))
		f.close()


func meet_customer(customer_id: String, persist: bool = true) -> bool:
	if customer_id.is_empty() or customers_discovered.has(customer_id):
		return false
	customers_discovered[customer_id] = true
	if persist:
		save()
	return true


func add_result(level_id: int, result: Dictionary, level_snacks: Array) -> void:
	var key := str(level_id)
	stars[key] = maxi(int(stars.get(key, 0)), int(result.get("stars", 0)))
	unlocked = maxi(unlocked, level_id + 1)
	coins += int(result.get("coins", 0))
	for s in level_snacks:
		discovered[s] = true
	save()


func total_stars() -> int:
	var n := 0
	for k in stars:
		n += int(stars[k])
	return n
