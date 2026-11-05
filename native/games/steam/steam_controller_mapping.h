// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <vector>

namespace plezy::steam {
// Receiver-side mapping, before Steam sees the virtual pad. Never changes a
// host's Steam Input files, action sets, or another application's configuration.
struct ControllerMapping {
  std::array<int, 15> buttons{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14};
  int stickDeadzone = 0, triggerDeadzone = 0, flags = 0;

  static bool decode(const std::vector<int64_t>& value, ControllerMapping& output) {
    if (value.size() != 19 || value[0] != 1) return false;
    ControllerMapping parsed;
    for (size_t i = 0; i < 15; ++i) {
      if (value[i + 1] < -1 || value[i + 1] > 14) return false;
      parsed.buttons[i] = int(value[i + 1]);
    }
    if (value[16] < 0 || value[16] > 8192 || value[17] < 0 || value[17] > 8192 || value[18] < 0 || value[18] > 63)
      return false;
    parsed.stickDeadzone = int(value[16]);
    parsed.triggerDeadzone = int(value[17]);
    parsed.flags = int(value[18]);
    output = parsed;
    return true;
  }

  void apply(std::array<int16_t, 6>& axes, uint32_t& pressed) const {
    uint32_t mapped = 0;
    for (size_t i = 0; i < buttons.size(); ++i)
      if ((pressed & (1u << i)) && buttons[i] >= 0) mapped |= 1u << buttons[i];
    pressed = mapped;
    for (size_t i = 0; i < axes.size(); ++i) {
      int value = std::clamp(int(axes[i]), i < 4 ? -32767 : 0, 32767);
      const int zone = i < 4 ? stickDeadzone : triggerDeadzone;
      const int magnitude = value < 0 ? -value : value;
      value = magnitude <= zone ? 0 : (magnitude - zone) * 32767 / (32767 - zone) * (value < 0 ? -1 : 1);
      if (i < 4 && (flags & (1 << i))) value = -value;
      axes[i] = int16_t(value);
    }
    if (flags & 16) {
      std::swap(axes[0], axes[2]);
      std::swap(axes[1], axes[3]);
    }
    if (flags & 32) std::swap(axes[4], axes[5]);
  }
};
}  // namespace plezy::steam
