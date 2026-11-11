// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

#include "plezy_audio_tap_types.h"

namespace plezy::visualization {
// MPV speaker IDs are WAVEFORMATEXTENSIBLE bit positions (audio/chmap.h).
// Native group output advertises a stereo bus. Fold known surround/height
// speakers into that bus; leave LFE and silent padding out of the Lo/Ro mix.
inline bool DownmixMusicPcm(mpv_plezy_audio_block* block) {
  if (!block || block->frames < 1 || block->frames > MPV_PLEZY_AUDIO_TAP_FRAMES || block->channels < 1 ||
      block->channels > MPV_PLEZY_AUDIO_TAP_CHANNELS)
    return false;
  std::array<std::array<double, 2>, MPV_PLEZY_AUDIO_TAP_CHANNELS> weights{};
  std::array<bool, 65> seen{};
  constexpr double surround = 0.7071067811865475244;
  double left = 0, right = 0;
  for (uint32_t channel = 0; channel < block->channels; ++channel) {
    const auto speaker = block->speaker_ids[channel];
    if (speaker > 64 || (speaker != 64 && seen[speaker])) return false;
    seen[speaker] = true;
    auto& weight = weights[channel];
    switch (speaker) {
      case 0:
      case 29:
        weight = {1, 0};
        break;
      case 1:
      case 30:
        weight = {0, 1};
        break;
      case 2:
      case 8:
      case 11:
      case 13:
      case 16:
      case 38:
        weight = {surround, surround};
        break;
      case 4:
      case 6:
      case 9:
      case 12:
      case 15:
      case 31:
      case 33:
      case 36:
      case 39:
        weight = {surround, 0};
        break;
      case 5:
      case 7:
      case 10:
      case 14:
      case 17:
      case 32:
      case 34:
      case 37:
      case 40:
        weight = {0, surround};
        break;
      case 3:
      case 35:
      case 64:
        weight = {0, 0};
        break;
      default:
        return false;
    }
    if (block->channels == 1 && speaker == 2) weight = {1, 1};
    left += weight[0];
    right += weight[1];
  }
  const double normalization = std::max({1.0, left, right});
  std::array<float, MPV_PLEZY_AUDIO_TAP_FRAMES * 2> stereo{};
  for (uint32_t frame = 0; frame < block->frames; ++frame) {
    double l = 0, r = 0;
    for (uint32_t channel = 0; channel < block->channels; ++channel) {
      const float value = block->samples[frame * block->channels + channel];
      if (!std::isfinite(value)) return false;
      l += value * weights[channel][0];
      r += value * weights[channel][1];
    }
    stereo[frame * 2] = static_cast<float>(std::clamp(l / normalization, -1.0, 1.0));
    stereo[frame * 2 + 1] = static_cast<float>(std::clamp(r / normalization, -1.0, 1.0));
  }
  std::memcpy(block->samples, stereo.data(), block->frames * 2 * sizeof(float));
  block->channels = 2;
  std::fill(std::begin(block->speaker_ids), std::end(block->speaker_ids), uint8_t{64});
  block->speaker_ids[0] = 0;
  block->speaker_ids[1] = 1;
  return true;
}
}  // namespace plezy::visualization
