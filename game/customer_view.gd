class_name CustomerView
extends Control
## 独立角色：立绘 + 姓名性格 + 对话气泡 + 耐心条（冻结变蓝、告急变红）。

var _bubble: Label
var _bar: ProgressBar
var _avatar: TextureRect
var _celebrate_tween: Tween = null


func setup(profile: Dictionary, line_seed: int = 0) -> void:
	if _celebrate_tween and _celebrate_tween.is_valid():
		_celebrate_tween.kill()
	for child in get_children():
		child.queue_free()
	_avatar = TextureRect.new()
	_avatar.texture = load("res://assets/svg/" + String(profile.get("avatar", "customer_normal.svg")))
	_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar.position = Vector2(10, 0)
	_avatar.size = Vector2(160, 200)
	add_child(_avatar)

	var bubble_panel := UIKit.make_panel(UIKit.PAPER, 18)
	bubble_panel.position = Vector2(185, 10)
	bubble_panel.size = Vector2(270, 64)
	_bubble = UIKit.make_label("", 23)
	bubble_panel.add_child(_bubble)
	add_child(bubble_panel)
	var lines: Array = profile.get("lines", ["今天也要零食自由！"])
	var line_index := posmod(String(profile.get("id", "customer")).hash() + line_seed, lines.size())
	set_bubble(String(lines[line_index]))

	var identity_panel := UIKit.make_panel(Color(UIKit.PAPER, 0.96), 8)
	identity_panel.position = Vector2(185, 80)
	identity_panel.size = Vector2(270, 30)
	add_child(identity_panel)
	var identity := UIKit.make_label("%s · %s" % [profile.get("name", "顾客"), profile.get("personality", "随和")], 20, UIKit.BROWN)
	identity_panel.add_child(identity)
	_bar = UIKit.make_bar(UIKit.GREEN, 22)
	_bar.position = Vector2(185, 116)
	_bar.size = Vector2(270, 22)
	add_child(_bar)


func set_bubble(text: String) -> void:
	_bubble.text = text


func set_patience(ratio: float, frozen: bool) -> void:
	_bar.value = ratio
	var color := UIKit.GREEN
	if frozen:
		color = Color("6FA8FF")
	elif ratio <= 0.35:
		color = UIKit.RED
	UIKit.fill_style(_bar, color)


func celebrate() -> void:
	set_bubble("叮叮咚～ 好评！")
	if _celebrate_tween and _celebrate_tween.is_valid():
		_celebrate_tween.kill()
	_celebrate_tween = create_tween()
	_celebrate_tween.tween_property(_avatar, "position:y", -14.0, 0.12)
	_celebrate_tween.tween_property(_avatar, "position:y", 0.0, 0.18).set_trans(Tween.TRANS_BOUNCE)
