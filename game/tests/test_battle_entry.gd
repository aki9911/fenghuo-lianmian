extends SceneTree
## Reproduce the player path, normal input routing and visible battle buttons.
var game
var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	call_deferred("run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("BATTLE_ENTRY FAIL: " + message)

func key(code: int) -> void:
	for pressed in [true, false]:
		var event = InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event, true)

func click(control: Control) -> void:
	var point: Vector2 = control.get_global_rect().get_center()
	var motion = InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)

func settle() -> void:
	for i in range(3): await process_frame
	game._refresh_ui()

func capture(name: String) -> void:
	if DisplayServer.get_name() != "headless": await game._qa_capture(name)

func walk_to(target: Vector2) -> void:
	for step in range(240):
		if game.town_pos.distance_to(target) < 0.35: break
		var movement: Vector2 = (target - game.town_pos).normalized()
		game.town_pos = game.world.move_player(movement, 1.0 / 30)
		game.world.sync_town(game.town_pos, 1.0 / 30)
		await physics_frame
	expect(game.town_pos.distance_to(target) < 0.6, "physical walking reaches " + str(target))

func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	await settle()
	expect(game.battle_guide.is_visible_in_tree() and "米" in game.battle_guide_text.text, "spawn shows persistent HQ direction and distance")
	expect(not game.primary_action.is_visible_in_tree(), "no remote battle button outside HQ")
	await capture("v051_01_entry_guide")
	key(KEY_M)
	await settle()
	expect(game.interface_mode == "map", "M passes through normal UI input routing")
	key(KEY_M)
	await walk_to(Vector2(0,18))
	await walk_to(Vector2(-6,20.8))
	await settle()
	expect("按 E" in game.battle_guide_text.text and "迎敌" in game.interaction_hint.text, "arrival explains local E interaction")
	key(KEY_E)
	await settle()
	expect(game.interface_mode == "building" and game.selected_role == "headquarters", "E opens HQ through normal input routing")
	expect(game.primary_action.is_visible_in_tree() and not game.primary_action.disabled, "incoming battle button is visible and enabled")
	expect(game.sidebar_panel.get_global_rect().encloses(game.primary_action.get_global_rect()), "incoming button is inside visible panel")
	await capture("v051_02_hq_action")
	click(game.primary_action)
	await settle()
	expect(not game.operating and game.battle.mode == "deploy" and game.interface_mode == "command", "mouse click opens deployment")
	expect(game.battle.enemy_count() > 0 and game.battle.enemy_count() <= 30 and game.battle.ally_count() == 30, "raid has real enemies and 30 allies within raid caps")
	var scroll: ScrollContainer = game.sidebar.get_parent()
	scroll.scroll_vertical = 10000
	await settle()
	expect(game.primary_action.is_visible_in_tree() and game.sidebar_panel.get_global_rect().encloses(game.primary_action.get_global_rect()), "start combat remains visible after scrolling")
	root.size = Vector2i(1024,640)
	await settle()
	expect(game.sidebar_panel.get_global_rect().encloses(game.primary_action.get_global_rect()), "combat action stays inside panel at smaller window size")
	await capture("v051_03_fixed_combat_action")
	click(game.primary_action)
	await settle()
	expect(game.battle.mode == "combat" and game.interface_mode == "field", "mouse click starts real-time third-person combat")
	game._physics_process(0.1)
	expect(game.battle.elapsed > 0, "battle simulation advances after clicking")
	print("BATTLE_ENTRY_TESTS checks=%d failures=%d" % [checks,failures])
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)
