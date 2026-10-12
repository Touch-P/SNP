class_name RecordUI
extends CanvasLayer
## Record/Stop button, status label and a toggleable live preview grid of
## all shelf cameras (one TextureRect per ViewportTexture).
## Shortcuts: R = record/stop, P = toggle preview.

@export var recording_manager: RecordingManager
@export var thumbnail_size: Vector2 = Vector2(224, 126)
@export var preview_columns: int = 5

@onready var _record_button: Button = %RecordButton
@onready var _preview_button: Button = %PreviewButton
@onready var _status_label: Label = %StatusLabel
@onready var _preview_panel: PanelContainer = %PreviewPanel
@onready var _preview_grid: GridContainer = %PreviewGrid


func _ready() -> void:
	_record_button.pressed.connect(recording_manager.toggle_recording)
	_preview_button.toggled.connect(_on_preview_toggled)
	_preview_panel.visible = false
	_preview_grid.columns = preview_columns
	if recording_manager.is_ready_to_record():
		_build_preview_grid()
	else:
		recording_manager.cameras_ready.connect(_build_preview_grid, CONNECT_ONE_SHOT)


func _process(_delta: float) -> void:
	var state := recording_manager.state
	_status_label.text = recording_manager.get_status_text()
	_record_button.text = "Record" if state == RecordingManager.State.IDLE else "Stop"
	_record_button.disabled = (
		not recording_manager.is_ready_to_record()
		or state == RecordingManager.State.STOPPING
		or recording_manager.is_batch_mode())


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_R and not _record_button.disabled:
		recording_manager.toggle_recording()
	elif key.keycode == KEY_P:
		_preview_button.button_pressed = not _preview_button.button_pressed


func _on_preview_toggled(enabled: bool) -> void:
	_preview_panel.visible = enabled
	recording_manager.set_preview_enabled(enabled)


func _build_preview_grid() -> void:
	for child in _preview_grid.get_children():
		child.queue_free()
	for camera in recording_manager.cameras:
		var cell := VBoxContainer.new()
		var view := TextureRect.new()
		view.texture = camera.get_texture()
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		view.custom_minimum_size = thumbnail_size
		var label := Label.new()
		label.text = camera.camera_id
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 12)
		cell.add_child(view)
		cell.add_child(label)
		_preview_grid.add_child(cell)
