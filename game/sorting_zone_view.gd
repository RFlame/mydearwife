class_name SortingZoneView
extends Control
## 四角的小型椭圆集货垫：无边框，拖入高亮、集齐回弹、排队与称重状态。

var zone_index := 0
var accent := UIKit.RED
var title_label: Label
var detail_label: Label
var _hover := false
var _queued := false
var _active := false
var _pulse: Tween = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(func():
		pivot_offset = size * 0.5
		queue_redraw())
	title_label = UIKit.make_label("%d  集货区" % (zone_index + 1), 18, accent)
	title_label.position = Vector2(16, 12)
	title_label.size = Vector2(size.x - 32, 26)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title_label)
	detail_label = UIKit.make_label("拖入同款", 15, UIKit.BROWN)
	detail_label.position = Vector2(8, size.y - 36)
	detail_label.size = Vector2(size.x - 16, 24)
	detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(detail_label)
	queue_redraw()


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
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := size * 0.5
	var fill := Color(accent, 0.13)
	if _queued:
		fill = Color(UIKit.GOLD, 0.25)
	if _active:
		fill = Color(UIKit.GREEN, 0.28)
	if _hover:
		fill = Color(accent, 0.30)
	# 柔和投影与半透明填充都没有描边，不占中央分拣通道。
	draw_colored_polygon(_ellipse_points(center + Vector2(0, 3), radius + Vector2(3, 2)), Color(0.25, 0.14, 0.07, 0.07))
	draw_colored_polygon(_ellipse_points(center, radius), fill)


func _ellipse_points(center: Vector2, radius: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in 64:
		var angle := TAU * float(index) / 64.0
		points.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	return points
