class_name UIKit
extends RefCounted
## 复古国潮 UI 工具：统一色板 / 字体 / 按钮 / 面板 / 进度条。

const PAPER := Color("F5E6C8")
const CREAM := Color("F5F0E4")
const RED := Color("C94F3D")
const GREEN := Color("7A9B76")
const BROWN := Color("4A3525")
const GOLD := Color("E8C97A")
const BLUE := Color("3E5C8F")
const WOOD := Color("B08954")
const GRAY := Color("9C8F7A")

static var _font: Font = null


static func font() -> Font:
	if _font == null:
		for path in ["res://assets/fonts/ui_font.ttc", "res://assets/fonts/ui_font.ttf"]:
			if ResourceLoader.exists(path):
				_font = load(path)
				break
	return _font


static func stylebox(bg: Color, border_color: Color = BROWN, border: int = 3, radius: int = 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border_color
	sb.set_border_width_all(border)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


static func make_label(text: String, size: int = 28, color: Color = BROWN, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_override("font", font())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func make_button(text: String, bg: Color = RED, font_color: Color = CREAM, size: int = 28) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", font())
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", font_color)
	b.add_theme_color_override("font_hover_color", font_color)
	b.add_theme_color_override("font_pressed_color", font_color)
	b.add_theme_color_override("font_disabled_color", GRAY)
	b.add_theme_stylebox_override("normal", stylebox(bg))
	b.add_theme_stylebox_override("hover", stylebox(bg.lightened(0.12)))
	b.add_theme_stylebox_override("pressed", stylebox(bg.darkened(0.15)))
	b.add_theme_stylebox_override("disabled", stylebox(Color("D8CBB2"), GRAY, 3))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


static func make_panel(bg: Color = PAPER, radius: int = 16, border: int = 3) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", stylebox(bg, BROWN, border, radius))
	return p


static func make_bar(fill: Color = GREEN, height: int = 22) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 1
	bar.value = 1
	bar.show_percentage = false
	bar.custom_minimum_size.y = height
	var bg := stylebox(CREAM, BROWN, 3, 8)
	bg.content_margin_top = 0
	bg.content_margin_bottom = 0
	var fg := stylebox(fill, fill, 0, 6)
	fg.content_margin_top = 0
	fg.content_margin_bottom = 0
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)
	return bar


static func fill_style(bar: ProgressBar, color: Color) -> void:
	bar.add_theme_stylebox_override("fill", stylebox(color, color, 0, 6))


static func spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = height
	return c


static func toast(parent: Control, text: String, pos: Vector2 = Vector2(360, 560)) -> void:
	var panel := make_panel(PAPER, 20)
	var label := make_label(text, 30)
	panel.add_child(label)
	parent.add_child(panel)
	panel.position = pos - panel.get_combined_minimum_size() * 0.5
	panel.z_index = 1000
	panel.modulate.a = 0.0
	var tween := parent.create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.15)
	tween.tween_interval(1.2)
	tween.tween_property(panel, "modulate:a", 0.0, 0.3)
	tween.tween_callback(panel.queue_free)
