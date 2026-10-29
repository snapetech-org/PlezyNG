// SPDX-License-Identifier: MIT
#pragma once
#include <linux/input.h>
#include <sys/stat.h>

#include <array>
#include <cstdint>
#include <string>

// A fixed gamepad node and a verified sensor sibling, never a host-provided
// device path. Normal evdev input remains read-only and works without effects.
class LinuxGamepadEffects {
 public:
  LinuxGamepadEffects(const std::string& path, int inputFd);
  ~LinuxGamepadEffects();
  void Rumble(unsigned low, unsigned high, unsigned milliseconds);
  void Sensors(bool enabled);
  std::array<double, 7> State();

 private:
  void CloseSensor();
  std::string path_;
  input_id identity_{};
  int feedbackFd_ = -1, effectId_ = -1, sensorFd_ = -1;
  bool enabled_ = false;
  unsigned capabilities_ = 0;
  std::array<int, 6> resolutions_{};
  uint64_t lastSensorNs_ = 0;
};
