@tool
extends CompositorEffect
class_name RaytracedAmbientOcclusion

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var blases := []
var tlas: RID

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
		rd.free_rid(tlas)
		tlas = RID()

	for blas in blases:
		if blas.is_valid():
			rd.free_rid(blas)
	blases.clear()

func _render_callback(_p_effect_callback_type: int, p_render_data: RenderData):
	if rd == null:
		return

	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return
	var size = render_scene_buffers.get_internal_size()

	var render_scene_data: RenderSceneDataRD = p_render_data.get_render_scene_data()
	if render_scene_data == null:
		return

	var transform_size = 12 * 4;
	var transform_count = render_scene_data.get_transform_count()
	var transform_buffer = render_scene_data.get_transform_buffer()
	assert(transform_buffer != RID())

	_free_acceleration_structures()
	
	var instance_count = p_render_data.get_instance_count()
	var blas_index = transform_count - 1
	for i in range(instance_count):
		var vertex_arrays = p_render_data.get_vertex_arrays(i)
		var index_arrays = p_render_data.get_index_arrays(i)
		var vertex_count = vertex_arrays.size()
		var index_count = index_arrays.size()
		assert(vertex_count == index_count)
		for j in range(vertex_count):
			var transform_offset = blas_index * transform_size
			assert(blas_index < transform_count)
			blas_index = blas_index - 1
			var blas = rd.blas_create(vertex_arrays[j], index_arrays[j], transform_buffer, transform_offset)
			assert(blas != RID())
			rd.acceleration_structure_build(blas)
			blases.push_back(blas)

	tlas = rd.tlas_create(blases)
	assert(tlas != RID())
	rd.acceleration_structure_build(tlas)

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

		var uniform_set = rd.uniform_set_create([image_uniform, as_uniform], shader, 0)

		var raylist = rd.raytracing_list_begin()
		rd.raytracing_list_bind_raytracing_pipeline(raylist, pipeline)
		rd.raytracing_list_bind_uniform_set(raylist, uniform_set, 0)
		rd.raytracing_list_trace_rays(raylist, size.x, size.y)
		rd.raytracing_list_end()
