struct RayPayload {
    uint instance_id;
    uint primitive_id;
    vec2 attribs;
    bool hit;
};

RayPayload ray_payload_create() {
    return RayPayload(0, 0, vec2(0.0, 0.0), false);
}
