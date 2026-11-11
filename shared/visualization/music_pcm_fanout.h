// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <cmath>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>

#include "plezy_audio_tap_types.h"

namespace plezy::visualization {
// One native tap owner per core, with ordered capture and an independent,
// bounded presentation queue for a simultaneous visualizer.
class MusicPcmFanout {
 public:
  using Enable = std::function<int(bool)>;
  using Read = std::function<int(mpv_plezy_audio_block*)>;
  int EnableCapture(uint64_t key, bool enabled, const Enable& enable) {
    return SetEnabled(key, enabled, false, enable);
  }
  int EnableVisual(uint64_t key, bool enabled, const Enable& enable) { return SetEnabled(key, enabled, true, enable); }
  int ReadCapture(uint64_t key, mpv_plezy_audio_block* out, double playback_pts, const Read& read) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = entries_.find(key);
    if (!key || !out || found == entries_.end() || !found->second.capture) return MPV_PLEZY_AUDIO_UNSUPPORTED;
    auto& entry = found->second;
    entry.playback_pts = playback_pts;
    const int result = read(out);
    if (result > 0 && entry.visual) {
      if (entry.generation != out->generation) {
        entry.visual_queue.clear();
        entry.generation = out->generation;
      }
      if (entry.visual_queue.size() >= 32) entry.visual_queue.pop_front();
      entry.visual_queue.push_back(*out);
    }
    return result;
  }
  int ReadVisual(uint64_t key, mpv_plezy_audio_block* out, double playback_pts, const Read& read) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = entries_.find(key);
    if (!out || found == entries_.end() || !found->second.visual) return 0;
    auto& entry = found->second;
    if (!entry.capture) return read(out);
    const double pts = std::isfinite(playback_pts) ? playback_pts : entry.playback_pts;
    if (!std::isfinite(pts)) return 0;
    bool have = false;
    while (!entry.visual_queue.empty()) {
      const auto& block = entry.visual_queue.front();
      if (block.pts > pts) break;
      *out = block;
      entry.visual_queue.pop_front();
      have = true;
    }
    return have ? 1 : 0;
  }
  void Forget(uint64_t key) {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.erase(key);
  }

 private:
  struct Entry {
    bool capture = false, visual = false;
    uint32_t generation = 0;
    double playback_pts = NAN;
    std::deque<mpv_plezy_audio_block> visual_queue;
  };
  int SetEnabled(uint64_t key, bool enabled, bool visual, const Enable& enable) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!key) return MPV_PLEZY_AUDIO_UNSUPPORTED;
    auto found = entries_.find(key);
    if (found == entries_.end()) {
      if (!enabled) return 0;
      if (entries_.size() >= 16) return MPV_PLEZY_AUDIO_UNSUPPORTED;
      found = entries_.emplace(key, Entry{}).first;
    }
    auto& entry = found->second;
    bool& requested = visual ? entry.visual : entry.capture;
    if (requested == enabled) return 0;
    const bool before = entry.visual || entry.capture;
    const bool after = enabled || (visual ? entry.capture : entry.visual);
    if (before != after) {
      const int result = enable(after);
      if (result < 0) {
        if (!before) entries_.erase(found);
        return result;
      }
    }
    requested = enabled;
    entry.visual_queue.clear();
    if (!after) entries_.erase(found);
    return 0;
  }
  std::mutex mutex_;
  std::map<uint64_t, Entry> entries_;
};
inline MusicPcmFanout& SharedMusicPcmFanout() {
  static MusicPcmFanout value;
  return value;
}
}  // namespace plezy::visualization
