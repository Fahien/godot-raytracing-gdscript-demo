@tool
extends CompositorEffect
class_name RaytracedAmbientOcclusion

var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var blases := []
var tlas := RID()
var vertex_storage := RID()
var vertex_size_bytes := 0
var index_storage := RID()
var index_size_bytes := 0
var blue_noise := RID()
var uniform_set := RID()

# Can not use @onready with CompositorEffect
func _init():
	rd = RenderingServer.get_rendering_device()
	
	# Create raytracing shaders.
	var shader_file := load("res://raytraced_ambient_occlusion.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	assert(shader != RID())
	pipeline = rd.raytracing_pipeline_create(shader)
	assert(pipeline != RID())

	# Load blue noise image
	var blue_noise_image = Image.new()
	blue_noise_image.load("res://assets/blue-noise.png")
	var format = RDTextureFormat.new()
	format.width = blue_noise_image.get_width()
	format.height = blue_noise_image.get_height()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM;
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT;
	blue_noise = rd.texture_create(format, RDTextureView.new(), [blue_noise_image.get_data()])
	assert(blue_noise != RID())

static func _free_rid(dev: RenderingDevice, rid: RID):
	if rid.is_valid():
		dev.free_rid(rid)

func _notification(p_what: int):
	if p_what == NOTIFICATION_PREDELETE:
		_free_rid(rd, uniform_set)
		_free_rid(rd, vertex_storage)
		_free_rid(rd, index_storage)

		_free_rid(rd, tlas)

		for blas in blases:
			_free_rid(rd, blas)

		_free_rid(rd, blue_noise)
		_free_rid(rd, pipeline)
		_free_rid(rd, shader)

func _free_acceleration_structures():
	_free_rid(rd, tlas)
	tlas = RID()

	for blas in blases:
		_free_rid(rd, blas)
	blases.clear()

func _update_vertex_storage(addresses: PackedInt64Array):
	assert(addresses != null)
	assert(addresses.size() != 0)
	var addresses_bytes = addresses.to_byte_array()
	var size_bytes = addresses_bytes.size()
	if size_bytes > vertex_size_bytes:
		vertex_size_bytes = size_bytes
		_free_rid(rd, vertex_storage)
		vertex_storage = rd.storage_buffer_create(size_bytes, addresses_bytes)
		assert(vertex_storage != RID())
	else:
		rd.buffer_update(vertex_storage, 0, size_bytes, addresses_bytes)

func _update_index_storage(addresses: PackedInt64Array):
	assert(addresses != null)
	assert(addresses.size() != 0)
	var addresses_bytes = addresses.to_byte_array()
	var size_bytes = addresses_bytes.size()
	if size_bytes > index_size_bytes:
		index_size_bytes = size_bytes
		_free_rid(rd, index_storage)
		index_storage = rd.storage_buffer_create(size_bytes, addresses_bytes)
		assert(index_storage != RID())
	else:
		rd.buffer_update(index_storage, 0, size_bytes, addresses_bytes)

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
	_free_acceleration_structures()

	var render_list_index = 0

	var vertex_addresses = PackedInt64Array()
	var index_addresses = PackedInt64Array()

	var transform_count = render_scene_data.get_transform_count(render_list_index)
	var transform_buffer = render_scene_data.get_transform_buffer(render_list_index)
	if transform_buffer == RID():
		print("Skipping frame")
		return

	var vertex_arrays = render_scene_data.get_vertex_arrays(render_list_index)
	var index_arrays = render_scene_data.get_index_arrays(render_list_index)
	var vertex_count = vertex_arrays.size()
	var index_count = index_arrays.size()
	assert(vertex_count == index_count)
	assert(vertex_count <= transform_count)
	for i in range(vertex_count):
		assert(vertex_arrays[i] != RID())
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
		if blas != RID():
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
		vertex_addresses_uniform.add_id(vertex_storage)

		var index_addresses_uniform := RDUniform.new()
		index_addresses_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		index_addresses_uniform.binding = 4
		index_addresses_uniform.add_id(index_storage)

		var transform_uniform := RDUniform.new()
		transform_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		transform_uniform.binding = 5
		transform_uniform.add_id(transform_buffer)

		var blue_noise_uniform := RDUniform.new()
		blue_noise_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
		blue_noise_uniform.binding = 6
		blue_noise_uniform.add_id(blue_noise)

		uniform_set = rd.uniform_set_create([image_uniform, as_uniform, scene_uniform, vertex_addresses_uniform, index_addresses_uniform, transform_uniform, blue_noise_uniform], shader, 0)
		assert(uniform_set != RID())

		var raylist = rd.raytracing_list_begin()
		rd.raytracing_list_bind_raytracing_pipeline(raylist, pipeline)
		rd.raytracing_list_bind_uniform_set(raylist, uniform_set, 0)
		rd.raytracing_list_trace_rays(raylist, size.x, size.y)
		rd.raytracing_list_end()
