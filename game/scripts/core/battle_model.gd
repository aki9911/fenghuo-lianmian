extends RefCounted
class_name BattleModel
## Authoritative deterministic simulation; no camera or rendering dependency.

const POINT_POSITIONS = [Vector2(-12, 7), Vector2(0, 11), Vector2(12, 7)]
const SUPPLY_POSITION = Vector2(15, -17)
const EVAC_GATE = Vector2(21, 22)
const EVAC_ROUTE = [Vector2(5, 10), Vector2(12, 14), Vector2(12, 21), EVAC_GATE]
const BALLISTA_POSITIONS = [Vector2(-8, 2), Vector2(8, 2)]
const STEP: float = 0.1
const NPC_CONTROLLER = preload("res://scripts/actors/npc_controller.gd")

var town
var config: Dictionary = {}
var phase: int = 0
var mode: String = "result"
var morale: float = 100.0
var player_pos: Vector2 = Vector2(0, 8)
var player_facing: Vector2 = Vector2.UP
var movement_resolver: Callable = Callable()
var player_hp: float = 300.0
var player_max_hp: float = 300.0
var agents: Array = []
var gate_hp: float = 2400.0
var points: Array = [0.0, 0.0, 0.0]
var supply_destroyed: bool = false
var supply_hp: float = 120.0
var kills: int = 0
var elapsed: float = 0.0
var report: Dictionary = {}
var escaped: int = 0
var evac_groups: Array = []
var formations: Array = []
var squad_orders: Array = []
var ballista_count: int = 0
var front_capture: float = 0.0
var point_owners: Array = [false, false, false]
var events: Array = []
var battle_id: String = ""
var pursuit_stopped: bool = false
var rationed: bool = false
var _next_id: int = 1
var _battle_number: int = 0
var _accumulator: float = 0.0
var _spawn_timer: float = 0.0
var _attack_timer: float = 0.0
var _supply_timer: float = 0.0
var _ballista_timer: float = 0.0
var _gate_credit: float = 0.0
var _event_ids: Dictionary = {}
var _baseline: Dictionary = {}
var _escaped_ids: Dictionary = {}
var _soldier_hp: Dictionary = {}
var _breakthroughs: Dictionary = {}
var _had_escort: bool = false
var _escort_wiped: bool = false

func setup(town_ref, settings: Dictionary) -> void:
	town = town_ref
	config = settings.duplicate(true)

func _g(key: String, fallback: float) -> float:
	return float(config.get("globals", {}).get(key, fallback))

func _c(key: String, fallback: float) -> float:
	return float(config.get("combat", {}).get(key, fallback))

func begin_battle() -> void:
	if mode != "result":
		return
	_battle_number += 1
	battle_id = "local_%d_%d" % [Time.get_unix_time_from_system(), _battle_number]
	phase = 0
	mode = "deploy"
	morale = _g("morale_initial", 100)
	player_max_hp = _c("player_max_hp", 250)
	player_hp = player_max_hp
	player_pos = Vector2(0, 8)
	player_facing = Vector2.UP
	gate_hp = _c("gate_base_hp", 2400) * maxf(0.2, float(town.facilities.get("outer", 100)) / 100.0)
	supply_hp = _c("supply_hp", 120)
	supply_destroyed = false
	kills = 0
	elapsed = 0.0
	escaped = 0
	ballista_count = 0
	front_capture = 0.0
	points = [0.0, 0.0, 0.0]
	point_owners = [false, false, false]
	_obliterate_transients()
	for person in town.people:
		person["escaped"] = false
		if person.health in ["healthy", "wounded"]:
			_baseline[int(person.id)] = str(person.origin)
	_default_formations()
	_sync_allies()
	_spawn_enemies(int(_c("raid_initial_enemies", 24)))
	_emit("begin", {"baseline": _baseline.size()})

func _obliterate_transients() -> void:
	agents.clear()
	evac_groups.clear()
	events.clear()
	report.clear()
	_event_ids.clear()
	_baseline.clear()
	_escaped_ids.clear()
	_soldier_hp.clear()
	_breakthroughs.clear()
	_accumulator = 0.0
	_spawn_timer = 0.0
	_attack_timer = 0.0
	_supply_timer = 0.0
	_ballista_timer = 0.0
	_gate_credit = 0.0
	_had_escort = false
	_escort_wiped = false
	pursuit_stopped = false

func _default_formations() -> void:
	match phase:
		0: formations = [Vector2(-10, -5), Vector2(-5, -5), Vector2(0, -5), Vector2(5, -5), Vector2(10, -5)]
		1: formations = [Vector2(-10, 3), Vector2(-5, 3), Vector2(0, 3), Vector2(5, 3), Vector2(10, 3)]
		2: formations = [Vector2(-10, 6), Vector2(-5, 5), Vector2(0, 11), Vector2(5, 9), Vector2(12, 7)]
		3: formations = [Vector2(-10, 3), Vector2(-5, 3), Vector2(0, 3), Vector2(5, 3), Vector2(10, 3)]
	squad_orders.clear()
	for anchor in formations:
		squad_orders.append({"mode": "hold", "target": anchor})

func place_squad(slot: int, pos: Vector2) -> bool:
	if mode != "deploy" or slot < 0 or slot >= formations.size() or not pos.is_finite():
		return false
	pos.x = clampf(pos.x, -22, 22)
	pos.y = clampf(pos.y, -15 if phase == 0 else 1.8, 23)
	formations[slot] = pos
	squad_orders[slot] = {"mode": "hold", "target": pos}
	for agent in agents:
		if agent.alive and agent.team == "ally" and int(agent.formation) == slot:
			# Deployment is an explicit teleport; combat motion uses the resolver.
			agent["pos"] = pos + agent.get("formation_offset", Vector2.ZERO)
	return true

func issue_order(slot: int, order: String, target: Vector2 = Vector2.ZERO) -> bool:
	if mode != "combat" or slot < 0 or slot >= squad_orders.size() or not order in ["follow", "hold", "advance"] or not target.is_finite():
		return false
	if order == "hold" and target == Vector2.ZERO:
		var total: Vector2 = Vector2.ZERO
		var count: int = 0
		for agent in agents:
			if agent.alive and agent.team == "ally" and int(agent.formation) == slot:
				total += agent.pos - agent.get("formation_offset", Vector2.ZERO)
				count += 1
		target = total / count if count > 0 else formations[slot]
	elif order == "advance" and target == Vector2.ZERO:
		target = player_pos + player_facing.normalized() * 10.0
	if order != "follow":
		target.x = clampf(target.x, -23, 23)
		target.y = clampf(target.y, -24 if phase == 0 else 1.8, 24)
		formations[slot] = target
	squad_orders[slot] = {"mode": order, "target": target}
	return true

func squad_anchor(slot: int) -> Vector2:
	var order: Dictionary = squad_orders[slot]
	if order.mode != "follow":
		return order.target
	var facing: Vector2 = player_facing.normalized()
	if facing == Vector2.ZERO:
		facing = Vector2.UP
	var side: float = float(slot % 3 - 1) * 4.0 if slot < 3 else float(slot - 3) * 4.0 - 2.0
	var behind: float = 4.0 if slot < 3 else 8.0
	return player_pos + Vector2(-facing.y, facing.x) * side - facing * behind

func start_combat() -> void:
	if mode != "deploy":
		return
	_sync_allies()
	var ration_cost: int = int(_c("ration_phase_cost", 10))
	rationed = int(town.resources.get("rations", 0)) >= ration_cost
	if rationed:
		town.resources["rations"] -= ration_cost
	_emit("rations_%d" % phase, {"consumed": ration_cost if rationed else 0})
	for slot in range(formations.size()):
		place_squad(slot, formations[slot])
	mode = "combat"
	_emit("phase_start_%d" % phase, {"phase": phase})
	_evaluate()

func _formation_position(slot: int, row: int) -> Vector2:
	var anchor: Vector2 = formations[slot]
	anchor.x = clampf(anchor.x, -23, 23)
	if phase > 0:
		anchor.y = clampf(anchor.y, 1.8, 24)
	else:
		anchor.y = clampf(anchor.y, -15, 20)
	return anchor + _slot_offset(row)

func _slot_offset(row: int) -> Vector2:
	return Vector2((row % 3 - 1) * 1.15, (row / 3) * 1.05)

func _available_formation() -> Vector2i:
	var occupied: Array = [{}, {}, {}, {}, {}]
	for agent in agents:
		if agent.team == "ally" and agent.alive:
			occupied[int(agent.formation)][int(agent.get("formation_row", 0))] = true
	var slot: int = 0
	for index in range(1, 5):
		if occupied[index].size() < occupied[slot].size():
			slot = index
	var row: int = 0
	while occupied[slot].has(row):
		row += 1
	return Vector2i(slot, row)

func _sync_allies() -> void:
	var present: Dictionary = {}
	for agent in agents:
		if agent.team == "ally" and agent.alive:
			present[int(agent.soldier_id)] = true
	var cap: int = int(_g("raid_ally_cap", 30) if phase == 0 else _g("battle_ally_cap", 50))
	for person in town.people:
		if person.role != "soldier" or person.health != "healthy" or person.get("escaped", false):
			continue
		if present.has(int(person.id)) or present.size() >= cap:
			continue
		var hp: float = float(_soldier_hp.get(int(person.id), _c("ally_hp", 100)))
		var assignment: Vector2i = _available_formation()
		var index: int = present.size()
		var equipped: bool = bool(person.get("equipped", false))
		agents.append({"id": _allocate_id(), "team": "ally", "pos": _formation_position(assignment.x, assignment.y), "hp": hp, "max_hp": _c("ally_hp", 100), "kind": "archer" if index % 3 == 0 else "guard", "soldier_id": int(person.id), "alive": true, "cooldown": float(index % 7) * 0.2, "formation": assignment.x, "formation_row": assignment.y, "formation_offset": _slot_offset(assignment.y), "equipped": equipped})
		present[int(person.id)] = true
	# Equipment allocation may change during deployment, without restoring health.
	for agent in agents:
		if agent.team == "ally":
			var person = _person(int(agent.soldier_id))
			if not person.is_empty():
				agent["equipped"] = bool(person.get("equipped", false))

func advance_phase() -> void:
	if mode != "combat" or phase >= 3:
		return
	if _evaluate():
		return
	if not _breakthroughs.has(phase):
		_breakthroughs[phase] = true
		morale = minf(_g("morale_cap", 100), morale * (1.0 + _g("breakthrough_recover", 0.3)))
		_emit("breakthrough_%d" % phase, {"morale": morale})
	if phase == 1:
		town.facilities["outer"] = 0.0
	if phase == 2:
		town.facilities["street"] = 0.0
	phase += 1
	mode = "deploy"
	_accumulator = 0.0
	_spawn_timer = 0.0
	_default_formations()
	player_pos = Vector2(0, 6) if phase < 3 else Vector2(8, 12)
	var enemy_index: int = 0
	for agent in agents:
		if not agent.alive:
			continue
		if agent.team == "enemy":
			agent["pos"] = Vector2((enemy_index % 9 - 4) * 1.4, -22 - float(enemy_index / 9) * 0.4)
			enemy_index += 1
		else:
			_soldier_hp[int(agent.soldier_id)] = float(agent.hp)
	_sync_allies()
	for slot in range(formations.size()):
		place_squad(slot, formations[slot])
	if phase == 3:
		_prepare_evacuation()
	_emit("phase_deploy_%d" % phase, {"phase": phase})

func retreat() -> void:
	if mode == "combat" and phase == 0:
		advance_phase()

func tick(delta: float) -> void:
	if mode != "combat" or delta <= 0.0 or not is_finite(delta):
		return
	_accumulator += delta
	# Fixed steps preserve all elapsed simulation time, independent of frame rate.
	while _accumulator + 0.000001 >= STEP and mode == "combat":
		_accumulator -= STEP
		_simulate(STEP)
	if mode != "combat":
		_accumulator = 0.0

func _simulate(delta: float) -> void:
	if _evaluate():
		return
	elapsed += delta
	_attack_timer = maxf(0, _attack_timer - delta)
	_supply_timer = maxf(0, _supply_timer - delta)
	_ballista_timer = maxf(0, _ballista_timer - delta)
	if morale > 0:
		_spawn_timer += delta
		var interval: float = maxf(0.1, _g("raid_spawn_interval", 8) if phase == 0 else _g("battle_spawn_interval", 6))
		while _spawn_timer >= interval:
			_spawn_timer -= interval
			_spawn_enemies(int(_g("raid_spawn_batch", 5) if phase == 0 else _g("battle_spawn_batch", 8)))
		_update_agents(delta)
	else:
		# Routing enemies cease combat, but escorts still reach the evacuation gate.
		for agent in agents:
			if agent.alive and agent.team == "ally":
				NPC_CONTROLLER.simulate(self, agent, delta)
	# Evaluate morale before a breach, so zero morale wins simultaneous gate damage.
	if _evaluate():
		return
	if phase == 0:
		_update_front(delta)
	elif phase == 1 and gate_hp <= 0:
		advance_phase()
	elif phase == 2:
		_update_points(delta)
	elif phase == 3:
		_update_evacuation(delta)
	agents = agents.filter(func(agent): return bool(agent.alive))

func _update_agents(delta: float) -> void:
	for agent in agents:
		if not agent.alive:
			continue
		agent["cooldown"] = maxf(0, float(agent.cooldown) - delta)
		NPC_CONTROLLER.simulate(self, agent, delta)
	_separate_agents(delta)

func _separate_agents(delta: float) -> void:
	# Local spatial buckets avoid quadratic crowd separation; entities remain real.
	var buckets: Dictionary = {}
	for agent in agents:
		if not agent.alive:
			continue
		var cell: Vector2i = Vector2i(floori(agent.pos.x), floori(agent.pos.y))
		if not buckets.has(cell):
			buckets[cell] = []
		buckets[cell].append(agent)
	for agent in agents:
		if not agent.alive:
			continue
		var cell: Vector2i = Vector2i(floori(agent.pos.x), floori(agent.pos.y))
		var separation: Vector2 = Vector2.ZERO
		for x in range(-1, 2):
			for y in range(-1, 2):
				for other in buckets.get(cell + Vector2i(x, y), []):
					if other.id == agent.id:
						continue
					var offset: Vector2 = agent.pos - other.pos
					var distance: float = offset.length()
					if distance >= 0.85:
						continue
					if distance < 0.001:
						offset = Vector2.RIGHT.rotated(float(int(agent.id) % 29) * 0.217)
					separation += offset.normalized() * (0.85 - distance)
		if separation != Vector2.ZERO:
			var destination: Vector2 = agent.pos + separation.limit_length(1.0) * delta * 3.0
			destination.x = clampf(destination.x, -24, 24)
			destination.y = clampf(destination.y, -27, 27)
			_move(agent, destination, delta * 3.0)

func _nearest_enemy_of(agent: Dictionary, radius: float) -> Dictionary:
	var best: Dictionary = {}
	var distance: float = radius * radius
	for target in agents:
		if not target.alive or target.team == agent.team:
			continue
		var squared: float = agent.pos.distance_squared_to(target.pos)
		if squared < distance:
			best = target
			distance = squared
	return best

func _can_strike(from: Vector2, to: Vector2, reach: float) -> bool:
	if phase != 1 or reach > 5:
		return true
	return not (from.y * to.y < 0 and (absf(from.x) > 2.5 or absf(to.x) > 2.5))

func _move(agent: Dictionary, destination: Vector2, distance: float) -> void:
	var pos: Vector2 = agent.pos
	# Crossing the main wall uses the central gate corridor; no offscreen shortcuts.
	if phase > 0 and pos.y < 0 and destination.y > 0:
		if absf(pos.x) > 1.5:
			destination = Vector2(0, -3)
		elif phase == 1:
			destination = Vector2(0, -1.3)
		else:
			destination = Vector2(0, 2.0)
	elif phase > 0 and pos.y > 0 and destination.y < 0:
		if phase == 1:
			destination = Vector2(clampf(pos.x, -20, 20), 1.8)
		elif absf(pos.x) > 1.5:
			destination = Vector2(0, 3)
		else:
			destination = Vector2(0, -2)
	var desired: Vector2 = pos.move_toward(destination, distance)
	agent["pos"] = _resolve_position(agent, desired)

func _resolve_position(agent: Dictionary, desired: Vector2) -> Vector2:
	if movement_resolver.is_valid():
		var resolved = movement_resolver.call(agent, desired)
		if resolved is Vector2 and resolved.is_finite():
			return resolved
	return desired

func _spawn_enemies(requested: int) -> void:
	if morale <= 0 or mode == "result":
		return
	var cap: int = int(_g("raid_enemy_cap", 30) if phase == 0 else _g("battle_enemy_cap", 100))
	var available: int = maxi(0, cap - enemy_count())
	# One authoritative synchronous allocator owns all spawn points; no pending slots.
	for index in range(mini(requested, available)):
		var id: int = _allocate_id()
		var spawn: Vector2 = Vector2((id % 13 - 6) * 1.7, -24 - float(id % 3) * 0.6)
		agents.append({"id": id, "team": "enemy", "pos": spawn, "hp": _c("enemy_hp", 90), "max_hp": _c("enemy_hp", 90), "kind": "archer" if id % 5 == 0 else "raider", "soldier_id": -1, "alive": true, "cooldown": float(id % 8) * 0.2})

func _allocate_id() -> int:
	var id: int = _next_id
	_next_id += 1
	return id

func enemy_count() -> int:
	var count: int = 0
	for agent in agents:
		if agent.team == "enemy" and agent.alive:
			count += 1
	return count

func ally_count() -> int:
	var count: int = 0
	for agent in agents:
		if agent.team == "ally" and agent.alive:
			count += 1
	return count

func _damage(agent: Dictionary, amount: float) -> void:
	if not agent.alive or amount <= 0:
		return
	agent["hp"] = maxf(0, float(agent.hp) - amount)
	if agent.team == "ally":
		_soldier_hp[int(agent.soldier_id)] = float(agent.hp)
	if float(agent.hp) > 0:
		return
	agent["alive"] = false
	if agent.team == "enemy":
		kills += 1
		morale = maxf(0, morale - _g("kill_morale_loss", 0.45))
		_emit("kill_%d" % int(agent.id), {"target_id": agent.id})
	else:
		var wounded: bool = int(agent.soldier_id) % 4 != 0
		town.mark_casualty(int(agent.soldier_id), wounded)
		_emit("casualty_%d" % int(agent.soldier_id), {"wounded": wounded})
		if wounded and phase == 3:
			_add_wounded_to_evac(int(agent.soldier_id), agent.pos)

func attack(target: Vector2) -> void:
	if mode != "combat" or player_hp <= 0 or _attack_timer > 0 or pursuit_stopped:
		return
	_attack_timer = _c("player_attack_cooldown", 0.65)
	var reach: float = _c("player_attack_range", 3.6)
	var direction: Vector2 = (target - player_pos).normalized()
	for agent in agents:
		if agent.team != "enemy" or not agent.alive or player_pos.distance_to(agent.pos) > reach:
			continue
		var offset: Vector2 = (agent.pos - player_pos).normalized()
		if direction == Vector2.ZERO or direction.dot(offset) >= -0.15:
			if _can_strike(player_pos, agent.pos, reach):
				_damage(agent, _c("player_damage", 42))
	if phase == 0 and target.distance_to(SUPPLY_POSITION) < 4.0 and player_pos.distance_to(SUPPLY_POSITION) <= 4.0:
		strike_supply()
	_evaluate()

func strike_supply() -> bool:
	if mode != "combat" or phase != 0 or supply_destroyed or _supply_timer > 0 or player_pos.distance_to(SUPPLY_POSITION) > _c("interaction_range", 4):
		return false
	_supply_timer = _c("supply_attack_interval", 1.0)
	supply_hp = maxf(0, supply_hp - _c("supply_strike_damage", 40))
	if supply_hp <= 0:
		supply_destroyed = true
		morale = maxf(0, morale - _g("supply_morale_loss", 30))
		_emit("supply_destroyed", {"morale_loss": _g("supply_morale_loss", 30)})
		_evaluate()
	return true

func deploy_ballista() -> bool:
	if mode != "deploy" or phase != 1 or ballista_count >= int(_c("ballista_limit", 2)):
		return false
	if int(town.resources.get("siege_engine", 0)) <= 0:
		return false
	town.resources["siege_engine"] -= 1
	ballista_count += 1
	return true

func use_ballista() -> bool:
	if mode != "combat" or phase != 1 or ballista_count <= 0 or _ballista_timer > 0:
		return false
	var location: Vector2 = Vector2.INF
	for index in range(mini(ballista_count, BALLISTA_POSITIONS.size())):
		if player_pos.distance_to(BALLISTA_POSITIONS[index]) <= _c("interaction_range", 4):
			location = BALLISTA_POSITIONS[index]
			break
	if location == Vector2.INF:
		return false
	var target: Dictionary = {}
	var distance: float = _c("ballista_range", 26)
	for agent in agents:
		if agent.team == "enemy" and agent.alive and location.distance_to(agent.pos) < distance:
			target = agent
			distance = location.distance_to(agent.pos)
	if target.is_empty():
		return false
	_ballista_timer = _c("ballista_cooldown", 3.2)
	var impact: Vector2 = target.pos
	for agent in agents:
		if agent.team == "enemy" and agent.alive and agent.pos.distance_to(impact) <= _c("ballista_radius", 3.0):
			_damage(agent, _c("ballista_damage", 95))
	_evaluate()
	return true

func _update_front(delta: float) -> void:
	var occupants: Vector2i = _occupants(Vector2(0, 4), 3.5)
	if occupants.x > 0 and occupants.y == 0:
		front_capture = minf(100, front_capture + _c("front_capture_rate", 3) * delta)
	elif occupants.y > 0 and occupants.x == 0:
		front_capture = maxf(0, front_capture - _c("front_capture_rate", 3) * delta)
	if front_capture >= 100:
		advance_phase()

func _occupants(position: Vector2, radius: float) -> Vector2i:
	var result: Vector2i = Vector2i.ZERO
	for agent in agents:
		if agent.alive and agent.pos.distance_squared_to(position) <= radius * radius:
			if agent.team == "enemy":
				result.x += 1
			else:
				result.y += 1
	if player_hp > 0 and player_pos.distance_to(position) <= radius:
		result.y += 1
	return result

func _update_points(delta: float) -> void:
	for index in range(3):
		var occupants: Vector2i = _occupants(POINT_POSITIONS[index], _c("capture_radius", 3))
		var condition: float = clampf(float(town.facilities.get("street", 100)) / 100.0, 0, 1)
		var rate: float = _c("capture_rate", 4) * delta * (1.0 - condition * _c("street_defense_factor", 0.5))
		if occupants.x > 0 and occupants.y == 0:
			points[index] = minf(100, float(points[index]) + rate)
		elif occupants.y > 0 and occupants.x == 0:
			points[index] = maxf(0, float(points[index]) - rate)
		if float(points[index]) >= 100:
			point_owners[index] = true
		elif float(points[index]) <= 0:
			point_owners[index] = false
	if point_owners[0] and point_owners[1] and point_owners[2]:
		advance_phase()

func _prepare_evacuation() -> void:
	var active: Dictionary = {}
	for agent in agents:
		if agent.team == "ally" and agent.alive:
			active[int(agent.soldier_id)] = true
	var ids: Array = []
	for person in town.people:
		if _baseline.has(int(person.id)) and person.health in ["healthy", "wounded"] and not active.has(int(person.id)):
			ids.append(int(person.id))
	var group_limit: int = maxi(1, int(_g("evac_visual_groups", 10)))
	var size: int = maxi(1, int(ceil(float(ids.size()) / group_limit)))
	for index in range(0, ids.size(), size):
		var members: Array = ids.slice(index, mini(index + size, ids.size()))
		var group_index: int = evac_groups.size()
		evac_groups.append({"id": group_index, "pos": Vector2((group_index % 3 - 1) * 0.7, 11 - float(group_index / 3) * 1.2), "count": members.size(), "members": members, "route": 0})
	_had_escort = not ids.is_empty()

func _add_wounded_to_evac(person_id: int, position: Vector2) -> void:
	var group: Dictionary = _nearest_group(position)
	if group.is_empty():
		if evac_groups.size() < int(_g("evac_visual_groups", 10)):
			group = {"id": evac_groups.size(), "pos": position, "count": 0, "members": [], "route": 0}
			evac_groups.append(group)
		elif not evac_groups.is_empty():
			group = evac_groups.back()
			group["pos"] = position
			group["route"] = 0
	if not group.is_empty() and not group.members.has(person_id):
		group.members.append(person_id)
		group["count"] = group.members.size()
		_had_escort = true

func _nearest_group(position: Vector2) -> Dictionary:
	var result: Dictionary = {}
	var distance: float = INF
	for group in evac_groups:
		if int(group.count) <= 0:
			continue
		var d: float = position.distance_squared_to(group.pos)
		if d < distance:
			distance = d
			result = group
	return result

func _escort_center() -> Vector2:
	var group: Dictionary = _nearest_group(Vector2(0, 5))
	return EVAC_GATE if group.is_empty() else group.pos

func _hurt_group(group: Dictionary) -> void:
	if group.members.is_empty() or morale <= 0:
		return
	var person_id: int = int(group.members.pop_front())
	town.mark_casualty(person_id, false)
	group["count"] = group.members.size()
	_emit("casualty_%d" % person_id, {"wounded": false})
	if _all_groups_finished() and _had_escort:
		_escort_wiped = true

func _update_evacuation(delta: float) -> void:
	if _escort_wiped:
		_finish(false, false)
		return
	var route: Array = EVAC_ROUTE
	var waiting: Array = []
	for group in evac_groups:
		if int(group.count) <= 0:
			continue
		var waypoint: Vector2 = route[mini(int(group.route), route.size() - 1)]
		var proxy: Dictionary = {"id": -1000 - int(group.id), "team": "civilian", "pos": group.pos, "alive": true}
		group["pos"] = _resolve_position(proxy, group.pos.move_toward(waypoint, _c("evac_speed", 0.75) * delta))
		if group.pos.distance_to(waypoint) < 0.45:
			if int(group.route) < route.size() - 1:
				group["route"] += 1
			else:
				waiting.append(group)
	if not waiting.is_empty():
		var condition: float = clampf(float(town.facilities.get("evac", 100)) / 100.0, 0, 1)
		var rate: float = lerpf(_g("evac_rate_damaged", 0.7), _g("evac_rate_intact", 1.8), condition)
		_gate_credit += rate * delta
		for group in waiting:
			while _gate_credit >= 1 and not group.members.is_empty():
				_gate_credit -= 1
				_register_escape(int(group.members.pop_front()))
				group["count"] = group.members.size()
	else:
		_gate_credit = 0.0

func _all_groups_finished() -> bool:
	for group in evac_groups:
		if int(group.count) > 0:
			return false
	return true

func _register_escape(person_id: int) -> void:
	if _escaped_ids.has(person_id) or not _baseline.has(person_id):
		return
	var person: Dictionary = _person(person_id)
	if person.is_empty() or not person.health in ["healthy", "wounded"]:
		return
	_escaped_ids[person_id] = true
	person["escaped"] = true
	escaped = _escaped_ids.size()
	_emit("escape_%d" % person_id, {"person_id": person_id})

func escape_player() -> void:
	# UI asks confirmation before calling this with residents left behind.
	if mode != "combat" or phase != 3 or player_hp <= 0 or player_pos.distance_to(EVAC_GATE) > _c("interaction_range", 4):
		return
	_finish(false, true)

func debug_set_morale(value: float) -> void:
	morale = clampf(value, 0, _g("morale_cap", 100))
	if mode == "combat":
		_evaluate()

func _evaluate() -> bool:
	if mode != "combat":
		return mode == "result"
	if player_hp <= 0:
		_finish(false, false)
		return true
	if morale <= 0:
		morale = 0.0
		if phase < 3:
			_finish(true, false)
			return true
		pursuit_stopped = true
		_spawn_timer = 0.0
		_emit("pursuit_stopped", {})
	return false

func _finish(held: bool, player_escaped: bool) -> void:
	if mode == "result":
		return
	mode = "result"
	for agent in agents:
		if agent.team == "ally" and agent.alive and float(agent.hp) < float(agent.max_hp) * 0.5:
			var person: Dictionary = _person(int(agent.soldier_id))
			if person.health == "healthy":
				town.mark_casualty(int(agent.soldier_id), true)
	var dead: int = 0
	var wounded: int = 0
	var missing: int = 0
	var alive: int = 0
	var civilian_escaped: int = 0
	var resident_dead: int = 0
	var soldier_dead: int = 0
	for person in town.people:
		var id: int = int(person.id)
		if not _baseline.has(id):
			continue
		if not held and person.health in ["healthy", "wounded"] and not _escaped_ids.has(id):
			person["health"] = "missing"
			person["equipped"] = false
		if person.health == "dead":
			dead += 1
			if _baseline[id] == "resident":
				resident_dead += 1
			else:
				soldier_dead += 1
		elif person.health == "missing":
			missing += 1
		else:
			alive += 1
			if person.health == "wounded":
				wounded += 1
		if _escaped_ids.has(id) and _baseline[id] == "resident":
			civilian_escaped += 1
	var result: String = "防守成功" if held else "大败"
	if not held:
		var ratio: float = float(escaped) / maxf(1, float(_baseline.size()))
		if player_escaped and player_hp > 0 and not _escort_wiped and ratio + 0.0000001 >= _g("minor_defeat_ratio", 0.8):
			result = "小败"
		elif civilian_escaped > 0:
			result = "失败"
	var remaining: int = enemy_count() if morale > 0 else 0
	var merit: int = kills * int(_c("merit_per_kill", 1)) + (int(_c("merit_supply", 20)) if supply_destroyed else 0)
	merit += int(_c("merit_victory", 50)) if held else escaped * int(_c("merit_per_escape", 1))
	report = {"battle_id": battle_id, "result": result, "town_held": held, "kills": kills, "escaped": escaped, "baseline": _baseline.size(), "civilian_escaped": civilian_escaped, "dead": dead, "wounded": wounded, "missing": missing, "alive": alive, "resident_dead": resident_dead, "soldier_dead": soldier_dead, "remaining_enemies": remaining, "merit": merit, "elapsed": elapsed, "morale": morale, "player_escaped": player_escaped, "supply_destroyed": supply_destroyed, "events": events.duplicate(true), "config_version": config.get("config_version", "prototype")}
	if held:
		town.salvage += kills
		town.money += int(_g("battle_money_grant", 100))
		town.facilities["outer"] = clampf(gate_hp / _c("gate_base_hp", 2400) * 100, 0, 100)
		# Consumed siege kits represent fixed installations, reclaimed only if held.
		town.resources["siege_engine"] = int(town.resources.get("siege_engine", 0)) + ballista_count
	else:
		town.facilities["outer"] = 0.0
		town.facilities["street"] = 0.0
		town.facilities["evac"] = maxf(0, float(town.facilities.get("evac", 100)) - 25)
	town.messages.append("战报：%s，击败 %d，撤出 %d/%d。" % [result, kills, escaped, _baseline.size()])
	_emit("settled", {"result": result})
	report["events"] = events.duplicate(true)

func _person(person_id: int) -> Dictionary:
	for person in town.people:
		if int(person.id) == person_id:
			return person
	return {}

func _emit(event_id: String, data: Dictionary) -> void:
	if _event_ids.has(event_id):
		return
	_event_ids[event_id] = true
	var entry: Dictionary = data.duplicate(true)
	entry["event_id"] = battle_id + ":" + event_id
	entry["phase"] = phase
	entry["time"] = elapsed
	events.append(entry)
