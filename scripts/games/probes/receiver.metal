// SPDX-License-Identifier: GPL-3.0-or-later
#include <metal_stdlib>
using namespace metal;
kernel void plezy_receiver_sdk_probe(texture2d<float, access::write> output [[texture(0)]],
                                    uint2 coordinate [[thread_position_in_grid]]) {
  if (coordinate.x < output.get_width() && coordinate.y < output.get_height())
    output.write(float4(0.f, 0.f, 0.f, 1.f), coordinate);
}
