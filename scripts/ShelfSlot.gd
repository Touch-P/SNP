class_name ShelfSlot
extends Marker3D
## One product position on a shelf face.
##
## The marker origin is where the product's bottom centre sits; +Z points
## out of the shelf face towards the aisle. `shelf` and `face` are filled in
## by the owning ShelfUnit at runtime.

@export var slot_id: String = ""

var occupied_product: ProductInstance = null
var shelf: ShelfUnit = null
var face: String = "front"


func is_occupied() -> bool:
	return occupied_product != null and is_instance_valid(occupied_product)


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
## the scene tree: the caller decides where the node goes (e.g. a basket).
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
