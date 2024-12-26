@tool
extends CompositorEffect
class_name RaytracedAmbientOcclusion

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var blases := []
var tlas: RID
var vertex_storages = []
var vertex_size_bytes := 0
var index_storages = []
var index_size_bytes := 0
var uniform_sets := []

var to_delete := []


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
		for rid in to_delete:
			rd.free_rid(rid)

		for rid in uniform_sets:
			rd.free_rid(rid)
		for rid in vertex_storages:
			rd.free_rid(rid)
		for rid in index_storages:
			rd.free_rid(rid)

		if tlas.is_valid():
			rd.free_rid(tlas)

		for blas in blases:
			if blas.is_valid():
				rd.free_rid(blas)

		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)

func _free_acceleration_structures():
	if tlas.is_valid():
		to_delete.push_back(tlas)
		tlas = RID()

	for blas in blases:
		if blas.is_valid():
			to_delete.push_back(blas)
	blases.clear()

func process():
	if rd == null:
		return

	for rid in to_delete:
		rd.free_rid(rid)
	to_delete.clear()

func _update_vertex_storage(addresses: PackedInt64Array):
	assert(addresses != null)
	assert(addresses.size() != 0)
	var addresses_bytes = addresses.to_byte_array()
	var size_bytes = addresses_bytes.size()
	if size_bytes > vertex_size_bytes:
		vertex_size_bytes = size_bytes
		vertex_storages.push_back(rd.storage_buffer_create(size_bytes, addresses_bytes))
		print("new vertex buffer ", size_bytes)
	#else:
	#	rd.buffer_update(vertex_storage, 0, size_bytes, addresses_bytes)
	#	print("Updated")

func _update_index_storage(addresses: PackedInt64Array):
	assert(addresses != null)
	assert(addresses.size() != 0)
	var addresses_bytes = addresses.to_byte_array()
	var size_bytes = addresses_bytes.size()
	if size_bytes > index_size_bytes:
		index_size_bytes = size_bytes
		index_storages.push_back(rd.storage_buffer_create(size_bytes, addresses_bytes))
		print("new index buffer ", size_bytes)
	#else:
	#	rd.buffer_update(index_storage, 0, size_bytes, addresses_bytes)
	#	print("Updated")

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

	var uniform_buffer = render_scene_data.get_uniform_buffer()

	var transform_size = 12 * 4;
	var transform_count = render_scene_data.get_transform_count()
	var transform_buffer = render_scene_data.get_transform_buffer()
	assert(transform_buffer != RID())

	_free_acceleration_structures()

	var vertex_addresses = PackedInt64Array()
	var index_addresses = PackedInt64Array()
	
	var vertex_arrays = render_scene_data.get_vertex_arrays()
	var index_arrays = render_scene_data.get_index_arrays()
	var vertex_count = vertex_arrays.size()
	var index_count = index_arrays.size()
	assert(vertex_count == index_count)
	assert(vertex_count == transform_count)
	for i in range(transform_count):
		var vertex_buffer = rd.vertex_array_get_buffer(vertex_arrays[i])
		var vertex_buffer_offset = rd.vertex_array_get_buffer_offset(vertex_arrays[i])
		assert(vertex_buffer != RID())
		var vertex_address = rd.buffer_get_device_address(vertex_buffer)
		vertex_addresses.push_back(vertex_address + vertex_buffer_offset)

		if (index_arrays[i] != RID()):
			var index_buffer = rd.index_array_get_buffer(index_arrays[i])
			var index_buffer_offset = rd.index_array_get_buffer_offset(index_arrays[i])
			assert(index_buffer != RID())
			var index_address = rd.buffer_get_device_address(index_buffer)
			index_addresses.push_back(index_address + index_buffer_offset)
		else:
			index_addresses.push_back(0)
		
		var transform_offset = i * transform_size
		var blas = rd.blas_create(vertex_arrays[i], index_arrays[i], transform_buffer, transform_offset)
		assert(blas != RID())
		rd.acceleration_structure_build(blas)
		blases.push_back(blas)

	tlas = rd.tlas_create(blases)
	assert(tlas != RID())
	rd.acceleration_structure_build(tlas)

	_update_vertex_storage(vertex_addresses)
	_update_index_storage(index_addresses)

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
		vertex_addresses_uniform.add_id(vertex_storages[vertex_storages.size() - 1])

		var index_addresses_uniform := RDUniform.new()
		index_addresses_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		index_addresses_uniform.binding = 4
		index_addresses_uniform.add_id(index_storages[index_storages.size() - 1])

		uniform_sets.push_back(
			rd.uniform_set_create([image_uniform, as_uniform, scene_uniform, vertex_addresses_uniform, index_addresses_uniform], shader, 0)
		)

		var raylist = rd.raytracing_list_begin()
		rd.raytracing_list_bind_raytracing_pipeline(raylist, pipeline)
		rd.raytracing_list_bind_uniform_set(raylist, uniform_sets[uniform_sets.size() - 1], 0)
		rd.raytracing_list_trace_rays(raylist, size.x, size.y)
		rd.raytracing_list_end()
