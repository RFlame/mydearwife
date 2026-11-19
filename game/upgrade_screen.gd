class_name UpgradeScreen
extends Control
## 设备升级：永久称重台容量 / 电子秤动画速度。

var app = null


static func create(p_app) -> UpgradeScreen:
	var s := UpgradeScreen.new()
	s.app = p_app
	return s


func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://assets/svg/bg_shop.svg")
	bg.size = Vector2(720, 1280)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(bg)

	var title := UIKit.make_label("设备升级", 48, UIKit.RED)
	title.position = Vector2(210, 90)
	title.size = Vector2(300, 70)
	add_child(title)
	var coins := UIKit.make_label("¥ %d" % app.save.coins, 32)
	coins.position = Vector2(210, 176)
	coins.size = Vector2(300, 50)
	add_child(coins)

	var box := VBoxContainer.new()
	box.position = Vector2(70, 270)
	box.custom_minimum_size.x = 580
	box.add_theme_constant_override("separation", 26)
	add_child(box)

	for key in ["tray", "scale"]:
		box.add_child(_make_card(key))

	var back := UIKit.make_button("返回店铺", UIKit.WOOD, UIKit.CREAM, 28)
	back.position = Vector2(230, 1140)
	back.size = Vector2(260, 72)
	back.pressed.connect(func(): app.show_home())
	add_child(back)


func _make_card(key: String) -> PanelContainer:
	var cfg: Dictionary = app.db.upgrades[key]
	var lv: int = int(app.save.upgrades.get(key, 1))
	var max_lv: int = int(cfg["max_level"])
	var panel := UIKit.make_panel(UIKit.PAPER, 16)
	panel.custom_minimum_size.x = 580
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	box.add_child(UIKit.make_label("%s  Lv.%d" % [cfg["name"], lv], 32, UIKit.RED, HORIZONTAL_ALIGNMENT_LEFT))
	box.add_child(UIKit.make_label(cfg["desc"], 24, UIKit.BROWN, HORIZONTAL_ALIGNMENT_LEFT))
	if lv >= max_lv:
		box.add_child(UIKit.make_label("已满级", 26, UIKit.GRAY))
	else:
		var cost: int = int(cfg["costs"][lv - 1])
		var btn := UIKit.make_button("升级 ¥%d" % cost, UIKit.RED, UIKit.CREAM, 28)
		btn.disabled = app.save.coins < cost
		btn.pressed.connect(func():
			app.save.coins -= cost
			app.save.upgrades[key] = lv + 1
			app.save.save()
			SFX.play("ding")
			app.show_upgrades())
		box.add_child(btn)
	return panel
