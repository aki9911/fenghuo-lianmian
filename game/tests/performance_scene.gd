extends SceneTree
## 60-second rendered stress fixture, distinct from normal balance testing.
var game
var started: int
var samples: Dictionary = {"wall": [], "evac": []}
var costs: Dictionary = {"wall": [], "evac": []}
var stats: Dictionary = {}
var phase_started: float = 0
var section: String = "wall"
var killed_at: float = 0
var screen_at: float = 0
var done: bool = false
var previous_frame: int = 0

func _initialize() -> void:
	call_deferred("begin")

func begin() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.config.combat.ally_hp = 1000000
	game.config.combat.player_max_hp = 1000000
	game.config.combat.gate_base_hp = 1000000
	game.config.globals.kill_morale_loss = 0
	game.town.equip_soldiers()
	game._qa_visit_hq()
	game._begin_battle()
	game.battle.start_combat()
	game.battle.advance_phase()
	game.battle._spawn_enemies(100)
	game.battle.start_combat()
	game._physics_process(0)
	game._set_interface("map")
	stats = {"scope":"60s rendered controlled stress, not 10-minute performance acceptance", "engine":Engine.get_version_info().string, "cpu":OS.get_processor_name(), "gpu":RenderingServer.get_video_adapter_name(), "renderer":"gl_compatibility", "window":str(root.size), "viewport_3d":str(game.viewport.size), "max_enemy":0, "max_ally":0, "max_groups":0, "offscreen_simulation":false, "fixture":"ally/player/gate HP raised; kill morale=0; normal AI, damage, replenishment and rendering remain active"}
	started = Time.get_ticks_msec()
	previous_frame = Time.get_ticks_usec()
	process_frame.connect(tick)

func tick() -> void:
	if done: return
	var elapsed: float = (Time.get_ticks_msec() - started) / 1000.0
	var delta: float = root.get_process_delta_time()
	var before: int = Time.get_ticks_usec()
	var wall_frame_ms: float = (before - previous_frame) / 1000.0
	previous_frame = before
	game._physics_process(delta)
	game._process(delta)
	var cost: float = (Time.get_ticks_usec() - before) / 1000.0
	if elapsed - phase_started > 2:
		samples[section].append(wall_frame_ms)
		costs[section].append(cost)
	stats.max_enemy = maxi(int(stats.max_enemy), game.battle.enemy_count())
	stats.max_ally = maxi(int(stats.max_ally), game.battle.ally_count())
	stats.max_groups = maxi(int(stats.max_groups), game.battle.evac_groups.size())
	if elapsed - killed_at > 4:
		killed_at = elapsed
		for agent in game.battle.agents:
			if agent.alive and agent.team == "enemy":
				game.battle._damage(agent, 1000000)
				break
	if elapsed > 20 and elapsed < 25:
		game.world.set_tactical(true)
		game.world.camera.position.x = 500
		stats.offscreen_simulation = game.battle.elapsed > 21 and game.battle.enemy_count() > 0
	elif elapsed >= 25:
		game.world.tactical_camera.position.x = 31
	if elapsed >= 40 and section == "wall":
		section = "evac"
		phase_started = elapsed
		game.battle.advance_phase()
		game.battle.start_combat()
		game.battle.advance_phase()
		game.battle._spawn_enemies(100)
		game.battle.start_combat()
		print("PERFORMANCE_EVAC enemies=%d allies=%d groups=%d" % [game.battle.enemy_count(),game.battle.ally_count(),game.battle.evac_groups.size()])
	if elapsed > 30 and screen_at == 0:
		screen_at = elapsed
		game._qa_capture("v06_03_full_battle")
	if elapsed >= 60:
		done = true
		stats.wall_clock_seconds = elapsed
		stats.viewport_3d = str(game.viewport.size)
		stats.frame_sampling = "monotonic microseconds between rendered process frames; 60 FPS cap; first2s of each phase excluded"
		stats.total_kills = game.battle.kills
		stats.sections = {}
		for id in samples:
			stats.sections[id] = {"frame_ms":summary(samples[id]), "controller_ms":summary(costs[id])}
		var file = FileAccess.open("res://../outputs/qa/performance_v06.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(stats, "\t"))
		print("PERFORMANCE_RESULT ", JSON.stringify(stats))
		game.queue_free()
		await process_frame
		quit()

func summary(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	values.sort()
	var total: float = 0
	for v in values: total += float(v)
	return {"samples":values.size(), "mean":total / values.size(), "p50":values[int(values.size()*0.5)], "p99":values[mini(values.size()-1,int(values.size()*0.99))], "max":values.back()}
