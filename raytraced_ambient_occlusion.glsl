#[raygen]

#version 460

#pragma shader_stage(raygen)

#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_samplerless_texture_functions : enable
#extension GL_EXT_shader_explicit_arithmetic_types : enable
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : enable
#extension GL_EXT_buffer_reference2 : require

#if !defined(MODE_RENDER_DEPTH) || defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED) ||defined(LIGHT_CLEARCOAT_USED)
#ifndef NORMAL_USED
#define NORMAL_USED
#endif
#endif

#define MAX_VIEWS 2
#include "scene_data_inc.glsl"
#include "ray_payload_inc.glsl"

layout(location = 0) rayPayloadEXT RayPayload payload;

// Render target in raytracing is a storage image with general layout.
layout(set = 0, binding = 0, rgba16f) uniform image2D image;

// Bounding Volume Hierarchy: top-level acceleration structure.
layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;

layout(set = 0, binding = 2, std140) uniform SceneDataBlock {
	SceneData data;
} scene_data_block;

layout(buffer_reference, buffer_reference_align = 4) buffer PointerToVertex { highp float vertex[]; };
layout(buffer_reference, buffer_reference_align = 2) buffer PointerToIndex { uint16_t index[]; };
layout(buffer_reference, buffer_reference_align = 2) buffer PointerToNormal { u16vec4 normal[]; };

layout(set = 0, binding = 3, std430) readonly buffer VertexAddressesBlock {
	PointerToVertex data[];
} vertex_addresses;

layout(set = 0, binding = 4, std430) readonly buffer IndexAddressesBlock {
	PointerToIndex data[];
} index_addresses;

layout(set = 0, binding = 5, std430) readonly buffer TransformBlock {
	mat3x4 data[];
} transforms;

layout(set = 0, binding = 6) uniform texture2D blue_noise_texture;

layout(set = 0, binding = 7, std430) readonly buffer NormalAddressesBlock {
	PointerToNormal data[];
} normal_addresses;

const float c_pi = 3.14159265359;
const float c_golden_ratio_conjugate = 0.61803398875; // also just fract(goldenRatio)

vec4 get_blue_noise_sample() {
	ivec2 pix = ivec2(gl_LaunchIDEXT.x % 1024, gl_LaunchIDEXT.y % 1024);
	return texelFetch(blue_noise_texture, pix, 0);
}

float get_blue_noise_rand(float blue_noise_sample, uint count) {
	return fract(
		blue_noise_sample + c_golden_ratio_conjugate * float(count));
}

vec3 get_random_dir_on_hemisphere(vec3 normal, float e1, float e2) {
	float theta = acos(sqrt(e1));
	float omega = 2.0 * c_pi * e2;

	float sin_theta = sin(theta);
	float cos_theta = cos(theta);
	float sin_omega = sin(omega);
	float cos_omega = cos(omega);

	vec3 s = vec3(cos_omega * sin_theta, sin_omega * sin_theta, cos_theta);

	// Rotate s so that the emisphere is centered around the normal
	vec3 w = normal;
	vec3 a = vec3(0.0, 1.0, 0.0);
	if (abs(dot(w, a)) > 0.9) {
		a = vec3(1.0, 0.0, 0.0);
	}
	vec3 u = normalize(cross(a, w));
	vec3 v = cross(w, u);

	return s.x * u + s.y * v + s.z * w;
}

highp mat3x3 adjoint_transpose(highp mat4x3 m) {
	highp mat3x3 ret;
	ret[0][0] = m[2][2] * m[1][1] - m[1][2] * m[2][1];
	ret[0][1] = m[1][2] * m[2][0] - m[1][0] * m[2][2];
	ret[0][2] = m[1][0] * m[2][1] - m[2][0] * m[1][1];

	ret[1][0] = m[0][2] * m[2][1] - m[2][2] * m[0][1];
	ret[1][1] = m[2][2] * m[0][0] - m[0][2] * m[2][0];
	ret[1][2] = m[2][0] * m[0][1] - m[0][0] * m[2][1];

	ret[2][0] = m[1][2] * m[0][1] - m[0][2] * m[1][1];
	ret[2][1] = m[1][0] * m[0][2] - m[1][2] * m[0][0];
	ret[2][2] = m[0][0] * m[1][1] - m[1][0] * m[0][1];

	return ret;
}

vec3 oct_to_vec3(vec2 e) {
	vec3 v = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
	float t = max(-v.z, 0.0);
	v.xy += t * -sign(v.xy);
	return normalize(v);
}

vec3 unpack_normal(u16vec4 p_normal_in) {
	return oct_to_vec3((p_normal_in.xy / 65535.0) * 2.0 - 1.0);
}

void main() {
	const vec2 pixel_center = vec2(gl_LaunchIDEXT.xy) + vec2(0.5);
	const vec2 in_uv = pixel_center / vec2(gl_LaunchSizeEXT.xy);

	uint blue_noise_sample_count = 0;

	vec2 d = in_uv * 2.0 - 1.0;

	vec4 target = scene_data_block.data.inv_projection_matrix * vec4(d.x, d.y, 1.0, 1.0);
	vec4 origin = scene_data_block.data.inv_view_matrix * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 direction = scene_data_block.data.inv_view_matrix * vec4(normalize(target.xyz), 0);

	float t_min = 0.001;
	float t_max = 10000.0;

	traceRayEXT(tlas, gl_RayFlagsOpaqueEXT, 0xFF, 0, 0, 0, origin.xyz, t_min, direction.xyz, t_max, 0);

	vec3 color = vec3(0.0, 0.0, 0.0);

	if (payload.hit) {
		vec3 barycentrics = vec3(1.0 - payload.attribs.x - payload.attribs.y, payload.attribs.x, payload.attribs.y);

		PointerToIndex p_index = index_addresses.data[payload.instance_id];
		uint64_t u_p_index = uint64_t(p_index);
		PointerToVertex p_vertex = vertex_addresses.data[payload.instance_id];

		uint idx0 = 0;
		uint idx1 = 1;
		uint idx2 = 2;
		uint vertex_offset = 0;

		if (u_p_index == 0) {
			vertex_offset = payload.primitive_id * 3;
		} else {
			uint index_offset = payload.primitive_id * 3;
			idx0 = p_index.index[index_offset + 0];
			idx1 = p_index.index[index_offset + 1];
			idx2 = p_index.index[index_offset + 2];
		}

		highp mat4x3 transform = transpose(transforms.data[payload.instance_id]);

		vec4 pos0 = vec4(
			p_vertex.vertex[vertex_offset + idx0 * 3 + 0],
			p_vertex.vertex[vertex_offset + idx0 * 3 + 1],
			p_vertex.vertex[vertex_offset + idx0 * 3 + 2], 1.0
		);
		vec4 pos1 = vec4(
			p_vertex.vertex[vertex_offset + idx1 * 3 + 0],
			p_vertex.vertex[vertex_offset + idx1 * 3 + 1],
			p_vertex.vertex[vertex_offset + idx1 * 3 + 2], 1.0
		);
		vec4 pos2 = vec4(
			p_vertex.vertex[vertex_offset + idx2 * 3 + 0],
			p_vertex.vertex[vertex_offset + idx2 * 3 + 1],
			p_vertex.vertex[vertex_offset + idx2 * 3 + 2], 1.0
		);
		vec3 pos = transform * (pos0 * barycentrics.x + pos1 * barycentrics.y + pos2 * barycentrics.z);

#ifdef NORMAL_USED
		PointerToNormal p_normal = normal_addresses.data[payload.instance_id];

		vec3 normal0 = unpack_normal(p_normal.normal[vertex_offset + idx0]);
		vec3 normal1 = unpack_normal(p_normal.normal[vertex_offset + idx1]);
		vec3 normal2 = unpack_normal(p_normal.normal[vertex_offset + idx2]);

		vec3 normal_interp = normalize(normal0 * barycentrics.x + normal1 * barycentrics.y + normal2 * barycentrics.z).xyz;

#else // NORMAL_USED
		vec3 normal_interp = normalize(cross(pos2.xyz - pos0.xyz, pos1.xyz - pos0.xyz));
#endif // NORMAL_USED

		highp mat3x3 normal_matrix = adjoint_transpose(transform);
		vec3 normal = normalize(normal_matrix * normal_interp);

		// shadow ray origin
		float epsilon = 0.001;
		vec3 shadow_origin = pos.xyz + normal * epsilon;

		uint shadow_sample_count = 8;

		const vec4 blue_noise_sample = get_blue_noise_sample();

		for (uint shadow_sample_index = 0; shadow_sample_index < shadow_sample_count; shadow_sample_index++) {
			const float blue_noise_rand1 = get_blue_noise_rand(blue_noise_sample.x, blue_noise_sample_count);
			const float blue_noise_rand2 = get_blue_noise_rand(blue_noise_sample.y, blue_noise_sample_count);
			blue_noise_sample_count += 1;
			
			vec3 shadow_direction = get_random_dir_on_hemisphere(normal, blue_noise_rand1, blue_noise_rand2);

			traceRayEXT(tlas, gl_RayFlagsOpaqueEXT, 0xFF, 0, 0, 0, shadow_origin.xyz, t_min, shadow_direction.xyz, t_max, 0);

			if (!payload.hit) {
				color += vec3(1.0);
			}
		}

		color /= float(shadow_sample_count);
	}

	imageStore(image, ivec2(gl_LaunchIDEXT.xy), vec4(color, 1.0));
}

#[miss]

#version 460

#pragma shader_stage(miss)
#extension GL_EXT_ray_tracing : enable

#include "ray_payload_inc.glsl"

layout(location = 0) rayPayloadInEXT RayPayload payload;

void main() {
	payload.hit = false;
}

#[closest_hit]

#version 460

#pragma shader_stage(closest_hit)
#extension GL_EXT_ray_tracing : enable

#include "ray_payload_inc.glsl"

hitAttributeEXT vec3 attribs;

layout(location = 0) rayPayloadInEXT RayPayload payload;

void main() {
	payload.instance_id = gl_InstanceID;
	payload.primitive_id = gl_PrimitiveID;
	payload.attribs = attribs.xy;
	payload.hit = true;
}
