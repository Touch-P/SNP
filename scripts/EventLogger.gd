class_name EventLogger
extends Node
## Writes events.csv for one recording session.
##
## frame_index is the first captured frame whose sim_time is >= the event's
## sim_time (i.e. the first frame that shows the state after the event).
## camera_ids_visible is APPROXIMATE: a frustum test only, with no occlusion
## check. Cameras are joined with ';'. pick_anim is the animation played for
## pick_start / pick_end rows and empty for every other action.

const HEADER := "sim_time,frame_index,agent_id,action,class_id,class_name,instance_uid,shelf_id,slot_id,camera_ids_visible,pick_anim"

## All rows logged in the current session, as dictionaries.
var events: Array[Dictionary] = []

var _file: FileAccess
var _cameras: Array[ShelfCamera] = []
var _time_source: Callable
var _frame_source: Callable


func begin(path: String, cameras: Array[ShelfCamera], time_source: Callable, frame_source: Callable) -> bool:
	end()
	events.clear()
	_cameras = cameras
	_time_source = time_source
	_frame_source = frame_source
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		push_error("EventLogger: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return false
	_file.store_line(HEADER)
	return true


## Logs one event and returns the row. Product events use the product centre
## for the visibility test; agent-only events (enter/exit) use `fallback_position`.
func log_event(action: String, agent_id: String, product: ProductInstance = null,
		slot: ShelfSlot = null, fallback_position: Vector3 = Vector3.ZERO,
		pick_anim: String = "") -> Dictionary:
	var point := product.get_center_global() if product else fallback_position
	var visible := PackedStringArray()
	for camera in _cameras:
		if camera.is_point_in_view(point):
			visible.append(camera.camera_id)

	var row := {
		"sim_time": float(_time_source.call()) if _time_source.is_valid() else 0.0,
		"frame_index": int(_frame_source.call()) if _frame_source.is_valid() else 0,
		"agent_id": agent_id,
		"action": action,
		"class_id": product.class_id if product else -1,
		"class_name": product.class_name_str if product else "",
		"instance_uid": product.instance_uid if product else -1,
		"shelf_id": slot.shelf.shelf_id if slot and slot.shelf else "",
		"slot_id": slot.slot_id if slot else "",
		"camera_ids_visible": ";".join(visible),
		"pick_anim": pick_anim,
	}
	events.append(row)

	if _file:
		_file.store_line(",".join(PackedStringArray([
			"%.4f" % row["sim_time"],
			str(row["frame_index"]),
			row["agent_id"],
			row["action"],
			str(row["class_id"]) if product else "",
			row["class_name"],
			str(row["instance_uid"]) if product else "",
			row["shelf_id"],
			row["slot_id"],
			row["camera_ids_visible"],
			row["pick_anim"],
		])))
	print("[event] t=%.2f f=%d %s %s %s" % [row["sim_time"], row["frame_index"], action, row["class_name"], row["slot_id"]])
	return row


## Session sim_time / frame_index "now", as they would be logged.
func get_sim_time() -> float:
	return float(_time_source.call()) if _time_source.is_valid() else 0.0


func get_frame_index() -> int:
	return int(_frame_source.call()) if _frame_source.is_valid() else 0


func end() -> void:
	if _file:
		_file.close()
		_file = null
