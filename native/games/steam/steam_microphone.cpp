// SPDX-License-Identifier: GPL-3.0-or-later
#include "steam_microphone.h"

#include <algorithm>

namespace plezy::steam {
bool MicrophoneEncoder::start(unsigned rate, unsigned channels) {
  reset();
  if ((channels != 1 && channels != 2) ||
      (rate != 8000 && rate != 12000 && rate != 16000 && rate != 24000 && rate != 48000))
    return false;
  int error = OPUS_OK;
  encoder_ = opus_encoder_create(rate, channels, OPUS_APPLICATION_VOIP, &error);
  if (!encoder_ || error != OPUS_OK) {
    reset();
    return false;
  }
  channels_ = channels;
  frameSize_ = rate / 100;
  if (opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(channels == 1 ? 32000 : 64000)) != OPUS_OK ||
      opus_encoder_ctl(encoder_, OPUS_SET_COMPLEXITY(5)) != OPUS_OK ||
      opus_encoder_ctl(encoder_, OPUS_SET_INBAND_FEC(1)) != OPUS_OK ||
      opus_encoder_ctl(encoder_, OPUS_SET_PACKET_LOSS_PERC(10)) != OPUS_OK) {
    reset();
    return false;
  }
  return true;
}
bool MicrophoneEncoder::push(const int16_t* samples, size_t count, const Send& send) {
  if (!encoder_ || !samples || !count || count > 11520 || count % channels_ || !send) return false;
  const size_t frame = size_t(frameSize_) * channels_;
  while (count) {
    const size_t copied = std::min(count, frame - buffered_);
    std::copy_n(samples, copied, pcm_.data() + buffered_);
    samples += copied;
    count -= copied;
    buffered_ += copied;
    if (buffered_ != frame) continue;
    const int bytes = opus_encode(encoder_, pcm_.data(), frameSize_, packet_.data(), packet_.size());
    buffered_ = 0;
    pcm_.fill(0);
    if (bytes < 1 || !send(packet_.data(), size_t(bytes))) {
      clear();
      return false;
    }
  }
  return true;
}
void MicrophoneEncoder::clear() {
  buffered_ = 0;
  pcm_.fill(0);
  packet_.fill(0);
  if (encoder_) opus_encoder_ctl(encoder_, OPUS_RESET_STATE);
}
void MicrophoneEncoder::reset() {
  clear();
  if (encoder_) opus_encoder_destroy(encoder_);
  encoder_ = nullptr;
  channels_ = frameSize_ = 0;
}
}  // namespace plezy::steam
