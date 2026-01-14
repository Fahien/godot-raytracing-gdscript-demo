@tool
extends CompositorEffect
class_name RaytracedAmbientOcclusion

static func _free_rid(dev: RenderingDevice, rid: RID):
	if rid.is_valid():
		dev.free_rid(rid)

class CustomStorageBuffer:
	var buffer := RID()
	var size_bytes := 0

	func update(rd: RenderingDevice, bytes: PackedByteArray):
		assert(bytes != null)
		assert(bytes.size() != 0)
		var current_size_bytes = bytes.size()
		if current_size_bytes > size_bytes:
			size_bytes = current_size_bytes
			RaytracedAmbientOcclusion._free_rid(rd, buffer)
			buffer = rd.storage_buffer_create(current_size_bytes, bytes)
			assert(buffer != RID())
		else:
			rd.buffer_update(buffer, 0, current_size_bytes, bytes)

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var blases := []
var instances_buffer: RID
var tlas: RID

var vertex_storage := CustomStorageBuffer.new()
var index_storage := CustomStorageBuffer.new()
var transform_storage := CustomStorageBuffer.new()
var normal_storage := CustomStorageBuffer.new()
var uniform_set := RID()

var blue_noise := RID()


# Can not use @onready with CompositorEffect
func _init():
	_create_rendering_resources()
	_load_blue_noise()

func _create_rendering_resources():
	rd = RenderingServer.get_rendering_device()
	# Create raytracing shaders.
	var shader_file := load("res://raytraced_ambient_occlusion.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.raytracing_pipeline_create(shader)

func _load_blue_noise():
	var blue_noise_image = Image.new()
	blue_noise_image.load("res://assets/blue-noise.png")
	var format = RDTextureFormat.new()
	format.width = blue_noise_image.get_width()
	format.height = blue_noise_image.get_height()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM;
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT;
	blue_noise = rd.texture_create(format, RDTextureView.new(), [blue_noise_image.get_data()])
	assert(blue_noise != RID())

func _notification(p_what: int):
	if p_what == NOTIFICATION_PREDELETE:
		_free_rid(rd, uniform_set)
		_free_rid(rd, normal_storage.buffer)
		_free_rid(rd, transform_storage.buffer)
		_free_rid(rd, vertex_storage.buffer)
		_free_rid(rd, index_storage.buffer)
		_free_rid(rd, tlas)

		_free_rid(rd, instances_buffer)

		for blas in blases:
			_free_rid(rd, blas)

		_free_rid(rd, blue_noise)
		_free_rid(rd, pipeline)
		_free_rid(rd, shader)

func _free_acceleration_structures():
	_free_rid(rd, tlas)
	tlas = RID()
	_free_rid(rd, instances_buffer)
	instances_buffer = RID()

	for blas in blases:
		_free_rid(rd, blas)
	blases.clear()

func _get_vertex_buffer_address(vertex_array: RID, buffer_index: RenderingServer.ArrayType):
	assert(vertex_array.is_valid())
	var buffer = rd.vertex_array_get_buffer(vertex_array, buffer_index)
	assert(buffer.is_valid())
	var buffer_offset = rd.vertex_array_get_buffer_offset(vertex_array, buffer_index)
	var address = rd.buffer_get_device_address(buffer)
	return address + buffer_offset

func _get_index_buffer_address(index_array: RID):
	if !index_array.is_valid():
		return 0
	var buffer = rd.index_array_get_buffer(index_array)
	assert(buffer.is_valid())
	var buffer_offset = rd.index_array_get_buffer_offset(index_array)
	var address = rd.buffer_get_device_address(buffer)
	return address + buffer_offset

func transform3d_to_mat3x4_bytes(transform: Transform3D) -> PackedByteArray:
	var bx = transform.basis.x
	var by = transform.basis.y
	var bz = transform.basis.z
	var o = transform.origin
	var f := PackedFloat32Array([
		bx.x, by.x, bz.x, o.x,
		bx.y, by.y, bz.y, o.y,
		bx.z, by.z, bz.z, o.z,
	])
	return f.to_byte_array()

func transforms_to_mat3x4_bytes(transforms: Array) -> PackedByteArray:
	var transforms_bytes := PackedByteArray()
	for transform in transforms:
		var t_bytes = transform3d_to_mat3x4_bytes(transform)
		transforms_bytes.append_array(t_bytes)
	return transforms_bytes

func _render_callback(_p_effect_callback_type: int, p_render_data: RenderData):
	if rd == null or pipeline == RID():
		return

	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return
	var size = render_scene_buffers.get_internal_size()

	var render_scene_data: RenderSceneDataRD = p_render_data.get_render_scene_data()
	if render_scene_data == null:
		return

	var render_list_index = 0

	var uniform_buffer = render_scene_data.get_uniform_buffer()

	_free_acceleration_structures()

	var vertex_addresses = PackedInt64Array()
	var normal_addresses = PackedInt64Array()
	var index_addresses = PackedInt64Array()

	var transforms = render_scene_data.get_transforms(render_list_index)
	
	var vertex_arrays = render_scene_data.get_vertex_arrays(render_list_index)
	var index_arrays = render_scene_data.get_index_arrays(render_list_index)
	var vertex_count = vertex_arrays.size()
	var index_count = index_arrays.size()
	assert(vertex_count == index_count)
	for i in range(vertex_count):
		assert(vertex_arrays[i].is_valid())
		var vertex_address = _get_vertex_buffer_address(vertex_arrays[i], RenderingServer.ARRAY_VERTEX)
		vertex_addresses.push_back(vertex_address)
		var index_address = _get_index_buffer_address(index_arrays[i])
		index_addresses.push_back(index_address)
		var normal_address = _get_vertex_buffer_address(vertex_arrays[i], RenderingServer.ARRAY_NORMAL)
		normal_addresses.push_back(normal_address)

		var blas = rd.blas_create(vertex_arrays[i], index_arrays[i])
		if (blas != RID()):
			rd.acceleration_structure_build(blas)
			blases.push_back(blas)

	instances_buffer = rd.tlas_instances_buffer_create(blases.size())
	rd.tlas_instances_buffer_fill(instances_buffer, blases, transforms)
	tlas = rd.tlas_create(instances_buffer)
	assert(tlas != RID())
	rd.acceleration_structure_build(tlas)

	vertex_storage.update(rd, vertex_addresses.to_byte_array())
	index_storage.update(rd, index_addresses.to_byte_array())
	normal_storage.update(rd, normal_addresses.to_byte_array())
	transform_storage.update(rd, transforms_to_mat3x4_bytes(transforms))

	var view_count = render_scene_buffers.get_view_count()
	for view in range(view_count):
		var input_image = render_scene_buffers.get_color_layer(view)

		var image_uniform := RDUniform.new()
		image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image_uniform.binding = 0
		image_uniform.add_id(input_image)

		var as_uniform := RDUniform.new()
		as_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
		as_uniform.binding = 1
		as_uniform.add_id(tlas)

		var scene_uniform := RDUniform.new()
		scene_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		scene_uniform.binding = 2
		scene_uniform.add_id(uniform_buffer)

		var vertex_addresses_uniform := RDUniform.new()
		vertex_addresses_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		vertex_addresses_uniform.binding = 3
		vertex_addresses_uniform.add_id(vertex_storage.buffer)

		var index_addresses_uniform := RDUniform.new()
		index_addresses_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		index_addresses_uniform.binding = 4
		index_addresses_uniform.add_id(index_storage.buffer)

		var transforms_uniform := RDUniform.new()
		transforms_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		transforms_uniform.binding = 5
		transforms_uniform.add_id(transform_storage.buffer)

		var blue_noise_uniform := RDUniform.new()
		blue_noise_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
		blue_noise_uniform.binding = 6
		blue_noise_uniform.add_id(blue_noise)

		var normal_addresses_uniform := RDUniform.new()
		normal_addresses_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		normal_addresses_uniform.binding = 7
		normal_addresses_uniform.add_id(normal_storage.buffer)

		uniform_set = rd.uniform_set_create(
			[
				image_uniform,
				as_uniform,
				scene_uniform,
				vertex_addresses_uniform,
				index_addresses_uniform,
				transforms_uniform,
				blue_noise_uniform,
				normal_addresses_uniform,
			],
			shader,
			0
		)
		assert(uniform_set.is_valid())

		var raylist = rd.raytracing_list_begin()
		rd.raytracing_list_bind_raytracing_pipeline(raylist, pipeline)
		rd.raytracing_list_bind_uniform_set(raylist, uniform_set, 0)
		rd.raytracing_list_trace_rays(raylist, size.x, size.y)
		rd.raytracing_list_end()
