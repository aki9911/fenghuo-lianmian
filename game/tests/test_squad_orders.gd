extends SceneTree

const Model = preload("res://scripts/core/battle_model.gd")
const Town = preload("res://scripts/core/town_state.gd")
const Controller = preload("res://scripts/actors/npc_controller.gd")
var checks: int = 0
var failures: int = 0
var settings: Dictionary = {}
var resolver_calls: int = 0
var civilian_calls: int = 0

func _initialize() -> void:
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://data/runtime_config.json"))
	call_deferred("_run")

func _run() -> void:
	_deployment()
	_orders()
	_reinforcement_slots()
	_movement_hook()
	await _physical_collision()
	print("SQUAD_TESTS checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func fixture():
	var town = Town.new()
	town.setup(settings)
	var model = Model.new()
	model.setup(town, settings)
	model.begin_battle()
	return model

func _deployment() -> void:
	var model = fixture()
	var before: Array = model.agents.duplicate(true)
	var elapsed: float = model.elapsed
	var target: Vector2 = Vector2(12, -6)
	expect(model.squad_orders.size() == 5, "five independent squad orders")
	expect(model.place_squad(2, target), "deployment accepts placement")
	var members: int = 0
	for index in range(model.agents.size()):
		var agent: Dictionary = model.agents[index]
		if agent.team == "ally" and agent.formation == 2:
			members += 1
			expect(agent.pos == target + agent.formation_offset, "placement changes each member immediately")
		else:
			expect(agent.pos == before[index].pos, "placement leaves other teams untouched")
		expect(agent.id == before[index].id and agent.hp == before[index].hp, "placement preserves identity and HP")
	expect(members == 6 and model.elapsed == elapsed, "deployment does not simulate time or create soldiers")
	var placed: Array = model.agents.duplicate(true)
	model.tick(20)
	expect(model.agents == placed, "paused arrangement stays frozen")
	expect(not model.issue_order(2, "follow"), "combat order unavailable during deployment")
	expect(not model.place_squad(-1, target) and not model.place_squad(5, target), "invalid squad cannot mutate roster")
	model.start_combat()
	for agent in model.agents:
		if agent.team == "ally" and agent.formation == 2:
			expect(agent.pos == target + agent.formation_offset, "start combat retains deployed positions")
	expect(not model.place_squad(2, Vector2.ZERO), "combat forbids instant teleport placement")
	model.advance_phase()
	expect(model.mode == "deploy", "phase transition still pauses")
	for agent in model.agents:
		if agent.team == "ally" and agent.alive:
			expect(agent.pos == model.formations[agent.formation] + agent.formation_offset, "phase deployment immediately updates all survivors")

func _orders() -> void:
	var model = fixture()
	model.start_combat()
	var ally: Dictionary = model.agents[1]
	ally.kind = "guard"
	ally.pos = Vector2(-15, -10)
	ally.formation = 0
	ally.formation_offset = Vector2.ZERO
	model.agents = [ally]
	model.player_pos = Vector2(5, 5)
	model.player_facing = Vector2.UP
	expect(model.issue_order(0, "follow"), "follow order accepted")
	for index in range(150):
		Controller.simulate(model, ally, 0.1)
	expect(ally.pos.distance_to(model.squad_anchor(0)) < 0.01, "follow reaches moving commander formation")
	var unique: Dictionary = {}
	for slot in range(5):
		model.issue_order(slot, "follow")
		unique[model.squad_anchor(slot)] = true
	expect(unique.size() == 5, "five following squads use distinct anchors")
	var first: Vector2 = model.squad_anchor(0)
	model.player_facing = Vector2.RIGHT
	expect(model.squad_anchor(0) != first, "following formation rotates with player facing")
	model.player_pos = Vector2(20, 20)
	var start: Vector2 = ally.pos
	var enemy: Dictionary = {"id": 9999, "team": "enemy", "pos": start + Vector2(2, 0), "hp": 100.0, "max_hp": 100.0, "alive": true, "kind": "raider", "soldier_id": -1, "cooldown": 0.0}
	model.agents.append(enemy)
	Controller.simulate(model, ally, 0.1)
	expect(ally.pos.distance_to(model.squad_anchor(0)) < start.distance_to(model.squad_anchor(0)), "distant follower returns to player despite distracting enemy")
	expect(model.issue_order(0, "hold", Vector2(0, 5)), "hold order accepted")
	ally.pos = Vector2(0, 5)
	enemy.pos = Vector2(4, 5)
	for index in range(30):
		Controller.simulate(model, ally, 0.1)
	expect(ally.pos == Vector2(0, 5), "holding melee unit does not chase distant enemy")
	model.player_pos = Vector2(-10, -10)
	expect(model.squad_anchor(0) == Vector2(0, 5), "hold target independent from player movement")
	expect(model.issue_order(0, "advance", Vector2(10, 5)), "advance order accepted")
	model.agents = [ally]
	for index in range(50):
		Controller.simulate(model, ally, 0.1)
	expect(ally.pos == Vector2(10, 5), "advance reaches explicit target")
	expect(not model.issue_order(0, "unknown") and not model.issue_order(5, "follow"), "unknown orders and invalid indices rejected")
	var saved: Dictionary = ally.duplicate(true)
	model.mode = "deploy"
	Controller.simulate(model, ally, 100)
	expect(ally == saved, "shared actor behavior obeys authoritative pause")

func _movement_hook() -> void:
	var model = fixture()
	model.movement_resolver = Callable(self, "_limit_movement")
	var ally: Dictionary = model.agents[0]
	ally.pos = Vector2.ZERO
	model._move(ally, Vector2(10, 0), 8)
	expect(ally.pos.x == 1 and resolver_calls == 1, "model commits resolved position instead of desired position")
	var other: Dictionary = model.agents[1]
	other.pos = ally.pos
	model._separate_agents(0.1)
	expect(resolver_calls > 1, "crowd separation also resolves collisions")
	while model.phase < 3:
		model.start_combat()
		model.advance_phase()
	model.start_combat()
	model.debug_set_morale(0)
	model.tick(0.1)
	expect(civilian_calls > 0, "evacuation authoritative movement also uses collision resolver")
	model.movement_resolver = Callable()
	var walker: Dictionary = {"team": "enemy", "pos": Vector2(0, 10)}
	model._move(walker, Vector2(5, 10), 5)
	expect(walker.pos == Vector2(5, 10), "headless simulation remains available without bodies")

func _reinforcement_slots() -> void:
	var model = fixture()
	model.town.hire("reserve", 2)
	model.start_combat()
	for agent in model.agents:
		if agent.team == "ally" and int(agent.soldier_id) % 4 == 0:
			model._damage(agent, 10000)
			break
	var survivor_slots: Dictionary = {}
	for agent in model.agents:
		if agent.team == "ally" and agent.alive:
			survivor_slots[agent.id] = Vector2i(agent.formation, agent.formation_row)
	model.advance_phase()
	model.town.reinforce()
	model.start_combat()
	var occupied: Dictionary = {}
	for agent in model.agents:
		if agent.team != "ally" or not agent.alive:
			continue
		var key: Vector2i = Vector2i(agent.formation, agent.formation_row)
		expect(not occupied.has(key), "reinforcement receives unused formation position")
		occupied[key] = true
		if survivor_slots.has(agent.id):
			expect(survivor_slots[agent.id] == key, "survivors retain squad membership across phase")
	expect(model.ally_count() == 50 and occupied.size() == 50, "full real army has50 separate formation positions")

func _limit_movement(agent: Dictionary, target: Vector2) -> Vector2:
	resolver_calls += 1
	if agent.team == "civilian":
		civilian_calls += 1
	return Vector2(minf(target.x, 1), target.y)

func _actor() -> CharacterBody3D:
	var actor = Controller.new()
	var shape = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	shape.shape = capsule
	shape.position.y = 0.9
	actor.add_child(shape)
	var visual = Node3D.new()
	visual.name = "Visual"
	actor.add_child(visual)
	return actor

func _physical_collision() -> void:
	var world = Node3D.new()
	root.add_child(world)
	var wall = StaticBody3D.new()
	wall.collision_layer = 1
	wall.collision_mask = 2
	var box = BoxShape3D.new()
	box.size = Vector3(0.5, 3, 8)
	var collision = CollisionShape3D.new()
	collision.shape = box
	wall.add_child(collision)
	wall.position = Vector3(2, 1.5, 0)
	world.add_child(wall)
	var actor = _actor()
	actor.combat_style = 2
	actor.speed_multiplier = 1.5
	world.add_child(actor)
	var agent: Dictionary = {"id": 1, "team": "ally", "pos": Vector2.ZERO, "alive": true}
	actor.configure(agent)
	await physics_frame
	await physics_frame
	expect(actor.collision_layer == 2 and actor.collision_mask == 3, "all characters collide with environment and characters")
	expect(agent.npc_tuning.combat_style == 2 and agent.npc_tuning.speed_multiplier == 1.5, "Inspector properties bind into shared simulation")
	agent["position_locked"] = true
	var held: Vector2 = actor.resolve_motion(Vector2.ZERO, Vector2(1, 0))
	expect(held == Vector2.ZERO and actor.global_position.x == 0, "shared physical controller preserves held actor position")
	agent["position_locked"] = false
	var stopped: Vector2 = actor.resolve_motion(Vector2.ZERO, Vector2(5, 0))
	expect(stopped.x < 1.5 and stopped.x > 1.0, "real capsule blocked by static wall")
	agent.pos = Vector2.ZERO
	actor.sync_from_state(agent, true)
	await physics_frame
	var slid: Vector2 = actor.resolve_motion(Vector2.ZERO, Vector2(5, 3))
	expect(slid.x < 1.5 and slid.y > 2.5, "actor slides along static wall")
	agent.pos = Vector2.ZERO
	actor.sync_from_state(agent, true)
	var second = _actor()
	world.add_child(second)
	var other: Dictionary = {"id": 2, "team": "enemy", "pos": Vector2(0, 3), "alive": true}
	second.configure(other)
	await physics_frame
	await physics_frame
	var blocked: Vector2 = second.resolve_motion(Vector2(0, 3), Vector2(0, -3))
	expect(blocked.y >= 0.59, "NPC capsule cannot walk through another NPC")
	agent.pos = Vector2(5, 0)
	actor.sync_from_state(agent, false)
	expect(agent.pos.x < 1.5, "ordinary state sync does not teleport through wall")
	actor.sync_from_state({"pos": Vector2(8, 0), "alive": true}, true)
	expect(actor.global_position.x == 8, "explicit deployment sync teleports immediately")
	world.queue_free()
	await process_frame
