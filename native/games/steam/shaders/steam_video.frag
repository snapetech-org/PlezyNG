// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
layout(set = 0, binding = 0) uniform sampler2D yPlane;
layout(set = 0, binding = 1) uniform sampler2D cbPlane;
layout(set = 0, binding = 2) uniform sampler2D crPlane;
layout(push_constant) uniform Color {
  vec4 conversion; // luma offset, luma scale, chroma scale, BT.2020 flag
  vec4 chroma; // sample offset XY, digital chroma midpoint Z
} params;
void main() {
  float y = (texture(yPlane, uv).r - params.conversion.x) * params.conversion.y;
  vec2 c = (vec2(texture(cbPlane, uv + params.chroma.xy).r,
                 texture(crPlane, uv + params.chroma.xy).r) - vec2(params.chroma.z)) * params.conversion.z;
  // PQ stays PQ all the way to a 10-bit HDR10 swapchain. No SDR gamma transform,
  // tone mapping, 8-bit intermediate or metadata-only "HDR" conversion.
  vec3 rgb = params.conversion.w > 0.5
    ? vec3(y + 1.4746 * c.y, y - 0.164553 * c.x - 0.571353 * c.y, y + 1.8814 * c.x)
    : vec3(y + 1.5748 * c.y, y - 0.187324 * c.x - 0.468124 * c.y, y + 1.8556 * c.x);
  color = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
