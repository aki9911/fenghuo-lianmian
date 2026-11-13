extends CharacterBody3D
## Called by the composition root during its physics tick.
@export var move_speed: float = 6.0
@export var gravity: float = 24.0

func move_input(input: Vector2, delta: float, yaw: float) -> Vector2:
	var direction: Vector3 = Basis(Vector3.UP, yaw) * Vector3(input.x, 0, input.y).limit_length()
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	velocity.y = -0.5 if is_on_floor() else velocity.y - gravity * delta
	move_and_slide()
	get_node("Visual").rotation.y = yaw
	return Vector2(global_position.x, global_position.z)

func warp(pos: Vector2) -> void:
	global_position = Vector3(pos.x, 0.04, pos.y)
	velocity = Vector3.ZERO
	reset_physics_interpolation()
