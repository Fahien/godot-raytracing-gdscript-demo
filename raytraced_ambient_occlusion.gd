@tool
extends CompositorEffect
class_name RaytracedAmbientOcclusion

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var blases := []
var instances_buffer: RID
var tlas: RID

var vertex_storage := RID()
var vertex_size_bytes := 0
var index_storage := RID()
var index_size_bytes := 0
var transform_storage := RID()
var transform_size_bytes := 0
var uniform_set := RID()

# Can not use @onready with CompositorEffect
func _init():
	rd = RenderingServer.get_rendering_device()
	
	# Create raytracing shaders.
	var shader_file := load("res://raytraced_ambient_occlusion.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.raytracing_pipeline_create(shader)

func _notification(p_what: int):
	if p_what == NOTIFICATION_PREDELETE:
		if uniform_set.is_valid():
			rd.free_rid(uniform_set)
		if transform_storage.is_valid():
			rd.free_rid(transform_storage)
		if vertex_storage.is_valid():
			rd.free_rid(vertex_storage)
		if index_storage.is_valid():
			rd.free_rid(index_storage)

		if tlas.is_valid():
			rd.free_rid(tlas)

		if instances_buffer.is_valid():
			rd.free_rid(instances_buffer)
			instances_buffer = RID()

		for blas in blases:
			if blas.is_valid():
				rd.free_rid(blas)

		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)

func _free_acceleration_structures():
	if tlas.is_valid():
		rd.free_rid(tlas)
		tlas = RID()
	if instances_buffer.is_valid():
		rd.free_rid(instances_buffer)
		instances_buffer = RID()

	for blas in blases:
		if blas.is_valid():
			rd.free_rid(blas)
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

func _update_vertex_storage(addresses: PackedInt64Array):
	assert(addresses != null)
	assert(addresses.size() != 0)
	var addresses_bytes = addresses.to_byte_array()
	var size_bytes = addresses_bytes.size()
	if size_bytes > vertex_size_bytes:
		vertex_size_bytes = size_bytes
		if vertex_storage.is_valid():
			rd.free_rid(vertex_storage)
		vertex_storage = rd.storage_buffer_create(size_bytes, addresses_bytes)
		assert(vertex_storage.is_valid())
	else:
		rd.buffer_update(vertex_storage, 0, size_bytes, addresses_bytes)

func _update_index_storage(addresses: PackedInt64Array):
	assert(addresses != null)
	assert(addresses.size() != 0)
	var addresses_bytes = addresses.to_byte_array()
	var size_bytes = addresses_bytes.size()
	if size_bytes > index_size_bytes:
		index_size_bytes = size_bytes
		if index_storage.is_valid():
			rd.free_rid(index_storage)
		index_storage = rd.storage_buffer_create(size_bytes, addresses_bytes)
		assert(index_storage.is_valid())
	else:
		rd.buffer_update(index_storage, 0, size_bytes, addresses_bytes)

func transform3d_to_mat3x4_bytes(transform: Transform3D) -> PackedByteArray:
	var bx = transform.basis.x
	var by = transform.basis.y
	var bz = transform.basis.z
	var o = transform.origin
	var f := PackedFloat32Array([
		bx.x, bx.y, bx.z, o.x,
		by.x, by.y, by.z, o.y,
		bz.x, bz.y, bz.z, o.z,
	])
	return f.to_byte_array()

func _update_transform_storage(transforms):
	var transforms_bytes := PackedByteArray()
	for transform in transforms:
		var t_bytes = transform3d_to_mat3x4_bytes(transform)
		transforms_bytes.append_array(t_bytes)
	var size_bytes = transforms_bytes.size()
	if size_bytes > transform_size_bytes:
		transform_size_bytes = size_bytes
		if transform_storage.is_valid():
			rd.free_rid(transform_storage)
		transform_storage = rd.storage_buffer_create(size_bytes, transforms_bytes)
		assert(transform_storage.is_valid())
	else:
		rd.buffer_update(transform_storage, 0, size_bytes, transforms_bytes)

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
	var instance_count = render_scene_data.get_instance_count(render_list_index)

	_free_acceleration_structures()

	var vertex_addresses = PackedInt64Array()
	var index_addresses = PackedInt64Array()

	var transforms = render_scene_data.get_transforms(render_list_index)
	
	var vertex_arrays = render_scene_data.get_vertex_arrays(render_list_index)
	var index_arrays = render_scene_data.get_index_arrays(render_list_index)
	var vertex_count = vertex_arrays.size()
	var index_count = index_arrays.size()
	assert(vertex_count == index_count)
	assert(instance_count == vertex_count)
	for i in range(vertex_count):
		assert(vertex_arrays[i].is_valid())
		var vertex_address = _get_vertex_buffer_address(vertex_arrays[i], RenderingServer.ARRAY_VERTEX)
		vertex_addresses.push_back(vertex_address)
		var index_address = _get_index_buffer_address(index_arrays[i])
		index_addresses.push_back(index_address)

		var blas = rd.blas_create(vertex_arrays[i], index_arrays[i])
		if (blas != RID()):
			rd.acceleration_structure_build(blas)
			blases.push_back(blas)

	instances_buffer = rd.tlas_instances_buffer_create(blases.size())
	rd.tlas_instances_buffer_fill(instances_buffer, blases, transforms)
	tlas = rd.tlas_create(instances_buffer)
	assert(tlas != RID())
	rd.acceleration_structure_build(tlas)

	_update_vertex_storage(vertex_addresses)
	_update_index_storage(index_addresses)
	_update_transform_storage(transforms)

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
		vertex_addresses_uniform.add_id(vertex_storage)

		var index_addresses_uniform := RDUniform.new()
		index_addresses_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		index_addresses_uniform.binding = 4
		index_addresses_uniform.add_id(index_storage)

		var transforms_uniform := RDUniform.new()
		transforms_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		transforms_uniform.binding = 5
		transforms_uniform.add_id(transform_storage)

		uniform_set = rd.uniform_set_create([image_uniform, as_uniform, scene_uniform, vertex_addresses_uniform, index_addresses_uniform, transforms_uniform], shader, 0)
		assert(uniform_set.is_valid())

		var raylist = rd.raytracing_list_begin()
		rd.raytracing_list_bind_raytracing_pipeline(raylist, pipeline)
		rd.raytracing_list_bind_uniform_set(raylist, uniform_set, 0)
		rd.raytracing_list_trace_rays(raylist, size.x, size.y)
		rd.raytracing_list_end()
