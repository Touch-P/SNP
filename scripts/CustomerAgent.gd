class_name CustomerAgent
extends CharacterBody3D
## Single customer NPC: SPAWN -> CHOOSE_TARGET -> WALK -> PICK -> (repeat)
## -> WALK_TO_EXIT -> DONE.
##
## All randomness comes from the session RNG passed to begin(), so a seed
## reproduces the same shopping trip. Forward is -Z (Godot convention); the
## Mixamo model under Visual/Model faces +Z, so it is rotated 180 degrees.
##
## Animations: the clips come from the Mixamo FBX files (one "mixamo_com"
## clip each) and are registered in $AnimationPlayer as walk, pick,
## upper_pick and under_pick. walk loops, has its horizontal root motion
## removed (navigation moves the body) and its playback speed follows the
## actual ground speed. There is no idle clip, so standing still holds the
## first frame of the pick clip ("stand").
##
## Picking: the agent walks to a stand point derived from the slot's
## navmesh-snapped pick point, placed so the picking (right) hand is over the
## slot at the clip's grab time. It only picks when the horizontal distance
## to the slot is within pick_reach, turns to face the shelf, then plays the
## clip for the slot level (top: upper_pick, bottom: under_pick, else pick).
## At grab time the product is reparented into the right hand and the slot
## is freed; when the clip ends the product moves into the basket, which
## hangs upright from the left hand.

signal finished
signal item_picked(product: ProductInstance)
signal _anim_marker_reached

enum State { SPAWN, CHOOSE_TARGET, WALK, PICK, WALK_TO_EXIT, DONE }

const ANIM_WALK := "walk"
const ANIM_STAND := "stand"
const ANIM_PICK := "pick"
const ANIM_UPPER_PICK := "upper_pick"
const ANIM_UNDER_PICK := "under_pick"
const PICK_ANIMS: Array[String] = [ANIM_PICK, ANIM_UPPER_PICK, ANIM_UNDER_PICK]

@export var base_walk_speed: float = 1.2
## Per-session speed variation (fraction of base_walk_speed).
@export_range(0.0, 0.5, 0.01) var walk_speed_variation: float = 0.12
@export_range(0.0, 1.0, 0.01) var wander_probability: float = 0.3
@export var pick_pause_range: Vector2 = Vector2(0.5, 1.5)
@export var turn_speed: float = 8.0
@export var arrive_distance: float = 0.15
## Seconds without progress before a walk target is abandoned.
@export var stuck_timeout: float = 6.0
@export var max_items: int = 10

@export_group("Picking")
## Max horizontal distance from the agent's origin to the slot for a pick
## to start.
@export_range(0.2, 2.0, 0.01, "suffix:m") var pick_reach: float = 0.85
## How close the agent must get to its stand point before picking.
@export_range(0.005, 0.5, 0.005, "suffix:m") var stand_tolerance: float = 0.03
## Once navigation reports finished within this distance of the stand point,
## the agent walks the rest in a straight line.
@export_range(0.0, 1.0, 0.01, "suffix:m") var final_approach_distance: float = 0.4
@export var turn_seconds: float = 0.25
## Product glides from the slot into the hand over this time at grab_time.
@export_range(0.05, 0.5, 0.01, "suffix:s") var hand_tween_seconds: float = 0.12
## Product glides from the hand into the basket over this time.
@export_range(0.05, 1.0, 0.01, "suffix:s") var basket_tween_seconds: float = 0.25

@export_group("Animations")
@export_file("*.fbx", "*.glb", "*.gltf") var walk_source: String = "res://Walking.fbx"
@export_file("*.fbx", "*.glb", "*.gltf") var pick_source: String = "res://pick.fbx"
@export_file("*.fbx", "*.glb", "*.gltf") var upper_pick_source: String = "res://upper_pick.fbx"
@export_file("*.fbx", "*.glb", "*.gltf") var under_pick_source: String = "res://under_pick.fbx"
## Name of the clip inside each source file.
@export var source_clip_name: String = "mixamo_com"
## Seconds into each clip at which the hand closes on the product. Defaults
## are the moment the right hand is furthest forward (sampled at 240 Hz).
@export var grab_time_pick: float = 1.067
@export var grab_time_upper_pick: float = 3.383
@export var grab_time_under_pick: float = 3.050
@export var anim_blend_seconds: float = 0.2
@export var hips_bone: String = "mixamorig_Hips"
@export var picking_hand_bone: String = "mixamorig_RightHand"
@export var head_top_bone: String = "mixamorig_HeadTop_End"

@export_group("Basket")
## Usable volume of the basket in Basket/Items space (origin = floor centre,
## x across the basket, z along it, y up from the floor).
@export var basket_interior: AABB = AABB(Vector3(-0.085, 0.0, -0.15), Vector3(0.17, 0.21, 0.30))
## Floor grid (cells across x, cells along z). Items fill the floor first,
## then stack a second layer on top of the first.
@export var basket_grid: Vector2i = Vector2i(2, 3)
## Extra offset of the basket from the grip, in the agent's frame (x right,
## y up, z back), e.g. to keep it clear of the leg.
@export var basket_hang_offset: Vector3 = Vector3(-0.06, 0.0, 0.0)

var agent_id: String = "customer_1"
var state: State = State.SPAWN
var items_to_pick: int = 0
var walk_speed: float = 1.2
## pick_end event rows, in pick order.
var picked_items: Array[Dictionary] = []

# Imported clips, shared by every customer in the process.
static var _clip_cache: Dictionary = {}
static var _fit_reported: bool = false

var _rng: RandomNumberGenerator
var _logger: EventLogger
var _targets: Array[ShelfSlot] = []
var _spare_targets: Array[ShelfSlot] = []
var _current_slot: ShelfSlot
var _current_anim: String = ""
var _walk_attempt: int = 0
var _walk_goal: Vector3
var _walk_kind: String = ""
var _exit_position: Vector3
var _wander_bounds: AABB
var _wander_pending: bool = false
var _stuck_timer: float = 0.0
var _progress_anchor: Vector3
var _floor_y: float = 0.0
var _ground_speed: float = 0.0
## Ground speed (m/s) the walk clip was authored at; playback is scaled to it.
var _walk_cycle_speed: float = 1.0
## Agent-local position of the picking hand at each clip's grab time.
var _grab_hand_offsets: Dictionary = {}
var _marker_anim: String = ""
var _marker_time: float = -1.0
var _cell_heights: PackedFloat32Array = PackedFloat32Array()

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var _model: Node3D = $Visual/Model
@onready var _skeleton: Skeleton3D = $Visual/Model/Skeleton3D
@onready var _hold_point: Node3D = $Visual/Model/Skeleton3D/RightHand/HoldPoint
@onready var _basket_grip: Node3D = $Visual/Model/Skeleton3D/LeftHand/BasketGrip
@onready var basket: Node3D = $Visual/Model/Skeleton3D/LeftHand/Basket
@onready var basket_items: Node3D = $Visual/Model/Skeleton3D/LeftHand/Basket/Items


func _ready() -> void:
	_cell_heights.resize(maxi(1, basket_grid.x * basket_grid.y))
	_cell_heights.fill(0.0)
	_setup_animations()
	_skeleton.skeleton_updated.connect(_hang_basket)
	_play(ANIM_STAND, 0.0)


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


## Products currently held in the hand (between grab and basket).
func get_held_products() -> Array[ProductInstance]:
	var result: Array[ProductInstance] = []
	for child in _hold_point.get_children():
		if child is ProductInstance:
			result.append(child)
	return result


## Which pick clip a slot gets: top level -> upper_pick, bottom level ->
## under_pick, anything in between -> pick. Back faces use the same levels.
static func anim_for_slot(slot: ShelfSlot) -> String:
	if slot.level_count <= 1:
		return ANIM_PICK
	if slot.is_top_level():
		return ANIM_UPPER_PICK
	if slot.is_bottom_level():
		return ANIM_UNDER_PICK
	return ANIM_PICK


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


func _process(_delta: float) -> void:
	if _marker_time >= 0.0 and animation_player.current_animation == _marker_anim \
			and animation_player.current_animation_position >= _marker_time:
		_marker_time = -1.0
		_anim_marker_reached.emit()


# --- walking -----------------------------------------------------------------

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

	_current_anim = anim_for_slot(_current_slot)
	_walk_attempt = 1
	_start_walk(_stand_point_for(_current_slot, _current_anim), "slot")
	state = State.WALK


func _start_walk(goal: Vector3, kind: String) -> void:
	_walk_goal = Vector3(goal.x, _floor_y, goal.z)
	_walk_kind = kind
	navigation_agent.target_position = _walk_goal
	_stuck_timer = 0.0
	_progress_anchor = global_position
	_play(ANIM_WALK, anim_blend_seconds)


func _step_walk(delta: float) -> void:
	var to_goal := _walk_goal - global_position
	to_goal.y = 0.0
	var remaining := to_goal.length()
	var tolerance := stand_tolerance if _walk_kind == "slot" else arrive_distance
	if remaining <= tolerance:
		_arrive()
		return

	var direction: Vector3
	if navigation_agent.is_navigation_finished():
		# Navigation also reports finished when it stops short of a target
		# it cannot reach, so only trust it near the goal.
		if _walk_kind == "slot" and remaining <= final_approach_distance:
			direction = to_goal
		else:
			_arrive()
			return
	else:
		direction = navigation_agent.get_next_path_position() - global_position
		direction.y = 0.0
		if direction.length_squared() < 1e-6:
			direction = to_goal
	direction = direction.normalized()

	var speed := walk_speed
	if _walk_kind == "slot":
		speed = minf(walk_speed, remaining / maxf(delta, 1e-4))
	velocity = direction * speed
	var before := global_position
	move_and_slide()
	global_position.y = _floor_y
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	_ground_speed = lerpf(_ground_speed, moved / maxf(delta, 1e-4), 0.3)
	animation_player.speed_scale = clampf(_ground_speed / _walk_cycle_speed, 0.1, 3.0)
	rotation.y = lerp_angle(rotation.y, _yaw_for(direction), clampf(turn_speed * delta, 0.0, 1.0))

	_stuck_timer += delta
	if global_position.distance_to(_progress_anchor) > 0.25:
		_progress_anchor = global_position
		_stuck_timer = 0.0
	elif _stuck_timer > stuck_timeout:
		push_warning("[customer] stuck walking to %s target, giving up on it" % _walk_kind)
		velocity = Vector3.ZERO
		if _walk_kind == "slot":
			_abandon_current_slot()
		else:
			_arrive()


func _arrive() -> void:
	velocity = Vector3.ZERO
	_ground_speed = 0.0
	if _walk_kind != "wander":
		_play(ANIM_STAND, anim_blend_seconds)
	_on_arrived()


func _on_arrived() -> void:
	match _walk_kind:
		"slot":
			var distance := _horizontal_distance_to(_current_slot)
			if distance <= pick_reach:
				state = State.PICK
				_pick(_current_slot)
			elif _walk_attempt < 2:
				print("[customer] %s/%s out of reach (%.3f m > %.2f m), re-pathing" % [
					_current_slot.shelf.shelf_id, _current_slot.slot_id, distance, pick_reach])
				_walk_attempt += 1
				_start_walk(_current_slot.pick_point if _current_slot.has_pick_point
					else _stand_point_for(_current_slot, _current_anim), "slot")
			else:
				push_warning("[customer] cannot get within reach of %s/%s (%.3f m), choosing another slot" % [
					_current_slot.shelf.shelf_id, _current_slot.slot_id, distance])
				_abandon_current_slot()
		"wander":
			state = State.CHOOSE_TARGET
		"exit":
			state = State.DONE
			_logger.log_event("exit", agent_id, null, null, global_position + Vector3.UP)
			finished.emit()


func _abandon_current_slot() -> void:
	_play(ANIM_STAND, anim_blend_seconds)
	if not _spare_targets.is_empty():
		_targets.append(_spare_targets.pop_front())
	state = State.CHOOSE_TARGET


## Floor point where the agent stands (facing the shelf) so that the picking
## hand is over the slot at the clip's grab time; snapped onto the navmesh,
## so it is pushed back into the aisle when the hand reaches further than
## the shelf clearance allows.
func _stand_point_for(slot: ShelfSlot, anim_name: String) -> Vector3:
	var facing := Basis(Vector3.UP, _yaw_for(-slot.shelf.get_face_normal(slot.face)))
	var hand: Vector3 = facing * (_grab_hand_offsets.get(anim_name, Vector3.ZERO) as Vector3)
	var goal := slot.global_position - Vector3(hand.x, 0.0, hand.z)
	goal.y = slot.pick_point.y if slot.has_pick_point else _floor_y
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, goal)


func _horizontal_distance_to(slot: ShelfSlot) -> float:
	var offset := slot.global_position - global_position
	return Vector2(offset.x, offset.z).length()


# --- picking -----------------------------------------------------------------

func _pick(slot: ShelfSlot) -> void:
	var anim_name := _current_anim
	# Face the shelf (forward -Z into the face) before the clip starts.
	await _turn_to(_yaw_for(-slot.shelf.get_face_normal(slot.face)), turn_seconds)
	await _wait(_rng.randf_range(pick_pause_range.x, pick_pause_range.y))

	var product := slot.occupied_product
	if product == null or not is_instance_valid(product):
		state = State.CHOOSE_TARGET
		return

	var reach := _horizontal_distance_to(slot)
	print("[customer] pick_start %s/%s level=%d/%d anim=%s reach=%.3f m (pick_reach %.2f m)" % [
		slot.shelf.shelf_id, slot.slot_id, slot.level, slot.level_count - 1, anim_name, reach, pick_reach])
	_logger.log_event("pick_start", agent_id, product, slot, Vector3.ZERO, anim_name)

	_play(anim_name, anim_blend_seconds)
	_marker_anim = anim_name
	_marker_time = minf(_grab_time(anim_name), animation_player.get_animation(anim_name).length - 0.01)
	await _anim_marker_reached
	_grab(product, slot)

	await animation_player.animation_finished
	_play(ANIM_STAND, 0.0)
	await _put_in_basket(product)

	picked_items.append(_logger.log_event("pick_end", agent_id, product, slot, Vector3.ZERO, anim_name))
	item_picked.emit(product)

	_wander_pending = picked_items.size() < items_to_pick and _rng.randf() < wander_probability
	state = State.CHOOSE_TARGET


## Grab moment: the slot lets go, the product (same node, uid intact) moves
## under the hand and glides into the grip.
func _grab(product: ProductInstance, slot: ShelfSlot) -> void:
	slot.take_product()
	product.set_collision_enabled(false)
	product.reparent(_hold_point, true)
	var hand_error := product.get_center_global().distance_to(_hold_point.global_position)
	print("[customer] grab %s uid=%d t=%.3f frame=%d product->hand %.3f m" % [
		product.class_name_str, product.instance_uid, _logger.get_sim_time(),
		_logger.get_frame_index(), hand_error])
	# HoldPoint: +Y = product up, +Z = out of the palm; centre the product
	# half its depth in front of the palm.
	var held := Transform3D(Basis.IDENTITY, Vector3(0.0, -product.size.y * 0.5, product.size.z * 0.5))
	await _glide(product, held, hand_tween_seconds)


func _put_in_basket(product: ProductInstance) -> void:
	var target := _next_basket_transform(product)
	product.reparent(basket_items, true)
	await _glide(product, target, basket_tween_seconds)


## Tweens `node`'s local transform to `target` (the tween is bound to this
## agent, so it dies with it).
func _glide(node: Node3D, target: Transform3D, seconds: float) -> void:
	var from := node.transform
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(
		func(weight: float) -> void:
			if is_instance_valid(node):
				node.transform = from.interpolate_with(target, weight),
		0.0, 1.0, seconds)
	await tween.finished
	if is_instance_valid(node):
		node.transform = target


## Next free spot on the basket floor grid (cell centres inside
## basket_interior); once every floor cell is used, items stack on top of
## the item already in that cell. The long side of the product's footprint
## follows the long side of the cell.
func _next_basket_transform(product: ProductInstance) -> Transform3D:
	var index := 0
	for child in basket_items.get_children():
		if child is ProductInstance and child != product:
			index += 1
	var cell := index % _cell_heights.size()
	var column := cell % basket_grid.x
	var row := cell / basket_grid.x
	var cell_size := Vector2(basket_interior.size.x / basket_grid.x, basket_interior.size.z / basket_grid.y)
	var spot := Vector3(
		basket_interior.position.x + (column + 0.5) * cell_size.x,
		basket_interior.position.y + _cell_heights[cell],
		basket_interior.position.z + (row + 0.5) * cell_size.y)
	_cell_heights[cell] += product.size.y
	var yaw := PI * 0.5 if (product.size.x > product.size.z) != (cell_size.x > cell_size.y) else 0.0
	return Transform3D(Basis(Vector3.UP, yaw), spot)


## Keeps the basket upright and hanging from the left-hand grip. Runs after
## every skeleton update, i.e. after the BoneAttachment3D has followed the hand.
func _hang_basket() -> void:
	if not is_inside_tree():
		return
	var upright := Basis(Vector3.UP, global_rotation.y)
	basket.global_transform = Transform3D(upright, _basket_grip.global_position + upright * basket_hang_offset)


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


func _shuffle(items: Array) -> void:
	# Fisher-Yates with the session RNG (Array.shuffle() uses the global RNG).
	for i in range(items.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp


static func _yaw_for(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


# --- animation ---------------------------------------------------------------

func _play(anim_name: String, blend: float) -> void:
	if anim_name != ANIM_WALK:
		animation_player.speed_scale = 1.0
	if animation_player.current_animation == anim_name and anim_name in [ANIM_WALK, ANIM_STAND]:
		return
	animation_player.play(anim_name, blend)


func _grab_time(anim_name: String) -> float:
	match anim_name:
		ANIM_UPPER_PICK:
			return grab_time_upper_pick
		ANIM_UNDER_PICK:
			return grab_time_under_pick
	return grab_time_pick


func _setup_animations() -> void:
	var sources := {
		ANIM_WALK: walk_source,
		ANIM_PICK: pick_source,
		ANIM_UPPER_PICK: upper_pick_source,
		ANIM_UNDER_PICK: under_pick_source,
	}
	var library := AnimationLibrary.new()
	for anim_name: String in sources:
		var clip := _load_clip(sources[anim_name], source_clip_name)
		if clip == null:
			push_error("CustomerAgent: clip '%s' not found in %s" % [source_clip_name, sources[anim_name]])
			continue
		if anim_name == ANIM_WALK:
			clip = _make_in_place_loop(clip)
		library.add_animation(anim_name, clip)
	if library.has_animation(ANIM_PICK):
		library.add_animation(ANIM_STAND, _first_frame_pose(library.get_animation(ANIM_PICK)))
	animation_player.add_animation_library("", library)

	for anim_name in PICK_ANIMS:
		if library.has_animation(anim_name):
			_grab_hand_offsets[anim_name] = _bone_position_at(
				library.get_animation(anim_name), picking_hand_bone, _grab_time(anim_name))
	_report_fit(library)


## The clip of an imported scene, loaded once per process.
static func _load_clip(path: String, clip_name: String) -> Animation:
	var key := "%s::%s" % [path, clip_name]
	if _clip_cache.has(key):
		return _clip_cache[key]
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var root := scene.instantiate()
	var clip: Animation = null
	for node in root.find_children("*", "AnimationPlayer", true, false):
		if (node as AnimationPlayer).has_animation(clip_name):
			clip = (node as AnimationPlayer).get_animation(clip_name)
			break
	root.free()
	_clip_cache[key] = clip
	return clip


## Looping copy of the walk clip with the hips' forward drift removed, so it
## walks in place; the authored ground speed is kept for playback scaling.
func _make_in_place_loop(source: Animation) -> Animation:
	var walk := source.duplicate(true) as Animation
	walk.loop_mode = Animation.LOOP_LINEAR
	var track := walk.find_track(_bone_track_path(hips_bone), Animation.TYPE_POSITION_3D)
	if track < 0 or walk.track_get_key_count(track) < 2:
		push_warning("CustomerAgent: walk clip has no %s position track" % hips_bone)
		return walk
	var last_key := walk.track_get_key_count(track) - 1
	var first: Vector3 = walk.track_get_key_value(track, 0)
	var last: Vector3 = walk.track_get_key_value(track, last_key)
	var span := walk.track_get_key_time(track, last_key) - walk.track_get_key_time(track, 0)
	var drift := Vector3(last.x - first.x, 0.0, last.z - first.z)
	if span > 0.0:
		_walk_cycle_speed = maxf(drift.length() / span, 0.01)
	for key in walk.track_get_key_count(track):
		var weight := (walk.track_get_key_time(track, key) - walk.track_get_key_time(track, 0)) / maxf(span, 1e-6)
		var value: Vector3 = walk.track_get_key_value(track, key)
		walk.track_set_key_value(track, key, value - drift * weight)
	return walk


## One-key looping pose taken from the first frame of `source`.
static func _first_frame_pose(source: Animation) -> Animation:
	var pose := Animation.new()
	pose.length = 0.1
	pose.loop_mode = Animation.LOOP_LINEAR
	for i in source.get_track_count():
		var type := source.track_get_type(i)
		if type != Animation.TYPE_POSITION_3D and type != Animation.TYPE_ROTATION_3D \
				and type != Animation.TYPE_SCALE_3D:
			continue
		var track := pose.add_track(type)
		pose.track_set_path(track, source.track_get_path(i))
		pose.track_insert_key(track, 0.0, source.track_get_key_value(i, 0))
	return pose


func _bone_track_path(bone_name: String) -> NodePath:
	return NodePath("%s:%s" % [_model.get_path_to(_skeleton), bone_name])


## Agent-local position of `bone_name` at `time` in `anim`, evaluated from
## the clip's own tracks (rest pose for bones the clip does not animate).
func _bone_position_at(anim: Animation, bone_name: String, time: float) -> Vector3:
	var bone := _skeleton.find_bone(bone_name)
	if bone < 0:
		push_error("CustomerAgent: bone %s not found" % bone_name)
		return Vector3.ZERO
	var pose := Transform3D.IDENTITY
	while bone >= 0:
		var rest := _skeleton.get_bone_rest(bone)
		var path := _bone_track_path(_skeleton.get_bone_name(bone))
		var origin := rest.origin
		var rotation_q := rest.basis.get_rotation_quaternion()
		var scale_v := rest.basis.get_scale()
		var track := anim.find_track(path, Animation.TYPE_POSITION_3D)
		if track >= 0:
			origin = anim.position_track_interpolate(track, time)
		track = anim.find_track(path, Animation.TYPE_ROTATION_3D)
		if track >= 0:
			rotation_q = anim.rotation_track_interpolate(track, time)
		track = anim.find_track(path, Animation.TYPE_SCALE_3D)
		if track >= 0:
			scale_v = anim.scale_track_interpolate(track, time)
		pose = Transform3D(Basis(rotation_q) * Basis.from_scale(scale_v), origin) * pose
		bone = _skeleton.get_bone_parent(bone)
	var skeleton_to_agent := global_transform.affine_inverse() * _skeleton.global_transform
	return skeleton_to_agent * pose.origin


## Time at which the picking hand is furthest forward (agent -Z).
func _furthest_reach_time(anim: Animation) -> float:
	var best_time := 0.0
	var best_forward := -INF
	var steps := ceili(anim.length * 120.0)
	for i in steps + 1:
		var t := anim.length * i / steps
		var forward := -_bone_position_at(anim, picking_hand_bone, t).z
		if forward > best_forward:
			best_forward = forward
			best_time = t
	return best_time


## Prints (once per process) the character height and where the picking
## hand is at each clip's grab time, to check the clips against the shelf.
func _report_fit(library: AnimationLibrary) -> void:
	if _fit_reported or not library.has_animation(ANIM_STAND):
		return
	_fit_reported = true
	var head := _bone_position_at(library.get_animation(ANIM_STAND), head_top_bone, 0.0)
	print("[customer] character height (%s, standing): %.3f m; walk clip ground speed %.3f m/s" % [
		head_top_bone, head.y, _walk_cycle_speed])
	for anim_name in PICK_ANIMS:
		if not library.has_animation(anim_name):
			continue
		var anim := library.get_animation(anim_name)
		var hand: Vector3 = _grab_hand_offsets[anim_name]
		var furthest := _furthest_reach_time(anim)
		print("[customer] %s: length %.3f s, grab_time %.3f s (furthest reach sampled at %.3f s), hand at grab: height %.3f m, forward %.3f m, right %.3f m" % [
			anim_name, anim.length, _grab_time(anim_name), furthest, hand.y, -hand.z, hand.x])
		if absf(furthest - _grab_time(anim_name)) > 0.05:
			push_warning("CustomerAgent: grab_time for %s differs from the sampled furthest reach (%.3f s)" % [anim_name, furthest])
