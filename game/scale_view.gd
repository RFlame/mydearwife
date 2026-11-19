class_name ScaleView
extends Node2D
## 高位俯视称重台：承重平台、底座与前缘 LED；上方 POS 通过短支架组成一体设备。

var _led: Label
var _weight_tween: Tween
var _rolling := false


func _ready() -> void:
	var sprite := Sprite2D.new()
	sprite.texture = load("res://assets/svg/scale_platform.svg")
	sprite.centered = false
	add_child(sprite)
	sprite.z_index = -1
	_led = UIKit.make_label("0 g", 26, Color("B8F5D3"))
	_led.position = Vector2(44, 250)
	_led.size = Vector2(124, 44)
	add_child(_led)


func reset() -> void:
	_rolling = false
	if _weight_tween and _weight_tween.is_valid():
		_weight_tween.kill()
	_weight_tween = null
	_led.text = "0 g"


## 拣入/退货时立即显示理论总重；结算滚动期间的空台刷新不打断本次定格演出。
func set_live_weight(weight: int) -> void:
	if weight == 0 and _rolling:
		return
	_rolling = false
	if _weight_tween and _weight_tween.is_valid():
		_weight_tween.kill()
	_weight_tween = null
	_led.text = "%d g" % weight


func show_weight(weight: int, duration: float) -> void:
	_rolling = true
	if _weight_tween and _weight_tween.is_valid():
		_weight_tween.kill()
	_weight_tween = create_tween()
	_weight_tween.tween_method(_set_led, 0.0, float(weight), duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_weight_tween.tween_callback(func():
		_rolling = false
		SFX.play("beep"))


func _set_led(v: float) -> void:
	_led.text = "%d g" % int(v)
