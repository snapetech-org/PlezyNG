// SPDX-License-Identifier: AGPL-3.0-only
#include "visualizer_pcm.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace audioplayers_soloud_webos {
namespace {
void AddDropped(std::atomic<uint32_t>& dropped, uint32_t frames) noexcept {
  auto current = dropped.load(std::memory_order_relaxed);
  while (current != UINT32_MAX) {
    const uint32_t next = frames > UINT32_MAX - current ? UINT32_MAX : current + frames;
    if (dropped.compare_exchange_weak(current, next, std::memory_order_relaxed)) return;
  }
}
}  // namespace

VisualizerPcm& VisualizerPcm::Shared() {
  // Keep this process-lifetime object alive until the SoLoud callback has
  // stopped. AudioPlayer initializes it on the platform thread before audio
  // starts, so the real-time mixer callback never performs its first-use
  // allocation or local-static initialization.
  static VisualizerPcm* tap = new VisualizerPcm();
  return *tap;
}

void VisualizerPcm::SetActive(bool active) noexcept {
  const bool previous = active_.exchange(active, std::memory_order_acq_rel);
  if (previous != active) Discontinuity();
}

void VisualizerPcm::Discontinuity() noexcept {
  auto current = generation_.load(std::memory_order_relaxed);
  for (;;) {
    if (current == UINT32_MAX) {
      active_.store(false, std::memory_order_release);
      return;
    }
    if (generation_.compare_exchange_weak(current, current + 1,
                                           std::memory_order_acq_rel)) return;
  }
}

void VisualizerPcm::Publish(const float* samples, unsigned frames,
                            unsigned channels, unsigned sample_rate,
                            double pts) noexcept {
  if (!active_.load(std::memory_order_acquire) || !samples || !frames ||
      channels != 2 || sample_rate < 8000 || sample_rate > 384000 ||
      !std::isfinite(pts)) return;
  const uint32_t generation = generation_.load(std::memory_order_acquire);
  for (unsigned offset = 0; offset < frames;) {
    const unsigned count = std::min<unsigned>(MPV_PLEZY_AUDIO_TAP_FRAMES, frames - offset);
    const uint64_t head = head_.load(std::memory_order_relaxed);
    const uint64_t tail = tail_.load(std::memory_order_acquire);
    if (head - tail >= kBlocks) {
      AddDropped(dropped_, count);
      offset += count;
      continue;
    }
    auto& block = queue_[head % kBlocks].block;
    block.generation = generation;
    block.frames = count;
    block.sample_rate = sample_rate;
    block.channels = 2;
    block.dropped_frames = 0;
    block.speaker_ids[0] = 0;
    block.speaker_ids[1] = 1;
    block.pts = pts + static_cast<double>(offset) / sample_rate;
    block.seconds_per_frame = 1.0 / sample_rate;
    std::copy_n(samples + static_cast<size_t>(offset) * 2,
                static_cast<size_t>(count) * 2, block.samples);
    head_.store(head + 1, std::memory_order_release);
    offset += count;
  }
}

int VisualizerPcm::Read(mpv_plezy_audio_block* result) noexcept {
  if (!result) return MPV_PLEZY_AUDIO_UNSUPPORTED;
  for (;;) {
    const uint64_t tail = tail_.load(std::memory_order_relaxed);
    if (tail == head_.load(std::memory_order_acquire)) return 0;
    *result = queue_[tail % kBlocks].block;
    tail_.store(tail + 1, std::memory_order_release);
    if (result->generation != generation_.load(std::memory_order_acquire)) continue;
    result->dropped_frames = dropped_.exchange(0, std::memory_order_acq_rel);
    return 1;
  }
}

bool VisualizerPcm::AcceptsFrame(uint32_t generation) const noexcept {
  return active_.load(std::memory_order_acquire) &&
      generation_.load(std::memory_order_acquire) == generation;
}

std::string VisualizerPcm::Reason() const {
  if (generation_.load(std::memory_order_acquire) == UINT32_MAX)
    return "The webOS PCM generation counter is exhausted. Restart the app.";
  if (!active_.load(std::memory_order_acquire))
    return "Waiting for the app-owned webOS audio output.";
  return {};
}
}  // namespace audioplayers_soloud_webos
