class_name TownState
extends RefCounted
## Authoritative realtime town economy. Visual citizens never create resources.

var config: Dictionary = {}
var money: int = 0
var resources: Dictionary = {}
var people: Array = []
var jobs: Dictionary = {}
var facilities: Dictionary = {}
var salvage: int = 0
var messages: Array = []
var transfers: Array = []
var job_progress: Dictionary = {}
var job_status: Dictionary = {}
var neighbor_inventory: Dictionary = {}
var _batches: Dictionary = {}
var _accumulator: float = 0.0
var _transfer_id: int = 0
var _gift_received: bool = false


func setup(settings: Dictionary) -> void:
	config = settings.duplicate(true)
	money = int(config.get("globals", {}).get("money_initial", 600))
	resources = config.get("initial_resources", {}).duplicate(true)
	people.clear()
	var global: Dictionary = config.get("globals", {})
	var economy: Dictionary = config.get("economy", {})
	var residents: int = int(global.get("residents_initial", 100))
	var soldiers: int = int(global.get("soldiers_initial", 50))
	var equipped: int = int(economy.get("initial_equipped", 30))
	for i in range(residents + soldiers):
		var military: bool = i >= residents
		people.append({"id": i + 1, "origin": "soldier" if military else "resident", "role": "soldier" if military else "unhired", "health": "healthy", "escaped": false, "equipped": military and i - residents < equipped})
	jobs = {"unhired": "gather_material", "engineer": "repair_outer", "medical": "heal_wounded", "supply": "craft_equipment"}
	facilities = economy.get("initial_facilities", {"outer": 70.0, "street": 65.0, "evac": 50.0}).duplicate(true)
	neighbor_inventory = economy.get("neighbor_inventory", {"material": 100, "medicine": 20, "rations": 40}).duplicate(true)
	salvage = 0
	messages.clear()
	transfers.clear()
	_batches.clear()
	job_progress.clear()
	job_status.clear()
	_accumulator = 0.0
	_transfer_id = 0
	_gift_received = false
	_message("望烽镇就绪：居民100，守军50。请前往营地雇佣人手。")


func _living(person: Dictionary) -> bool:
	return person.get("health", "healthy") in ["healthy", "wounded"]


func count_role(role: String, healthy_only: bool = false) -> int:
	var total: int = 0
	for person in people:
		if person.get("role", "") == role and _living(person) and (not healthy_only or person.get("health", "") == "healthy"):
			total += 1
	return total


func resident_count() -> int:
	var total: int = 0
	for person in people:
		if person.get("role", "") != "soldier" and _living(person):
			total += 1
	return total


func soldier_count() -> int:
	return count_role("soldier")


func hire(role: String, amount: int) -> bool:
	var hiring: Dictionary = config.get("hire", {})
	if not hiring.has(role) or amount <= 0:
		return false
	var row: Dictionary = hiring[role]
	var cost: int = int(row.get("hire_cost", -1)) * amount
	if int(row.get("hire_cost", -1)) < 0 or count_role(role) + amount > int(row.get("max_workers", 20)):
		_message("该岗位已达上限或费用未配置。")
		return false
	if count_role("unhired", true) < amount or money < cost:
		_message("钱币或健康待业居民不足。")
		return false
	_flush_fraction()
	money -= cost
	var remaining: int = amount
	for person in people:
		if person.role == "unhired" and person.health == "healthy" and remaining > 0:
			person.role = role
			remaining -= 1
	_message("已雇佣 %d 名%s，支出 %d 钱。" % [amount, row.get("name", role), cost])
	return true


func dismiss(role: String, amount: int) -> bool:
	if not config.get("hire", {}).has(role) or amount <= 0 or count_role(role, true) < amount:
		return false
	_flush_fraction()
	var remaining: int = amount
	for person in people:
		if person.role == role and person.health == "healthy" and remaining > 0:
			person.role = "unhired"
			remaining -= 1
	if count_role(role, true) == 0:
		_cancel_batch(role)
	_message("%d 名居民返回基础采集，雇佣费不返还。" % amount)
	return true


func set_job(role: String, job_id: String) -> void:
	var defs: Dictionary = config.get("jobs", {})
	if not defs.has(job_id) or defs[job_id].get("team_id", "") != role:
		return
	if jobs.get(role, "") == job_id:
		return
	_flush_fraction()
	_cancel_batch(role)
	jobs[role] = job_id
	job_progress[role] = 0.0
	job_status[role] = "等待人手"


func tick(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	_accumulator += delta
	var step: float = maxf(0.1, float(config.get("globals", {}).get("economy_step_sec", 1.0)))
	while _accumulator + 0.000001 >= step:
		_accumulator = maxf(0.0, _accumulator - step)
		_economy_step(step)


func _flush_fraction() -> void:
	if _accumulator > 0.0:
		var elapsed: float = _accumulator
		_accumulator = 0.0
		_economy_step(elapsed)


func _economy_step(delta: float) -> void:
	for role in ["unhired", "engineer", "medical", "supply"]:
		_process_job(role, str(jobs.get(role, "")), count_role(role, true), delta)
	job_status["reserve"] = "待补员 %d 人" % count_role("reserve", true)
	_tick_transfers(delta)


func _process_job(slot: String, job_id: String, workers: int, delta: float) -> void:
	var defs: Dictionary = config.get("jobs", {})
	if not defs.has(job_id):
		job_status[slot] = "待配置"
		return
	if workers <= 0:
		job_status[slot] = "等待人手"
		return
	var job: Dictionary = defs[job_id]
	var required: float = float(job.get("work_required", 0.0))
	var rate: float = float(job.get("rate_per_person_sec", 0.0))
	if required <= 0.0 or rate <= 0.0:
		job_status[slot] = "待配置"
		return
	var budget: float = workers * rate * delta
	while budget > 0.000001:
		var reason: String = _blocked_reason(job)
		if not reason.is_empty():
			job_status[slot] = reason
			return
		if not _batches.has(slot):
			var inputs: Dictionary = config.get("inputs", {}).get(job_id, {})
			for item in inputs:
				if int(resources.get(item, 0)) < int(inputs[item]):
					job_status[slot] = "材料不足：%s" % item
					return
			for item in inputs:
				resources[item] = int(resources.get(item, 0)) - int(inputs[item])
			_batches[slot] = {"job": job_id, "work": 0.0, "locked": inputs.duplicate(true)}
		var batch: Dictionary = _batches[slot]
		var needed: float = required - float(batch.work)
		var used: float = minf(budget, needed)
		batch.work = float(batch.work) + used
		budget -= used
		job_progress[slot] = clampf(float(batch.work) / required, 0.0, 1.0)
		job_status[slot] = "工作中 · %d人" % workers
		if float(batch.work) + 0.000001 < required:
			return
		_complete_job(job)
		_batches.erase(slot)
		job_progress[slot] = 0.0


func _blocked_reason(job: Dictionary) -> String:
	var output: String = str(job.get("output_id", ""))
	var repair: Dictionary = {"wall_hp": "outer", "street_hp": "street", "evac_hp": "evac"}
	if repair.has(output):
		return "已修缮完毕" if float(facilities.get(repair[output], 100.0)) >= 100.0 else ""
	if output == "healed_person":
		for person in people:
			if person.health == "wounded":
				return ""
		return "暂无伤员"
	if output == "salvage_unit":
		if salvage <= 0:
			return "无可回收战利品"
		return "仓库已满" if _stored_amount("material") >= int(config.get("economy", {}).get("warehouse_capacity", 500)) else ""
	var cap: int = int(config.get("economy", {}).get("warehouse_capacity", 500))
	if _stored_amount(output) + int(job.get("output_qty", 0)) > cap:
		return "仓库已满"
	return ""


func _complete_job(job: Dictionary) -> void:
	var output: String = str(job.output_id)
	var amount: int = int(job.output_qty)
	var repair: Dictionary = {"wall_hp": "outer", "street_hp": "street", "evac_hp": "evac"}
	if repair.has(output):
		var target: String = str(repair[output])
		facilities[target] = minf(100.0, float(facilities.get(target, 0.0)) + amount)
	elif output == "healed_person":
		for person in people:
			if person.health == "wounded" and amount > 0:
				person.health = "healthy"
				amount -= 1
	elif output == "salvage_unit":
		var cap: int = int(config.get("economy", {}).get("warehouse_capacity", 500))
		var recovered: int = mini(amount, mini(salvage, cap - _stored_amount("material")))
		if recovered > 0:
			salvage -= recovered
			resources.material = int(resources.get("material", 0)) + recovered
	else:
		resources[output] = int(resources.get(output, 0)) + amount


func _stored_amount(item: String) -> int:
	# Work-in-progress inputs reserve storage until consumed or returned on cancel.
	var total: int = int(resources.get(item, 0))
	for slot in _batches:
		total += int(_batches[slot].get("locked", {}).get(item, 0))
	return total


func _cancel_batch(slot: String) -> void:
	if _batches.has(slot):
		for item in _batches[slot].locked:
			resources[item] = int(resources.get(item, 0)) + int(_batches[slot].locked[item])
		_batches.erase(slot)
	job_progress[slot] = 0.0


func healthy_soldier_ids() -> Array:
	var result: Array = []
	for person in people:
		if person.role == "soldier" and person.health == "healthy":
			result.append(int(person.id))
	return result


func equipped_count() -> int:
	var result: int = 0
	for person in people:
		if person.role == "soldier" and person.health == "healthy" and person.get("equipped", false):
			result += 1
	return result


func equip_soldiers() -> int:
	var added: int = 0
	for person in people:
		if person.role == "soldier" and person.health == "healthy" and not person.get("equipped", false) and int(resources.get("equipment", 0)) > 0:
			resources.equipment = int(resources.equipment) - 1
			person.equipped = true
			added += 1
	_message("分发 %d 套装备，已装备 %d 名守军。" % [added, equipped_count()])
	return added


func reinforce() -> int:
	var slots: int = maxi(0, int(config.get("globals", {}).get("soldier_roster_cap", 50)) - soldier_count())
	var count: int = mini(slots, mini(count_role("reserve", true), int(resources.get("equipment", 0))))
	var remaining: int = count
	for person in people:
		if person.role == "reserve" and person.health == "healthy" and remaining > 0:
			person.role = "soldier"
			person.equipped = true
			resources.equipment = int(resources.equipment) - 1
			remaining -= 1
	_message("预备队补入 %d 人；居民 %d，守军 %d。" % [count, resident_count(), soldier_count()])
	return count


func mark_casualty(id: int, wounded: bool) -> void:
	for person in people:
		if int(person.id) != id or not _living(person):
			continue
		person.health = "wounded" if wounded else "dead"
		if not wounded:
			person.equipped = false
		return


func send_transfer(item: String, amount: int) -> bool:
	var capacity: int = int(config.get("globals", {}).get("transport_capacity", 20))
	var weight: int = 10 if item == "siege_engine" else 1
	if amount <= 0 or amount * weight > capacity or int(resources.get(item, 0)) < amount:
		_message("运输失败：物资不足或超过单车载重。")
		return false
	for transfer in transfers:
		if not transfer.delivered:
			_message("运输队正在途中，请等待返回。")
			return false
	resources[item] = int(resources.get(item, 0)) - amount
	_transfer_id += 1
	var duration: float = float(config.get("globals", {}).get("transport_duration", 20.0))
	transfers.append({"id": _transfer_id, "item": item, "amount": amount, "remaining": duration, "duration": duration, "delivered": false})
	_message("模拟邻镇支援出发：%s × %d。" % [item, amount])
	return true


func _tick_transfers(delta: float) -> void:
	for transfer in transfers:
		if transfer.delivered:
			continue
		transfer.remaining = maxf(0.0, float(transfer.remaining) - delta)
		if float(transfer.remaining) > 0.000001:
			continue
		transfer.delivered = true
		var item: String = str(transfer.item)
		neighbor_inventory[item] = int(neighbor_inventory.get(item, 0)) + int(transfer.amount)
		_message("模拟邻镇已收到支援。")
		if not _gift_received:
			var economy: Dictionary = config.get("economy", {})
			var gift_item: String = str(economy.get("neighbor_gift_item", "medicine"))
			var cap: int = int(economy.get("warehouse_capacity", 500))
			var qty: int = mini(int(economy.get("neighbor_gift_amount", 10)), int(neighbor_inventory.get(gift_item, 0)))
			qty = mini(qty, cap - _stored_amount(gift_item))
			if qty > 0:
				neighbor_inventory[gift_item] = int(neighbor_inventory.get(gift_item, 0)) - qty
				resources[gift_item] = int(resources.get(gift_item, 0)) + qty
				_message("邻镇回赠 %d 份药品（本局一次，离线模拟）。" % qty)
			_gift_received = true


func snapshot() -> Dictionary:
	return {"schema_version": 1, "money": money, "resources": resources.duplicate(true), "people": people.duplicate(true), "jobs": jobs.duplicate(true), "facilities": facilities.duplicate(true), "salvage": salvage, "messages": messages.duplicate(true), "transfers": transfers.duplicate(true), "job_progress": job_progress.duplicate(true), "job_status": job_status.duplicate(true), "batches": _batches.duplicate(true), "accumulator": _accumulator, "transfer_id": _transfer_id, "gift_received": _gift_received, "neighbor_inventory": neighbor_inventory.duplicate(true)}


func restore(data: Dictionary) -> void:
	if not _valid_snapshot(data):
		_message("存档格式不兼容。")
		return
	money = maxi(0, int(data.get("money", 0)))
	resources = data.resources.duplicate(true)
	people = data.people.duplicate(true)
	jobs = data.get("jobs", jobs).duplicate(true)
	facilities = data.get("facilities", facilities).duplicate(true)
	salvage = maxi(0, int(data.get("salvage", 0)))
	messages = data.get("messages", []).duplicate(true)
	transfers = data.get("transfers", []).duplicate(true)
	job_progress = data.get("job_progress", {}).duplicate(true)
	job_status = data.get("job_status", {}).duplicate(true)
	_batches = data.get("batches", {}).duplicate(true)
	_accumulator = maxf(0.0, float(data.get("accumulator", 0.0)))
	_transfer_id = int(data.get("transfer_id", 0))
	_gift_received = bool(data.get("gift_received", false))
	neighbor_inventory = data.get("neighbor_inventory", {}).duplicate(true)


func _valid_snapshot(data: Dictionary) -> bool:
	if int(data.get("schema_version", 0)) != 1 or not data.get("people") is Array or not data.get("resources") is Dictionary:
		return false
	var initial_count: int = int(config.get("globals", {}).get("residents_initial", 100)) + int(config.get("globals", {}).get("soldiers_initial", 50))
	if data.people.size() != initial_count:
		return false
	var seen: Dictionary = {}
	var roles: Dictionary = {}
	for person in data.people:
		if not person is Dictionary:
			return false
		var id: int = int(person.get("id", 0))
		if id <= 0 or id > initial_count or seen.has(id) or person.get("origin", "") not in ["resident", "soldier"]:
			return false
		seen[id] = true
		if person.get("role", "") not in ["unhired", "engineer", "medical", "supply", "reserve", "soldier"] or person.get("health", "") not in ["healthy", "wounded", "dead", "missing"]:
			return false
		if _living(person):
			roles[person.role] = int(roles.get(person.role, 0)) + 1
	for role in config.get("hire", {}):
		if int(roles.get(role, 0)) > int(config.hire[role].max_workers):
			return false
	if int(roles.get("soldier", 0)) > int(config.get("globals", {}).get("soldier_roster_cap", 50)):
		return false
	for item in data.resources:
		var quantity = data.resources[item]
		if not (quantity is int or quantity is float) or not is_finite(float(quantity)) or float(quantity) < 0.0 or float(quantity) != float(int(quantity)):
			return false
	var transfer_ids: Dictionary = {}
	for transfer in data.get("transfers", []):
		if not transfer is Dictionary or int(transfer.get("id", 0)) <= 0 or transfer_ids.has(int(transfer.id)) or int(transfer.get("amount", 0)) <= 0:
			return false
		transfer_ids[int(transfer.id)] = true
	return true


func _message(message: String) -> void:
	messages.append(message)
	if messages.size() > 20:
		messages.pop_front()
