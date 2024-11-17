extends Node3D

@onready
var rd := RenderingServer.create_local_rendering_device()
@onready
var screen_texture := get_node("TextureRect")

var raytracing_texture: RID
var shader: RID
var raytracing_pipeline: RID
var vertex_buffer: RID
var vertex_array: RID
var index_buffer: RID
var index_array: RID
var transform_buffer: RID
var blas: RID
var tlas: RID
var uniform_set: RID

func _ready():
	if rd.raytracing_is_supported():
		_initialise_screen_texture()
		_initialize_raytracing_texture()
		_initialize_scene()
		_initialize_raytracing_pipeline()

func _process(_delta):
	if rd.raytracing_is_supported():
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
	raytracing_pipeline = rd.raytracing_pipeline_create(shader)

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
	vertex_buffer = rd.vertex_buffer_create(point_bytes.size(), point_bytes, true)
	var vertex_desc := RDVertexAttribute.new()
	vertex_desc.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vertex_desc.location = 0
	vertex_desc.stride = 4 * 3
	var vertex_format := rd.vertex_format_create([vertex_desc])
	vertex_array = rd.vertex_array_create(points.size() / 3, vertex_format, [vertex_buffer], [3*3*4])

	# Index buffer
	var indices := PackedInt32Array([0, 2, 1])
	var index_bytes := indices.to_byte_array()
	index_buffer = rd.index_buffer_create(indices.size(), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, index_bytes)
	index_array = rd.index_array_create(index_buffer, 0, indices.size())

	# Transform buffer
	var transform_matrix := PackedFloat32Array([
		1.0, 0.0, 0.0, 0.0,
		0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0,
	])
	var transform_bytes := transform_matrix.to_byte_array()
	transform_buffer = rd.storage_buffer_create(transform_bytes.size(), transform_bytes, RenderingDevice.STORAGE_BUFFER_USAGE_SHADER_DEVICE_ADDRESS | RenderingDevice.STORAGE_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY)

	# Create a BLAS for a mesh
	blas = rd.blas_create(vertex_array, index_array, transform_buffer)
	# Create TLAS with BLASs.
	tlas = rd.tlas_create([blas])

func _render():
	var raylist := rd.raytracing_list_begin()
	rd.raytracing_list_build_acceleration_structure(raylist, blas)
	rd.raytracing_list_build_acceleration_structure(raylist, tlas)
	rd.raytracing_list_bind_raytracing_pipeline(raylist, raytracing_pipeline)
	rd.raytracing_list_bind_uniform_set(raylist, uniform_set, 0)
	var width = get_viewport().size.x
	var height = get_viewport().size.y
	rd.raytracing_list_trace_rays(raylist, width, height)
	rd.raytracing_list_add_barrier(raylist)
	rd.raytracing_list_end()
	
	var byte_data := rd.texture_get_data(raytracing_texture, 0)
	_set_screen_texture_data(byte_data)
