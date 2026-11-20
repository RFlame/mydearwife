class_name ResultScreen
extends Control
## 结算页：星级 / 金币明细 / 最高连击 / 下一关。

var app = null
var level_id: int = 1
var result: Dictionary = {}
var next_button: Button = null
var retry_button: Button = null


static func create(p_app, p_level: int, p_result: Dictionary) -> ResultScreen:
	var s := ResultScreen.new()
	s.app = p_app
	s.level_id = p_level
	s.result = p_result
	return s


func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://assets/svg/bg_shop.svg")
	bg.size = Vector2(720, 1280)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(bg)

	var panel := UIKit.make_panel(UIKit.PAPER, 24)
	panel.position = Vector2(90, 250)
	panel.size = Vector2(540, 700)
	add_child(panel)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 22)
	panel.add_child(box)

	box.add_child(UIKit.make_label("测试完成 · 不写存档" if result.get("test_mode", false) else "营业完成！", 38 if result.get("test_mode", false) else 48, UIKit.RED))
	var stars := ""
	for i in 3:
		stars += "★" if i < int(result.get("stars", 0)) else "☆"
	box.add_child(UIKit.make_label(stars, 84, Color("D8A020")))
	box.add_child(UIKit.make_label("最高连击 ×%d" % int(result.get("best_combo", 0)), 30))
	box.add_child(UIKit.make_label("用时 %d 秒 · 称重 %d 件 / %d 批" % [int(result.get("time_used", 0)), int(result.get("bagged_items", 0)), int(result.get("total_groups", 0))], 26))
	box.add_child(UIKit.make_label("台上退货 %d 次" % int(result.get("return_count", 0)), 24, UIKit.BROWN))
	if result.get("perfect", false):
		box.add_child(UIKit.make_label("完美清篮！收益 +30%", 28, UIKit.RED))
	box.add_child(UIKit.make_label("小费 +%d" % int(result.get("tip", 0)), 28))
	box.add_child(UIKit.make_label("金币合计 +%d" % int(result.get("coins", 0)), 36, Color("B8860B")))

	if result.get("test_mode", false):
		next_button = UIKit.make_button("返回测试设置", UIKit.BLUE, UIKit.CREAM, 30)
		next_button.pressed.connect(func(): app.show_test(result.get("test_config", {})))
		box.add_child(next_button)
	elif level_id < app.db.level_count():
		next_button = UIKit.make_button("下一关 →", UIKit.RED, UIKit.CREAM, 34)
		next_button.pressed.connect(func(): app.start_level(level_id + 1))
		box.add_child(next_button)
	retry_button = UIKit.make_button("按此配置再试" if result.get("test_mode", false) else "再玩一次", UIKit.GREEN, UIKit.CREAM, 28)
	retry_button.pressed.connect(func():
		if result.get("test_mode", false):
			app.start_test(result.get("test_config", {}))
		else:
			app.start_level(level_id))
	box.add_child(retry_button)
	var home := UIKit.make_button("返回店铺", UIKit.WOOD, UIKit.CREAM, 28)
	home.pressed.connect(func(): app.show_home())
	box.add_child(home)
