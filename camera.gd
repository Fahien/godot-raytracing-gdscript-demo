extends Camera3D

@export var auto_camera_enabled := true
@export var auto_camera_use_initial_pose := true
@export var auto_camera_target_path: NodePath
@export var auto_camera_target_position := Vector3.ZERO
@export var auto_camera_orbit_radius := 18.0
@export var auto_camera_height := 1.8
@export var auto_camera_orbit_speed := 0.25 # radians/sec
@export var auto_camera_bob_amplitude := 0.0
@export var auto_camera_bob_speed := 0.6
@export var auto_camera_start_angle_degrees := 0.0

var _auto_camera_time := 0.0
var _auto_camera_camera: Camera3D
var _auto_camera_target: Node3D
var _auto_camera_initialized := false

func _process(delta):
	_update_auto_camera(delta)

func _update_auto_camera(delta: float) -> void:
	if not auto_camera_enabled:
		return

	_auto_camera_time += delta

	var target_position := auto_camera_target_position
	var target_node := _get_auto_target()
	if target_node != null:
		target_position = target_node.global_position

	if auto_camera_use_initial_pose and not _auto_camera_initialized:
		_auto_camera_initialized = true
		var offset := self.global_position - target_position
		auto_camera_orbit_radius = max(0.001, Vector2(offset.x, offset.z).length())
		auto_camera_height = offset.y
		auto_camera_start_angle_degrees = rad_to_deg(atan2(offset.z, offset.x))

	var angle := deg_to_rad(auto_camera_start_angle_degrees) + _auto_camera_time * auto_camera_orbit_speed
	var height := auto_camera_height + sin(_auto_camera_time * auto_camera_bob_speed) * auto_camera_bob_amplitude
	var orbit_offset := Vector3(cos(angle) * auto_camera_orbit_radius, height, sin(angle) * auto_camera_orbit_radius)

	self.global_position = target_position + orbit_offset
	self.look_at(target_position, Vector3.UP)

func _get_auto_target() -> Node3D:
	if auto_camera_target_path == NodePath():
		return null
	if is_instance_valid(_auto_camera_target):
		return _auto_camera_target
	_auto_camera_target = get_node_or_null(auto_camera_target_path) as Node3D
	return _auto_camera_target
