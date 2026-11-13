extends SceneTree
## Context UI, controls and model/view contracts exercised on the actual game scene.
var checks: int = 0
var failures: int = 0
var game

func _initialize() -> void:
	call_deferred("run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INTEGRATION FAIL: " + message)

func find_button(node: Node, title: String):
	if node is Button and node.text == title: return node
	for child in node.get_children():
		var result = find_button(child, title)
		if result != null: return result
	return null

func press(title: String) -> void:
	var b = find_button(game.sidebar_panel, title)
	expect(b != null, "context button: " + title)
	if b != null: b.pressed.emit()

func key(code: int) -> void:
	var event = InputEventKey.new()
	event.keycode = code
	event.pressed = true
	game._unhandled_key_input(event)

func at_building(id: String) -> void:
	for building in game.world.get_building_definitions():
		if building.id == id:
			game.world.warp_player(building.pos)
			if game.operating: game.town_pos = building.pos
			else: game.battle.player_pos = building.pos
	game._set_interface("field")
	key(KEY_E)

func frames(n: int) -> void:
	for i in range(n):
		game._physics_process(1.0 / 60.0)
		game._process(1.0 / 60.0)

func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	await physics_frame
	expect(game.operating and game.town.resident_count() == 100 and game.town.soldier_count() == 50, "real 100+50 start")
	expect(game.interface_mode == "field" and not game.sidebar_panel.visible, "no global management at startup")
	expect(game.world.camera.projection == Camera3D.PROJECTION_PERSPECTIVE and not game.world.tactical, "third person default")
	var money: int = game.town.money
	game._hire()
	game._begin_battle()
	expect(game.town.money == money and game.operating, "remote hire and incoming battle blocked")
	key(KEY_M)
	expect(game.interface_mode == "map" and game.world.tactical, "M opens tactical overview")
	expect(find_button(game.sidebar, "雇佣 5 人") == null, "overview cannot hire remotely")
	game._visit_building("engineer")
	expect(game.interface_mode == "map", "remote building selection only locates building")
	key(KEY_M)
	at_building("engineer")
	expect(game.interface_mode == "building" and not game.world.tactical, "E opens local department")
	press("雇佣 5 人")
	press("雇佣 5 人")
	expect(game.town.count_role("engineer") == 10, "local hire affects real population")
	var stock: Dictionary = game.town.resources.duplicate(true)
	var prior_job: String = game.town.jobs.supply
	game._assign_job("supply", "craft_equipment")
	expect(game.town.jobs.supply == prior_job and game.town.resources == stock, "cannot use other department from this panel")
	var integrity: float = game.town.facilities.outer
	frames(900)
	expect(game.town.facilities.outer > integrity, "real time production while panel open")
	game.world.warp_player(Vector2(0,12))
	game.town_pos = Vector2(0,12)
	frames(1)
	expect(game.interface_mode == "field", "walking away closes department panel")
	money = game.town.money
	game._dismiss()
	expect(game.town.count_role("engineer") == 10 and game.town.money == money, "stale local actions blocked")
	at_building("supply")
	press("支援邻镇：10 木石")
	frames(1260)
	expect(game.town.transfers.size() == 1 and game.town.transfers[0].delivered, "support delivery remains realtime")
	at_building("headquarters")
	press("迎战来敌  →  暂停布阵")
	expect(not game.operating and game.interface_mode == "command" and game.battle.mode == "deploy", "HQ opens deployment")
	stock = game.town.resources.duplicate(true)
	var agents: Array = game.battle.agents.duplicate(true)
	frames(120)
	expect(game.town.resources == stock and game.battle.agents == agents and game.battle.elapsed == 0, "deployment freezes NPC and economy")
	press("分发装备")
	expect(game.town.equipped_count() == 50, "HQ equipment from inventory")
	var click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	var point = Vector2(6,-8)
	click.position = game.world.camera.unproject_position(Vector3(point.x,0,point.y)) * game.viewport_container.size / Vector2(game.viewport.size)
	game._map_input(click)
	expect(game.battle.formations[0].distance_to(point) < 0.1, "map click sets formation")
	var moved: int = 0
	for agent in game.battle.agents:
		if agent.team == "ally" and agent.formation == 0:
			moved += 1
			expect(agent.pos.distance_to(point) < 3, "deployment immediately moves squad entity")
			var body = game.world.troop_nodes["ally_%s" % str(agent.id)]
			expect(Vector2(body.position.x,body.position.z).distance_to(agent.pos) < 0.01, "deployment immediately moves visible body")
	expect(moved > 0, "squad contains real soldiers")
	press("确认布阵 · 开始交战")
	expect(game.battle.mode == "combat" and game.interface_mode == "field" and not game.world.tactical, "combat returns third person")
	key(KEY_H)
	key(KEY_3)
	expect(game.interface_mode == "wheel" and game.wheel.selected == 2, "H wheel and keyboard team selection")
	var elapsed: float = game.battle.elapsed
	frames(60)
	expect(game.battle.elapsed > elapsed, "wheel does not pause battle")
	game.wheel.order_requested.emit(2,"follow")
	expect(game.battle.squad_orders[2].mode == "follow" and game.interface_mode == "field", "wheel issues follow to chosen squad")
	key(KEY_H)
	game.wheel.order_requested.emit(2,"guard")
	expect(game.battle.squad_orders[2].mode == "guard", "wheel guards position with bounded pursuit")
	key(KEY_H)
	game.wheel.order_requested.emit(2,"advance")
	expect(game.battle.squad_orders[2].mode == "advance", "wheel advance")
	game.battle.retreat()
	frames(1)
	expect(game.battle.mode == "deploy" and game.interface_mode == "field", "phase pauses while player remains field controlled")
	at_building("headquarters")
	press("布置床弩（消耗 1 器械）")
	expect(game.battle.ballista_count == 1, "local deploy consumes ballista stock")
	press("确认布阵 · 开始交战")
	game.battle.debug_set_morale(0)
	frames(1)
	expect(game.interface_mode == "report" and game.reports.size() == 1, "result opens report and settles")
	var merit: int = game.total_merit
	game._record_report()
	frames(10)
	expect(game.reports.size() == 1 and game.total_merit == merit, "idempotent report")
	press("返回镇务 · 救治与修缮")
	expect(game.operating and game.interface_mode == "field", "return to third person operations")
	print("INTEGRATION_TESTS checks=%d failures=%d" % [checks,failures])
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)
