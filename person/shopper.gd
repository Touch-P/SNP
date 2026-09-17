extends Node3D
## Simulated shopper behavior, for generating shopping trip data.
##
## Implements the "person" component from project-details/details.md:
## each trip the shopper randomly decides whether they are carrying a
## basket, then picks a random number of products (basket: 1-10 items,
## no basket: 1-2 items), walks to the shelf to "pick" them one at a
## time, and returns to their starting spot (used as both entry and
## exit) before starting a new trip.
##
## Movement is a simple waypoint walk rather than a baked NavigationMesh:
## the store layout is small and static, so a route via a safe aisle
## point in front of the shelf is enough to avoid clipping through it.
## Attach this script to the person avatar node in node_3d.tscn (or any
## Node3D that has a sibling node named "shelf" built the same way as
## the "shelf/snack_shelf" cluster).

@export var walk_speed: float = 1.2
@export var pick_seconds: float = 1.0
@export var arrive_distance: float = 0.12
@export var basket_chance: float = 0.5
@export var basket_item_range: Vector2i = Vector2i(1, 10)
@export var no_basket_item_range: Vector2i = Vector2i(1, 2)
@export var aisle_clearance: float = 0.6
## Path (relative to this node) to the shelf's product cluster used to
## compute where the shopper stands to pick items.
@export var shelf_path: NodePath = NodePath("../shelf/snack_shelf")

enum State { WALK, PICKING }

var _state: State = State.WALK
var _entry_position: Vector3
var _route: Array[Vector3] = []
var _route_index: int = 0
var _items_remaining: int = 0
var _has_basket: bool = false
var _pick_timer: float = 0.0
var _basket_mesh: MeshInstance3D
var _shelf_aabb: AABB


func _ready() -> void:
	_entry_position = position
	_basket_mesh = _make_basket_mesh()
	add_child(_basket_mesh)

	var shelf: Node = get_node_or_null(shelf_path)
	if shelf:
		_shelf_aabb = _world_aabb(shelf)

	_start_new_trip()


func _process(delta: float) -> void:
	match _state:
		State.WALK:
			_walk_route(delta)
		State.PICKING:
			_pick_timer -= delta
			if _pick_timer <= 0.0:
				_finish_one_pick()


func _start_new_trip() -> void:
	_has_basket = randf() < basket_chance
	_items_remaining = (
		randi_range(basket_item_range.x, basket_item_range.y)
		if _has_basket
		else randi_range(no_basket_item_range.x, no_basket_item_range.y)
	)
	_basket_mesh.visible = _has_basket
	print(
		"[shopper] new trip: basket=%s target_items=%d"
		% [_has_basket, _items_remaining]
	)
	_route = _build_route_to_shelf()
	_route_index = 0
	_state = State.WALK


func _build_route_to_shelf() -> Array[Vector3]:
	var route: Array[Vector3] = []
	if _shelf_aabb.size == Vector3.ZERO:
		# No shelf found; nothing to shop for, so just idle at the entry.
		return route

	var pick_x: float = randf_range(_shelf_aabb.position.x, _shelf_aabb.position.x + _shelf_aabb.size.x)
	var shelf_front_z: float = _shelf_aabb.position.z + _shelf_aabb.size.z
	var aisle_z: float = shelf_front_z + aisle_clearance
	var y: float = _entry_position.y

	# Walk out to a safe aisle line first (clear of the shelf's footprint),
	# slide sideways to line up with the picked product, then step up to
	# the shelf face. Avoids cutting a diagonal straight through the shelf.
	route.append(Vector3(_entry_position.x, y, aisle_z))
	route.append(Vector3(pick_x, y, aisle_z))
	route.append(Vector3(pick_x, y, shelf_front_z + 0.15))
	return route


func _build_route_to_exit() -> Array[Vector3]:
	var route: Array[Vector3] = []
	if _shelf_aabb.size == Vector3.ZERO:
		return route
	var shelf_front_z: float = _shelf_aabb.position.z + _shelf_aabb.size.z
	var aisle_z: float = shelf_front_z + aisle_clearance
	var y: float = _entry_position.y
	# Mirror the inbound route: back out to the aisle, slide to the
	# entry's x, then walk home.
	route.append(Vector3(position.x, y, aisle_z))
	route.append(Vector3(_entry_position.x, y, aisle_z))
	route.append(_entry_position)
	return route


func _walk_route(delta: float) -> void:
	if _route.is_empty():
		# Nothing to walk to (e.g. shelf not found) - just wait a beat and retry.
		_pick_timer = pick_seconds
		_state = State.PICKING
		return

	var target: Vector3 = _route[_route_index]
	var to_target: Vector3 = target - position
	to_target.y = 0.0

	if to_target.length() <= arrive_distance:
		_route_index += 1
		if _route_index >= _route.size():
			_on_route_finished()
		return

	var step: float = walk_speed * delta
	var dir: Vector3 = to_target.normalized()
	position += dir * min(step, to_target.length())
	if dir.length_squared() > 0.0001:
		rotation.y = atan2(dir.x, dir.z)


func _on_route_finished() -> void:
	# Reaching the end of the inbound route means we're at the shelf;
	# reaching the end of the outbound route means we're home.
	if position.distance_to(_entry_position) <= arrive_distance and _items_remaining <= 0:
		_start_new_trip()
	else:
		_pick_timer = pick_seconds
		_state = State.PICKING


func _finish_one_pick() -> void:
	_items_remaining -= 1
	print("[shopper] picked an item, %d remaining" % _items_remaining)
	if _items_remaining > 0:
		# Pick another random spot along the shelf for the next item.
		var pick_x: float = randf_range(_shelf_aabb.position.x, _shelf_aabb.position.x + _shelf_aabb.size.x)
		var shelf_front_z: float = _shelf_aabb.position.z + _shelf_aabb.size.z
		_route = [Vector3(pick_x, position.y, shelf_front_z + 0.15)]
		_route_index = 0
		_state = State.WALK
	else:
		_route = _build_route_to_exit()
		_route_index = 0
		_state = State.WALK


func _make_basket_mesh() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BasketVisual"
	var box := BoxMesh.new()
	box.size = Vector3(0.35, 0.25, 0.25)
	mesh_instance.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.55, 0.35, 0.15)
	mesh_instance.material_override = material
	mesh_instance.position = Vector3(0.35, 1.0, 0.15)
	mesh_instance.visible = false
	return mesh_instance


func _world_aabb(node: Node) -> AABB:
	var result := AABB()
	var first := true
	for mesh_instance in _find_mesh_instances(node):
		var transformed: AABB = mesh_instance.global_transform * mesh_instance.get_aabb()
		if first:
			result = transformed
			first = false
		else:
			result = result.merge(transformed)
	return result


func _find_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for child in node.get_children():
		if child is MeshInstance3D:
			result.append(child)
		result.append_array(_find_mesh_instances(child))
	return result
