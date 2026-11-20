class_name TestScreen
extends Control
## 可见的核心玩法测试台：显式局内配置，不写正式金币、解锁或图鉴。

var app = null
var initial_options: Dictionary = {}
var level_option: OptionButton
var preset_option: OptionButton
var random_check: CheckButton
var quantity_slider: HSlider
var quantity_value: Label
var size_slider: HSlider
var size_value: Label
var giant_option: OptionButton
var start_button: Button
var back_button: Button


static func create(p_app, p_options: Dictionary = {}) -> TestScreen:
	var screen := TestScreen.new()
	screen.app = p_app
	screen.initial_options = p_options.duplicate(true)
	return screen


func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://assets/svg/bg_shop.svg")
	bg.size = Vector2(720, 1280)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(bg)

	var title := UIKit.make_panel(UIKit.BLUE, 12)
	title.position = Vector2(100, 56)
	title.size = Vector2(520, 96)
	add_child(title)
	title.add_child(UIKit.make_label("核心玩法测试台", 46, UIKit.PAPER))
	var subtitle := UIKit.make_label("调参数、试聚堆，不影响正式营业", 25)
	subtitle.position = Vector2(110, 164)
	subtitle.size = Vector2(500, 38)
	add_child(subtitle)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", UIKit.stylebox(UIKit.PAPER, UIKit.BROWN, 3, 20))
	panel.position = Vector2(60, 220)
	panel.size = Vector2(600, 680)
	add_child(panel)

	_add_row_label(panel, "关卡", 30)
	level_option = _make_option(Vector2(270, 28), Vector2(290, 62))
	for level_id in range(1, app.db.level_count() + 1):
		var kinds := int(app.db.get_level(level_id).get("snack_kinds", 3))
		level_option.add_item("第 %d 关 · %d 款" % [level_id, kinds])
	level_option.select(clampi(int(initial_options.get("level_id", 1)), 1, 20) - 1)
	panel.add_child(level_option)

	_add_row_label(panel, "难度", 120)
	preset_option = _make_option(Vector2(270, 118), Vector2(290, 62))
	for entry in [["relax", "轻松"], ["standard", "标准"], ["challenge", "挑战"]]:
		preset_option.add_item(entry[1])
	var presets := ["relax", "standard", "challenge"]
	preset_option.select(maxi(0, presets.find(String(initial_options.get("preset", "standard")))))
	panel.add_child(preset_option)

	random_check = CheckButton.new()
	random_check.text = "每款随机 1～10 件"
	random_check.button_pressed = bool(initial_options.get("random_quantity", true))
	random_check.position = Vector2(32, 205)
	random_check.size = Vector2(520, 70)
	random_check.add_theme_font_override("font", UIKit.font())
	random_check.add_theme_font_size_override("font_size", 27)
	random_check.add_theme_color_override("font_color", UIKit.BROWN)
	random_check.toggled.connect(func(_pressed): _sync_values())
	panel.add_child(random_check)

	_add_row_label(panel, "固定每款", 300)
	quantity_slider = HSlider.new()
	quantity_slider.position = Vector2(270, 318)
	quantity_slider.size = Vector2(200, 44)
	quantity_slider.min_value = 1
	quantity_slider.max_value = 10
	quantity_slider.step = 1
	quantity_slider.value = clampi(int(initial_options.get("fixed_quantity", 2)), 1, 10)
	quantity_slider.value_changed.connect(func(_value): _sync_values())
	panel.add_child(quantity_slider)
	quantity_value = UIKit.make_label("", 26, UIKit.RED)
	quantity_value.position = Vector2(486, 300)
	quantity_value.size = Vector2(74, 62)
	panel.add_child(quantity_value)

	_add_row_label(panel, "包装倍率", 390)
	size_slider = HSlider.new()
	size_slider.position = Vector2(270, 408)
	size_slider.size = Vector2(200, 44)
	size_slider.min_value = 1.0
	size_slider.max_value = 2.0
	size_slider.step = 0.05
	size_slider.value = clampf(float(initial_options.get("package_scale", 1.5)), 1.0, 2.0)
	size_slider.value_changed.connect(func(_value): _sync_values())
	panel.add_child(size_slider)
	size_value = UIKit.make_label("", 26, UIKit.RED)
	size_value.position = Vector2(486, 390)
	size_value.size = Vector2(74, 62)
	panel.add_child(size_value)

	_add_row_label(panel, "巨大款种数", 480)
	giant_option = _make_option(Vector2(270, 478), Vector2(290, 62))
	for count in range(3):
		giant_option.add_item("%d 种 · 每种 1～2 件" % count)
	giant_option.select(clampi(int(initial_options.get("giant_kinds", 2)), 0, 2))
	panel.add_child(giant_option)

	var note := UIKit.make_label("正式局巨大款随机 0～2 种\n测试局在此固定，方便验收；固定数量只作用于普通款", 22, UIKit.BROWN)
	note.position = Vector2(24, 566)
	note.size = Vector2(552, 86)
	panel.add_child(note)

	start_button = UIKit.make_button("开始测试 · 不写存档", UIKit.RED, UIKit.CREAM, 31)
	start_button.position = Vector2(130, 940)
	start_button.size = Vector2(460, 84)
	start_button.pressed.connect(func(): app.start_test(current_options()))
	add_child(start_button)
	back_button = UIKit.make_button("返回店铺", UIKit.WOOD, UIKit.CREAM, 25)
	back_button.position = Vector2(250, 1054)
	back_button.size = Vector2(220, 66)
	back_button.pressed.connect(func(): app.show_home())
	add_child(back_button)
	var footer := UIKit.make_label("金币 · 关卡解锁 · 零食图鉴 · 顾客图鉴均保持不变", 20, UIKit.BROWN)
	footer.position = Vector2(60, 1150)
	footer.size = Vector2(600, 42)
	add_child(footer)
	_sync_values()


func _add_row_label(panel: Control, text: String, y: float) -> void:
	var label := UIKit.make_label(text, 27, UIKit.BROWN, HORIZONTAL_ALIGNMENT_LEFT)
	label.position = Vector2(34, y)
	label.size = Vector2(220, 62)
	panel.add_child(label)


func _make_option(point: Vector2, dimensions: Vector2) -> OptionButton:
	var option := OptionButton.new()
	option.position = point
	option.size = dimensions
	option.add_theme_font_override("font", UIKit.font())
	option.add_theme_font_size_override("font_size", 25)
	option.add_theme_color_override("font_color", UIKit.BROWN)
	return option


func _sync_values() -> void:
	quantity_value.text = "%d 件" % int(quantity_slider.value)
	quantity_slider.modulate.a = 0.42 if random_check.button_pressed else 1.0
	quantity_slider.mouse_filter = Control.MOUSE_FILTER_IGNORE if random_check.button_pressed else Control.MOUSE_FILTER_STOP
	size_value.text = "%.2f×" % size_slider.value


func current_options() -> Dictionary:
	var presets := ["relax", "standard", "challenge"]
	return {
		"test_mode": true,
		"level_id": level_option.selected + 1,
		"preset": presets[preset_option.selected],
		"random_quantity": random_check.button_pressed,
		"fixed_quantity": int(quantity_slider.value),
		"package_scale": snappedf(size_slider.value, 0.01),
		"giant_kinds": giant_option.selected,
		"seed_value": int(initial_options.get("seed_value", 0)),
	}
