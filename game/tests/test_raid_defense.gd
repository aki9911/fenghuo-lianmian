extends SceneTree
const Model = preload("res://scripts/core/battle_model.gd")
const Town = preload("res://scripts/core/town_state.gd")
const Npc = preload("res://scripts/actors/npc_controller.gd")
var checks: int = 0
var failures: int = 0
var config: Dictionary

func _initialize() -> void:
	config = JSON.parse_string(FileAccess.get_file_as_string("res://data/runtime_config.json"))
	_schedule()
	_guard_ai()
	_ally_commands()
	_restore_prior_orders()
	_hold_evacuation()
	print("RAID_DEFENSE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)

func expect(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func fixture():
	var town = Town.new()
	town.setup(config)
	var model = Model.new()
	model.setup(town, config)
	model.begin_battle()
	return model

func _schedule() -> void:
	var model = fixture()
	expect(model.enemy_count() == 30 and model.ally_count() == 30, "initial raid30 guards and30 allies")
	expect(model.raid_next_reinforcement_in() == 180 and model.raid_next_reinforcement_count() == 10, "initial countdown180 and wave10")
	model.tick(600)
	model._tick_raid_reinforcements(600)
	expect(model.raid_elapsed == 0 and model.enemy_count() == 30, "deploy freezes raid clock and reinforcements")
	model.start_combat()
	model._tick_raid_reinforcements(179.999)
	expect(model.enemy_count() == 30, "no early reinforcement at179.999")
	model._tick_raid_reinforcements(0.001)
	expect(model.enemy_count() == 40 and model._raid_wave_index == 1, "180 exact adds10 once")
	for agent in model.agents:
		if agent.team == "enemy" and agent.id > 60:
			expect(agent.pos.distance_to(Model.SUPPLY_POSITION) >= 6.99 and agent.pos.distance_to(model.player_pos) >= 3.5, "reinforcements enter clear camp perimeter, not on player")
			for other in model.agents:
				if other.alive and other.id != agent.id: expect(agent.pos.distance_to(other.pos) >= 0.849, "reinforcement never overlaps existing NPC")
	model._tick_raid_reinforcements(0)
	expect(model.enemy_count() == 40, "repeated time boundary does not duplicate wave")
	for row in [[60,50,15], [60,65,20], [60,85,20], [60,100,20]]:
		model._tick_raid_reinforcements(row[0])
		expect(model.enemy_count() == row[1] and model.raid_next_reinforcement_count() == row[2], "confirmed minute wave schedule")
	expect(model.raid_pending_reinforcements == 5, "overflow waits at100 regional cap")
	model._tick_raid_reinforcements(60)
	expect(model.raid_pending_reinforcements == 25 and model.enemy_count() == 100, "subsequent minute overflow accumulates")
	var enemy: Dictionary = {}
	for agent in model.agents:
		if agent.team == "enemy": enemy = agent; break
	model._damage(enemy, 10000)
	var morale: float = model.morale
	model._tick_raid_reinforcements(0)
	expect(model.enemy_count() == 100 and model.raid_pending_reinforcements == 24 and model.morale == morale, "vacancy admits pending guard without morale recovery")
	var clock: float = model.raid_elapsed
	model.mode = "deploy"
	model.tick(100)
	model._tick_raid_reinforcements(100)
	expect(model.raid_elapsed == clock and model.raid_pending_reinforcements == 24, "paused pending queue and timer frozen")
	model.mode = "combat"
	model.advance_phase()
	model.start_combat()
	model._tick_raid_reinforcements(600)
	expect(model.raid_elapsed == clock and model.raid_pending_reinforcements == 0, "phase change cancels raid queue and clock")
	expect(model.raid_next_reinforcement_in() == -1 and model.raid_next_reinforcement_count() == 0, "inactive HUD schedule sentinel")
	var victim: Dictionary = {}
	for agent in model.agents:
		if agent.team == "enemy" and agent.alive: victim = agent; break
	model._damage(victim, 10000)
	model.tick(float(config.globals.battle_spawn_interval))
	expect(model.enemy_count() == 100, "normal phase keeps ordinary continuous replacement")
	var zero = fixture()
	zero.start_combat()
	zero._tick_raid_reinforcements(179.9)
	zero.debug_set_morale(0)
	zero.tick(600)
	zero._tick_raid_reinforcements(600)
	expect(zero.raid_elapsed == 179.9 and zero._raid_wave_index == 0, "zero morale and result cancel clock before imminent wave")
	var fixed_step = fixture()
	fixed_step.start_combat()
	fixed_step._tick_raid_reinforcements(179.9)
	fixed_step.tick(0.099)
	expect(fixed_step.enemy_count() == 30, "fractional frame does not fire early wave")
	fixed_step.tick(0.001)
	expect(fixed_step.enemy_count() == 40, "authoritative fixed step fires exact180 boundary")

func _guard_ai() -> void:
	var model = fixture()
	model.start_combat()
	model.issue_all_order("hold")
	var gate_hp: float = model.gate_hp
	model.tick(20)
	expect(model.front_capture == 0 and model.gate_hp == gate_hp and model.phase == 0, "raid never attacks front flag or gate")
	for agent in model.agents:
		if agent.team == "enemy":
			expect(agent.pos.distance_to(Model.SUPPLY_POSITION) <= 10.001 and agent.pos.x <= 23 and agent.pos.y >= -26, "patrol stays inside bounded supply defense region")
	var guard: Dictionary = {}
	for agent in model.agents:
		if agent.team == "enemy": guard = agent; break
	model.agents = [guard]
	guard.kind = "raider"
	guard.pos = Model.SUPPLY_POSITION + Vector2(0,3)
	guard.cooldown = 0
	model.player_pos = guard.pos + Vector2(0,1)
	var hp: float = model.player_hp
	Npc.simulate(model, guard, 0.1)
	expect(model.player_hp < hp, "guard fights nearby player inside camp")
	model.player_pos = Model.SUPPLY_POSITION + Vector2(0,11)
	guard.pos = Model.SUPPLY_POSITION + Vector2(0,9)
	var before: Vector2 = guard.pos
	Npc.simulate(model, guard, 0.1)
	expect(guard.pos.distance_to(Model.SUPPLY_POSITION) < before.distance_to(Model.SUPPLY_POSITION), "guard returns when target leaves zone")
	var ally: Dictionary = {"id":900,"soldier_id":101,"team":"ally","pos":Model.SUPPLY_POSITION + Vector2(0,3),"hp":100.0,"max_hp":100.0,"alive":true,"kind":"guard","cooldown":0.0,"formation":0,"formation_offset":Vector2.ZERO,"equipped":true}
	guard.pos = ally.pos + Vector2(1,0)
	guard.cooldown = 0
	model.agents.append(ally)
	Npc.simulate(model, guard, 0.1)
	expect(ally.hp < 100, "guard defends camp against invading soldier")
	ally.pos = Vector2(0,4)
	guard.cooldown = 0
	for index in range(300): Npc.simulate(model, guard, 0.1)
	expect(guard.pos.distance_to(Model.SUPPLY_POSITION) <= 10 and ally.hp > 0, "guard never pursues soldier to front flag")

func _ally_commands() -> void:
	var model = fixture()
	expect(model.squad_orders[0].mode == "guard", "default squad mode permits limited pursuit")
	model.start_combat()
	var ally: Dictionary = model.agents[0]
	ally.pos = Vector2.ZERO
	ally.kind = "guard"
	ally.formation_offset = Vector2.ZERO
	model.formations[0] = Vector2.ZERO
	model.squad_orders[0] = {"mode":"guard", "target":Vector2.ZERO}
	var enemy: Dictionary = {"id":900,"team":"enemy","pos":Vector2(5,0),"hp":1000.0,"max_hp":1000.0,"alive":true,"kind":"raider","soldier_id":-1,"cooldown":0.0}
	model.agents = [ally,enemy]
	Npc.simulate(model, ally, 0.1)
	expect(ally.pos.x > 0, "default guard pursues nearby enemy")
	ally.pos = Vector2(7.9,0)
	enemy.pos = Vector2(12,0)
	Npc.simulate(model, ally, 0.1)
	expect(ally.pos.x < 7.9, "target beyond pursuit leash makes guard return")
	ally.pos = Vector2(7.99,0)
	enemy.pos = Vector2(7.8,0)
	model._separate_agents(1)
	expect(ally.pos.length() <= 8.00001, "separation cannot push guard beyond pursuit boundary")
	ally.pos = Vector2(4.123, 2.456)
	ally.cooldown = 0
	enemy.pos = ally.pos + Vector2(1,0)
	var original: Vector2 = ally.pos
	expect(model.issue_all_order("hold") and model.army_holding, "whole army hold enabled")
	Npc.simulate(model, ally, 0.1)
	expect(enemy.hp < 1000 and ally.pos == original, "hold attacks in range without shifting position")
	enemy.pos = ally.pos
	model._separate_agents(10)
	model._move(ally, Vector2(20,20), 20)
	expect(ally.pos == original, "hold ignores separation and movement requests exactly")
	expect(not model.issue_order(0,"follow") and not model.issue_order(0,"guard"), "global hold rejects squad commands")
	model.advance_phase()
	expect(model.army_holding, "hold survives stage deployment")
	model.place_squad(0,Vector2(7,7))
	model.start_combat()
	var deployed: Vector2 = ally.pos
	model.tick(0.2)
	expect(model.army_holding and ally.pos == deployed, "manual deployment intentionally reanchors held soldiers")
	expect(model.issue_all_order("guard") and not model.army_holding and model.issue_order(0,"follow"), "all guard releases motion and squad commands")
	model.debug_set_morale(0)
	model.begin_battle()
	expect(not model.army_holding, "new battle clears all army hold")

func _hold_evacuation() -> void:
	var model = fixture()
	while model.phase < 3:
		model.start_combat()
		model.advance_phase()
	model.start_combat()
	model.issue_all_order("hold")
	model.debug_set_morale(0)
	var positions: Dictionary = {}
	for agent in model.agents:
		if agent.team == "ally": positions[agent.id] = agent.pos
	model.tick(140)
	expect(model.escaped == 100 and model.ally_count() == 50, "held army does not auto evacuate after civilians")
	for agent in model.agents:
		if agent.team == "ally": expect(agent.pos == positions[agent.id], "hold keeps exact position throughout evacuation")
	model.issue_all_order("guard")
	model.tick(60)
	expect(model.escaped == 150, "release allows military evacuation to finish")

func _restore_prior_orders() -> void:
	var model = fixture()
	model.start_combat()
	model.issue_order(0, "follow")
	model.issue_order(1, "advance", Vector2(2, -4))
	var previous: Array = model.squad_orders.duplicate(true)
	model.issue_all_order("hold")
	model.tick(1)
	model.issue_all_order("guard")
	expect(model.squad_orders == previous, "release resumes follow and advance orders held before freeze")
	var ally: Dictionary = model.agents[0]
	var before: float = ally.pos.distance_to(model.squad_anchor(0))
	Npc.simulate(model, ally, 0.1)
	expect(ally.pos.distance_to(model.squad_anchor(0)) < before, "released following squad continues toward commander")
