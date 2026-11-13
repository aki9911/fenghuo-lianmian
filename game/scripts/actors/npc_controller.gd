extends CharacterBody3D
class_name NpcController
## One shared controller for editable NPC scenes and the authoritative simulation.
## The director invokes simulate(); instances never advance combat on their own.

@export var template_id: String = "npc"
@export_enum("沿用实体兵种", "近战", "远程") var combat_style: int = 0
@export_range(0.1, 3.0, 0.05) var speed_multiplier: float = 1.0
@export_range(0.1, 3.0, 0.05) var damage_multiplier: float = 1.0

var state: Dictionary = {}

func _ready() -> void:
	collision_layer = 2
	collision_mask = 3
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	set_physics_process(false)

func configure(agent: Dictionary) -> void:
	state = agent
	state["npc_tuning"] = {"combat_style": combat_style, "speed_multiplier": speed_multiplier, "damage_multiplier": damage_multiplier, "template_id": template_id}
	sync_from_state(agent, true)

func sync_from_state(agent: Dictionary, teleport: bool = false) -> void:
	state = agent
	var target: Vector2 = agent.get("pos", Vector2.ZERO)
	var current: Vector2 = Vector2(global_position.x, global_position.z) if is_inside_tree() else Vector2(position.x, position.z)
	if teleport or not is_inside_tree():
		if is_inside_tree():
			global_position = Vector3(target.x, global_position.y, target.y)
		else:
			position = Vector3(target.x, position.y, target.y)
	elif not current.is_equal_approx(target):
		state["pos"] = resolve_motion(current, target)
	var alive: bool = bool(agent.get("alive", true))
	collision_layer = 2 if alive else 0
	collision_mask = 3 if alive else 0
	visible = alive
	var motion: Vector2 = target - current
	var visual: Node3D = get_node_or_null("Visual")
	if visual != null and motion.length_squared() > 0.0001:
		visual.rotation.y = atan2(-motion.x, -motion.y)

func resolve_motion(from: Vector2, to: Vector2) -> Vector2:
	if state.get("position_locked", false):
		return Vector2(global_position.x, global_position.z) if is_inside_tree() else from
	if not is_inside_tree():
		position.x = to.x
		position.z = to.y
		return to
	# Only deployment/phase transitions teleport. Normal motion starts from the
	# collision body's actual position, never from a potentially stale visual pose.
	var origin: Vector2 = Vector2(global_position.x, global_position.z)
	var requested: Vector2 = to - from
	var remainder: Vector3 = Vector3(requested.x, 0, requested.y)
	for index in range(3):
		if remainder.length_squared() < 0.0000001:
			break
		var contact: KinematicCollision3D = move_and_collide(remainder)
		if contact == null:
			break
		remainder = contact.get_remainder().slide(contact.get_normal())
		remainder.y = 0.0
	var result: Vector2 = Vector2(global_position.x, global_position.z)
	var visual: Node3D = get_node_or_null("Visual")
	var movement: Vector2 = result - origin
	if visual != null and movement.length_squared() > 0.0001:
		visual.rotation.y = atan2(-movement.x, -movement.y)
	return result

static func simulate(model, agent: Dictionary, delta: float) -> void:
	if model.mode != "combat" or not agent.get("alive", false):
		return
	if agent.team == "ally":
		_ally_step(model, agent, delta)
	elif agent.team == "enemy":
		_enemy_step(model, agent, delta)

static func _ranged(agent: Dictionary) -> bool:
	var style: int = int(agent.get("npc_tuning", {}).get("combat_style", 0))
	return style == 2 or (style == 0 and agent.get("kind", "") == "archer")

static func _speed(model, agent: Dictionary) -> float:
	var base: float = model._c("ally_speed", 2.1) if agent.team == "ally" else model._c("enemy_speed", 1.65)
	return base * float(agent.get("npc_tuning", {}).get("speed_multiplier", 1.0))

static func _damage_multiplier(agent: Dictionary) -> float:
	return float(agent.get("npc_tuning", {}).get("damage_multiplier", 1.0))

static func _ally_step(model, agent: Dictionary, delta: float) -> void:
	var speed: float = _speed(model, agent)
	agent.erase("pursuit_anchor")
	agent.erase("pursuit_radius")
	var reach: float = model._c("ranged_range", 10) if _ranged(agent) or model.phase == 1 else model._c("melee_range", 1.8)
	if model.army_holding:
		var close: Dictionary = {} if model.pursuit_stopped else model._nearest_enemy_of(agent, reach)
		if not close.is_empty(): _ally_attack(model, agent, close, reach)
		return
	if model.phase == 3 and model._all_groups_finished():
		# The last covering troops use the same open street as residents rather
		# than a straight line through the workshop and occupied houses.
		if not agent.has("evac_route"):
			agent["evac_route"] = -1
			agent["evac_assembly"] = Vector2(agent.pos.x, maxf(6.5, agent.pos.y))
		var waypoint: Vector2 = agent.evac_assembly if int(agent.evac_route) < 0 else model.EVAC_ROUTE[mini(int(agent.evac_route), model.EVAC_ROUTE.size() - 1)]
		model._move(agent, waypoint, speed * delta)
		# Intermediate road corners are areas, not a single occupied capsule
		# position. The final gate retains its tight physical crossing threshold.
		var arrival_radius: float = 0.55 if int(agent.evac_route) == model.EVAC_ROUTE.size() - 1 else 1.6
		if agent.pos.distance_to(waypoint) < arrival_radius:
			agent["evac_route"] += 1
		if int(agent.evac_route) >= model.EVAC_ROUTE.size() and agent.pos.distance_to(model.EVAC_GATE) < 0.65:
			model._register_escape(int(agent.soldier_id))
			agent["alive"] = false
		return
	var slot: int = int(agent.get("formation", 0))
	var order: Dictionary = model.squad_orders[slot]
	var anchor: Vector2 = model.squad_anchor(slot)
	var offset: Vector2 = agent.get("formation_offset", Vector2.ZERO)
	if order.mode == "follow":
		var facing: Vector2 = model.player_facing.normalized()
		if facing == Vector2.ZERO:
			facing = Vector2.UP
		offset = Vector2(-facing.y, facing.x) * offset.x - facing * offset.y
	anchor += offset
	var leash: float = maxf(0.1, model._c("ally_pursuit_radius", 8))
	if order.mode in ["guard", "follow"]:
		agent["pursuit_anchor"] = anchor
		agent["pursuit_radius"] = leash
	# Follow first when separated from the commander. Nearby threats never pull
	# a squad indefinitely away from its current moving formation.
	if order.mode in ["follow", "guard"] and agent.pos.distance_to(anchor) > leash:
		model._move(agent, anchor, speed * delta)
		return
	var target: Dictionary = {} if model.pursuit_stopped else model._nearest_enemy_of(agent, maxf(reach, leash))
	if not target.is_empty():
		if agent.pos.distance_to(target.pos) <= reach:
			_ally_attack(model, agent, target, reach)
			return
		if order.mode != "hold" and model.phase != 1 and target.pos.distance_to(anchor) <= leash:
			model._move(agent, target.pos, speed * delta)
			return
	model._move(agent, anchor, speed * delta)

static func _ally_attack(model, agent: Dictionary, target: Dictionary, reach: float) -> void:
	if float(agent.cooldown) > 0 or not model._can_strike(agent.pos, target.pos, reach): return
	var equipment: float = 1.0 if agent.get("equipped", false) else model._c("unequipped_damage_factor", 0.45)
	var food: float = 1.0 if model.rationed else model._c("unfed_damage_factor", 0.8)
	model._damage(target, model._c("ally_damage", 9) * equipment * food * _damage_multiplier(agent))
	agent["cooldown"] = model._c("ally_attack_interval", 2.4)

static func _enemy_step(model, agent: Dictionary, delta: float) -> void:
	if model.morale <= 0:
		return
	if model.phase == 0:
		_raid_guard_step(model, agent, delta)
		return
	var speed: float = _speed(model, agent)
	var reach: float = model._c("enemy_ranged_range", 7.5) if _ranged(agent) else model._c("melee_range", 1.8)
	var target: Dictionary = model._nearest_enemy_of(agent, maxf(5.0, reach))
	var player_distance: float = agent.pos.distance_to(model.player_pos)
	if player_distance <= reach and (target.is_empty() or player_distance < agent.pos.distance_to(target.pos)) and model._can_strike(agent.pos, model.player_pos, reach):
		if float(agent.cooldown) <= 0:
			model.player_hp = maxf(0, model.player_hp - model._c("enemy_damage", 5.5) * _damage_multiplier(agent))
			agent["cooldown"] = model._c("enemy_attack_interval", 2.8)
		return
	if not target.is_empty() and agent.pos.distance_to(target.pos) <= reach and model._can_strike(agent.pos, target.pos, reach):
		if float(agent.cooldown) <= 0:
			model._damage(target, model._c("enemy_damage", 5.5) * _damage_multiplier(agent))
			agent["cooldown"] = model._c("enemy_attack_interval", 2.8)
		return
	if model.phase == 1:
		var siege_slot: Vector2 = Vector2((int(agent.id) % 7 - 3) * 0.8, -1.2 - float(int(agent.id) % 3) * 0.7)
		model._move(agent, siege_slot, speed * delta)
		if agent.pos.distance_to(Vector2.ZERO) < 3.0 and float(agent.cooldown) <= 0:
			model.gate_hp = maxf(0, model.gate_hp - model._c("gate_damage", 2.0))
			agent["cooldown"] = model._c("gate_attack_interval", 4.0)
		return
	if not target.is_empty():
		model._move(agent, target.pos, speed * delta)
		return
	if player_distance < 5.0:
		model._move(agent, model.player_pos, speed * delta)
		return
	var destination: Vector2 = Vector2(0, 4)
	if model.phase == 2:
		destination = model.POINT_POSITIONS[int(agent.id) % 3]
	elif model.phase == 3:
		var group: Dictionary = model._nearest_group(agent.pos)
		if group.is_empty():
			destination = model.player_pos
		else:
			destination = group.pos
			if agent.pos.distance_to(destination) < 1.8 and float(agent.cooldown) <= 0:
				model._hurt_group(group)
				agent["cooldown"] = model._c("civilian_attack_interval", 7)
				return
	model._move(agent, destination, speed * delta)

static func _raid_guard_step(model, agent: Dictionary, delta: float) -> void:
	var center: Vector2 = model.SUPPLY_POSITION
	var guard_radius: float = model._c("raid_guard_radius", 10)
	var detection: float = model._c("raid_detection_radius", 8)
	var target: Dictionary = {}
	var nearest: float = detection
	for other in model.agents:
		if not other.alive or other.team != "ally" or other.pos.distance_to(center) > guard_radius:
			continue
		var distance: float = agent.pos.distance_to(other.pos)
		if distance <= nearest:
			nearest = distance
			target = other
	var player_near: bool = model.player_hp > 0 and model.player_pos.distance_to(center) <= guard_radius and agent.pos.distance_to(model.player_pos) <= nearest
	var reach: float = model._c("enemy_ranged_range", 7.5) if _ranged(agent) else model._c("melee_range", 1.8)
	if player_near or not target.is_empty():
		var position: Vector2 = model.player_pos if player_near else target.pos
		if agent.pos.distance_to(position) <= reach:
			if float(agent.cooldown) <= 0:
				var damage: float = model._c("enemy_damage", 5.5) * _damage_multiplier(agent)
				if player_near: model.player_hp = maxf(0, model.player_hp - damage)
				else: model._damage(target, damage)
				agent["cooldown"] = model._c("enemy_attack_interval", 2.8)
		else:
			model._move(agent, position, _speed(model, agent) * delta)
		return
	var waypoint: int = int(agent.get("patrol_waypoint", 0))
	var destination: Vector2 = model.raid_patrol_position(int(agent.id), waypoint)
	if agent.pos.distance_to(destination) < 0.6:
		waypoint += 1
		agent["patrol_waypoint"] = waypoint
		destination = model.raid_patrol_position(int(agent.id), waypoint)
	model._move(agent, destination, _speed(model, agent) * delta)
