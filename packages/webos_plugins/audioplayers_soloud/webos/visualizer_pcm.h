// SPDX-License-Identifier: AGPL-3.0-only
#pragma once

#include "../../../../shared/visualization/plezy_audio_tap_types.h"
#include <array>
#include <atomic>
#include <cstdint>
#include <string>

namespace audioplayers_soloud_webos {
// Receives the final interleaved SoLoud mix that is sent to ALSA. The callback
// is a single producer; NativeWorker is the single consumer. Audio callbacks
// never lock, allocate, or wait for renderer work.
class VisualizerPcm final {
 public:
  static VisualizerPcm& Shared();
  void SetActive(bool active) noexcept;
  void Discontinuity() noexcept;
  void Publish(const float* interleaved, unsigned frames, unsigned channels,
               unsigned sample_rate, double pts) noexcept;
  int Read(mpv_plezy_audio_block* block) noexcept;
  bool AcceptsFrame(uint32_t generation) const noexcept;
  bool Available() const noexcept { return true; }
  std::string Reason() const;

 private:
  static constexpr uint64_t kBlocks = 16;
  struct Slot { mpv_plezy_audio_block block{}; };
  std::array<Slot, kBlocks> queue_{};
  alignas(64) std::atomic<uint64_t> head_{0};
  alignas(64) std::atomic<uint64_t> tail_{0};
  std::atomic<uint32_t> generation_{1};
  std::atomic<uint32_t> dropped_{0};
  std::atomic<bool> active_{false};
};
}  // namespace audioplayers_soloud_webos
