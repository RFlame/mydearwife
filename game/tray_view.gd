class_name TrayView
extends Node2D
## 独立承重平台：零食以固定俯视位形叠放，不再排成独立格子。

const PILE_CENTER := Vector2(125, 124)
const PILE_OFFSETS := [
	Vector2(0, 0), Vector2(-38, -28), Vector2(32, -32),
	Vector2(-48, 12), Vector2(42, 18), Vector2(-8, 42),
	Vector2(5, -52), Vector2(58, -8), Vector2(-58, -14),
	Vector2(24, 50), Vector2(-30, 52), Vector2(54, 38),
]

var slots: int = 7
var _grid: Node2D = null


func build(slot_count: int) -> void:
	slots = slot_count
	if _grid:
		_grid.queue_free()
	_grid = Node2D.new()
	add_child(_grid)
	# 小刻度只表示容量，不是零食必须对齐的格子。
	for i in slots:
		var tick := Panel.new()
		tick.add_theme_stylebox_override("panel", UIKit.stylebox(Color(UIKit.CREAM, 0.65), UIKit.BROWN, 1, 3))
		tick.position = Vector2(125 + (i - (slots - 1) * 0.5) * 20 - 7, 236)
		tick.size = Vector2(14, 6)
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_grid.add_child(tick)


## 每个 UID 使用确定的俯视落点；退货其他物品不会让剩余零食换位置。
func entry_positions(entries: Array) -> Dictionary:
	var result := {}
	for e in entries:
		var uid := int(e["uid"])
		var index := posmod(uid - 1, PILE_OFFSETS.size())
		result[uid] = to_global(PILE_CENTER + PILE_OFFSETS[index])
	return result


static func entry_rotation(item: Dictionary) -> float:
	return deg_to_rad(float(item.get("rot", 0.0)))
