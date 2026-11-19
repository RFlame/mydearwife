extends Node
## 百件散布的真实渲染聚焦截图；只修改测试进程的内存配置，不改关卡文件。


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var app = load("res://game/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(0.25).timeout
	for level in app.db.levels:
		if int(level["id"]) != 2:
			continue
		level["items"] = 100
		level["snack_kinds"] = 16
		level["pool"] = app.db.snacks.keys()
		level["overlap"] = 0.15
		level["scatter_width"] = 520
		level["scatter_height"] = 620
	app.start_level(2, 42)
	var game: GameScreen = app.current
	var guard := 0
	while (game._switching_customer or is_instance_valid(game.basket_view)) and guard < 200:
		guard += 1
		await get_tree().create_timer(0.05).timeout
	if game._switching_customer or is_instance_valid(game.basket_view):
		printerr("FAIL - large basket visual did not unlock")
		get_tree().quit(1)
		return
	await get_tree().create_timer(0.25).timeout
	await RenderingServer.frame_post_draw
	var image := get_tree().root.get_texture().get_image()
	image.save_png("res://docs/images/dev_scatter_100.png")
	var pickable := game.state.basket.top_items().size()
	var ok := game.state.basket.items.size() == 100 and pickable >= 95
	print("scatter visual: items=", game.state.basket.items.size(),
		" pickable=", pickable, " shot=dev_scatter_100.png")
	get_tree().quit(0 if ok else 1)
