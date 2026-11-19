class_name BasketView
extends Node2D
## 左屏外固定 90° 侧立的 3D 篮口，桌面仍使用 2D 零食与热区。

const PIVOT := Vector2(560, 400)
const MOUTH_LOCAL := Vector2(300, 400)
const MOUTH_TILT := PI / 2.0
const VIEW_SIZE := Vector2i(600, 760)
const VIEW_CENTER := Vector2(300, 380)
const CAMERA_HOME := Vector3(0, -6, 12)

var content: Node2D
var basket_root: Node3D
var camera: Camera3D
var side_tilt := MOUTH_TILT
var _viewport: SubViewport
var _shadow: Sprite2D
var _snack_sprites := {}


func _ready() -> void:
	# 逻辑节点继续保存零食；未离篮时只显示其 3D 投影，不显示平面节点。
	content = Node2D.new()
	content.position = -PIVOT
	add_child(content)
	_make_shadow()

	_viewport = SubViewport.new()
	_viewport.size = VIEW_SIZE
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	camera = Camera3D.new()
	camera.position = CAMERA_HOME
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 9.2
	camera.near = 0.1
	camera.far = 40.0
	_viewport.add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	camera.current = true

	basket_root = Node3D.new()
	basket_root.rotation = Vector3(0, MOUTH_TILT, 0)
	_viewport.add_child(basket_root)
	_make_basket_meshes()

	var display := TextureRect.new()
	display.texture = _viewport.get_texture()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.position = -VIEW_CENTER
	display.size = Vector2(VIEW_SIZE)
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.z_index = -2
	add_child(display)


func _make_shadow() -> void:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color(0.16, 0.10, 0.05, 0.24), Color(0.16, 0.10, 0.05, 0.0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 256
	texture.height = 256
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	_shadow = Sprite2D.new()
	_shadow.texture = texture
	_shadow.position = Vector2(-150, 40)
	_shadow.scale = Vector2(2.4, 3.0)
	_shadow.z_index = -3
	add_child(_shadow)


func _make_basket_meshes() -> void:
	var center := _local_to_3d(Vector2(300, 380))
	_add_textured_quad("BasketMouth", "res://assets/svg/basket.svg", center)
	_add_textured_quad("BasketBottom", "res://assets/svg/basket_back.svg", center + Vector3(0, 0, -0.86), true)
	_add_textured_quad("BasketFrontRim", "res://assets/svg/basket_rim.svg", center + Vector3(0, 0, 0.045))
	# 四面侧壁连接篮口与后方篮底；超过 90° 后能看到容器深度而非一块薄板。
	_add_rim_box(Vector3(-5.28, 0, -0.43), Vector3(0.13, 6.62, 0.86), Color("A88761"), true)
	_add_rim_box(Vector3(0.02, 0, -0.43), Vector3(0.13, 6.62, 0.86), Color("B18C5F"), true)
	_add_rim_box(Vector3(-2.62, 3.31, -0.43), Vector3(5.30, 0.13, 0.86), Color("BA986E"), true)
	_add_rim_box(Vector3(-2.62, -3.19, -0.43), Vector3(5.30, 0.13, 0.86), Color("8B6B4C"), true)
	# 独立厚篮沿在侧立和超过 90° 时提供真实体积，不再只是压扁一张图。
	_add_rim_box(Vector3(0.04, 0, 0.01), Vector3(0.16, 6.75, 0.18), Color("B98F57"))
	_add_rim_box(Vector3(-5.30, 0, -0.01), Vector3(0.16, 6.75, 0.18), Color("8F653D"))
	_add_rim_box(Vector3(-2.62, 3.37, 0.0), Vector3(5.35, 0.15, 0.18), Color("D0A66C"))
	_add_rim_box(Vector3(-2.62, -3.18, 0.0), Vector3(5.35, 0.15, 0.18), Color("9B7145"))


func _add_textured_quad(node_name: String, path: String, center: Vector3, show_back: bool = false) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(6.0, 7.6)
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = quad
	mesh.position = center
	var material := StandardMaterial3D.new()
	material.albedo_texture = load(path)
	material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.08
	material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = StandardMaterial3D.CULL_DISABLED if show_back else StandardMaterial3D.CULL_BACK
	mesh.material_override = material
	basket_root.add_child(mesh)


func _add_rim_box(center: Vector3, dimensions: Vector3, color: Color, woven: bool = false) -> void:
	var box := BoxMesh.new()
	box.size = dimensions
	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	mesh.position = center
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	if woven:
		material.albedo_texture = load("res://assets/svg/basket_weave.svg")
	material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = material
	basket_root.add_child(mesh)


static func home_position(item: Dictionary) -> Vector2:
	return Vector2(float(item["x"]), float(item["y"]))


static func packed_position(index: int) -> Vector2:
	var angle := float(index) * 2.399963
	var radius := 20.0 * sqrt(float(index % 42))
	return Vector2(300, 420) + Vector2(cos(angle) * radius * 1.35, sin(angle) * radius * 0.85)


static func packed_height(index: int) -> float:
	return -0.70 + float(index) * 0.0015


func add_snack(uid: int, item: Dictionary, texture: Texture2D, index: int) -> void:
	var sprite := Sprite3D.new()
	sprite.texture = texture
	sprite.pixel_size = 0.01
	var package_scale := BasketModel.hit_size(item) / 120.0
	sprite.scale = Vector3(package_scale.x, package_scale.y, 1.0)
	sprite.position = _local_to_3d(packed_position(index), packed_height(index))
	sprite.set_meta("packed_z", sprite.position.z)
	sprite.rotation.z = -deg_to_rad(float(item["rot"]))
	sprite.shaded = false
	sprite.double_sided = true
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.alpha_scissor_threshold = 0.10
	basket_root.add_child(sprite)
	_snack_sprites[uid] = sprite


## 离篮时从真实篮口投回逻辑分辨率，保留包装朝向与标准桌面尺寸。
func release_snack(uid: int) -> Dictionary:
	var sprite: Sprite3D = _snack_sprites.get(uid)
	if sprite == null:
		return {"position": mouth_global_position(), "rotation": 0.0, "depth_scale": 1.0}
	var world := sprite.global_position
	var world_point := _project_world(world)
	var point := projected_release_position(uid)
	var axis := _project_world(world + sprite.global_transform.basis.x.normalized() * 0.1) - world_point
	var facing := axis.angle() if axis.length() > 0.001 else 0.0
	var depth_scale := 1.0
	sprite.hide()
	return {"position": point, "rotation": facing, "depth_scale": depth_scale}


func project_basket_point(local: Vector2, height: float = 0.0) -> Vector2:
	return _project_world(basket_root.to_global(_local_to_3d(local, height)))


func projected_release_position(uid: int) -> Vector2:
	# 篮口内的小范围确定性偏移避免所有包装完全重叠，同时保持共同出货口。
	var angle := float(uid) * 2.399963
	var local := MOUTH_LOCAL + Vector2(cos(angle) * 14.0, sin(angle) * 10.0)
	return project_basket_point(local, 0.06)


func mouth_global_position() -> Vector2:
	return project_basket_point(MOUTH_LOCAL)


func _project_world(world: Vector3) -> Vector2:
	var projected := camera.unproject_position(world)
	return to_global(projected - VIEW_CENTER)


func _local_to_3d(local: Vector2, height: float = 0.0) -> Vector3:
	return Vector3((local.x - PIVOT.x) * 0.01, (PIVOT.y - local.y) * 0.01, height)
