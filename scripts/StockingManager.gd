class_name StockingManager
extends Node
## Loads the product class table and (re)stocks every shelf slot.
##
## Adding a product class only requires adding a row to products.json:
##   {"class_id": int, "name": str, "base_mesh": "box"|"bottle"|"can"|"pouch"|"cup",
##    "color": "#rrggbb", "size": [width, height, depth] (metres)}

@export_file("*.json") var catalog_path: String = "res://data/products.json"
@export var product_scene: PackedScene = preload("res://scenes/products/product_template.tscn")
## Probability that each slot gets a product.
@export_range(0.0, 1.0, 0.01) var fill_ratio: float = 0.8
## Max random offset (metres) of a product from its slot centre, in X and Z.
@export var position_jitter: float = 0.008
@export var yaw_jitter_degrees: float = 12.0

var classes: Array[Dictionary] = []

var _next_uid: int = 1


func _ready() -> void:
	load_catalog()


func load_catalog() -> bool:
	if not FileAccess.file_exists(catalog_path):
		push_error("StockingManager: catalog not found: %s" % catalog_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(catalog_path))
	if not parsed is Array:
		push_error("StockingManager: %s must contain a JSON list" % catalog_path)
		return false

	classes.clear()
	var seen_ids := {}
	for row: Variant in parsed:
		if not row is Dictionary:
			continue
		var size: Array = row.get("size", [0.08, 0.12, 0.08])
		var entry := {
			"class_id": int(row.get("class_id", -1)),
			"name": str(row.get("name", "unknown")),
			"base_mesh": str(row.get("base_mesh", "box")),
			"color": str(row.get("color", "#cccccc")),
			"size": [float(size[0]), float(size[1]), float(size[2])],
		}
		if seen_ids.has(entry["class_id"]):
			push_warning("StockingManager: duplicate class_id %d" % entry["class_id"])
		seen_ids[entry["class_id"]] = true
		classes.append(entry)
	print("[stocking] loaded %d product classes from %s" % [classes.size(), catalog_path])
	return not classes.is_empty()


## Clears every slot and refills it with probability fill_ratio, using the
## session RNG. Returns the number of stocked slots. instance_uid restarts at
## 1 so it is unique per session.
func restock(shelves: Array[ShelfUnit], rng: RandomNumberGenerator) -> int:
	_next_uid = 1
	var stocked := 0
	for shelf in shelves:
		for slot in shelf.get_slots():
			slot.clear()
			if classes.is_empty() or rng.randf() >= fill_ratio:
				continue
			var class_def: Dictionary = classes[rng.randi_range(0, classes.size() - 1)]
			var product := product_scene.instantiate() as ProductInstance
			product.setup(class_def, _next_uid)
			_next_uid += 1
			slot.place_product(product)
			product.position = Vector3(
				rng.randf_range(-position_jitter, position_jitter),
				0.0,
				rng.randf_range(-position_jitter, position_jitter))
			product.rotation.y = deg_to_rad(rng.randf_range(-yaw_jitter_degrees, yaw_jitter_degrees))
			stocked += 1
	print("[stocking] stocked %d slots" % stocked)
	return stocked


func get_stocked_slots(shelves: Array[ShelfUnit]) -> Array[ShelfSlot]:
	var result: Array[ShelfSlot] = []
	for shelf in shelves:
		for slot in shelf.get_slots():
			if slot.is_occupied():
				result.append(slot)
	return result


func get_class_table() -> Array[Dictionary]:
	return classes.duplicate(true)
