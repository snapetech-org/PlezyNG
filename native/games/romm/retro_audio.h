// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <mutex>
#ifndef PLEZY_RETRO_TEST_NO_AUDIO
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#endif
namespace plezy::retro {
class AudioOutput {
  std::mutex mutex_;
  std::array<int16_t, 32768> samples_{};
  size_t read_ = 0, write_ = 0;
  bool paused_ = true;
#ifndef PLEZY_RETRO_TEST_NO_AUDIO
  ma_device device_{}; bool started_ = false;
  static void Render(ma_device* device, void* output, const void*, ma_uint32 frames) {
    auto& self = *static_cast<AudioOutput*>(device->pUserData);
    auto* target = static_cast<int16_t*>(output); std::lock_guard<std::mutex> lock(self.mutex_);
    for (size_t n = 0; n < size_t(frames) * 2; ++n) {
      target[n] = self.paused_ || self.read_ == self.write_ ? 0 : self.samples_[self.read_];
      if (self.read_ != self.write_) self.read_ = (self.read_ + 1) % self.samples_.size();
    }
  }
#endif
 public:
  explicit AudioOutput(int rate) {
#ifndef PLEZY_RETRO_TEST_NO_AUDIO
    auto config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_s16; config.playback.channels = 2; config.sampleRate = rate;
    config.dataCallback = Render; config.pUserData = this;
    if (ma_device_init(nullptr, &config, &device_) != MA_SUCCESS) throw std::runtime_error("Audio device unavailable");
    started_ = true;
    if (ma_device_start(&device_) != MA_SUCCESS) { ma_device_uninit(&device_); started_ = false; throw std::runtime_error("Audio device unavailable"); }
#else
    (void)rate;
#endif
  }
  ~AudioOutput() {
#ifndef PLEZY_RETRO_TEST_NO_AUDIO
    if (started_) ma_device_uninit(&device_);
#endif
  }
  void Pause(bool paused) { std::lock_guard<std::mutex> lock(mutex_); paused_ = paused; read_ = write_; }
  void Push(const std::vector<uint8_t>& bytes) {
    std::lock_guard<std::mutex> lock(mutex_); if (paused_) return;
    for (size_t n = 0; n < bytes.size(); n += 4) {
      const auto next = (write_ + 2) % samples_.size();
      if (next == read_) read_ = (read_ + 2) % samples_.size();
      for (size_t channel = 0; channel < 2; ++channel) {
        const auto offset = n + channel * 2;
        samples_[write_] = static_cast<int16_t>(uint16_t(bytes[offset]) | (uint16_t(bytes[offset + 1]) << 8));
        write_ = (write_ + 1) % samples_.size();
      }
    }
  }
};
}
