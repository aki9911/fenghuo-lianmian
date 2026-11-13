extends SceneTree
## Actual saved scene + collision bodies; no teleport or headless movement fallback.
const Model = preload("res://scripts/core/battle_model.gd")
const Town = preload("res://scripts/core/town_state.gd")
const WorldScene = preload("res://scenes/wangfeng_town.tscn")
var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/runtime_config.json"))
	var town = Town.new()
	town.setup(config)
	var model = Model.new()
	model.setup(town, config)
	model.begin_battle()
	while model.phase < 3:
		model.start_combat()
		model.advance_phase()
	var world = WorldScene.instantiate()
	root.add_child(world)
	world.setup()
	model.movement_resolver = Callable(world, "resolve_npc_motion")
	world.sync_battle(model, 0)
	await physics_frame
	await physics_frame
	expect(model.evac_groups.size() == 10 and model.ally_count() == 50, "real evacuation starts with10 resident groups and50 soldiers")
	expect(world.troop_nodes.size() == model.enemy_count() + 50 + 10, "every simulation entity has an independent scene body")
	model.start_combat()
	model.debug_set_morale(0)
	world.sync_battle(model, 0)
	# Camera is not allowed to decide which authoritative entities are simulated.
	world.set_tactical(true)
	world.camera.global_position = Vector3(500, 100, 500)
	world.camera.look_at(Vector3(500, 0, 501), Vector3.UP)
	world.camera.far = 80
	model.player_pos = Vector2(-20, 24)
	world.warp_player(model.player_pos)
	var initial_enemy_count: int = model.enemy_count()
	var initial_hp: float = model.player_hp
	var start: Array = model.evac_groups.duplicate(true)
	var last_escaped: int = 0
	var steps: int = 0
	for step in range(2400):
		# One fixed simulation step per physics frame permits the real broadphase
		# to refresh; simulation advances6x realtime without bypassing collisions.
		await physics_frame
		model.tick(0.1)
		world.sync_battle(model, 0.1)
		steps = step + 1
		if step == 99:
			expect(model.evac_groups != start, "offscreen resident queues continue authoritative movement")
		if (step + 1) % 300 == 0:
			print("EVAC_PROGRESS seconds=%.1f escaped=%d allies=%d" % [model.elapsed, model.escaped, model.ally_count()])
		if model.escaped < last_escaped:
			expect(false, "evacuation accounting must be monotonic")
		last_escaped = model.escaped
		if model.escaped == 150:
			break
	expect(model.escaped == 150, "all150 people reach evacuation gate within240 simulated seconds")
	expect(model.enemy_count() == initial_enemy_count and model.player_hp == initial_hp, "morale0 disables pursuit, spawning and damage offscreen")
	expect(not model._escort_wiped and model.mode == "combat", "normal queue completion does not count as annihilation or town victory")
	if model.escaped != 150:
		_dump_blockers(model, world)
	else:
		model.player_pos = Model.EVAC_GATE
		world.warp_player(model.player_pos)
		model.escape_player()
		expect(model.report.result == "小败" and model.report.escaped == 150, "real world evacuation settles150 rescued as minor defeat")
		expect(model.report.dead + model.report.alive + model.report.missing == 150, "real collision world preserves population ledger")
	print("WORLD_EVAC_TESTS checks=%d failures=%d steps=%d sim_seconds=%.1f rescued=%d" % [checks, failures, steps, model.elapsed, model.escaped])
	world.queue_free()
	await process_frame
	quit(1 if failures > 0 else 0)

func _dump_blockers(model, world) -> void:
	for group in model.evac_groups:
		if group.count <= 0:
			continue
		print("STUCK_GROUP id=%d remaining=%d route=%d pos=%s" % [group.id, group.count, group.route, str(group.pos)])
	var shown: int = 0
	for agent in model.agents:
		if agent.team != "ally" or not agent.alive:
			continue
		if shown < 15:
			print("STUCK_ALLY id=%d squad=%d pos=%s target=%s" % [agent.id, agent.formation, str(agent.pos), str(model.squad_anchor(agent.formation))])
		shown += 1
	print("UNEVACUATED_ALLIES=%d ACTUAL_COLLIDERS=%d CAMERA=%s" % [shown, world.troop_nodes.size(), str(world.camera.global_position)])
