class_name CustomerAgent
extends CharacterBody3D
## Single customer NPC: SPAWN -> CHOOSE_TARGET -> WALK -> PICK -> (repeat)
## -> WALK_TO_EXIT -> DONE.
##
## All randomness comes from the session RNG passed to begin(), so a seed
## reproduces the same shopping trip. The placeholder body lives under
## "Visual" and can be swapped for a humanoid model without touching this
## script; "Basket" and "NavigationAgent3D" are what the logic relies on.
## Forward is -Z (Godot convention).

signal finished
signal item_picked(product: ProductInstance)

enum State { SPAWN, CHOOSE_TARGET, WALK, PICK, WALK_TO_EXIT, DONE }

@export var base_walk_speed: float = 1.2
## Per-session speed variation (fraction of base_walk_speed).
@export_range(0.0, 0.5, 0.01) var walk_speed_variation: float = 0.12
@export_range(0.0, 1.0, 0.01) var wander_probability: float = 0.3
@export var pick_pause_range: Vector2 = Vector2(0.5, 1.5)
@export var pick_tween_seconds: float = 0.4
@export var turn_speed: float = 8.0
@export var arrive_distance: float = 0.15
## Seconds without progress before a walk target is abandoned.
@export var stuck_timeout: float = 6.0
## Spacing of the 3 x 2 stacking grid in the basket (x, layer height, z).
@export var basket_stack_spacing: Vector3 = Vector3(0.11, 0.12, 0.11)
@export var max_items: int = 10

var agent_id: String = "customer_1"
var state: State = State.SPAWN
var items_to_pick: int = 0
var walk_speed: float = 1.2
## pick_end event rows, in pick order.
var picked_items: Array[Dictionary] = []

var _rng: RandomNumberGenerator
var _logger: EventLogger
var _targets: Array[ShelfSlot] = []
var _spare_targets: Array[ShelfSlot] = []
var _current_slot: ShelfSlot
var _walk_goal: Vector3
var _walk_kind: String = ""
var _exit_position: Vector3
var _wander_bounds: AABB
var _wander_pending: bool = false
var _stuck_timer: float = 0.0
var _progress_anchor: Vector3
var _floor_y: float = 0.0

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var basket: Node3D = $Basket
@onready var basket_items: Node3D = $Basket/Items


## Call after the agent is in the tree and placed at the entrance.
func begin(rng: RandomNumberGenerator, stocked_slots: Array[ShelfSlot], exit_position: Vector3,
		wander_bounds: AABB, logger: EventLogger, p_agent_id: String = "customer_1") -> void:
	_rng = rng
	_logger = logger
	agent_id = p_agent_id
	_exit_position = exit_position
	_wander_bounds = wander_bounds
	_floor_y = global_position.y
	walk_speed = base_walk_speed * (1.0 + _rng.randf_range(-walk_speed_variation, walk_speed_variation))
	items_to_pick = mini(_rng.randi_range(1, max_items), stocked_slots.size())

	var shuffled := stocked_slots.duplicate()
	_shuffle(shuffled)
	_targets.assign(shuffled.slice(0, items_to_pick))
	_spare_targets.assign(shuffled.slice(items_to_pick))

	print("[customer] items_to_pick=%d walk_speed=%.2f" % [items_to_pick, walk_speed])
	_logger.log_event("enter", agent_id, null, null, global_position + Vector3.UP)
	state = State.SPAWN


## Stops all behaviour (used when the session is stopped early).
func cancel() -> void:
	state = State.DONE
	velocity = Vector3.ZERO


func get_basket_contents() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for child in basket_items.get_children():
		if child is ProductInstance:
			result.append(child.to_dict())
	return result


func _physics_process(delta: float) -> void:
	match state:
		State.SPAWN:
			# One physics frame after spawning, so the agent is registered
			# on the navigation map before the first path query.
			state = State.CHOOSE_TARGET
		State.CHOOSE_TARGET:
			_choose_next_target()
		State.WALK, State.WALK_TO_EXIT:
			_step_walk(delta)


func _choose_next_target() -> void:
	if picked_items.size() >= items_to_pick:
		_start_walk(_exit_position, "exit")
		state = State.WALK_TO_EXIT
		return
	if _wander_pending:
		_wander_pending = false
		_start_walk(_random_wander_point(), "wander")
		state = State.WALK
		return

	_current_slot = null
	while not _targets.is_empty() and _current_slot == null:
		var candidate: ShelfSlot = _targets.pop_front()
		if candidate.is_occupied():
			_current_slot = candidate
	if _current_slot == null:
		# Nothing left to pick (all targets abandoned and no spares).
		items_to_pick = picked_items.size()
		state = State.CHOOSE_TARGET
		return

	var pick_point := _current_slot.shelf.get_pick_point(_current_slot.face)
	_start_walk(pick_point.global_position, "slot")
	state = State.WALK


func _start_walk(goal: Vector3, kind: String) -> void:
	_walk_goal = Vector3(goal.x, _floor_y, goal.z)
	_walk_kind = kind
	navigation_agent.target_position = _walk_goal
	_stuck_timer = 0.0
	_progress_anchor = global_position


func _step_walk(delta: float) -> void:
	var to_goal := _walk_goal - global_position
	to_goal.y = 0.0
	if to_goal.length() <= arrive_distance or navigation_agent.is_navigation_finished():
		velocity = Vector3.ZERO
		_on_arrived()
		return

	var direction := navigation_agent.get_next_path_position() - global_position
	direction.y = 0.0
	if direction.length_squared() < 1e-6:
		direction = to_goal
	direction = direction.normalized()
	velocity = direction * walk_speed
	move_and_slide()
	global_position.y = _floor_y
	rotation.y = lerp_angle(rotation.y, _yaw_for(direction), clampf(turn_speed * delta, 0.0, 1.0))

	_stuck_timer += delta
	if global_position.distance_to(_progress_anchor) > 0.25:
		_progress_anchor = global_position
		_stuck_timer = 0.0
	elif _stuck_timer > stuck_timeout:
		push_warning("[customer] stuck walking to %s target, giving up on it" % _walk_kind)
		velocity = Vector3.ZERO
		if _walk_kind == "slot":
			if not _spare_targets.is_empty():
				_targets.append(_spare_targets.pop_front())
			state = State.CHOOSE_TARGET
		else:
			_on_arrived()


func _on_arrived() -> void:
	match _walk_kind:
		"slot":
			state = State.PICK
			_pick(_current_slot)
		"wander":
			state = State.CHOOSE_TARGET
		"exit":
			state = State.DONE
			_logger.log_event("exit", agent_id, null, null, global_position + Vector3.UP)
			finished.emit()


func _pick(slot: ShelfSlot) -> void:
	# Face the shelf: forward (-Z) points into the shelf face.
	await _turn_to(_yaw_for(-slot.shelf.get_face_normal(slot.face)), 0.25)
	await _wait(_rng.randf_range(pick_pause_range.x, pick_pause_range.y))

	var product := slot.occupied_product
	if product == null or not is_instance_valid(product):
		state = State.CHOOSE_TARGET
		return

	_logger.log_event("pick_start", agent_id, product, slot)
	var start := product.global_transform
	var end_local := Transform3D(Basis.IDENTITY, _stack_offset(picked_items.size()))
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(
		func(weight: float) -> void:
			product.global_transform = start.interpolate_with(basket_items.global_transform * end_local, weight),
		0.0, 1.0, pick_tween_seconds)
	await tween.finished

	# Same node all the way: reparent, never free or duplicate.
	product.reparent(basket_items, true)
	product.transform = end_local
	slot.take_product()
	picked_items.append(_logger.log_event("pick_end", agent_id, product, slot))
	item_picked.emit(product)

	_wander_pending = picked_items.size() < items_to_pick and _rng.randf() < wander_probability
	state = State.CHOOSE_TARGET


func _turn_to(target_yaw: float, seconds: float) -> void:
	var from := rotation.y
	var tween := create_tween()
	tween.tween_method(
		func(weight: float) -> void: rotation.y = lerp_angle(from, target_yaw, weight),
		0.0, 1.0, seconds)
	await tween.finished


# Timer/tween are children of (or bound to) this node, so if the customer is
# freed mid-pick the awaits simply never resume instead of erroring.
func _wait(seconds: float) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = maxf(seconds, 0.001)
	add_child(timer)
	timer.start()
	await timer.timeout
	timer.queue_free()


func _random_wander_point() -> Vector3:
	var p := _wander_bounds.position + Vector3(
		_rng.randf() * _wander_bounds.size.x, 0.0, _rng.randf() * _wander_bounds.size.z)
	p.y = _floor_y
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, p)


func _stack_offset(index: int) -> Vector3:
	var layer := floori(index / 6.0)
	var k := index % 6
	var column := k % 3
	var row := floori(k / 3.0)
	return Vector3(
		(row - 0.5) * basket_stack_spacing.x,
		layer * basket_stack_spacing.y,
		(column - 1) * basket_stack_spacing.z)


func _shuffle(items: Array) -> void:
	# Fisher-Yates with the session RNG (Array.shuffle() uses the global RNG).
	for i in range(items.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp


static func _yaw_for(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)
