class_name ShelfCamera
extends SubViewport
## Fixed CCTV-style camera for one shelf face.
##
## A SubViewport with own_world_3d = false, so it renders the main World3D.
## The Camera3D under a SubViewport does not inherit any Node3D transform,
## so setup() copies the mount's global_transform once (cameras are static).
## Update mode is driven by RecordingManager: UPDATE_ALWAYS while recording,
## disabled or occasional UPDATE_ONCE (preview) otherwise.

@export var resolution: Vector2i = Vector2i(1280, 720)
@export_range(10.0, 120.0, 0.5, "suffix:deg") var fov: float = 70.0

var camera_id: String = ""
var shelf_id: String = ""
var face: String = "front"

@onready var camera: Camera3D = $Camera3D


func setup(p_camera_id: String, p_shelf_id: String, p_face: String, mount: Node3D) -> void:
	camera_id = p_camera_id
	shelf_id = p_shelf_id
	face = p_face
	name = "CCTV_%s" % camera_id
	size = resolution
	camera.fov = fov
	camera.global_transform = mount.global_transform
	add_to_group("shelf_cameras")
	set_render_mode(SubViewport.UPDATE_DISABLED)


func set_render_mode(mode: SubViewport.UpdateMode) -> void:
	render_target_update_mode = mode


## Must be called on the main thread, after RenderingServer.frame_post_draw.
func capture_image() -> Image:
	return get_texture().get_image()


## Frustum-only test (no occlusion), used for events.csv camera_ids_visible.
func is_point_in_view(world_point: Vector3) -> bool:
	return camera.is_position_in_frustum(world_point)


func get_metadata() -> Dictionary:
	var t := camera.global_transform
	var focal := (resolution.y * 0.5) / tan(deg_to_rad(camera.fov) * 0.5)
	return {
		"camera_id": camera_id,
		"shelf_id": shelf_id,
		"face": face,
		"resolution": [resolution.x, resolution.y],
		"fov": camera.fov,
		"fov_axis": "vertical",
		"near": camera.near,
		"far": camera.far,
		"global_transform": {
			"origin": _vec(t.origin),
			"basis_x": _vec(t.basis.x),
			"basis_y": _vec(t.basis.y),
			"basis_z": _vec(t.basis.z),
			"matrix_row_major": [
				[t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x],
				[t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y],
				[t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z],
				[0.0, 0.0, 0.0, 1.0],
			],
		},
		"intrinsics_px": {"fx": focal, "fy": focal, "cx": resolution.x * 0.5, "cy": resolution.y * 0.5},
		"convention": "Godot camera-to-world transform; camera looks along -basis_z, +basis_y is up, +basis_x is right; image origin top-left",
	}


static func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]
