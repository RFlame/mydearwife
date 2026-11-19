class_name SettingsPanel
extends Control
## 设置弹层：音效 / 震动 / 难度预设（下一局生效）。

var app = null


static func show_panel(p_app, parent: Control) -> SettingsPanel:
	var s := SettingsPanel.new()
	s.app = p_app
	parent.add_child(s)
	return s


func _ready() -> void:
	z_index = 400
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.size = Vector2(720, 1280)
	add_child(dim)

	var panel := UIKit.make_panel(UIKit.PAPER, 20)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	panel.add_child(box)
	box.add_child(UIKit.make_label("设置", 40, UIKit.RED))

	var sfx_toggle := CheckButton.new()
	sfx_toggle.text = "音效"
	sfx_toggle.button_pressed = app.save.settings.get("sfx", true)
	_style_toggle(sfx_toggle)
	box.add_child(sfx_toggle)
	sfx_toggle.toggled.connect(func(on: bool):
		app.save.settings["sfx"] = on
		app.save.save()
		SFX.enabled = on)

	var vibrate_toggle := CheckButton.new()
	vibrate_toggle.text = "震动（支持的设备）"
	vibrate_toggle.button_pressed = app.save.settings.get("vibrate", true)
	_style_toggle(vibrate_toggle)
	box.add_child(vibrate_toggle)
	vibrate_toggle.toggled.connect(func(on: bool):
		app.save.settings["vibrate"] = on
		app.save.save())

	box.add_child(UIKit.make_label("难度预设（下一局生效）", 26))
	var preset := OptionButton.new()
	preset.add_theme_font_override("font", UIKit.font())
	preset.add_theme_font_size_override("font_size", 28)
	preset.add_theme_color_override("font_color", UIKit.BROWN)
	preset.add_theme_stylebox_override("normal", UIKit.stylebox(UIKit.CREAM))
	var names := {"relax": "解压 · 宽松", "standard": "标准 · 适中", "challenge": "挑战 · 紧凑"}
	var keys := ["relax", "standard", "challenge"]
	for i in keys.size():
		preset.add_item(names[keys[i]], i)
	preset.selected = keys.find(app.save.settings.get("preset", "standard"))
	box.add_child(preset)
	preset.item_selected.connect(func(idx: int):
		app.save.settings["preset"] = keys[idx]
		app.db.set_preset(keys[idx])
		app.save.save())

	var close := UIKit.make_button("关闭", UIKit.RED, UIKit.CREAM, 30)
	close.pressed.connect(queue_free)
	box.add_child(close)

	add_child(panel)
	panel.position = Vector2(360, 560) - panel.get_combined_minimum_size() * 0.5


func _style_toggle(toggle: CheckButton) -> void:
	toggle.add_theme_font_override("font", UIKit.font())
	toggle.add_theme_font_size_override("font_size", 28)
	toggle.add_theme_color_override("font_color", UIKit.BROWN)
