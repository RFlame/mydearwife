class_name CashierView
extends Node2D
## 底部过道中央俯视收银员： idle 呼吸、拿篮伸手、分拣摆手与称重庆祝。

var rig: Node2D
var body: Sprite2D
var left_arm: Sprite2D
var right_arm: Sprite2D
var action_seq := 0

var _idle_time := 0.0
var _sort_cooldown := 0.0
var _arm_tween: Tween = null
var _body_tween: Tween = null
var _arm_busy := false


func _ready() -> void:
	rig = Node2D.new()
	add_child(rig)
	body = Sprite2D.new()
	body.texture = load("res://assets/svg/cashier_body.svg")
	body.z_index = 1
	rig.add_child(body)
	left_arm = _make_arm(Vector2(-62, 40), -0.16)
	right_arm = _make_arm(Vector2(62, 40), 0.16)


func _make_arm(at: Vector2, angle: float) -> Sprite2D:
	var arm := Sprite2D.new()
	arm.texture = load("res://assets/svg/cashier_arm.svg")
	arm.centered = false
	arm.offset = Vector2(-27, -105)
	arm.position = at
	arm.rotation = angle
	arm.z_index = 0
	rig.add_child(arm)
	return arm


func _process(delta: float) -> void:
	_idle_time += delta
	_sort_cooldown = maxf(0.0, _sort_cooldown - delta)
	rig.position.y = sin(_idle_time * 2.2) * 2.2
	rig.rotation = sin(_idle_time * 1.35) * 0.012
	if not _arm_busy:
		left_arm.rotation = -0.16 + sin(_idle_time * 1.8) * 0.035
		right_arm.rotation = 0.16 - sin(_idle_time * 1.8) * 0.035


func reach_for_basket() -> void:
	action_seq += 1
	_kill_arm_tween()
	_arm_busy = true
	_arm_tween = create_tween()
	_arm_tween.set_parallel(true)
	_arm_tween.tween_property(left_arm, "rotation", -0.72, 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_arm_tween.tween_property(right_arm, "rotation", -0.48, 0.24)
	_arm_tween.chain().tween_interval(0.55)
	_arm_tween.tween_property(left_arm, "rotation", -0.16, 0.24)
	_arm_tween.parallel().tween_property(right_arm, "rotation", 0.16, 0.24)
	_arm_tween.chain().tween_callback(func(): _arm_busy = false)


func sort() -> void:
	if _sort_cooldown > 0.0:
		return
	_sort_cooldown = 0.20
	action_seq += 1
	_kill_arm_tween()
	_arm_busy = true
	_arm_tween = create_tween()
	_arm_tween.tween_property(right_arm, "rotation", -0.58, 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_arm_tween.tween_property(right_arm, "rotation", 0.16, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_arm_tween.tween_callback(func(): _arm_busy = false)


func celebrate() -> void:
	action_seq += 1
	if _body_tween and _body_tween.is_valid():
		_body_tween.kill()
	rig.scale = Vector2.ONE
	_body_tween = create_tween()
	_body_tween.tween_property(rig, "scale", Vector2.ONE * 1.07, 0.10).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_body_tween.tween_property(rig, "scale", Vector2.ONE, 0.18)


func _kill_arm_tween() -> void:
	if _arm_tween and _arm_tween.is_valid():
		_arm_tween.kill()
	_arm_tween = null
