// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <utility>

namespace plezy::visualization {
struct RenderBudget {
  int width, height, frames_per_second;
  static constexpr RenderBudget Desktop() { return {1920, 1080, 60}; }
  static constexpr RenderBudget Constrained() { return {1280, 720, 30}; }
};

// Called under the host control mutex. Measure completed render/readback and
// presentation work, excluding shader loading, pause and audio starvation.
// Slow windows reduce scale promptly; sustained headroom restores it gradually.
class RenderQuality {
 public:
  using Clock = std::chrono::steady_clock;
  explicit RenderQuality(RenderBudget budget = RenderBudget::Constrained())
      : budget_(budget), fps_(budget.frames_per_second) {}
  void Resize(int width, int height) {
    width = std::clamp(width, 1, 16384);
    height = std::clamp(height, 1, 16384);
    const double fit = std::min({1.0, double(budget_.width) / width, double(budget_.height) / height});
    const int w = std::max(1, int(width * fit)), h = std::max(1, int(height * fit));
    if (w == width_ && h == height_) return;
    width_ = w;
    height_ = h;
    ResetTiming();
  }
  std::pair<int, int> Size() const {
    return {std::max(1, int(width_ * scale_)), std::max(1, int(height_ * scale_))};
  }
  std::chrono::microseconds Interval() const { return std::chrono::microseconds(1000000 / fps_); }
  int FramesPerSecond() const { return fps_; }
  double FrameMilliseconds() const { return frame_ms_; }
  void ResetTiming(Clock::time_point now = Clock::now()) {
    count_ = 0;
    adjusted_ = now;
  }
  void Observe(double milliseconds, Clock::time_point now = Clock::now()) {
    if (!std::isfinite(milliseconds) || milliseconds < 0) return;
    frame_ms_ = milliseconds;
    samples_[count_++] = milliseconds;
    if (count_ != samples_.size()) return;
    count_ = 0;
    auto ordered = samples_;
    std::sort(ordered.begin(), ordered.end());
    const double p90 = ordered[ordered.size() * 9 / 10];
    const double target = 1000.0 / fps_;
    if (p90 > target * 0.9 && now - adjusted_ >= std::chrono::seconds(1)) {
      if (scale_ > 0.5) scale_ = std::max(0.5, scale_ * 0.8);
      else if (fps_ > 30) fps_ = 30;
      else return;
    } else if (now - adjusted_ >= std::chrono::seconds(10)) {
      if (fps_ < budget_.frames_per_second && p90 < 1000.0 / budget_.frames_per_second * 0.45)
        fps_ = budget_.frames_per_second;
      else if (scale_ < 1.0 && p90 < target * 0.5)
        scale_ = std::min(1.0, scale_ * 1.25);
      else return;
    } else return;
    adjusted_ = now;
  }
 private:
  RenderBudget budget_;
  int width_ = 768, height_ = 432, fps_;
  double scale_ = 1.0, frame_ms_ = 0;
  std::array<double, 60> samples_{};
  size_t count_ = 0;
  Clock::time_point adjusted_ = Clock::now();
};
}  // namespace plezy::visualization
