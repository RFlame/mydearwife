class_name SortingZoneView
extends Panel
## 桌面四角的半透明集货垫：拖入高亮、集齐回弹、排队与称重状态。

var zone_index := 0
var accent := UIKit.RED
var title_label: Label
var detail_label: Label
var footer_label: Label
var _hover := false
var _queued := false
var _active := false
var _pulse: Tween = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(func(): pivot_offset = size * 0.5)
	title_label = UIKit.make_label("%d  集货区" % (zone_index + 1), 22, accent)
	title_label.position = Vector2(12, 8)
	title_label.size = Vector2(196, 30)
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title_label)
	detail_label = UIKit.make_label("拖入同款", 19, UIKit.BROWN)
	detail_label.position = Vector2(12, 42)
	detail_label.size = Vector2(196, 32)
	detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(detail_label)
	footer_label = UIKit.make_label("集齐自动称重", 16, Color(UIKit.BROWN, 0.76))
	footer_label.position = Vector2(12, 202)
	footer_label.size = Vector2(196, 24)
	footer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(footer_label)
	_apply_style()


func set_drag_hover(on: bool) -> void:
	if _hover == on:
		return
	_hover = on
	_apply_style()


func set_status(text: String, queued: bool = false, active: bool = false) -> void:
	detail_label.text = text
	_queued = queued
	_active = active
	detail_label.add_theme_color_override("font_color", accent if queued or active else UIKit.BROWN)
	_apply_style()


func pulse_ready() -> void:
	if _pulse and _pulse.is_valid():
		_pulse.kill()
	pivot_offset = size * 0.5
	scale = Vector2.ONE
	_pulse = create_tween()
	_pulse.tween_property(self, "scale", Vector2.ONE * 1.045, 0.09).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pulse.tween_property(self, "scale", Vector2.ONE, 0.14)


func _apply_style() -> void:
	var border := accent
	var fill := Color(UIKit.PAPER, 0.30)
	if _queued:
		border = UIKit.GOLD
		fill = Color(UIKit.GOLD, 0.25)
	if _active:
		border = UIKit.GREEN
		fill = Color(UIKit.GREEN, 0.28)
	if _hover:
		fill = Color(accent, 0.30)
	add_theme_stylebox_override("panel", UIKit.stylebox(fill, border, 4 if _hover or _active else 3, 20))
