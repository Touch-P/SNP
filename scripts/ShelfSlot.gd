class_name ShelfSlot
extends Marker3D
## One product position on a shelf face.
##
## The marker origin is where the product's bottom centre sits; +Z points
## out of the shelf face towards the aisle. `shelf`, `face`, `level`,
## `level_count` and `pick_point` are filled in by the owning ShelfUnit at
## runtime.

@export var slot_id: String = ""

var occupied_product: ProductInstance = null
var shelf: ShelfUnit = null
var face: String = "front"
## 0 = bottom level of this face, level_count - 1 = top level.
var level: int = 0
var level_count: int = 1
## Where a customer stands to pick from this slot: in front of the slot on
## the aisle side, snapped onto the navmesh (world space, floor height).
var pick_point: Vector3 = Vector3.ZERO
var has_pick_point: bool = false


func is_occupied() -> bool:
	return occupied_product != null and is_instance_valid(occupied_product)


func is_top_level() -> bool:
	return level == level_count - 1


func is_bottom_level() -> bool:
	return level == 0


## Puts `product` in this slot (parenting it here at the slot origin).
func place_product(product: ProductInstance) -> void:
	var parent := product.get_parent()
	if parent == null:
		add_child(product)
	elif parent != self:
		product.reparent(self, false)
	product.transform = Transform3D.IDENTITY
	occupied_product = product


## Releases the slot's claim on its product and returns it. Does not touch
## the scene tree: the caller decides where the node goes (e.g. a hand).
func take_product() -> ProductInstance:
	var product := occupied_product
	occupied_product = null
	return product


## Frees any product nodes still parented to this slot.
func clear() -> void:
	for child in get_children():
		if child is ProductInstance:
			remove_child(child)
			child.queue_free()
	occupied_product = null


## Number of product nodes physically parented to this slot (0 or 1).
func count_products() -> int:
	var count := 0
	for child in get_children():
		if child is ProductInstance:
			count += 1
	return count


## Places pick_point `standoff` metres out of the face (horizontally), at
## floor height, then snaps it onto the navigation map.
func update_pick_point(map: RID, standoff: float, floor_y: float) -> void:
	var normal := shelf.get_face_normal(face)
	normal.y = 0.0
	var wanted := global_position + normal.normalized() * standoff
	wanted.y = floor_y
	pick_point = NavigationServer3D.map_get_closest_point(map, wanted)
	has_pick_point = true
