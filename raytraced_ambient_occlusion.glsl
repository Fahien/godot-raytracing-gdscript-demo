#[raygen]

#version 460

#define MAX_VIEWS 2
#include "scene_data_inc.glsl"

#pragma shader_stage(raygen)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_samplerless_texture_functions : enable


layout(location = 0) rayPayloadEXT vec3 payload;

// Render target in raytracing is a storage image with general layout.
layout(set = 0, binding = 0, rgba16f) uniform image2D image;

// Bounding Volume Hierarchy: top-level acceleration structure.
layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;

layout(set = 0, binding = 2, std140) uniform SceneDataBlock {
	SceneData data;
} scene_data_block;

layout(set = 0, binding = 6) uniform texture2D blue_noise_texture;

void main() {
	const vec2 pixel_center = vec2(gl_LaunchIDEXT.xy) + vec2(0.5);
	const vec2 in_uv = pixel_center / vec2(gl_LaunchSizeEXT.xy);

	ivec2 pix = ivec2(int(in_uv.x * 1024.0), int(in_uv.y * 1024.0));
	const vec3 blue_noise = texelFetch(blue_noise_texture, pix, 0).xyz;

	vec2 d = in_uv * 2.0 - 1.0;

	vec4 target = scene_data_block.data.inv_projection_matrix * vec4(d.x, d.y, 1.0, 1.0);
	vec4 origin = scene_data_block.data.inv_view_matrix * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 direction = scene_data_block.data.inv_view_matrix * vec4(normalize(target.xyz), 0);

	float t_min = 0.001;
	float t_max = 10000.0;

	traceRayEXT(tlas, gl_RayFlagsOpaqueEXT, 0xFF, 0, 0, 0, origin.xyz, t_min, direction.xyz, t_max, 0);

	imageStore(image, ivec2(gl_LaunchIDEXT.xy), vec4(payload, 1.0));
}

#[miss]

#version 460
#extension GL_EXT_ray_tracing : enable

layout(location = 0) rayPayloadInEXT vec3 payload;

void main() {
	payload = vec3(1.0, 0.0, 0.0);
}

#[closest_hit]

#version 460

#pragma shader_stage(closest_hit)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_shader_explicit_arithmetic_types : enable
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : enable
#extension GL_EXT_buffer_reference2 : require

hitAttributeEXT vec3 attribs;

layout(buffer_reference, buffer_reference_align = 4) buffer PointerToVertex { float vertex[]; };
layout(buffer_reference, buffer_reference_align = 2) buffer PointerToIndex { uint16_t index[]; };

layout(set = 0, binding = 3, std430) readonly buffer VertexAddressesBlock {
	PointerToVertex data[];
} vertex_addresses;

layout(set = 0, binding = 4, std430) readonly buffer IndexAddressesBlock {
	PointerToIndex data[];
} index_addresses;

layout(set = 0, binding = 5, std430) readonly buffer TransformBlock {
	mat3x4 data[];
} transforms;

layout(location = 0) rayPayloadInEXT vec3 payload;

vec3 get_random_dir_on_hemisphere(vec3 normal) {
	return vec3(1.0);
}

void main() {
	vec3 barycentrics = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
	payload = barycentrics;

	PointerToIndex p_index = index_addresses.data[gl_InstanceID];
	uint64_t u_p_index = uint64_t(p_index);
	PointerToVertex p_vertex = vertex_addresses.data[gl_InstanceID];

	uint idx0 = 0;
	uint idx1 = 1;
	uint idx2 = 2;
	uint vertex_offset = 0;

	if (u_p_index == 0) {
		vertex_offset = gl_PrimitiveID * 3;
	} else {
		uint index_offset = gl_PrimitiveID * 3;
		idx0 = p_index.index[index_offset + 0];
		idx1 = p_index.index[index_offset + 1];
		idx2 = p_index.index[index_offset + 2];
	}

	mat3x4 transform = transforms.data[gl_InstanceID];

	vec4 pos0 = transform * vec3(
		p_vertex.vertex[vertex_offset + idx0 * 3 + 0],
		p_vertex.vertex[vertex_offset + idx0 * 3 + 1],
		p_vertex.vertex[vertex_offset + idx0 * 3 + 2]
	);
	vec4 pos1 = transform * vec3(
		p_vertex.vertex[vertex_offset + idx1 * 3 + 0],
		p_vertex.vertex[vertex_offset + idx1 * 3 + 1],
		p_vertex.vertex[vertex_offset + idx1 * 3 + 2]
	);
	vec4 pos2 = transform * vec3(
		p_vertex.vertex[vertex_offset + idx2 * 3 + 0],
		p_vertex.vertex[vertex_offset + idx2 * 3 + 1],
		p_vertex.vertex[vertex_offset + idx2 * 3 + 2]
	);
	vec4 pos = pos0 * barycentrics.x + pos1 * barycentrics.y + pos2 * barycentrics.z;

	vec3 normal = normalize(cross(pos1.xyz - pos0.xyz, pos2.xyz - pos0.xyz));

	// shadow ray origin
	float epsilon = 0.001;
	vec3 shadow_origin = pos.xyz + normal * epsilon;

	vec3 shadow_ray = get_random_dir_on_hemisphere(normal);

	payload = (normal + 1.0) / 2.0;
}
