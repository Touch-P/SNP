extends CharacterBody3D
## First-person player controller: WASD to move, mouse to look, Space to
## jump, hold Shift to sprint. Esc releases the mouse cursor; click the
## viewport again to recapture it.

@export var walk_speed: float = 4.0
@export var sprint_speed: float = 7.5
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.0025
@export var acceleration: float = 10.0

const GRAVITY: float = 9.8
const MAX_PITCH_DEG: float = 85.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var _yaw: float = 0.0
var _pitch: float = 0.0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_yaw = rotation.y
	_pitch = head.rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, deg_to_rad(-MAX_PITCH_DEG), deg_to_rad(MAX_PITCH_DEG))
		rotation.y = _yaw
		head.rotation.x = _pitch

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := _get_input_dir()
	var move_dir := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y))
	if move_dir.length_squared() > 0.0:
		move_dir = move_dir.normalized()

	var speed := sprint_speed if Input.is_key_pressed(KEY_SHIFT) else walk_speed
	var target_velocity := move_dir * speed

	velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta * speed)
	velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta * speed)

	move_and_slide()


func _get_input_dir() -> Vector2:
	# Raw key polling so no project-level InputMap changes are required.
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	return dir.normalized()
