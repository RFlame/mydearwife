class_name HomeScreen
extends Control
## 店铺主界面：标题 / 开始营业 / 选关 / 升级 / 图鉴 / 设置。

var app = null


static func create(p_app) -> HomeScreen:
	var s := HomeScreen.new()
	s.app = p_app
	return s


func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://assets/svg/bg_shop.svg")
	bg.size = Vector2(720, 1280)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(bg)

	var title := UIKit.make_panel(UIKit.RED, 12)
	title.position = Vector2(100, 84)
	title.size = Vector2(520, 120)
	add_child(title)
	var title_label := UIKit.make_label("零食叮叮咚", 60, UIKit.PAPER)
	title.add_child(title_label)
	var subtitle := UIKit.make_label("复古小卖部 · 解压分拣", 26)
	subtitle.position = Vector2(160, 222)
	subtitle.size = Vector2(400, 40)
	add_child(subtitle)

	var stats := UIKit.make_label("¥ %d      ★ %d / 60" % [app.save.coins, app.save.total_stars()], 30)
	stats.position = Vector2(160, 286)
	stats.size = Vector2(400, 44)
	add_child(stats)

	var start := UIKit.make_button("开始营业 · 第 %d 关" % mini(app.save.unlocked, 20), UIKit.RED, UIKit.CREAM, 34)
	start.position = Vector2(130, 356)
	start.size = Vector2(460, 84)
	start.pressed.connect(func(): app.start_level(mini(app.save.unlocked, 20)))
	add_child(start)

	var grid := GridContainer.new()
	grid.columns = 5
	grid.position = Vector2(66, 490)
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	add_child(grid)
	for lvl in app.db.levels:
		var lid: int = lvl["id"]
		var unlocked: bool = lid <= app.save.unlocked
		var star_count: int = int(app.save.stars.get(str(lid), 0))
		var star_text := ""
		for i in 3:
			star_text += "★" if i < star_count else "·"
		var btn := UIKit.make_button("%d\n%s" % [lid, star_text], UIKit.GREEN if unlocked else UIKit.GRAY, UIKit.CREAM, 24)
		btn.custom_minimum_size = Vector2(112, 84)
		btn.disabled = not unlocked
		btn.pressed.connect(func(): app.start_level(lid))
		grid.add_child(btn)

	var upgrades_btn := UIKit.make_button("设备升级", UIKit.BLUE, UIKit.CREAM, 24)
	upgrades_btn.position = Vector2(40, 1130)
	upgrades_btn.size = Vector2(145, 72)
	upgrades_btn.pressed.connect(func(): app.show_upgrades())
	add_child(upgrades_btn)
	var collection_btn := UIKit.make_button("零食图鉴", UIKit.GREEN, UIKit.CREAM, 24)
	collection_btn.position = Vector2(205, 1130)
	collection_btn.size = Vector2(145, 72)
	collection_btn.pressed.connect(func(): app.show_collection())
	add_child(collection_btn)
	var customers_btn := UIKit.make_button("顾客图鉴", UIKit.RED, UIKit.CREAM, 24)
	customers_btn.position = Vector2(370, 1130)
	customers_btn.size = Vector2(145, 72)
	customers_btn.pressed.connect(func(): app.show_customers())
	add_child(customers_btn)
	var settings_btn := UIKit.make_button("设置", UIKit.WOOD, UIKit.CREAM, 24)
	settings_btn.position = Vector2(535, 1130)
	settings_btn.size = Vector2(145, 72)
	settings_btn.pressed.connect(func(): SettingsPanel.show_panel(app, self))
	add_child(settings_btn)
