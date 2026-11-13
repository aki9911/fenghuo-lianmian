extends Node3D
## Scene geometry is saved; only authoritative entity instances are added at runtime.
@export var ally_template: PackedScene = preload("res://scenes/actors/ally_soldier.tscn")
@export var enemy_template: PackedScene = preload("res://scenes/actors/enemy_soldier.tscn")
@export var civilian_template: PackedScene = preload("res://scenes/actors/civilian.tscn")
var camera: Camera3D
var player: CharacterBody3D
var tactical_camera: Camera3D
var camera_rig: Node3D
var tactical: bool = false
var ambient_people: Array = []
var ambient_states: Array = []
var ambient_homes: Array = []
var buildings: Array = []
var labels: Array = []
var objective_nodes: Array = []
var troop_nodes: Dictionary = {}
var gate: Node3D
var gate_body: StaticBody3D
var supplies: Node3D
var ballista_nodes: Array = []
var time: float = 0.0
var phase: int = -1
var material_cache: Dictionary = {}
var formation_markers: Array = []
var attack_effect: MeshInstance3D
var effect_time: float = 0.0
var operating: bool = true
const TEAL = Color("6bbab4")
const RED = Color("b45140")
const GOLD = Color("dfb96d")

func setup() -> void:
	tactical_camera = get_node("Camera")
	player = get_node("Commander")
	camera_rig = get_node("ThirdPersonRig")
	camera_rig.follow(player)
	gate = get_node("MainGate")
	gate_body = get_node("MainGate/CollisionBody")
	supplies = get_node("EnemySupplies")
	attack_effect = get_node("AttackEffect")
	buildings = get_node("Buildings").get_children()
	ambient_people = get_node("AmbientResidents").get_children()
	objective_nodes = get_node("StreetPoints").get_children()
	ballista_nodes = get_node("Ballistas").get_children()
	formation_markers = get_node("DeploymentMarkers").get_children()
	labels = find_children("*", "Label3D", true, false)
	ambient_states.clear()
	ambient_homes.clear()
	for i in range(ambient_people.size()):
		var body: CharacterBody3D = ambient_people[i]
		var pos: Vector2 = Vector2(body.global_position.x, body.global_position.z)
		var state: Dictionary = {"id": -10000-i, "team": "civilian", "pos": pos, "alive": true}
		body.configure(state)
		ambient_states.append(state)
		ambient_homes.append(pos)
	set_tactical(false)
	_set_gate(false)

func get_building_definitions() -> Array:
	var result: Array = []
	for node in buildings:
		var center: Vector3 = to_local(node.global_position)
		var entrance: Node3D = node.get_node_or_null("Entrance")
		var pos: Vector3 = to_local(entrance.global_position) if entrance != null else center
		result.append({"id": str(node.name), "name": str(node.get_meta("display_name", node.name)), "pos": Vector2(pos.x,pos.z), "center": Vector2(center.x,center.z)})
	return result

func set_tactical(enabled: bool) -> void:
	tactical = enabled
	camera = tactical_camera if enabled else camera_rig.view
	camera.make_current()

func move_player(input: Vector2, delta: float) -> Vector2:
	var yaw: float = camera_rig.yaw
	if tactical: yaw = atan2(tactical_camera.global_basis.z.x, tactical_camera.global_basis.z.z)
	var pos: Vector2 = player.move_input(input, delta, yaw)
	camera_rig.update_pose()
	return pos

func look_camera(relative: Vector2) -> void:
	if not tactical: camera_rig.look(relative)

func player_facing() -> Vector2:
	if tactical: return Vector2(-sin(player.get_node("Visual").rotation.y), -cos(player.get_node("Visual").rotation.y))
	return camera_rig.facing()

func warp_player(pos: Vector2) -> void:
	player.warp(pos)
	camera_rig.update_pose()

func _set_gate(closed: bool) -> void:
	gate.visible = closed
	gate_body.collision_layer = 1 if closed else 0
	gate_body.collision_mask = 2 if closed else 0

func mat(color: Color) -> StandardMaterial3D:
	var key: String = color.to_html()
	if material_cache.has(key): return material_cache[key]
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.92
	material_cache[key] = material
	return material

func show_attack(pos: Vector2) -> void:
	attack_effect.position = Vector3(pos.x, 0.2, pos.y)
	attack_effect.visible = true
	effect_time = 0.16

func _unit_key(agent: Dictionary) -> String:
	return "%s_%s" % [agent.get("team", "enemy"), str(agent.id)]

func _ensure_unit(agent: Dictionary) -> CharacterBody3D:
	var key: String = _unit_key(agent)
	if troop_nodes.has(key): return troop_nodes[key]
	var team: String = agent.get("team", "enemy")
	var template: PackedScene = ally_template if team == "ally" else (civilian_template if team == "civilian" else enemy_template)
	var body: CharacterBody3D = template.instantiate()
	body.name = key
	get_node("Troops").add_child(body)
	body.configure(agent)
	troop_nodes[key] = body
	return body

func resolve_npc_motion(agent: Dictionary, target: Vector2) -> Vector2:
	var body: CharacterBody3D = _ensure_unit(agent)
	return body.resolve_motion(agent.pos, target)

func can_deploy_squad(pos: Vector2) -> bool:
	if not pos.is_finite(): return false
	# Validate the exact anchor the model accepts, before testing its footprint.
	# Otherwise an invalid click can pass here and be clamped into a building.
	var minimum_z: float = 1.8 if phase > 0 else -15.0
	if absf(pos.x) > 22 or pos.y < minimum_z or pos.y > 23: return false
	var shape = CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.8
	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1 # Buildings/walls only; an existing squad may be repositioned.
	for row in range(10):
		var spot: Vector2 = pos + Vector2((row % 3 - 1) * 1.15, (row / 3) * 1.05)
		if absf(spot.x) > 23 or spot.y < -24 or spot.y > 25: return false
		query.transform = Transform3D(Basis.IDENTITY, Vector3(spot.x, 0.94, spot.y))
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return false
	return true

func _remove_unit(key: String) -> void:
	var body: CharacterBody3D = troop_nodes[key]
	body.collision_layer = 0
	body.collision_mask = 0
	body.visible = false
	body.queue_free()
	troop_nodes.erase(key)

func sync_battle(model, delta: float) -> void:
	time += delta
	var transition: bool = operating or phase != model.phase
	operating = false
	phase = model.phase
	if transition: warp_player(model.player_pos)
	effect_time = maxf(0, effect_time - delta)
	attack_effect.visible = effect_time > 0
	for i in range(formation_markers.size()):
		formation_markers[i].visible = model.mode == "deploy"
		var p: Vector2 = model.formations[i]
		formation_markers[i].position = Vector3(p.x,0,p.y)
	_set_gate(model.phase == 1 and model.gate_hp > 0)
	supplies.visible = not model.supply_destroyed
	for i in range(ballista_nodes.size()): ballista_nodes[i].visible = i < model.ballista_count
	for i in range(objective_nodes.size()):
		objective_nodes[i].visible = model.phase == 2
		if model.phase == 2: objective_nodes[i].material_override = mat(TEAL.lerp(RED,float(model.points[i])/100.0))
	for node in ambient_people:
		node.visible = false
		node.collision_layer = 0
		node.collision_mask = 0
	var active: Dictionary = {}
	for agent in model.agents:
		if not agent.get("alive",true): continue
		var body: CharacterBody3D = _ensure_unit(agent)
		body.sync_from_state(agent, transition or model.mode == "deploy")
		active[_unit_key(agent)] = true
	if model.phase == 3:
		for group in model.evac_groups:
			if int(group.count) <= 0: continue
			var state: Dictionary = {"id": -1000-int(group.id), "team": "civilian", "pos": group.pos, "alive": true}
			var body: CharacterBody3D = _ensure_unit(state)
			body.sync_from_state(state, transition or model.mode == "deploy")
			active[_unit_key(state)] = true
	for key in troop_nodes.keys():
		if not active.has(key): _remove_unit(key)
	player.visible = model.player_hp > 0

func sync_town(_player_pos: Vector2, delta: float) -> void:
	time += delta
	if not operating:
		warp_player(_player_pos)
		for key in troop_nodes.keys(): _remove_unit(key)
	operating = true
	phase = -1
	_set_gate(false)
	supplies.visible = true
	for node in ballista_nodes: node.visible = false
	attack_effect.visible = false
	for marker in formation_markers: marker.visible = false
	for node in objective_nodes: node.visible = false
	player.visible = true
	for i in range(ambient_people.size()):
		var person: CharacterBody3D = ambient_people[i]
		person.visible = true
		person.collision_layer = 2
		person.collision_mask = 3
		var home: Vector2 = ambient_homes[i]
		var a: float = time * (0.12 + float(i%3)*0.02) + float(i)*2.2
		var target: Vector2 = home + Vector2(sin(a), cos(a*0.7)) * 1.8
		var current: Vector2 = Vector2(person.global_position.x, person.global_position.z)
		ambient_states[i].pos = person.resolve_motion(current, current.move_toward(target, delta * 0.7))

func ground_position(screen_pos: Vector2) -> Vector2:
	var from: Vector3 = camera.project_ray_origin(screen_pos)
	var direction: Vector3 = camera.project_ray_normal(screen_pos)
	var hit = Plane(Vector3.UP,0).intersects_ray(from,direction)
	if hit is Vector3: return Vector2(hit.x,hit.z)
	return Vector2.ZERO
