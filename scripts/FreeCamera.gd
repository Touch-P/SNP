class_name FreeCamera
extends Camera3D
## Overview / free-fly camera for watching the store (not recorded).
## Hold right mouse button to look, WASD to move, Q/E down/up, Shift = fast,
## mouse wheel changes speed. The mouse is only captured while RMB is held,
## so the Record UI stays clickable.

@export var move_speed: float = 3.0
@export var fast_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.003
@export var look_at_on_start: Vector3 = Vector3(2.4, 0.3, -0.6)

var _yaw: float = 0.0
var _pitch: float = 0.0
var _looking: bool = false


func _ready() -> void:
	look_at(look_at_on_start, Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_looking = button.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			move_speed = minf(move_speed * 1.15, 30.0)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			move_speed = maxf(move_speed / 1.15, 0.2)
	elif event is InputEventMouseMotion and _looking:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0
	if Input.is_key_pressed(KEY_E):
		input.y += 1.0
	if Input.is_key_pressed(KEY_Q):
		input.y -= 1.0
	if input == Vector3.ZERO:
		return
	var speed := move_speed * (fast_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	global_position += global_basis * input.normalized() * speed * delta
