extends SceneTree
var failures: int = 0
var checks: int = 0

func _initialize() -> void:
	call_deferred("run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func run() -> void:
	var scene = load("res://scenes/wangfeng_town.tscn")
	var preview = scene.instantiate()
	expect(preview.find_children("*","MeshInstance3D",true,false).size() > 200, "Meshes exist before any setup or running the scene")
	expect(preview.get_node("Buildings").get_child_count() == 5, "Five editable named buildings")
	expect(preview.get_node("AmbientResidents").get_child_count() == 15, "15 resident visual representatives")
	for node in preview.find_children("*","",true,false):
		expect(node.owner != null,"Every scene node is serialized and editable")
	preview.free()
	var game = load("res://scenes/main.tscn").instantiate()
	var source = game.get_node("World")
	var house = source.get_node("Buildings/engineer")
	var roof = house.get_child(3)
	house.position.x -= 2
	roof.scale = Vector3(1.2,1.2,1.2)
	source.get_node("Sun").light_energy = 0.6
	var count: int = source.find_children("*","",true,false).size()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	expect(game.world == source,"Runtime uses the scene instance already present in main")
	expect(source.get_parent() == game.viewport,"World is reparented into game viewport")
	expect(source.find_children("*","",true,false).size() == count,"No duplicate generation after starting")
	expect(house.position.x == -17 and is_equal_approx(roof.scale.x,1.2),"User model edits survive setup")
	expect(is_equal_approx(source.get_node("Sun").light_energy,0.6),"Editor lighting survives setup")
	var entrance: Vector2
	for building in source.get_building_definitions():
		if building.id == "engineer": entrance = building.pos
	game.town_pos = entrance
	game.world.warp_player(entrance)
	game._visit_building("engineer")
	expect(game.interface_mode == "building" and is_equal_approx(entrance.x,-17), "Building interactions follow edited position")
	source.setup()
	expect(source.find_children("*","",true,false).size() == count,"Repeated binding is idempotent")
	game.queue_free()
	await process_frame
	print("EDITABLE_SCENE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
