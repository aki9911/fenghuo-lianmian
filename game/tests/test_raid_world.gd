extends SceneTree
## Render/collision integration. The reinforcement clock is accelerated explicitly.
var game
var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	call_deferred("run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("RAID_WORLD FAIL: " + message)

func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	await physics_frame
	game.config.combat.enemy_damage = 0
	game.config.combat.ally_damage = 0
	game._qa_visit_hq()
	game._begin_battle()
	game._start_combat()
	game.battle.issue_all_order("hold")
	game.battle._tick_raid_reinforcements(420)
	game.world.sync_battle(game.battle, 0)
	game._set_interface("map")
	await process_frame
	var held: Dictionary = {}
	var guards: Dictionary = {}
	for agent in game.battle.agents:
		if agent.team == "ally": held[agent.id] = agent.pos
		elif agent.alive: guards[agent.id] = agent.pos
	var gate_hp: float = game.battle.gate_hp
	var valid_area: bool = true
	var frozen_allies: bool = true
	for frame in range(300):
		game._physics_process(1.0 / 60)
		game._process(1.0 / 60)
		for agent in game.battle.agents:
			if not agent.alive: continue
			if agent.team == "enemy":
				valid_area = valid_area and agent.pos.distance_to(game.battle.SUPPLY_POSITION) <= game.config.combat.raid_guard_radius + 0.01
			elif held.has(agent.id):
				frozen_allies = frozen_allies and agent.pos.distance_to(held[agent.id]) < 0.0001
		await physics_frame
	var patrolled: int = 0
	var visible_enemies: int = 0
	for agent in game.battle.agents:
		if agent.team != "enemy" or not agent.alive: continue
		if guards.has(agent.id) and agent.pos.distance_to(guards[agent.id]) > 0.3: patrolled += 1
		var body = game.world.troop_nodes.get("enemy_%s" % str(agent.id))
		if body != null and body.visible and body.collision_layer != 0: visible_enemies += 1
	expect(game.battle.enemy_count() == 100 and visible_enemies == 100, "100 real guarded/colliding enemy models at cap")
	expect(game.battle.ally_count() == 30, "raid still limits actual friendly models to30")
	expect(valid_area, "physical movement remains in granary defense area")
	expect(frozen_allies, "full held army stays fixed while guard AI and collisions run")
	expect(patrolled > 0, "guards physically patrol instead of freezing with army")
	expect(game.battle.gate_hp == gate_hp and game.battle.front_capture == 0 and game.battle.phase == 0, "guards do not attack town or advance the phase")
	expect(game.battle.raid_pending_reinforcements == 5, "full-cap overflow remains pending without duplicate admission")
	if DisplayServer.get_name() != "headless": await game._qa_capture("v06_02_granary_guards")
	print("RAID_WORLD checks=%d failures=%d guards=%d patrolled=%d pending=%d fixture=420s-clock-advance,zero-damage" % [checks,failures,visible_enemies,patrolled,game.battle.raid_pending_reinforcements])
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)
