class_name ProductInstance
extends Node3D
## One product on a shelf (or in a basket).
##
## Purely visual: no physics body, so products never affect the navmesh.
## class_id / instance_uid are what the future labeling step keys on, so
## the same node is kept for the product's whole life (shelf -> basket).
## Origin is the bottom centre, so the node can sit directly on a slot marker.

@export var class_id: int = -1
@export var class_name_str: String = ""
## Unique per recording session (StockingManager resets the counter).
@export var instance_uid: int = -1
## Bounding size in metres: x = width, y = height, z = depth.
@export var size: Vector3 = Vector3(0.08, 0.12, 0.08)

# Mesh + material are shared between all products of the same class row.
static var _resource_cache: Dictionary = {}


## Configures this product from one row of res://data/products.json.
## Safe to call before the node enters the tree.
func setup(class_def: Dictionary, uid: int) -> void:
	class_id = int(class_def.get("class_id", -1))
	class_name_str = str(class_def.get("name", "unknown"))
	instance_uid = uid
	size = _parse_size(class_def.get("size", []))
	name = "%s_%d" % [class_name_str, uid]

	var key := JSON.stringify(class_def)
	if not _resource_cache.has(key):
		_resource_cache[key] = [
			_build_mesh(str(class_def.get("base_mesh", "box")), size),
			_build_material(str(class_def.get("color", "#cccccc"))),
		]
	var cached: Array = _resource_cache[key]
	var mesh_instance := get_node("Mesh") as MeshInstance3D
	mesh_instance.mesh = cached[0]
	mesh_instance.material_override = cached[1]
	mesh_instance.position = Vector3(0.0, size.y * 0.5, 0.0)


## Enables/disables every collision shape under this product. The template
## has none today; this keeps held / basket products out of physics if a
## product scene ever gains a body.
func set_collision_enabled(enabled: bool) -> void:
	for node in find_children("*", "CollisionShape3D", true, false):
		(node as CollisionShape3D).set_deferred("disabled", not enabled)


## World-space centre of the product's bounding box.
func get_center_global() -> Vector3:
	return global_transform * Vector3(0.0, size.y * 0.5, 0.0)


func to_dict() -> Dictionary:
	return {
		"class_id": class_id,
		"class_name": class_name_str,
		"instance_uid": instance_uid,
	}


static func _parse_size(value: Variant) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3(0.08, 0.12, 0.08)


static func _build_mesh(kind: String, s: Vector3) -> Mesh:
	var radius := s.x * 0.5
	match kind:
		"box", "pouch":
			var box := BoxMesh.new()
			box.size = s
			return box
		"can":
			return _cylinder(radius, radius, s.y)
		"bottle":
			return _cylinder(radius * 0.45, radius, s.y)
		"cup":
			return _cylinder(radius, radius * 0.75, s.y)
		_:
			push_warning("ProductInstance: unknown base_mesh '%s', using box" % kind)
			var fallback := BoxMesh.new()
			fallback.size = s
			return fallback


static func _cylinder(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = top_radius
	cylinder.bottom_radius = bottom_radius
	cylinder.height = height
	cylinder.radial_segments = 24
	cylinder.rings = 1
	return cylinder


static func _build_material(color_text: String) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_string(color_text, Color.MAGENTA)
	material.roughness = 0.55
	return material
