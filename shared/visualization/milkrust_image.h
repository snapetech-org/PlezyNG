// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <cstdint>
#include <vector>
namespace plezy::visualization {
struct MilkRustImage {
  uint32_t width = 0, height = 0;
  std::vector<uint8_t> rgba;
};
}
