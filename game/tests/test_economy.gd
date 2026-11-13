extends SceneTree
## Run: Godot --headless --path game --script res://tests/test_economy.gd
const TownScript = preload("res://scripts/core/town_state.gd")
var settings: Dictionary = {}
var failures: Array = []
var checks: int = 0


func _initialize() -> void:
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://data/runtime_config.json"))
	_test_population()
	_test_time_and_assignment()
	_test_production_and_storage()
	_test_recovery()
	_test_transfers_and_save()
	if failures.is_empty():
		print("ECONOMY PASS: %d assertions; conservation, realtime, production, recovery, transfers, save/load" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + str(failure))
		quit(1)


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func fresh(quiet_gather: bool = false):
	var town = TownScript.new()
	var local: Dictionary = settings.duplicate(true)
	if quiet_gather:
		for key in ["gather_material", "gather_herb", "gather_food"]:
			local.jobs[key].work_required = 100000000.0
	town.setup(local)
	return town


func _test_population() -> void:
	var town = fresh()
	check(town.people.size() == 150 and town.resident_count() == 100 and town.soldier_count() == 50, "Initial 100 residents + 50 soldiers")
	check(town.money == 600 and town.equipped_count() == 30 and town.resources.equipment == 20, "Initial money and equipment")
	check(town.equip_soldiers() == 20 and town.equipped_count() == 50 and town.resources.equipment == 0, "Distributing equipment conserves stock")
	check(town.equip_soldiers() == 0, "Equipment distribution is idempotent")
	for role in ["engineer", "medical", "supply", "reserve"]:
		check(town.hire(role, 20), "Hire 20 " + role)
		check(not town.hire(role, 1), "Department cap " + role)
	check(town.count_role("unhired") == 20 and town.money == 340, "Hiring preserves population and charges exact cost")
	check(not town.hire("soldier", 1) and not town.hire("engineer", -1), "Invalid hiring rejected")
	var ids: Array = town.healthy_soldier_ids()
	for i in range(10):
		town.mark_casualty(ids[i], false)
	town.resources.equipment = 10
	check(town.reinforce() == 10, "Reserve fills genuine roster vacancies")
	check(town.resident_count() == 90 and town.soldier_count() == 50 and town.people.size() == 150, "Reserve to soldier preserves identities and total living")
	check(town.resources.equipment == 0 and town.count_role("reserve") == 10, "Reinforcement consumes equipment and reserves")
	check(town.reinforce() == 0, "Cannot reinforce full roster")
	town.mark_casualty(ids[0], true)
	check(town.people[int(ids[0]) - 1].health == "dead", "Duplicate casualty cannot revive dead person")
	var wounded_town = fresh()
	wounded_town.hire("reserve", 10)
	wounded_town.mark_casualty(101, true)
	check(wounded_town.soldier_count() == 50 and wounded_town.healthy_soldier_ids().size() == 49 and wounded_town.reinforce() == 0, "Wounded soldiers retain roster slots")
	var poor_town = fresh()
	poor_town.money = 1
	check(not poor_town.hire("engineer", 1) and poor_town.money == 1 and poor_town.count_role("unhired") == 100, "Insufficient money is atomic")


func _test_time_and_assignment() -> void:
	var baseline = fresh()
	baseline.hire("supply", 20)
	baseline.hire("engineer", 20)
	baseline.tick(60.0)
	for fps in [30, 60, 120]:
		var town = fresh()
		town.hire("supply", 20)
		town.hire("engineer", 20)
		for frame in range(fps * 60):
			town.tick(1.0 / fps)
		check(town.resources == baseline.resources and town.facilities == baseline.facilities, "Production independent of FPS: %d" % fps)
	var assigned = fresh()
	assigned.set_job("unhired", "gather_herb")
	assigned.tick(3.0)
	check(assigned.resources.herb_raw == 34 and assigned.resources.material == 80 and assigned.resources.food_raw == 40, "Unhired residents follow selected gather job")
	assigned.set_job("unhired", "gather_food")
	assigned.tick(2.0)
	check(assigned.resources.food_raw == 45 and assigned.resources.herb_raw == 34, "Changing gathering affects only chosen production")
	var frozen: Dictionary = assigned.snapshot()
	assigned.tick(0.0)
	assigned.tick(-10.0)
	assigned.tick(INF)
	check(assigned.snapshot() == frozen, "No autonomous simulation; zero/negative/nonfinite time does not advance")
	var fraction = fresh(true)
	fraction.tick(0.5)
	fraction.hire("supply", 20)
	fraction.tick(0.5)
	check(float(fraction.snapshot().batches.get("supply", {}).get("work", 0.0)) == 0.0, "Hiring does not retroactively credit old fractional time")
	fraction.tick(0.5)
	check(is_equal_approx(float(fraction.snapshot().batches.supply.work), 20.0), "New staff receives only time worked")


func _test_production_and_storage() -> void:
	var town = fresh(true)
	town.hire("supply", 20)
	town.tick(1.0)
	check(town.resources.material == 75 and town.resources.equipment == 20, "Production locks inputs before output")
	town.set_job("supply", "prepare_medicine")
	check(town.resources.material == 80, "Changing recipe returns unconsumed input")
	town.tick(4.0)
	check(town.resources.medicine == 20 and town.resources.herb_raw == 25, "Recipe completes using correct ingredients")
	town.resources.herb_raw = 0
	town.tick(100.0)
	check(town.resources.medicine == 20 and town.resources.herb_raw == 0, "Missing input cannot create output or negative stock")
	town.resources.herb_raw = 5
	town.tick(1.0)
	check(town.resources.medicine == 20, "Blocked production did not bank work for free instant output")
	town.dismiss("supply", 20)
	check(town.resources.herb_raw == 5 and town.count_role("supply") == 0, "Removing last worker returns locked inputs")
	var full = fresh(true)
	full.hire("supply", 20)
	full.resources.equipment = 500
	full.tick(100.0)
	check(full.resources.equipment == 500 and full.resources.material == 80, "Warehouse full pauses before charging input")
	full.resources.equipment = 20
	full.resources.material = 500
	full.tick(1.0)
	full.config.jobs.gather_material.work_required = 1.0
	full.tick(1.0)
	full.set_job("supply", "cook_rations")
	check(full.resources.material == 500, "Locked inputs reserve warehouse space until cancellation")
	for item in town.resources:
		check(int(town.resources[item]) >= 0, "Nonnegative stock " + item)


func _test_recovery() -> void:
	var town = fresh(true)
	town.hire("engineer", 20)
	town.tick(30.0)
	check(town.facilities.outer == 100.0 and town.resources.material == 65, "Repairs stop at max integrity with exact material consumption")
	town.set_job("engineer", "salvage_field")
	town.salvage = 7
	var material_before: int = town.resources.material
	town.tick(30.0)
	check(town.salvage == 0 and town.resources.material == material_before + 7, "Salvage cannot exceed finite loot pool")
	town.resources.material = 500
	town.salvage = 7
	town.tick(3.0)
	check(town.salvage == 7 and town.resources.material == 500 and town.job_status.engineer == "仓库已满", "Salvage blocks at warehouse capacity")
	town.hire("medical", 20)
	for id in range(101, 106):
		town.mark_casualty(id, true)
	town.tick(4.0)
	check(town.healthy_soldier_ids().size() == 50 and town.resources.medicine == 10, "Treatment restores wounded identities and consumes medicine")
	town.tick(20.0)
	check(town.resources.medicine == 10, "No wounded means no medicine consumed")


func _test_transfers_and_save() -> void:
	var town = fresh(true)
	check(not town.send_transfer("rations", -1) and not town.send_transfer("rations", 21) and not town.send_transfer("unknown", 1), "Invalid transfers rejected")
	check(town.send_transfer("rations", 20) and town.resources.rations == 10, "Departure debits actual inventory")
	check(not town.send_transfer("rations", 1), "Single cart cannot duplicate dispatch")
	town.hire("supply", 20)
	town.tick(7.5)
	var serialized: Dictionary = JSON.parse_string(JSON.stringify(town.snapshot()))
	var restored = fresh(true)
	restored.restore(serialized)
	town.tick(12.5)
	restored.tick(12.5)
	for item in town.resources:
		check(int(restored.resources.get(item, -1)) == int(town.resources[item]), "Save/load preserves stock: " + item)
	for item in town.neighbor_inventory:
		check(int(restored.neighbor_inventory.get(item, -1)) == int(town.neighbor_inventory[item]), "Save/load preserves neighbor stock: " + item)
	check(restored.transfers[0].delivered and restored.neighbor_inventory.rations == 60, "Delivery credits neighbor once")
	check(restored.resources.medicine == 25 and restored.neighbor_inventory.medicine == 10, "Finite neighbor gift conserves medicine across towns")
	var delivered: Dictionary = JSON.parse_string(JSON.stringify(restored.snapshot()))
	restored.restore(delivered)
	restored.tick(100.0)
	check(restored.neighbor_inventory.rations == 60 and restored.resources.medicine == 25, "Completed delivery and gift do not repeat after load")
	check(restored.send_transfer("rations", 5), "Cart available after delivery")
	restored.tick(20.0)
	check(restored.neighbor_inventory.rations == 65 and restored.resources.medicine == 25 and int(restored.transfers[1].id) == 2, "Transfer IDs remain unique and gift only once")
	var bad: Dictionary = restored.snapshot()
	bad.resources.material = -1
	var material_before: int = restored.resources.material
	restored.restore(bad)
	check(restored.resources.material == material_before, "Negative-stock save rejected without mutating inventory")
	bad = restored.snapshot()
	bad.people[0].id = bad.people[1].id
	restored.restore(bad)
	check(restored.people[0].id == 1, "Duplicate identity save rejected")
	bad = restored.snapshot()
	bad.transfers.append(bad.transfers[0].duplicate(true))
	restored.restore(bad)
	check(restored.transfers.size() == 2, "Duplicate transfer save rejected")
