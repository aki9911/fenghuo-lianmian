extends Node3D
## Independent yaw rig; character rotation never rotates the camera twice.
@export var distance: float = 5.5
@export var sensitivity: float = 0.003
@export var focus_height: float = 1.5
@export var pitch: float = -0.2
var yaw: float = 0.0
var target: CharacterBody3D
@onready var spring: SpringArm3D = $SpringArm3D
@onready var view: Camera3D = $SpringArm3D/Camera3D

func follow(body: CharacterBody3D) -> void:
	target = body
	spring.add_excluded_object(body.get_rid())
	update_pose()

func look(relative: Vector2) -> void:
	yaw -= relative.x * sensitivity
	pitch = clampf(pitch - relative.y * sensitivity, -0.85, 0.25)
	update_pose()

func _process(_delta: float) -> void:
	update_pose()

func update_pose() -> void:
	if target == null: return
	global_position = target.global_position + Vector3.UP * focus_height
	rotation = Vector3(0, yaw, 0)
	spring.rotation.x = pitch
	spring.spring_length = distance

func facing() -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))
