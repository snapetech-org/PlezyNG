// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace plezy::visualization {
// Display fade from the last published image to a newly running preset. The
// old preset's equations do not keep running. Elapsed time belongs to the new
// preset, so pausing audio/rendering also pauses this transition.
class PresetTransition {
 public:
  static bool ValidDuration(double seconds) {
    return std::isfinite(seconds) && seconds >= 0 && seconds <= 10;
  }
  void Clear() {
    std::vector<uint8_t>().swap(previous_);
    width_ = height_ = 0;
    duration_ = 0;
  }
  void Start(const std::vector<uint8_t>& rgba, uint32_t width, uint32_t height, double seconds) {
    if (!ValidDuration(seconds))
      throw std::runtime_error("Preset transition must be between zero and ten seconds.");
    if (seconds == 0 || !ValidFrame(rgba, width, height)) {
      Clear();
      return;
    }
    previous_ = rgba;
    width_ = width;
    height_ = height;
    duration_ = seconds;
  }
  void Apply(std::vector<uint8_t>& rgba, uint32_t width, uint32_t height, double elapsed) {
    if (previous_.empty()) return;
    if (!std::isfinite(elapsed) || elapsed >= duration_ || !ValidFrame(rgba, width, height)) {
      Clear();
      return;
    }
    const double progress = elapsed <= 0 ? 0 : elapsed / duration_;
    const auto next = static_cast<uint32_t>(progress * progress * (3 - 2 * progress) * 65536 + 0.5);
    const auto prior = 65536u - next;
    for (uint32_t y = 0; y < height; ++y) {
      const auto old_y = static_cast<size_t>(static_cast<uint64_t>(y) * height_ / height);
      for (uint32_t x = 0; x < width; ++x) {
        const auto old_x = static_cast<size_t>(static_cast<uint64_t>(x) * width_ / width);
        const size_t src = (old_y * width_ + old_x) * 4;
        const size_t dst = (static_cast<size_t>(y) * width + x) * 4;
        for (size_t channel = 0; channel < 4; ++channel)
          rgba[dst + channel] = static_cast<uint8_t>(
              (previous_[src + channel] * prior + rgba[dst + channel] * next + 32768u) >> 16);
      }
    }
  }

 private:
  static bool ValidFrame(const std::vector<uint8_t>& rgba, uint32_t width, uint32_t height) {
    if (width == 0 || height == 0 || width > 4096 || height > 4096) return false;
    const size_t pixels = static_cast<size_t>(width) * height;
    return pixels <= 8 * 1024 * 1024 && rgba.size() == pixels * 4;
  }
  std::vector<uint8_t> previous_;
  uint32_t width_ = 0, height_ = 0;
  double duration_ = 0;
};
}  // namespace plezy::visualization
