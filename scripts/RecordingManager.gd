class_name RecordingManager
extends Node
## Runs recording sessions and captures ALL shelf cameras in sync.
##
## Synchronisation: there is one capture tick, driven by accumulated sim time
## (sum of frame deltas since the session started). On a tick we await
## RenderingServer.frame_post_draw, and then read every camera's SubViewport
## in the same loop. All viewports were rendered in that same draw, so frame
## k of every camera shows the same simulation instant and gets the same
## frame_index / sim_time. JPEG encoding + disk I/O run on WorkerThreadPool;
## get_image() stays on the main thread.
##
## Batch mode:  godot --path . -- --auto-record=5 [--seed=123]
## (never --headless: the dummy renderer produces no images).

signal session_started(run_name: String)
signal session_saved(run_dir: String)
signal cameras_ready

enum State { IDLE, RECORDING, STOPPING }

@export var store: StoreMain
@export var stocking_manager: StockingManager
@export var event_logger: EventLogger
@export var customers_root: Node3D
@export var customer_scene: PackedScene = preload("res://scenes/agent/customer_agent.tscn")
@export_range(1.0, 60.0, 1.0) var capture_fps: float = 10.0
@export var stop_delay_after_exit: float = 1.0
## Safety net: a session never records longer than this (sim seconds).
@export var max_session_seconds: float = 300.0
@export_range(0.0, 1.0, 0.01) var jpg_quality: float = 0.9
## Show a warning when more save jobs than this are queued.
@export var max_pending_jobs: int = 100
## Refresh rate of the live preview grid while not recording.
@export var preview_fps: float = 2.0

var state: State = State.IDLE
var run_name: String = ""
var run_dir: String = ""
var last_saved_dir: String = ""
var sim_time: float = 0.0
var frames_captured: int = 0
var session_seed: int = 0
var customer: CustomerAgent
var cameras: Array[ShelfCamera] = []
var preview_enabled: bool = false

var _rng := RandomNumberGenerator.new()
var _seed_source := RandomNumberGenerator.new()
var _forced_seed: int = -1
var _session_count: int = 0
var _auto_sessions: int = 0
var _next_capture_time: float = 0.0
var _capture_busy: bool = false
var _pending_frame_index: int = 0
var _first_frame: bool = true
var _skipped_ticks: int = 0
var _invalid_images: int = 0
var _stop_at: float = -1.0
var _stop_reason: String = ""
var _stocked_count: int = 0
var _jobs: Array[int] = []
var _peak_pending: int = 0
var _frames_file: FileAccess
var _preview_timer: float = 0.0
var _started_at: String = ""


func _ready() -> void:
	_seed_source.randomize()
	_parse_cmdline()
	if DisplayServer.get_name() == "headless":
		push_error("RecordingManager: running with --headless uses a dummy renderer, viewports produce no images. Run without --headless.")
		if _auto_sessions > 0:
			get_tree().quit(1)
			return
	if store.is_store_ready:
		_on_store_ready()
	else:
		store.store_ready.connect(_on_store_ready, CONNECT_ONE_SHOT)


func is_ready_to_record() -> bool:
	return store != null and store.is_store_ready and not cameras.is_empty()


func is_batch_mode() -> bool:
	return _auto_sessions > 0


func toggle_recording() -> void:
	match state:
		State.IDLE:
			start_session()
		State.RECORDING:
			stop_session("manual")


func set_preview_enabled(enabled: bool) -> void:
	preview_enabled = enabled
	_preview_timer = 0.0
	if state == State.IDLE:
		_apply_idle_update_mode()


func get_sim_time() -> float:
	return sim_time


## frame_index for an event happening now: the frame currently being
## captured if a tick is in flight, otherwise the next frame to be captured.
func get_current_frame_index() -> int:
	return _pending_frame_index if _capture_busy else frames_captured + 1


func get_pending_jobs() -> int:
	return _jobs.size()


func get_export_root() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://export")
	return ProjectSettings.globalize_path("user://export")


# --- session lifecycle -------------------------------------------------------

func start_session() -> bool:
	if state != State.IDLE or not is_ready_to_record():
		return false

	# 1. New seed, restock, (customer spawns below once the logger is open).
	session_seed = (_forced_seed + _session_count) if _forced_seed >= 0 else int(_seed_source.randi())
	_session_count += 1
	_rng.seed = session_seed
	print("[rec] ---- new session, seed=%d ----" % session_seed)
	_remove_customer()
	var shelves := store.get_shelves()
	_stocked_count = stocking_manager.restock(shelves, _rng)

	# 2. Run folder + output files.
	var root := get_export_root()
	DirAccess.make_dir_recursive_absolute(root)
	if not FileAccess.file_exists(root.path_join(".gdignore")):
		# Keeps the editor from importing thousands of dataset JPEGs.
		FileAccess.open(root.path_join(".gdignore"), FileAccess.WRITE)
	run_name = _make_run_name(root)
	run_dir = root.path_join(run_name)
	var err := DirAccess.make_dir_recursive_absolute(run_dir.path_join("images"))
	if err != OK:
		push_error("RecordingManager: cannot create %s (%s)" % [run_dir, error_string(err)])
		return false
	_frames_file = FileAccess.open(run_dir.path_join("frames.csv"), FileAccess.WRITE)
	_frames_file.store_line("frame_index,sim_time,camera_id,image_file")
	event_logger.begin(run_dir.path_join("events.csv"), cameras, get_sim_time, get_current_frame_index)

	sim_time = 0.0
	frames_captured = 0
	_next_capture_time = 0.0
	_first_frame = true
	_skipped_ticks = 0
	_invalid_images = 0
	_peak_pending = 0
	_stop_at = -1.0
	_stop_reason = ""
	_started_at = Time.get_datetime_string_from_system(false, true)

	customer = customer_scene.instantiate() as CustomerAgent
	customers_root.add_child(customer)
	customer.global_transform = store.entrance.global_transform
	customer.finished.connect(_on_customer_finished)
	customer.begin(_rng, stocking_manager.get_stocked_slots(shelves), store.exit_marker.global_position,
		store.wander_bounds, event_logger, "customer_1")

	# Start recording all cameras.
	for camera in cameras:
		camera.set_render_mode(SubViewport.UPDATE_ALWAYS)
	state = State.RECORDING
	print("[rec] recording %d cameras to %s" % [cameras.size(), run_dir])
	session_started.emit(run_name)
	return true


func stop_session(reason: String) -> void:
	if state != State.RECORDING:
		return
	state = State.STOPPING
	_stop_reason = reason
	print("[rec] stopping (%s) at sim_time=%.2f, %d frames" % [reason, sim_time, frames_captured])
	while _capture_busy:
		await RenderingServer.frame_post_draw

	var items_to_pick := 0
	var walk_speed := 0.0
	var picked: Array[Dictionary] = []
	var basket: Array[Dictionary] = []
	var in_hand := 0
	if is_instance_valid(customer):
		items_to_pick = customer.items_to_pick
		walk_speed = customer.walk_speed
		picked = customer.picked_items.duplicate(true)
		basket = customer.get_basket_contents()
		in_hand = customer.get_held_products().size()
	var on_shelves := _count_shelf_products()
	var stock_ok := on_shelves + basket.size() + in_hand == _stocked_count
	print("[rec] stock check: stocked=%d on_shelves=%d basket=%d in_hand=%d -> %s" % [
		_stocked_count, on_shelves, basket.size(), in_hand, "OK" if stock_ok else "MISMATCH"])
	if not stock_ok:
		push_error("RecordingManager: products not conserved (see stock check above)")
	_remove_customer()
	_apply_idle_update_mode()

	while not _jobs.is_empty():
		_poll_jobs()
		await get_tree().process_frame
	if _frames_file:
		_frames_file.close()
		_frames_file = null
	event_logger.end()

	_write_json(run_dir.path_join("cameras.json"), _cameras_metadata())
	_write_json(run_dir.path_join("session.json"), {
		"run_name": run_name,
		"seed": session_seed,
		"started_at": _started_at,
		"stop_reason": _stop_reason,
		"capture_fps": capture_fps,
		"total_frames": frames_captured,
		"num_cameras": cameras.size(),
		"total_images": frames_captured * cameras.size(),
		"sim_duration": sim_time,
		"skipped_capture_ticks": _skipped_ticks,
		"invalid_images": _invalid_images,
		"peak_pending_save_jobs": _peak_pending,
		"items_to_pick": items_to_pick,
		"items_picked": picked.size(),
		"picked_items": picked,
		"basket_contents": basket,
		"stocked_slots": _stocked_count,
		"total_slots": _count_slots(),
		"fill_ratio": stocking_manager.fill_ratio,
		"stock_check": {
			"stocked": _stocked_count,
			"on_shelves_at_end": on_shelves,
			"in_basket_at_end": basket.size(),
			"in_hand_at_end": in_hand,
			"conserved": stock_ok,
		},
		"customer": {"agent_id": "customer_1", "walk_speed": walk_speed},
		"product_classes": stocking_manager.get_class_table(),
		"engine_version": Engine.get_version_info()["string"],
		"notes": {
			"camera_ids_visible": "APPROXIMATE: Camera3D.is_position_in_frustum on the product centre (agent position + 1 m for enter/exit); no occlusion check.",
			"frame_index": "1-based; events.csv frame_index = first captured frame with sim_time >= the event time.",
			"sim_time": "Seconds of simulation since the session started (sum of frame deltas). All cameras of a frame share it.",
		},
	})

	last_saved_dir = run_dir
	state = State.IDLE
	print("[rec] Saved to %s" % run_dir)
	session_saved.emit(run_dir)


# --- per-frame --------------------------------------------------------------

func _process(delta: float) -> void:
	_poll_jobs()
	match state:
		State.RECORDING:
			if _first_frame:
				# The state drawn this frame is the t = 0 state (fresh restock).
				_first_frame = false
			else:
				sim_time += delta
			if _stop_at >= 0.0 and sim_time >= _stop_at:
				stop_session("auto")
				return
			if sim_time >= max_session_seconds:
				stop_session("timeout")
				return
			if not _capture_busy and sim_time + 1e-6 >= _next_capture_time:
				_capture_tick()
				var interval := 1.0 / capture_fps
				_next_capture_time += interval
				while _next_capture_time <= sim_time:
					_next_capture_time += interval
					_skipped_ticks += 1
		State.IDLE:
			_update_preview(delta)


func _capture_tick() -> void:
	_capture_busy = true
	var frame_index := frames_captured + 1
	_pending_frame_index = frame_index
	var tick_time := sim_time
	var target_dir := run_dir

	await RenderingServer.frame_post_draw

	# Every SubViewport was rendered in the draw that just finished.
	for camera in cameras:
		var image := camera.capture_image()
		if image == null or image.is_empty():
			_invalid_images += 1
			push_error("RecordingManager: empty image from %s at frame %d" % [camera.camera_id, frame_index])
			image = Image.create(camera.resolution.x, camera.resolution.y, false, Image.FORMAT_RGB8)
		var image_file := "images/%s_f%06d.jpg" % [camera.camera_id, frame_index]
		_queue_save(image, target_dir.path_join(image_file))
		_frames_file.store_line("%d,%.4f,%s,%s" % [frame_index, tick_time, camera.camera_id, image_file])
	frames_captured = frame_index
	_capture_busy = false


func _queue_save(image: Image, path: String) -> void:
	var quality := jpg_quality
	var task_id := WorkerThreadPool.add_task(
		func() -> void:
			var err := image.save_jpg(path, quality)
			if err != OK:
				push_error("save_jpg failed for %s: %s" % [path, error_string(err)]),
		false, "save_jpg")
	_jobs.append(task_id)
	_peak_pending = maxi(_peak_pending, _jobs.size())


func _poll_jobs() -> void:
	for i in range(_jobs.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_jobs[i]):
			WorkerThreadPool.wait_for_task_completion(_jobs[i])
			_jobs.remove_at(i)


func _update_preview(delta: float) -> void:
	if not preview_enabled or preview_fps <= 0.0:
		return
	_preview_timer += delta
	if _preview_timer >= 1.0 / preview_fps:
		_preview_timer = 0.0
		for camera in cameras:
			camera.set_render_mode(SubViewport.UPDATE_ONCE)


func _apply_idle_update_mode() -> void:
	for camera in cameras:
		camera.set_render_mode(SubViewport.UPDATE_ONCE if preview_enabled else SubViewport.UPDATE_DISABLED)


# --- status ----------------------------------------------------------------

func get_status_text() -> String:
	if not is_ready_to_record():
		return "Preparing store (baking navmesh)..."
	var lines := PackedStringArray()
	match state:
		State.IDLE:
			lines.append("Idle - press Record  (%d cameras)" % cameras.size())
			if last_saved_dir != "":
				lines.append("Saved to %s" % last_saved_dir)
		_:
			var picked := customer.picked_items.size() if is_instance_valid(customer) else 0
			var total := customer.items_to_pick if is_instance_valid(customer) else 0
			lines.append("Run: %s   seed %d" % [run_name, session_seed])
			lines.append("Frames: %d  (x %d cameras)" % [frames_captured, cameras.size()])
			lines.append("Items picked: %d / %d" % [picked, total])
			lines.append("Sim time: %.1f s" % sim_time)
			lines.append("Pending save jobs: %d" % _jobs.size())
			if _jobs.size() > max_pending_jobs:
				lines.append("WARNING: disk writes falling behind (%d jobs pending)" % _jobs.size())
			if state == State.STOPPING:
				lines.append("Stopping - flushing writes...")
	return "\n".join(lines)


# --- helpers -----------------------------------------------------------------

func _on_store_ready() -> void:
	cameras.clear()
	for shelf in store.get_shelves():
		cameras.append_array(shelf.get_cameras())
	cameras.sort_custom(func(a: ShelfCamera, b: ShelfCamera) -> bool: return a.camera_id < b.camera_id)
	_apply_idle_update_mode()
	print("[rec] ready: %d shelf cameras" % cameras.size())
	cameras_ready.emit()
	if _auto_sessions > 0:
		_run_batch()


func _run_batch() -> void:
	for i in _auto_sessions:
		print("[batch] session %d / %d" % [i + 1, _auto_sessions])
		if not start_session():
			push_error("[batch] could not start session %d" % (i + 1))
			break
		await session_saved
		await get_tree().process_frame
	print("[batch] done, quitting")
	get_tree().quit()


func _on_customer_finished() -> void:
	_stop_at = sim_time + stop_delay_after_exit


func _remove_customer() -> void:
	if is_instance_valid(customer):
		customer.cancel()
		customer.get_parent().remove_child(customer)
		customer.queue_free()
	customer = null


func _parse_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--auto-record":
			_auto_sessions = 1
		elif arg.begins_with("--auto-record="):
			_auto_sessions = maxi(1, arg.get_slice("=", 1).to_int())
		elif arg.begins_with("--seed="):
			_forced_seed = absi(arg.get_slice("=", 1).to_int())
		elif arg.begins_with("--capture-fps="):
			capture_fps = maxf(1.0, arg.get_slice("=", 1).to_float())
	if _auto_sessions > 0:
		print("[batch] auto-record %d sessions" % _auto_sessions)


func _make_run_name(root: String) -> String:
	var d := Time.get_datetime_dict_from_system()
	var base := "run_%04d_%02d_%02d_%02d%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]
	var candidate := base
	var n := 2
	while DirAccess.dir_exists_absolute(root.path_join(candidate)):
		candidate = "%s_%d" % [base, n]
		n += 1
	return candidate


func _cameras_metadata() -> Array:
	var result := []
	for camera in cameras:
		result.append(camera.get_metadata())
	return result


## Product nodes still physically on the shelves (children of slots).
func _count_shelf_products() -> int:
	var total := 0
	for shelf in store.get_shelves():
		for slot in shelf.get_slots():
			total += slot.count_products()
	return total


func _count_slots() -> int:
	var total := 0
	for shelf in store.get_shelves():
		total += shelf.get_slots().size()
	return total


func _write_json(path: String, data: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("RecordingManager: cannot write %s" % path)
		return
	file.store_string(JSON.stringify(data, "  ", false))
	file.close()
