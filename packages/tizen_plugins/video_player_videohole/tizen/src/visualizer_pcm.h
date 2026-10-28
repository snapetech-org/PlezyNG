// SPDX-License-Identifier: AGPL-3.0-only
#pragma once

#include <media_packet.h>
#include <player.h>
#include <array>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include "../../../../../shared/visualization/plezy_audio_tap_types.h"

namespace video_player_videohole_tizen {
// The Samsung player remains the only decoder and audible output. This queue
// owns copies, never vendor packets or a player handle. Only the player's
// control path calls Attach/Detach; the renderer only calls Read.
class VisualizerPcm : public std::enable_shared_from_this<VisualizerPcm> {
 public:
  static bool ApiAvailable();
  void Attach(player_h player, bool protected_media);
  void Detach(player_h player);
  void Playing(bool playing);
  void Seeking(bool seeking);
  void Rate(double rate);
  void Discontinuity();
  int Read(mpv_plezy_audio_block* block);
  std::string Reason() const;

 private:
  using Clock = std::chrono::steady_clock;
  static constexpr size_t kBlocks = 16;
  struct Slot { mpv_plezy_audio_block pcm{}; Clock::time_point at; };
  mutable std::mutex mutex_;
  std::array<Slot, kBlocks> queue_{};
  size_t head_ = 0, count_ = 0;
  uint32_t generation_ = 0, dropped_ = 0;
  uintptr_t callback_token_ = 0;
  bool attached_ = false, playing_ = false, seeking_ = false, normal_rate_ = true;
  std::string reason_;
  void ResetLocked();
  void Receive(media_packet_h packet);
  static void Decoded(media_packet_h packet, void* token) noexcept;
};
}  // namespace video_player_videohole_tizen
