extends Node3D

@onready
var rd := RenderingServer.create_local_rendering_device()
@onready
var screen_texture := get_node("TextureRect")

var raytracing_texture: RID
var shader: RID
var sbt: RID
var sbt_range: int
var raytracing_pipeline: RID
var vertex_buffer: RID
var vertex_array: RID
var index_buffer: RID
var index_array: RID
var blas: RID
var instances_buffer: RID
var tlas: RID
var uniform_set: RID

func _free_rid(p_rd: RenderingDevice, rid: RID):
	if rid != null:
		p_rd.free_rid(rid)

func _cleanup():
	if rd == null:
		return

	_free_rid(rd, uniform_set)
	_free_rid(rd, tlas)
	_free_rid(rd, instances_buffer)
	_free_rid(rd, blas)
	_free_rid(rd, index_array)
	_free_rid(rd, index_buffer)
	_free_rid(rd, vertex_array)
	_free_rid(rd, vertex_buffer)
	rd.hit_sbt_range_free(sbt, sbt_range)
	_free_rid(rd, sbt)
	_free_rid(rd, raytracing_pipeline)
	_free_rid(rd, shader)
	_free_rid(rd, raytracing_texture)
	rd = null

func _notification(what: int):
	if what == NOTIFICATION_PREDELETE:
		_cleanup()

func _ready():
	if rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		_initialise_screen_texture()
		_initialize_raytracing_texture()
		_initialize_raytracing_pipeline()
		_initialize_scene()
		_create_uniforms()

func _process(_delta):
	if rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		_render()

func _initialize_raytracing_texture():
	# Create texture for raytracing rendering.
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	texture_format.width = get_viewport().size.x
	texture_format.height = get_viewport().size.y
	# It needs storage bit for the raytracing pipeline and can copy from for the presentation graphics pipeline.
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var texture_view := RDTextureView.new()
	raytracing_texture = rd.texture_create(texture_format, texture_view)

func _initialise_screen_texture():
	var image_size = get_viewport().size
	var image = Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGBAF)
	var image_texture = ImageTexture.create_from_image(image)
	screen_texture.texture = image_texture

func _set_screen_texture_data(data: PackedByteArray):
	var image_size = get_viewport().size
	var image := Image.create_from_data(image_size.x, image_size.y, false, Image.FORMAT_RGBAF, data)
	screen_texture.texture.update(image)

func _initialize_raytracing_pipeline():
	# Create raytracing shaders.
	var shader_file := load("res://ray.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	var pipeline_shader = RDPipelineShader.new()
	pipeline_shader.shader = shader
	
	var hit_group = RDHitGroup.new()
	hit_group.closest_hit_shader = pipeline_shader
	
	raytracing_pipeline = rd.raytracing_pipeline_create([pipeline_shader], [pipeline_shader], [hit_group], 1)

	sbt = rd.hit_sbt_create(raytracing_pipeline, 1024)
	sbt_range = rd.hit_sbt_range_alloc(sbt, 1)
	assert(sbt_range != 0)
	var err = rd.hit_sbt_range_update(sbt, sbt_range, 0, [0])
	assert(err == OK)

func _create_uniforms():
	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(raytracing_texture)
	
	var as_uniform := RDUniform.new()
	as_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	as_uniform.binding = 1
	as_uniform.add_id(tlas)
	
	uniform_set = rd.uniform_set_create([image_uniform, as_uniform], shader, 0)

func _initialize_scene():
	# Vertex buffer for a triangle
	# Prepare our data. We use floats in the shader, so we need 32 bit.
	var points := PackedFloat32Array([
			 0.0, -0.7, 1.0,
			 0.5, -0.7, 1.0,
			 0.0,  0.5, 1.0,
			-0.5, -0.7, 1.0,
			 0.5, -0.7, 1.0,
			-0.5,  0.5, 1.0,
		])
	var point_bytes := points.to_byte_array()
	vertex_buffer = rd.vertex_buffer_create(point_bytes.size(), point_bytes, RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT | RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT)
	var vertex_desc := RDVertexAttribute.new()
	vertex_desc.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vertex_desc.location = 0
	vertex_desc.stride = 4 * 3
	var vertex_format := rd.vertex_format_create([vertex_desc])
	@warning_ignore("integer_division")
	var vertex_count := points.size() / 3
	vertex_array = rd.vertex_array_create(vertex_count, vertex_format, [vertex_buffer])

	# Index buffer
	var indices := PackedInt32Array([0, 2, 1])
	var index_bytes := indices.to_byte_array()
	index_buffer = rd.index_buffer_create(indices.size(), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, index_bytes, false, RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT | RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT)
	index_array = rd.index_array_create(index_buffer, 0, indices.size())
	
	var geometry = RDAccelerationStructureGeometry.new()
	geometry.index_buffer = index_buffer
	geometry.index_count = indices.size()
	geometry.vertex_buffer = vertex_buffer
	geometry.vertex_count = vertex_count
	geometry.vertex_format = vertex_desc.format
	geometry.vertex_stride = vertex_desc.stride

	# Create a BLAS for a mesh
	blas = rd.blas_create([geometry], RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT)

	rd.blas_build(blas)

	# Create TLAS with BLASs.
	tlas = rd.tlas_create(1, RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)

	var instance = RDAccelerationStructureInstance.new()
	instance.blas = blas
	instance.hit_sbt_range = sbt_range
	rd.tlas_build(tlas, [instance])

func _render():
	var raylist = rd.raytracing_list_begin()
	rd.raytracing_list_bind_raytracing_pipeline(raylist, raytracing_pipeline)
	rd.raytracing_list_bind_uniform_set(raylist, uniform_set, 0)
	var width = get_viewport().size.x
	var height = get_viewport().size.y
	rd.raytracing_list_trace_rays(raylist, 0, sbt, width, height, 1)
	rd.raytracing_list_end()
	
	var byte_data := rd.texture_get_data(raytracing_texture, 0)
	_set_screen_texture_data(byte_data)
