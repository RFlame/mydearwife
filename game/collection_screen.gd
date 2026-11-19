class_name CollectionScreen
extends Control
## 零食图鉴：按配置分类滚动展示，已发现显示包装，未发现显示剪影。

var app = null


static func create(p_app) -> CollectionScreen:
	var s := CollectionScreen.new()
	s.app = p_app
	return s


func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://assets/svg/bg_shop.svg")
	bg.size = Vector2(720, 1280)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(bg)

	var found := 0
	for snack_id in app.db.snacks:
		if app.save.discovered.has(snack_id):
			found += 1
	var header := UIKit.make_panel(UIKit.PAPER, 20)
	header.position = Vector2(70, 50)
	header.size = Vector2(580, 126)
	add_child(header)
	var title := UIKit.make_label("零食图鉴  %d / %d" % [found, app.db.snacks.size()], 42, UIKit.RED)
	title.position = Vector2(100, 62)
	title.size = Vector2(520, 70)
	add_child(title)
	var subtitle := UIKit.make_label("原创包装 · 按品类收集", 22, UIKit.BROWN)
	subtitle.position = Vector2(160, 128)
	subtitle.size = Vector2(400, 36)
	add_child(subtitle)

	var list_bg := UIKit.make_panel(Color("EFE0BD"), 20)
	list_bg.position = Vector2(36, 190)
	list_bg.size = Vector2(648, 910)
	add_child(list_bg)
	var scroll := ScrollContainer.new()
	scroll.name = "SnackScroll"
	scroll.position = Vector2(50, 200)
	scroll.size = Vector2(620, 890)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var content := VBoxContainer.new()
	content.custom_minimum_size.x = 580
	content.add_theme_constant_override("separation", 16)
	scroll.add_child(content)

	for category_id in app.db.categories:
		var category: Dictionary = app.db.categories[category_id]
		content.add_child(UIKit.make_label(String(category.get("name", category_id)), 30, UIKit.RED))
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 16)
		content.add_child(grid)
		for snack_id in app.db.snacks:
			var cfg: Dictionary = app.db.snacks[snack_id]
			if String(cfg.get("category", "")) != String(category_id):
				continue
			grid.add_child(_make_snack_card(snack_id, cfg))

	var back := UIKit.make_button("返回店铺", UIKit.WOOD, UIKit.CREAM, 28)
	back.position = Vector2(230, 1140)
	back.size = Vector2(260, 72)
	back.pressed.connect(func(): app.show_home())
	add_child(back)


func _make_snack_card(snack_id: String, cfg: Dictionary) -> PanelContainer:
	var unlocked: bool = app.save.discovered.has(snack_id)
	var panel := UIKit.make_panel(UIKit.PAPER, 16)
	panel.custom_minimum_size = Vector2(280, 146)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var tex := TextureRect.new()
	tex.texture = load("res://assets/svg/" + cfg["svg"])
	tex.custom_minimum_size = Vector2(96, 96)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if not unlocked:
		tex.modulate = Color(0.25, 0.2, 0.15)
	box.add_child(tex)
	var labels := VBoxContainer.new()
	labels.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(labels)
	labels.add_child(UIKit.make_label(String(cfg.get("brand", "原创")) if unlocked else "未发现", 17, UIKit.WOOD))
	labels.add_child(UIKit.make_label(String(cfg["name"]) if unlocked else "？？？", 22))
	labels.add_child(UIKit.make_label("%d g" % int(cfg.get("weight", 0)), 17, UIKit.BROWN))
	return panel
