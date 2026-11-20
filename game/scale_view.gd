class_name ScaleView
extends Node2D
## 高位俯视称重台：承重平台、底座与前缘 LED；上方 POS 通过短支架组成一体设备。

var _led: Label
var _weight_tween: Tween
var _rolling := false
var _led_value := 0.0


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
	_led_value = 0.0
	if _weight_tween and _weight_tween.is_valid():
		_weight_tween.kill()
	_weight_tween = null
	_led.text = "0 g"


## 空闲兼容接口不中断自动批次；连续批次由 show_weight 从当前值续接。
func set_live_weight(weight: int) -> void:
	if _rolling:
		return
	if _weight_tween and _weight_tween.is_valid():
		_weight_tween.kill()
	_weight_tween = null
	_set_led(float(weight))


func show_weight(weight: int, duration: float, with_beep: bool = true) -> void:
	_rolling = true
	if _weight_tween and _weight_tween.is_valid():
		_weight_tween.kill()
	_weight_tween = create_tween()
	_weight_tween.tween_method(_set_led, _led_value, float(weight), duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_weight_tween.tween_callback(func():
		_rolling = false
		_led_value = float(weight)
		if with_beep:
			SFX.play("beep"))


func _set_led(v: float) -> void:
	_led_value = v
	_led.text = "%d g" % int(roundf(v))
