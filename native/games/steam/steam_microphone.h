// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
extern "C" {
#include <opus.h>
}

namespace plezy::steam {
// Capture is separately permissioned and lease-owned by each platform. This
// encoder accepts interleaved signed PCM only; it never opens a capture device.
class MicrophoneEncoder {
 public:
  using Send = std::function<bool(const uint8_t*, size_t)>;
  MicrophoneEncoder() = default;
  MicrophoneEncoder(const MicrophoneEncoder&) = delete;
  MicrophoneEncoder& operator=(const MicrophoneEncoder&) = delete;
  ~MicrophoneEncoder() { reset(); }
  bool start(unsigned rate, unsigned channels);
  bool push(const int16_t* samples, size_t count, const Send& send);
  void clear();
  void reset();

 private:
  OpusEncoder* encoder_ = nullptr;
  unsigned channels_ = 0, frameSize_ = 0;
  size_t buffered_ = 0;
  std::array<int16_t, 960> pcm_{};  // Maximum: 10 ms, 48 kHz, stereo.
  std::array<uint8_t, 1275> packet_{};
};
}  // namespace plezy::steam
