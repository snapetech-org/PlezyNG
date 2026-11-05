// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace plezy::steam {
// At most one pending request of each kind per seat. Host output can never
// grow a queue or schedule unbounded vibration on a physical controller.
struct ControllerFeedback {
  bool enabled = false, sensors = false;
  uint8_t version = 0;
  unsigned dirty = 0;
  std::array<uint16_t, 4> motors{};
  std::array<std::chrono::steady_clock::time_point, 2> deadlines{};
  std::array<int16_t, 6> motion{};  // rad/s and m/s², encoded in Steam SDL units.

  static uint32_t read(const uint8_t* bytes, unsigned count) {
    uint32_t result = 0;
    for (unsigned i = 0; i < count; ++i) result |= uint32_t(bytes[i]) << (8 * i);
    return result;
  }
  bool command(const uint8_t* data, size_t length) {
    if (!data || !length) return false;
    if (data[0] == 9 && length == 2) {
      version = data[1];
      return true;
    }
    if (data[0] == 8 && length == 2 && data[1] <= 1) {
      sensors = data[1] != 0;
      dirty |= 4;
      if (!sensors) motion.fill(0);
      return true;
    }
    if ((data[0] == 5 && length == 4) || ((data[0] == 10 || data[0] == 11) && length == 2)) return true;
    if ((data[0] != 1 && data[0] != 6) || length != 9) return false;
    if (!enabled) return true;
    const unsigned pair = data[0] == 1 ? 0 : 1;
    const unsigned duration = std::min(read(data + 5, 4), 1000u);
    motors[pair * 2] = duration ? uint16_t(read(data + 1, 2)) : 0;
    motors[pair * 2 + 1] = duration ? uint16_t(read(data + 3, 2)) : 0;
    deadlines[pair] = std::chrono::steady_clock::now() + std::chrono::milliseconds(duration);
    dirty |= 1u << pair;
    return true;
  }
  std::array<uint8_t, 9> pending{};
  size_t pendingSize = 0;
  std::chrono::steady_clock::time_point motionAt{};
  bool write(const uint8_t* data, size_t length) {
    if (!data || !length || length > 128) return false;
    for (size_t i = 0; i < length; ++i) {
      pending[pendingSize++] = data[i];
      const unsigned type = pending[0];
      const size_t expected = type == 1 || type == 6 ? 9 : type == 5 ? 4 : type >= 8 && type <= 11 ? 2 : 0;
      if (!expected) {
        pendingSize = 0;
        return false;
      }
      if (pendingSize == expected) {
        pendingSize = 0;
        if (!command(pending.data(), expected)) return false;
      }
    }
    return true;
  }
  void expireMotion() {
    if (std::chrono::steady_clock::now() - motionAt > std::chrono::milliseconds(250)) motion.fill(0);
  }
  void ownership(bool value) {
    enabled = value;
    pendingSize = 0;
    motors.fill(0);
    motion.fill(0);
    dirty = value ? 7 : 0;
  }
  bool setMotion(const std::array<double, 6>& values) {
    if (!enabled || !sensors) return false;
    for (double value : values)
      if (!std::isfinite(value)) return false;
    for (size_t i = 0; i < values.size(); ++i) {
      const double limit = i < 3 ? 34.90659 : 19.6133;
      motion[i] = int16_t((std::clamp(values[i] / limit, -1.0, 1.0) + 1) * 32767.5 - 32768);
    }
    motionAt = std::chrono::steady_clock::now();
    return true;
  }
  // flags, low/high/duration, trigger-low/high/duration, sensor-request.
  std::array<int64_t, 8> take() {
    if (!enabled) return {};
    std::array<int64_t, 8> result{int64_t(dirty), 0, 0, 0, 0, 0, 0, sensors ? 1 : 0};
    const auto now = std::chrono::steady_clock::now();
    for (unsigned pair = 0; pair < 2; ++pair) {
      const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadlines[pair] - now).count();
      if (left > 0) {
        result[1 + pair * 3] = motors[pair * 2];
        result[2 + pair * 3] = motors[pair * 2 + 1];
        result[3 + pair * 3] = std::min<int64_t>(left, 1000);
      }
    }
    dirty = 0;
    return result;
  }
};
}  // namespace plezy::steam
