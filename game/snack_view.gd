class_name SnackView
extends Node2D
## 俯视零食：包装顶面 + 桌面投影 + 旋转热区 + 飞行/退货动画。

signal clicked(uid: int)

const TRAY_SCALE := 0.78

var uid: int = -1
var snack_id: String = ""
var item: Dictionary = {}
var sprite: Sprite2D
var flying: bool = false
var interactive: bool = true
var tap_seq := 0
var _tween: Tween = null
var _arc: Tween = null
var _tap_tween: Tween = null
var _base_scale := Vector2.ONE
var _area: Area2D
var _shadow: Sprite2D


static func create(p_item: Dictionary, texture: Texture2D) -> SnackView:
	var v := SnackView.new()
	v.uid = int(p_item["uid"])
	v.snack_id = p_item["snack"]
	v.item = p_item
	# 所有零食 SVG 均为 120×120；压缩顶面高度并与核心旋转热区对齐。
	v._base_scale = BasketModel.hit_size(p_item) / 120.0
	v._shadow = Sprite2D.new()
	v._shadow.texture = texture
	v._shadow.scale = v._base_scale
	v._shadow.position = Vector2(5, 7)
	v._shadow.modulate = Color(0.18, 0.12, 0.07, 0.30)
	v._shadow.z_index = -1
	v.add_child(v._shadow)
	v.sprite = Sprite2D.new()
	v.sprite.texture = texture
	v.sprite.scale = v._base_scale
	v.add_child(v.sprite)
	var area := Area2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = BasketModel.hit_size(p_item)
	shape.shape = rect
	area.add_child(shape)
	v.add_child(area)
	v._area = area
	area.input_event.connect(v._on_input)
	return v


func _on_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not interactive or flying:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(uid)
		get_viewport().set_input_as_handled()


func contains_global_point(point: Vector2) -> bool:
	var local := _area.to_local(point)
	var half := BasketModel.hit_size(item) * 0.5
	return absf(local.x) <= half.x and absf(local.y) <= half.y


## clickable_after：落到称重台后可点击退货；飞入袋子/称重动画时则关闭热区。
func fly_to(target: Vector2, duration: float = 0.26, clickable_after: bool = false,
		target_rotation: float = 0.0, delay: float = 0.0) -> void:
	flying = true
	interactive = false
	_area.input_pickable = false
	_kill_tweens()
	_tween = create_tween()
	if delay > 0.0:
		_tween.tween_interval(delay)
	_tween.tween_property(self, "global_position", target, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "rotation", target_rotation, duration)
	_tween.parallel().tween_property(sprite, "scale", _base_scale * TRAY_SCALE, duration)
	_tween.parallel().tween_property(_shadow, "scale", _base_scale * TRAY_SCALE, duration)
	_tween.parallel().tween_property(_area, "scale", Vector2.ONE * TRAY_SCALE, duration)
	_arc = create_tween()
	if delay > 0.0:
		_arc.tween_interval(delay)
	_arc.tween_property(sprite, "position:y", -64.0, duration * 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_arc.tween_property(sprite, "position:y", 0.0, duration * 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_callback(func():
		flying = false
		interactive = clickable_after
		_area.input_pickable = clickable_after)


## 从篮口落到桌面：保持桌面尺寸，错峰抛物线 + 轻弹跳形成整篮倾倒的堆叠感。
func spill_to(target: Vector2, target_rotation: float, duration: float, delay: float, arc_height: float = 82.0, spin: float = 0.16) -> void:
	flying = true
	interactive = false
	_area.input_pickable = false
	_kill_tweens()
	# 飞行途中不提前把百件阴影叠在落点；接近桌面时再淡入。
	_shadow.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_interval(delay)
	# 横向先抛入桌面、纵向加速下落，配合顶面弧高形成翻转途中可见的洒落感。
	_tween.tween_property(self, "global_position:x", target.x, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "global_position:y", target.y, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	# 离篮时继承篮体缩放；飞出过程中恢复桌面标准尺寸，保证包装与核心热区一致。
	_tween.parallel().tween_property(self, "scale", Vector2.ONE, duration * 0.42).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "rotation", target_rotation + spin, duration * 0.72)
	_tween.parallel().tween_property(_shadow, "modulate:a", 0.30, 0.16).set_delay(duration * 0.62)
	_tween.tween_property(self, "rotation", target_rotation, 0.10).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	_arc = create_tween()
	_arc.tween_interval(delay)
	_arc.tween_property(sprite, "position:y", -arc_height, duration * 0.38).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_arc.tween_property(sprite, "position:y", 0.0, duration * 0.62).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_callback(func():
		flying = false
		interactive = true
		_area.input_pickable = false)


func begin_drag() -> void:
	_kill_tweens()
	flying = false
	interactive = false
	_area.input_pickable = false
	scale = Vector2.ONE * 1.07
	_shadow.position = Vector2(9, 12)


func end_drag(home_layer: int) -> void:
	scale = Vector2.ONE
	_shadow.position = Vector2(5, 7)
	interactive = true
	z_index = home_layer


func return_to(target: Vector2, home_layer: int, home_rotation: float, duration: float = 0.24,
		arc_height: float = 0.0, on_complete: Callable = Callable()) -> void:
	flying = true
	interactive = false
	_area.input_pickable = false
	_kill_tweens()
	_tween = create_tween()
	_tween.tween_property(self, "global_position", target, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "rotation", home_rotation, duration)
	_tween.parallel().tween_property(sprite, "scale", _base_scale, duration)
	_tween.parallel().tween_property(_shadow, "scale", _base_scale, duration)
	_tween.parallel().tween_property(_area, "scale", Vector2.ONE, duration)
	if arc_height > 0.0:
		_arc = create_tween()
		_arc.tween_property(sprite, "position:y", -arc_height, duration * 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_arc.tween_property(sprite, "position:y", 0.0, duration * 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_callback(func():
		flying = false
		interactive = true
		_area.input_pickable = false
		z_index = home_layer
		# 完成回调放在最后；回调触发称重飞行后，旧动画不能再覆盖其状态。
		if on_complete.is_valid():
			on_complete.call())


func _kill_tweens() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	if _arc and _arc.is_valid():
		_arc.kill()
	if _tap_tween and _tap_tween.is_valid():
		_tap_tween.kill()
	sprite.position.y = 0.0


## 无远处同款时的桌面单击反馈，不改变核心位置、层序或称重状态。
func tap_bounce() -> void:
	if flying:
		return
	if _tap_tween and _tap_tween.is_valid():
		_tap_tween.kill()
	tap_seq += 1
	sprite.position.y = 0.0
	_tap_tween = create_tween()
	_tap_tween.tween_property(sprite, "position:y", -12.0, 0.075).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tap_tween.tween_property(sprite, "position:y", 0.0, 0.14).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


func move_to(target: Vector2) -> void:
	if flying:
		return
	var t := create_tween()
	t.tween_property(self, "global_position", target, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func reveal(texture: Texture2D) -> void:
	sprite.texture = texture
	_shadow.texture = texture
	pulse()


## 大礼包角标：显示所属品种名首字，保证同款可辨识。
func set_badge(text: String) -> void:
	var label := UIKit.make_label(text, 30, UIKit.BROWN)
	label.position = Vector2(-16, -14)
	label.z_index = 10
	add_child(label)


func pulse() -> void:
	var t := create_tween()
	t.tween_property(self, "scale", Vector2.ONE * 1.15, 0.08)
	t.tween_property(self, "scale", Vector2.ONE, 0.12)


func reject() -> void:
	var origin := position
	var t := create_tween()
	for i in 3:
		t.tween_property(self, "position:x", origin.x + 7, 0.05)
		t.tween_property(self, "position:x", origin.x - 7, 0.05)
	t.tween_property(self, "position:x", origin.x, 0.05)


func set_highlight(on: bool) -> void:
	sprite.modulate = Color(1.35, 1.25, 0.8) if on else Color.WHITE
