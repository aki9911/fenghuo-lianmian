extends SceneTree
const World = preload("res://scenes/wangfeng_town.tscn")
var checks: int = 0
var failures: int = 0
var world

func _initialize() -> void:
	call_deferred("run")

func expect(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func walk(direction: Vector2, frames: int) -> Vector2:
	var pos: Vector2 = Vector2.ZERO
	for i in range(frames):
		await physics_frame
		pos = world.move_player(direction, 1.0 / 60.0)
	return pos

func run() -> void:
	world = World.instantiate()
	root.add_child(world)
	world.setup()
	await physics_frame
	await physics_frame
	expect(world.player is CharacterBody3D, "commander uses a physical body")
	expect(world.camera.projection == Camera3D.PROJECTION_PERSPECTIVE, "default is third person perspective")
	expect(world.player_facing().is_equal_approx(Vector2.UP), "default view faces north")
	expect(world.ambient_people.size() == 15, "15 editable civilian representatives")
	for resident in world.ambient_people:
		expect(resident is CharacterBody3D and resident.get_node("CollisionShape3D").shape is CapsuleShape3D, "residents have shared controller and capsule")
		resident.collision_layer = 0
		resident.collision_mask = 0
	var hq: Dictionary = {}
	for building in world.get_building_definitions():
		if building.id == "headquarters": hq = building
	expect(not hq.is_empty() and hq.pos.distance_to(Vector2(-6,20.8)) < 0.02, "HQ entrance is north of the rotated building")
	world.warp_player(Vector2(-15,12))
	var pos: Vector2 = await walk(Vector2.UP, 60)
	expect(pos.y > 9.25, "player cannot walk through engineer building")
	# A moved building carries its colliders and interaction marker.
	var building: Node3D = world.get_node("Buildings/engineer")
	building.position.x -= 5
	await physics_frame
	world.warp_player(Vector2(-15,12))
	pos = await walk(Vector2.UP, 35)
	expect(pos.y < 9, "moving a building frees its former location")
	building.position.x += 5
	world.warp_player(Vector2(-20,-4))
	pos = await walk(Vector2.DOWN, 70)
	var touched_wall: bool = false
	for index in range(world.player.get_slide_collision_count()):
		var hit = world.player.get_slide_collision(index)
		if str(hit.get_collider().get_path()).contains("Palisade"):
			touched_wall = true
	print("PALISADE_CONTACT pos=%s contacted=%s" % [str(pos), str(touched_wall)])
	# The wall is made of cylinders; side contact permits a different z distance
	# from centre contact. Check the correct side and real collision, not -0.7.
	expect(pos.y < 0 and touched_wall, "palisade blocks crossing outside gate")
	world._set_gate(false)
	world.warp_player(Vector2(0,3))
	pos = await walk(Vector2.UP, 65)
	expect(pos.y < -2, "open central gate allows raid travel")
	world._set_gate(true)
	world.warp_player(Vector2(0,3))
	pos = await walk(Vector2.UP, 65)
	expect(pos.y > 0.60, "closed gate blocks player")
	world.warp_player(Vector2(0,-3))
	for i in range(5): await physics_frame
	expect(world.camera_rig.spring.get_hit_length() < 4, "spring arm retracts before closed gate")
	world._set_gate(false)
	world.warp_player(Vector2(0,3))
	pos = await walk(Vector2.UP, 65)
	expect(pos.y < -2, "broken gate corridor becomes passable")
	world.warp_player(Vector2(0,-26))
	pos = await walk(Vector2.UP, 70)
	expect(pos.y > -28 and world.player.position.y > -0.2, "world boundary prevents falling off terrain")
	world.warp_player(Vector2(0,12))
	world.look_camera(Vector2(-523.5988,0))
	pos = await walk(Vector2.UP, 15)
	expect(pos.x < -1 and absf(pos.y-12) < 0.1, "W follows camera yaw")
	world.look_camera(Vector2(523.5988,0))
	expect(world.can_deploy_squad(Vector2(0,7)), "clear road supports full squad footprint")
	expect(not world.can_deploy_squad(Vector2(-15,7)), "deployment rejects building overlap")
	expect(not world.can_deploy_squad(Vector2(-20,0)), "deployment rejects wall overlap")
	expect(not world.can_deploy_squad(Vector2(0,-16)), "deployment rejects raid anchor that model would clamp")
	world.phase = 1
	expect(not world.can_deploy_squad(Vector2(0,-10)), "wall phase forbids deploying across enemy side")
	expect(not world.can_deploy_squad(Vector2(23,7)), "deployment rejects anchor outside model bounds")
	world.phase = -1
	world.set_tactical(true)
	expect(world.camera == world.get_node("Camera") and world.camera.current, "tactical map selects saved camera")
	world.set_tactical(false)
	expect(world.camera == world.camera_rig.view, "third person view resumes")
	world.warp_player(Vector2(0,12))
	var npc: Dictionary = {"id": 900, "team": "enemy", "pos": Vector2(0,8), "alive": true}
	world.resolve_npc_motion(npc, npc.pos)
	await physics_frame
	pos = await walk(Vector2.UP, 65)
	expect(pos.y > 8.5, "player cannot pass through NPC capsule")
	world._remove_unit("enemy_900")
	await process_frame
	# Renderer creates one editable physical instance per actual entity, with no cap reduction.
	var model: Dictionary = {"phase": 1, "mode": "deploy", "player_pos": Vector2(0,6), "player_hp":100,
		"formations":[Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO], "gate_hp":100,
		"supply_destroyed":false,"ballista_count":0,"points":[0,0,0],"agents":[],"evac_groups":[]}
	for i in range(150):
		model.agents.append({"id":i,"team":"enemy" if i < 100 else "ally",
			"pos":Vector2((i%20-10)*1.1,-22+int(i/20)*1.1),"alive":true})
	world.sync_battle(model,0)
	expect(world.troop_nodes.size() == 150, "100 enemies and 50 allies receive independent actors")
	world.sync_battle(model,0)
	expect(world.get_node("Troops").get_child_count() == 150, "repeated sync does not duplicate instances")
	model.agents[0].alive = false
	world.sync_battle(model,0)
	await process_frame
	expect(world.troop_nodes.size() == 149, "dead entity releases actor")
	for key in world.troop_nodes.keys(): world._remove_unit(key)
	await process_frame
	world._set_gate(false)
	# Collision-backed evacuation follows the model's current waypoint path.
	var route: Array = preload("res://scripts/core/battle_model.gd").EVAC_ROUTE
	var civilian: Dictionary = {"id":-1000,"team":"civilian","pos":Vector2(0,5),"alive":true}
	for target in route:
		for i in range(1200):
			civilian.pos = world.resolve_npc_motion(civilian, civilian.pos.move_toward(target,0.025))
			if civilian.pos.distance_to(target) < 0.1: break
		expect(civilian.pos.distance_to(target) < 0.1, "civilian physical route reaches " + str(target))
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/runtime_config.json"))
	var town = preload("res://scripts/core/town_state.gd").new()
	town.setup(config)
	var battle = preload("res://scripts/core/battle_model.gd").new()
	battle.setup(town, config)
	battle.begin_battle()
	for phase_index in range(4):
		world.phase = phase_index
		world._set_gate(phase_index == 1)
		await physics_frame
		for slot in range(5):
			var legal: bool = world.can_deploy_squad(battle.formations[slot])
			if not legal: print("INVALID_DEFAULT_FORMATION phase=%d slot=%d pos=%s" % [phase_index,slot,str(battle.formations[slot])])
			expect(legal, "default squad deployment has a legal physical footprint")
		battle.start_combat()
		battle.advance_phase()
	print("ACTOR_PHYSICS checks=%d failures=%d" % [checks,failures])
	world.queue_free()
	await process_frame
	quit(1 if failures else 0)
