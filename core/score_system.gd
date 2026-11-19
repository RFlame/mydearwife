class_name ScoreSystem
extends RefCounted
## 结算：按实际称重件数计价，大批量与连击有少量加成；不设置三件门槛。


static func item_base(level_id: int) -> float:
	return 1.7 * (1.0 + level_id * 0.02)


static func batch_price(level_id: int, item_count: int, combo: int) -> Dictionary:
	var base := item_base(level_id) * item_count
	var batch_bonus := base * maxi(0, item_count - 1) * 0.04
	var combo_bonus := base * minf(combo * 0.05, 0.5)
	return {
		"base": int(round(base)),
		"bonus": int(round(batch_bonus + combo_bonus)),
		"total": int(round(base + batch_bonus + combo_bonus)),
	}


static func stars(fields: Dictionary) -> int:
	if not fields.get("completed", false):
		return 0
	var result := 1
	var total_items := maxi(1, int(fields.get("total_items", 1)))
	var fast: bool
	if fields.get("patience_unlimited", false):
		fast = fields["time_used"] <= total_items * 4.0 * 1.5
	else:
		fast = fields.get("patience_ratio", 0.0) >= 0.4
	if fast:
		result = 2
		if fields.get("best_combo", 0) >= int(ceil(total_items * 0.65)) and not fields.get("had_tray_full", false):
			result = 3
	return result


static func settle(fields: Dictionary) -> Dictionary:
	var completed: bool = fields.get("completed", false)
	var perfect: bool = completed and not fields.get("had_tray_full", false)
	var coins := int(round(fields.get("coins_earned", 0.0)))
	if perfect:
		coins = int(round(coins * 1.3))
	var tip := int(round(fields.get("best_combo", 0) * 2.0 * fields.get("tip_mult", 1.0)))
	return {
		"completed": completed,
		"stars": stars(fields),
		"coins": coins + tip if completed else int(coins * 0.2),
		"tip": tip,
		"perfect": perfect,
		"best_combo": fields.get("best_combo", 0),
		"time_used": fields.get("time_used", 0.0),
		"total_items": fields.get("total_items", 0),
		"bagged_items": fields.get("bagged_items", 0),
		"total_groups": fields.get("bagged_groups", 0),
		"return_count": fields.get("return_count", 0),
	}
