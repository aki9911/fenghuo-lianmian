extends SceneTree

const Model = preload("res://scripts/core/battle_model.gd")
const Town = preload("res://scripts/core/town_state.gd")
var failures: int = 0
var checks: int = 0
var settings: Dictionary = {}

func _initialize() -> void:
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://data/runtime_config.json"))
	_pause_and_actions()
	_morale_and_phases()
	_population_and_refresh()
	_deployment_and_equipment()
	_capture_and_paths()
	_evacuation()
	_ratings()
	_settlement()
	print("BATTLE_TESTS checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func fixture():
	var town = Town.new()
	town.setup(settings)
	var battle = Model.new()
	battle.setup(town, settings)
	battle.begin_battle()
	return battle

func to_phase(battle, target: int) -> void:
	while battle.phase < target:
		battle.start_combat()
		battle.advance_phase()

func _pause_and_actions() -> void:
	var battle = fixture()
	var initial: Array = battle.agents.duplicate(true)
	var stock: Dictionary = battle.town.resources.duplicate(true)
	battle.player_pos = Model.SUPPLY_POSITION
	battle.tick(100)
	battle.attack(Model.SUPPLY_POSITION)
	expect(not battle.strike_supply(), "deploy disallows supply interaction")
	expect(battle.agents == initial and battle.elapsed == 0, "deployment freezes positions/hp/spawn/time")
	expect(battle.town.resources == stock, "deployment and battle model do not produce resources")
	battle.start_combat()
	var rations: int = int(battle.town.resources.rations)
	battle.start_combat()
	expect(int(battle.town.resources.rations) == rations, "phase starts consume rations once")
	battle.player_pos = Vector2(0, 8)
	expect(not battle.strike_supply(), "supply interaction requires proximity")
	battle.tick(0.2)
	expect(battle.elapsed > 0 and battle.agents != initial, "real combat advances individual positions")
	expect(battle.town.resources.material == stock.material, "combat does not run town production")

func _morale_and_phases() -> void:
	var battle = fixture()
	battle.start_combat()
	battle.morale = 60
	battle.player_pos = Model.SUPPLY_POSITION
	for index in range(3):
		battle.strike_supply()
		battle.tick(1.1)
	expect(battle.supply_destroyed and is_equal_approx(battle.morale, 30), "supply subtracts fixed30 from60")
	expect(not battle.strike_supply() and battle.morale == 30, "supply is once per battle")
	var enemies: Array = []
	for agent in battle.agents:
		if agent.team == "enemy" and agent.alive:
			enemies.append(agent.id)
	battle.advance_phase()
	expect(battle.phase == 1 and battle.mode == "deploy" and is_equal_approx(battle.morale, 39), "breakthrough restores30% of residual")
	battle.advance_phase()
	expect(battle.phase == 1 and is_equal_approx(battle.morale, 39), "repeat phase transition cannot heal morale twice")
	var migrated: Array = []
	for agent in battle.agents:
		if agent.team == "enemy" and agent.alive:
			migrated.append(agent.id)
	expect(migrated == enemies, "phase transfer preserves enemy identities without extra wave")
	battle.start_combat()
	battle.gate_hp = 0
	battle.morale = 0
	battle.tick(0.1)
	expect(battle.report.town_held and battle.phase == 1, "morale victory precedes simultaneous breach")
	var dead_player = fixture()
	dead_player.start_combat()
	dead_player.player_hp = 0
	dead_player.morale = 0
	dead_player.tick(0.1)
	expect(not dead_player.report.town_held and dead_player.report.result == "大败", "player death precedes morale victory")
	var small = fixture()
	small.start_combat()
	small.morale = 25
	small.player_pos = Model.SUPPLY_POSITION
	small.supply_hp = 1
	small.strike_supply()
	expect(small.morale == 0 and small.report.town_held, "supply saturates at zero")

func _population_and_refresh() -> void:
	var battle = fixture()
	battle._spawn_enemies(1000)
	expect(battle.enemy_count() == 30 and battle.ally_count() == 30, "raid caps30/30")
	battle.start_combat()
	var victim: Dictionary = {}
	for agent in battle.agents:
		if agent.team == "enemy":
			victim = agent
			break
	var old_id: int = int(victim.id)
	battle._damage(victim, 10000)
	var morale: float = battle.morale
	battle._damage(victim, 10000)
	expect(battle.kills == 1, "duplicate damage does not double count kill")
	battle._spawn_enemies(1000)
	expect(battle.enemy_count() == 30 and battle.morale == morale, "refill only vacant slots without restoring morale")
	var ids: Dictionary = {}
	for agent in battle.agents:
		if agent.alive:
			expect(not ids.has(agent.id), "unique entity ID")
			ids[agent.id] = true
	expect(not ids.has(old_id), "replacement enemy has a new ID")
	battle.advance_phase()
	battle._spawn_enemies(1000)
	expect(battle.enemy_count() == 100 and battle.ally_count() == 50, "normal caps100/50")
	battle.start_combat()
	battle.player_pos = Vector2(24, 25)
	for index in range(120):
		battle.tick(0.1)
		expect(battle.enemy_count() <= 100 and battle.ally_count() <= 50, "authoritative cap holds during ongoing combat")

func _deployment_and_equipment() -> void:
	var battle = fixture()
	battle.town.hire("reserve", 5)
	battle.start_combat()
	var victim: Dictionary = {}
	for agent in battle.agents:
		if agent.team == "ally" and int(agent.soldier_id) % 4 == 0:
			victim = agent
			break
	battle._damage(victim, 10000)
	expect(battle.town.soldier_count() == 49, "combat death updates town roster")
	battle.advance_phase()
	var before: int = battle.town.resident_count()
	var reinforced: int = battle.town.reinforce()
	battle.town.equip_soldiers()
	battle.start_combat()
	expect(reinforced == 1 and battle.town.resident_count() == before - 1, "replacement consumes resident identity")
	expect(battle.ally_count() == 50, "start combat adds newly reinforced soldier")
	var equipped: int = 0
	for agent in battle.agents:
		if agent.alive and agent.team == "ally" and agent.equipped:
			equipped += 1
	expect(equipped == battle.town.equipped_count(), "start combat refreshes equipment from real roster")
	expect(battle._baseline.size() == 150 and battle.town.people.size() == 150, "reinforcement preserves baseline and unique population")
	var wall = fixture()
	to_phase(wall, 1)
	var kits: int = int(wall.town.resources.siege_engine)
	expect(wall.deploy_ballista() and wall.deploy_ballista() and not wall.deploy_ballista(), "ballista two-slot limit")
	expect(int(wall.town.resources.siege_engine) == kits - 2, "ballista consumes actual kits")
	wall.start_combat()
	wall.player_pos = Vector2(24, 20)
	expect(not wall.use_ballista(), "remote ballista firing prohibited")
	wall.player_pos = Model.BALLISTA_POSITIONS[0]
	expect(wall.use_ballista(), "nearby ballista fires at spawned enemies")
	var poor = fixture()
	poor.town.resources.rations = 0
	poor.start_combat()
	expect(not poor.rationed and poor.town.resources.rations == 0, "unfed army never creates negative food")

func _capture_and_paths() -> void:
	var battle = fixture()
	to_phase(battle, 2)
	battle.start_combat()
	battle.player_pos = Vector2(24, 24)
	for agent in battle.agents:
		agent.pos = Vector2(-22, 22)
	var enemy: Dictionary = {}
	var ally: Dictionary = {}
	for agent in battle.agents:
		if agent.team == "enemy":
			enemy = agent
		else:
			ally = agent
	enemy.pos = Model.POINT_POSITIONS[0]
	ally.pos = Model.POINT_POSITIONS[0]
	battle.points[0] = 40.0
	battle._update_points(1)
	expect(battle.points[0] == 40, "contested point freezes capture")
	ally.pos = Vector2(24, 24)
	battle._update_points(1)
	expect(battle.points[0] > 40, "uncontested enemy captures")
	battle.points = [99.9, 100.0, 100.0]
	battle.point_owners = [false, true, true]
	battle._update_points(1)
	expect(battle.phase == 3 and battle.mode == "deploy", "simultaneous three-point ownership triggers evacuation")
	var walker: Dictionary = {"pos": Vector2(20, -2)}
	battle._move(walker, Vector2(20, 10), 1)
	expect(walker.pos.y < 0, "offscreen unit cannot pass intact side wall")

func _evacuation() -> void:
	var battle = fixture()
	to_phase(battle, 3)
	expect(battle.evac_groups.size() <= 10, "resident representative groups <=10")
	var snapshot: Array = battle.evac_groups.duplicate(true)
	battle.tick(90)
	expect(battle.evac_groups == snapshot and battle.escaped == 0, "deployment freezes evacuation")
	battle.start_combat()
	battle.debug_set_morale(0)
	expect(battle.mode == "combat" and battle.pursuit_stopped and battle.report.is_empty(), "evac morale0 stops pursuit without victory")
	var enemies: int = battle.enemy_count()
	var hp: float = battle.player_hp
	battle.tick(10)
	expect(battle.enemy_count() == enemies and battle.player_hp == hp, "zero morale stops spawning and enemy damage")
	expect(battle.escaped == 0, "no teleport escape before gate reached")
	battle.tick(160)
	expect(battle.escaped == 150, "all residents then each soldier pass gate individually after pursuit stops")
	expect(not battle._escort_wiped, "successful empty evacuation queue is not annihilation")
	battle.player_pos = Model.EVAC_GATE
	battle.escape_player()
	expect(battle.report.result == "小败" and not battle.report.town_held, "complete evacuation still loses town")
	var wiped = fixture()
	to_phase(wiped, 3)
	wiped.start_combat()
	for group in wiped.evac_groups:
		while not group.members.is_empty():
			wiped._hurt_group(group)
	wiped.tick(0.1)
	expect(wiped.report.result == "大败" and wiped.report.dead == 100, "escort annihilation ends battle with confirmed deaths")

func _ratings() -> void:
	for count in [119, 120]:
		var battle = fixture()
		to_phase(battle, 3)
		battle.start_combat()
		for id in range(1, count + 1):
			battle._register_escape(id)
			battle._register_escape(id)
		battle.player_pos = Model.EVAC_GATE
		battle.escape_player()
		expect(battle.report.escaped == count, "escape IDs deduplicate")
		expect(battle.report.result == ("小败" if count == 120 else "失败"), "120/150 exact80percent boundary")
		expect(battle.report.dead + battle.report.alive + battle.report.missing == 150, "final population ledger conserves150")
		expect(battle.report.missing == 150 - count and battle.report.dead == 0, "unrescued are missing, not invented deaths")
	var death = fixture()
	to_phase(death, 3)
	death.start_combat()
	for id in range(1, 130):
		death._register_escape(id)
	death.player_hp = 0
	death.tick(0.1)
	expect(death.report.result == "失败", "player death disqualifies minor defeat despite80percent rescued")
	var soldiers_only = fixture()
	to_phase(soldiers_only, 3)
	soldiers_only.start_combat()
	for id in range(101, 151):
		soldiers_only._register_escape(id)
	soldiers_only.player_pos = Model.EVAC_GATE
	soldiers_only.escape_player()
	expect(soldiers_only.report.result == "大败", "military-only rescue is no civilian rescue")

func _settlement() -> void:
	var battle = fixture()
	battle.start_combat()
	var enemy: Dictionary = {}
	for agent in battle.agents:
		if agent.team == "enemy":
			enemy = agent
			break
	battle._damage(enemy, 10000)
	battle.debug_set_morale(0)
	var money: int = battle.town.money
	var salvage: int = battle.town.salvage
	var result: Dictionary = battle.report.duplicate(true)
	battle.tick(200)
	battle.escape_player()
	battle._finish(true, false)
	expect(battle.town.money == money and battle.town.salvage == salvage and battle.report == result, "settlement and rewards idempotent")
	expect(salvage == 1 and battle.report.remaining_enemies == 0, "only actual kills create salvage, routing enemies are not kills")
	expect(battle.report.baseline == battle.report.dead + battle.report.alive + battle.report.missing, "victory population ledger balances")
