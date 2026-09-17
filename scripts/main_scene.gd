extends Node3D
## Attached to the main scene root (node_3d.tscn).
##
## The imported shelf/floor meshes carry no collision shapes of their own,
## so at startup this builds simple box colliders for the floor and for
## each "snack_shelf*" cluster from their combined visual bounding box.
## That's enough for the player controller to stand on the floor and
## bump into shelves without walking through them; it is not exact
## per-mesh collision (which would mean thousands of individual shapes).

func _ready() -> void:
	_build_floor_collision()
	_build_shelf_collision()


func _build_floor_collision() -> void:
	var floor_node: Node = get_node_or_null("floor")
	if floor_node == null:
		return
	var aabb := _world_aabb(floor_node)
	if aabb.size == Vector3.ZERO:
		return

	var body := StaticBody3D.new()
	body.name = "floor_collision"
	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = Vector3(aabb.size.x, 0.1, aabb.size.z)
	shape.shape = box
	var center := aabb.get_center()
	shape.position = Vector3(center.x, aabb.position.y - 0.05, center.z)
	body.add_child(shape)
	add_child(body)


func _build_shelf_collision() -> void:
	# The shelf unit is a top-level "shelf" node with a "snack_shelf"
	# product cluster nested underneath it, not a top-level "snack_shelf"
	# node itself, so match on "shelf" here to actually catch it.
	for child in get_children():
		if child is Node3D and child.name.begins_with("shelf"):
			var aabb := _world_aabb(child)
			if aabb.size == Vector3.ZERO:
				continue

			var body := StaticBody3D.new()
			body.name = str(child.name, "_collision")
			var shape := CollisionShape3D.new()
			shape.name = "CollisionShape3D"
			var box := BoxShape3D.new()
			box.size = aabb.size
			shape.shape = box
			shape.position = aabb.get_center()
			body.add_child(shape)
			add_child(body)


func _world_aabb(node: Node) -> AABB:
	# Assumes the scene root sits at an identity transform, so world space
	# and this node's local space coincide (true for node_3d.tscn today).
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
