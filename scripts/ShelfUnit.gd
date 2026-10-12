@tool
class_name ShelfUnit
extends Node3D
## Reusable shelf section built around the imported confectionery_shelf model.
##
## Local frame: origin = floor level at the centre of the shelf footprint,
## +Z points out of the product face into the aisle. Children:
##   Model        the imported GLB. At runtime only the shelf boards are kept
##                (see strip_baked_products) so every visible product is a
##                labeled ProductInstance.
##   Collision    StaticBody3D footprint box. The navmesh bakes around this;
##                products have no bodies, so they never affect it.
##   Slots        ShelfSlot markers for the front face.
##   PickPoint    where the customer stands to pick from the front face.
##   CameraMount  CCTV mount for the front face, placed from the exports below
##                (live in the editor, so it can be tuned per shelf instance).
## Double-sided shelves: enable double_sided and the back face gets mirrored
## slots / pick point / camera mount, unless SlotsBack, PickPointBack or
## CameraMountBack already exist as children.

const CAMERA_SCENE: PackedScene = preload("res://scenes/camera/cctv_camera.tscn")
const FACE_FRONT := "front"
const FACE_BACK := "back"

@export var shelf_id: String = "shelf_00"
## Outer size of the shelf body in metres (width, height, depth).
@export var shelf_size: Vector3 = Vector3(0.584, 0.78, 0.255):
	set(value):
		shelf_size = value
		_refresh_mounts()
@export var double_sided: bool = false

@export_group("Camera mount")
## Height of the camera above the floor.
@export_range(1.0, 4.0, 0.05, "suffix:m") var camera_height: float = 2.5:
	set(value):
		camera_height = value
		_refresh_mounts()
## Horizontal distance from the shelf face out into the aisle.
@export_range(0.3, 4.0, 0.05, "suffix:m") var camera_distance: float = 1.4:
	set(value):
		camera_distance = value
		_refresh_mounts()
## Sideways shift along the shelf; positive = to the right as seen by someone
## standing in the aisle facing this face. The camera keeps aiming at the face.
@export_range(-3.0, 3.0, 0.05, "suffix:m") var camera_lateral_offset: float = 0.0:
	set(value):
		camera_lateral_offset = value
		_refresh_mounts()
## Offset of the aim point from the face centre (x along the shelf, y up, z out).
@export var camera_target_offset: Vector3 = Vector3.ZERO:
	set(value):
		camera_target_offset = value
		_refresh_mounts()
@export_range(10.0, 120.0, 0.5, "suffix:deg") var camera_fov: float = 70.0
@export var camera_resolution: Vector2i = Vector2i(1280, 720)

@export_group("Model")
## Removes the products that are baked into the imported shelf model at
## runtime, keeping only the structure nodes (names starting with one of
## structure_name_prefixes). Unlabeled baked products would pollute the dataset.
@export var strip_baked_products: bool = true
@export var structure_name_prefixes: PackedStringArray = PackedStringArray(["Plane"])
@export var model_root_name: String = "RootNode"

var _faces: Array[Dictionary] = []
var _cameras: Array[ShelfCamera] = []


func _ready() -> void:
	if double_sided and not Engine.is_editor_hint():
		_ensure_back_face()
	_collect_faces()
	_refresh_mounts()
	if Engine.is_editor_hint():
		return

	add_to_group("shelf_units")
	if strip_baked_products:
		_strip_baked_products()
	for face in _faces:
		for child in (face["slots"] as Node).get_children():
			if child is ShelfSlot:
				child.shelf = self
				child.face = face["name"]
	_create_cameras()


func get_slots() -> Array[ShelfSlot]:
	var result: Array[ShelfSlot] = []
	for face in _faces:
		for child in (face["slots"] as Node).get_children():
			if child is ShelfSlot:
				result.append(child)
	return result


func get_cameras() -> Array[ShelfCamera]:
	return _cameras


func get_pick_point(face_name: String) -> Node3D:
	for face in _faces:
		if face["name"] == face_name:
			return face["pick"]
	return get_node_or_null("PickPoint")


## World-space unit vector pointing out of the given face into the aisle.
func get_face_normal(face_name: String) -> Vector3:
	var sign := -1.0 if face_name == FACE_BACK else 1.0
	return global_basis.z.normalized() * sign


func _collect_faces() -> void:
	_faces.clear()
	if has_node("Slots"):
		_faces.append({
			"name": FACE_FRONT,
			"sign": 1.0,
			"slots": get_node("Slots"),
			"pick": get_node_or_null("PickPoint"),
			"mount": get_node_or_null("CameraMount"),
		})
	if double_sided and has_node("SlotsBack") and get_node("SlotsBack").get_child_count() > 0:
		_faces.append({
			"name": FACE_BACK,
			"sign": -1.0,
			"slots": get_node("SlotsBack"),
			"pick": get_node_or_null("PickPointBack"),
			"mount": get_node_or_null("CameraMountBack"),
		})


## Creates the back face by mirroring the front one (180 deg about local Y).
func _ensure_back_face() -> void:
	var flip := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	if not has_node("SlotsBack") and has_node("Slots"):
		var back := Node3D.new()
		back.name = "SlotsBack"
		add_child(back)
		for child in get_node("Slots").get_children():
			if child is ShelfSlot:
				var mirrored := ShelfSlot.new()
				mirrored.name = "%s_back" % child.name
				mirrored.slot_id = "b_%s" % child.slot_id
				mirrored.transform = flip * (child as Node3D).transform
				back.add_child(mirrored)
	if not has_node("PickPointBack") and has_node("PickPoint"):
		var pick := Marker3D.new()
		pick.name = "PickPointBack"
		pick.transform = flip * (get_node("PickPoint") as Node3D).transform
		add_child(pick)
	if not has_node("CameraMountBack"):
		var mount := Marker3D.new()
		mount.name = "CameraMountBack"
		add_child(mount)


func _refresh_mounts() -> void:
	if not is_node_ready():
		return
	if _faces.is_empty():
		_collect_faces()
	for face in _faces:
		var mount := face["mount"] as Node3D
		if mount:
			mount.transform = _mount_transform(face["sign"])


func _mount_transform(sign: float) -> Transform3D:
	var face_center := Vector3(0.0, shelf_size.y * 0.5, sign * shelf_size.z * 0.5)
	var target := face_center + Vector3(
		camera_target_offset.x * sign, camera_target_offset.y, camera_target_offset.z * sign)
	var pos := Vector3(
		camera_lateral_offset * sign, camera_height, sign * (shelf_size.z * 0.5 + camera_distance))
	return Transform3D(Basis.looking_at(target - pos, Vector3.UP), pos)


func _strip_baked_products() -> void:
	var model := get_node_or_null("Model")
	if model == null:
		return
	var root := model.find_child(model_root_name, true, false)
	if root == null:
		push_warning("ShelfUnit %s: '%s' not found in Model, nothing stripped" % [shelf_id, model_root_name])
		return
	for child in root.get_children():
		if not _is_structure(String(child.name)):
			child.queue_free()


func _is_structure(node_name: String) -> bool:
	for prefix in structure_name_prefixes:
		if node_name.begins_with(prefix):
			return true
	return false


func _create_cameras() -> void:
	var multi_face := _faces.size() > 1
	for face in _faces:
		var mount := face["mount"] as Node3D
		if mount == null:
			continue
		var camera := CAMERA_SCENE.instantiate() as ShelfCamera
		camera.resolution = camera_resolution
		camera.fov = camera_fov
		add_child(camera)
		var camera_id := "%s_%s" % [shelf_id, face["name"]] if multi_face else shelf_id
		camera.setup(camera_id, shelf_id, face["name"], mount)
		_cameras.append(camera)
