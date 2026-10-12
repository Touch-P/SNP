class_name StoreMain
extends Node3D
## Root of store_main.tscn. Bakes the navmesh at startup (shelf collision
## boxes, walls and floor are obstacles/walkable; products have no bodies so
## they are ignored) and exposes the store layout to RecordingManager.

signal store_ready

@export var navigation_region: NavigationRegion3D
@export var shelves_root: Node3D
@export var entrance: Marker3D
@export var exit_marker: Marker3D
## Area (floor plane, y ignored) where random wander waypoints are sampled.
@export var wander_bounds: AABB = AABB(Vector3(0.4, 0.0, -4.6), Vector3(5.2, 0.0, 7.2))

var is_store_ready: bool = false


func _ready() -> void:
	# CSG walls build their collision deferred; give them a frame first.
	await get_tree().process_frame
	navigation_region.bake_navigation_mesh(true)
	await navigation_region.bake_finished
	var polygons := navigation_region.navigation_mesh.get_polygon_count()
	if polygons == 0:
		push_error("StoreMain: navmesh bake produced no polygons")
	print("[store] navmesh baked: %d polygons" % polygons)
	# The navigation map syncs the new region a few physics frames later;
	# wait until it actually answers queries near the entrance.
	var map := get_world_3d().navigation_map
	for i in 300:
		await get_tree().physics_frame
		var closest := NavigationServer3D.map_get_closest_point(map, entrance.global_position)
		if NavigationServer3D.map_get_iteration_id(map) > 0 and closest.distance_to(entrance.global_position) < 1.0:
			break
	for shelf in get_shelves():
		shelf.update_pick_points(map)
	_report_slot_levels()
	is_store_ready = true
	store_ready.emit()


## Shelves sorted by shelf_id (stable order for seeded restocking).
func get_shelves() -> Array[ShelfUnit]:
	var result: Array[ShelfUnit] = []
	for node in shelves_root.find_children("*", "Node3D", true, false):
		if node is ShelfUnit:
			result.append(node)
	result.sort_custom(func(a: ShelfUnit, b: ShelfUnit) -> bool: return a.shelf_id < b.shelf_id)
	return result


## Prints the world-space height (slot marker = product bottom) of the bottom
## and top slot levels, for checking the pick animations against the shelf.
func _report_slot_levels() -> void:
	var bottom := INF
	var top := -INF
	for shelf in get_shelves():
		for slot in shelf.get_slots():
			if slot.is_bottom_level():
				bottom = minf(bottom, slot.global_position.y)
			if slot.is_top_level():
				top = maxf(top, slot.global_position.y)
	print("[store] slot levels (world y of product bottom): bottom=%.3f m  top=%.3f m" % [bottom, top])
