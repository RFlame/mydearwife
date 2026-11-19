class_name CustomerCollectionScreen
extends Control
## 顾客图鉴：接待过才解锁姓名、性格、台词与数值特点；所有头像均来自独立配置。

var app = null
var cards: Array = []


static func create(p_app) -> CustomerCollectionScreen:
	var s := CustomerCollectionScreen.new()
	s.app = p_app
	return s


func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://assets/svg/bg_shop.svg")
	bg.size = Vector2(720, 1280)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(bg)

	var found := 0
	for customer_id in app.db.customers:
		if app.save.customers_discovered.has(customer_id):
			found += 1
	var header := UIKit.make_panel(UIKit.PAPER, 20)
	header.position = Vector2(70, 50)
	header.size = Vector2(580, 126)
	add_child(header)
	var title := UIKit.make_label("顾客图鉴  %d / %d" % [found, app.db.customers.size()], 42, UIKit.RED)
	title.position = Vector2(100, 62)
	title.size = Vector2(520, 70)
	add_child(title)
	var subtitle := UIKit.make_label("接待新顾客，认识他们的性格", 22, UIKit.BROWN)
	subtitle.position = Vector2(130, 128)
	subtitle.size = Vector2(460, 36)
	add_child(subtitle)

	var list_bg := UIKit.make_panel(Color("EFE0BD"), 20)
	list_bg.position = Vector2(36, 190)
	list_bg.size = Vector2(648, 910)
	add_child(list_bg)
	var scroll := ScrollContainer.new()
	scroll.name = "CustomerScroll"
	scroll.position = Vector2(50, 200)
	scroll.size = Vector2(620, 890)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.custom_minimum_size.x = 580
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	scroll.add_child(grid)
	for customer_id in app.db.customers:
		var card := _make_customer_card(customer_id, app.db.customers[customer_id])
		cards.append(card)
		grid.add_child(card)

	var back := UIKit.make_button("返回店铺", UIKit.WOOD, UIKit.CREAM, 28)
	back.position = Vector2(230, 1140)
	back.size = Vector2(260, 72)
	back.pressed.connect(func(): app.show_home())
	add_child(back)


func _make_customer_card(customer_id: String, cfg: Dictionary) -> PanelContainer:
	var unlocked: bool = app.save.customers_discovered.has(customer_id)
	var panel := UIKit.make_panel(UIKit.PAPER, 16)
	panel.custom_minimum_size = Vector2(280, 292)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	box.add_child(top)
	var avatar := TextureRect.new()
	avatar.texture = load("res://assets/svg/" + String(cfg.get("avatar", "customer_normal.svg")))
	avatar.custom_minimum_size = Vector2(92, 112)
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if not unlocked:
		avatar.modulate = Color(0.23, 0.19, 0.15)
	top.add_child(avatar)
	var identity := VBoxContainer.new()
	identity.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_child(identity)
	identity.add_child(UIKit.make_label(String(cfg.get("name", "顾客")) if unlocked else "？？？", 25, UIKit.RED))
	identity.add_child(UIKit.make_label(String(cfg.get("personality", "神秘")) if unlocked else "尚未接待", 20, UIKit.WOOD))
	var description := UIKit.make_label(String(cfg.get("description", "")) if unlocked else "在营业中接待这位顾客，即可记录头像、性格和常用台词。", 17, UIKit.BROWN)
	description.custom_minimum_size = Vector2(250, 82)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(description)
	var patience := float(cfg.get("patience_mult", 1.0))
	var combo := float(cfg.get("combo_window_mult", 1.0))
	var effects := "耐心 ×%.2f · 连击窗口 ×%.2f" % [patience, combo]
	box.add_child(UIKit.make_label(effects if unlocked else "性格数值：待发现", 16, UIKit.BLUE))
	var lines: Array = cfg.get("lines", [])
	var quote := "“%s”" % String(lines[0]) if unlocked and not lines.is_empty() else "“……”"
	box.add_child(UIKit.make_label(quote, 17, UIKit.WOOD))
	return panel
