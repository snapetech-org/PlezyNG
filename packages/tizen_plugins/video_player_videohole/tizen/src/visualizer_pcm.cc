// SPDX-License-Identifier: AGPL-3.0-only
#include "visualizer_pcm.h"
#include <media_format.h>
#include <dlfcn.h>
#include <algorithm>
#include <atomic>
#include <limits>
#include <map>

namespace video_player_videohole_tizen {
namespace {
// Optional runtime symbols: older/limited firmware keeps ordinary playback.
// SDK types, rather than hand-written ABI declarations, define every function.
struct AudioApi {
  // Retained for the process lifetime: vendor callbacks may arrive during
  // teardown and must still be able to release their packet.
  void* media_tool = dlopen("libcapi-media-tool.so.0", RTLD_NOW | RTLD_LOCAL);
  void* Symbol(const char* name) {
    auto* value = dlsym(RTLD_DEFAULT, name);
    return value ? value : media_tool ? dlsym(media_tool, name) : nullptr;
  }
#define API(name) decltype(&::name) name = reinterpret_cast<decltype(&::name)>(Symbol(#name));
  API(player_set_media_packet_audio_frame_decoded_cb)
  API(player_unset_media_packet_audio_frame_decoded_cb)
  API(media_format_create) API(media_format_unref)
  API(media_format_set_audio_mime) API(media_format_set_audio_channel)
  API(media_format_set_audio_samplerate) API(media_format_set_audio_bit)
  API(media_format_get_audio_info)
  API(media_packet_destroy) API(media_packet_get_format)
  API(media_packet_get_buffer_data_ptr) API(media_packet_get_buffer_size)
  API(media_packet_get_pts) API(media_packet_is_encoded)
#undef API
  bool Available() const {
    return player_set_media_packet_audio_frame_decoded_cb && player_unset_media_packet_audio_frame_decoded_cb &&
        media_format_create && media_format_unref && media_format_set_audio_mime && media_format_set_audio_channel &&
        media_format_set_audio_samplerate && media_format_set_audio_bit && media_format_get_audio_info &&
        media_packet_destroy && media_packet_get_format && media_packet_get_buffer_data_ptr &&
        media_packet_get_buffer_size && media_packet_get_pts && media_packet_is_encoded;
  }
  static AudioApi& Get() { static AudioApi api; return api; }
};
std::mutex callbacks_mutex;
std::map<uintptr_t, std::shared_ptr<VisualizerPcm>> callbacks;
uintptr_t next_token = 0;
std::atomic<uint32_t> next_generation{0};
uint32_t Generation() {
  uint32_t value = next_generation.load();
  while (value < UINT32_MAX) {
    if (next_generation.compare_exchange_weak(value, value + 1)) return value + 1;
  }
  return 0;  // Never reuse a generation after exhaustion.
}
void AddDropped(uint32_t& count, uint64_t frames) {
  count = static_cast<uint32_t>(std::min<uint64_t>(UINT32_MAX, count + frames));
}
struct PacketOwner {
  media_packet_h packet;
  ~PacketOwner() { if (packet) AudioApi::Get().media_packet_destroy(packet); }
};
struct FormatOwner {
  media_format_h format = nullptr;
  ~FormatOwner() { if (format) AudioApi::Get().media_format_unref(format); }
};
}  // namespace

bool VisualizerPcm::ApiAvailable() { return AudioApi::Get().Available(); }

void VisualizerPcm::ResetLocked() {
  head_ = count_ = 0;
  generation_ = Generation();
  if (!generation_) reason_ = "The PCM generation counter is exhausted. Restart the app.";
}

void VisualizerPcm::Attach(player_h player, bool protected_media) {
  auto& api = AudioApi::Get();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ResetLocked(); playing_ = seeking_ = false; normal_rate_ = true;
    reason_ = protected_media ? "Protected playback does not expose visualization PCM." :
        !api.Available() ? "This Samsung firmware lacks the decoded-audio API." : "";
    if (!reason_.empty() || !generation_) return;
  }
  FormatOwner format;
  if (api.media_format_create(&format.format) ||
      api.media_format_set_audio_mime(format.format, MEDIA_FORMAT_PCM) ||
      api.media_format_set_audio_channel(format.format, 2) ||
      api.media_format_set_audio_samplerate(format.format, 44100) ||
      api.media_format_set_audio_bit(format.format, 16)) {
    std::lock_guard<std::mutex> lock(mutex_);
    reason_ = "Samsung could not negotiate stereo signed 16-bit PCM.";
    return;
  }
  {
    std::lock_guard<std::mutex> lock(callbacks_mutex);
    if (next_token == UINTPTR_MAX) {
      std::lock_guard<std::mutex> state(mutex_);
      reason_ = "The PCM callback counter is exhausted. Restart the app.";
      return;
    }
    callback_token_ = ++next_token;
    callbacks.emplace(callback_token_, shared_from_this());
  }
  // DEFAULT is synchronized with the audible playback clock. Do not use the
  // faster-than-playback extraction option or silently change output routing.
  const int result = api.player_set_media_packet_audio_frame_decoded_cb(player, format.format,
      PLAYER_AUDIO_EXTRACT_DEFAULT, Decoded, reinterpret_cast<void*>(callback_token_));
  if (result) {
    std::lock_guard<std::mutex> lock(callbacks_mutex);
    callbacks.erase(callback_token_); callback_token_ = 0;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  attached_ = result == 0;
  if (result) reason_ = "Samsung PCM extraction is unavailable for this codec or audio output.";
}

void VisualizerPcm::Detach(player_h player) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    attached_ = playing_ = false; ResetLocked();
  }
  if (!callback_token_) return;
  // Called after stop and before unprepare. Never hold our callback mutex
  // while the vendor unregister call may itself wait for a callback.
  AudioApi::Get().player_unset_media_packet_audio_frame_decoded_cb(player);
  std::lock_guard<std::mutex> lock(callbacks_mutex);
  // Acquiring this mutex also drains a callback's packet destruction. A late
  // callback carries an integer token, never a freed MediaPlayer/queue pointer.
  callbacks.erase(callback_token_); callback_token_ = 0;
}

void VisualizerPcm::Decoded(media_packet_h packet, void* token) noexcept {
  try {
    std::lock_guard<std::mutex> lock(callbacks_mutex);
    PacketOwner owner{packet};  // Destroy BEFORE releasing the drain mutex.
    auto found = callbacks.find(reinterpret_cast<uintptr_t>(token));
    if (packet && found != callbacks.end()) found->second->Receive(packet);
  } catch (...) { /* No exception crosses Samsung's callback ABI. */ }
}

void VisualizerPcm::Receive(media_packet_h packet) {
  // A renderer read/control change can never make the audio thread wait on
  // image decoding, shader compilation, GL, filesystem I/O or a Dart call.
  std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock() || !attached_ || !playing_ || seeking_ || !normal_rate_ || !generation_) return;
  auto& api = AudioApi::Get();
  FormatOwner format;
  media_format_mimetype_e mime{};
  int channels = 0, rate = 0, bits = 0, bps = 0;
  bool encoded = true;
  uint64_t bytes = 0, pts = 0;
  void* data = nullptr;
  if (api.media_packet_is_encoded(packet, &encoded) || encoded ||
      api.media_packet_get_format(packet, &format.format) || !format.format ||
      api.media_format_get_audio_info(format.format, &mime, &channels, &rate, &bits, &bps) ||
      mime != MEDIA_FORMAT_PCM || channels != 2 || rate != 44100 || bits != 16 ||
      api.media_packet_get_buffer_size(packet, &bytes) || !bytes || bytes % 4 ||
      bytes > 44100 * 4 || api.media_packet_get_pts(packet, &pts) || pts == UINT64_MAX ||
      api.media_packet_get_buffer_data_ptr(packet, &data) || !data) {
    ResetLocked(); reason_ = "Samsung returned an unsupported decoded PCM packet.";
    return;
  }
  reason_.clear();
  const auto now = Clock::now();
  const auto* input = static_cast<const uint8_t*>(data);
  const uint64_t frames = bytes / 4;
  // Retain the most recent bounded tail of a large callback packet.
  uint64_t offset = frames > kBlocks * MPV_PLEZY_AUDIO_TAP_FRAMES ? frames - kBlocks * MPV_PLEZY_AUDIO_TAP_FRAMES : 0;
  AddDropped(dropped_, offset);
  while (offset < frames) {
    if (count_ == kBlocks) {
      AddDropped(dropped_, queue_[head_].pcm.frames);
      head_ = (head_ + 1) % kBlocks; --count_;
    }
    auto& slot = queue_[(head_ + count_) % kBlocks];
    auto& block = slot.pcm;
    block.generation = generation_;
    block.frames = static_cast<uint32_t>(std::min<uint64_t>(MPV_PLEZY_AUDIO_TAP_FRAMES, frames - offset));
    block.sample_rate = 44100; block.channels = 2;
    block.speaker_ids[0] = 0; block.speaker_ids[1] = 1;
    block.pts = pts / 1.0e9 + offset / 44100.0;
    block.seconds_per_frame = 1.0 / 44100.0;
    for (uint32_t sample = 0; sample < block.frames * 2; ++sample) {
      const size_t i = static_cast<size_t>(offset * 4 + sample * 2);
      const uint32_t raw = input[i] | (uint32_t(input[i + 1]) << 8);
      const int32_t value = raw >= 32768 ? static_cast<int32_t>(raw) - 65536 : static_cast<int32_t>(raw);
      block.samples[sample] = value / 32768.0f;
    }
    slot.at = now + std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(offset / 44100.0));
    ++count_; offset += block.frames;
  }
}

int VisualizerPcm::Read(mpv_plezy_audio_block* output) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!reason_.empty() || !normal_rate_) return MPV_PLEZY_AUDIO_UNSUPPORTED;
  if (!attached_ || !playing_ || seeking_) return 0;
  while (count_) {
    auto& slot = queue_[head_];
    if (slot.at > Clock::now()) return 0;
    head_ = (head_ + 1) % kBlocks; --count_;
    if (Clock::now() - slot.at > std::chrono::milliseconds(200)) { AddDropped(dropped_, slot.pcm.frames); continue; }
    *output = slot.pcm; output->dropped_frames = dropped_; return 1;
  }
  return 0;
}
std::string VisualizerPcm::Reason() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!normal_rate_) return "Samsung visualization currently requires normal playback speed.";
  return reason_;
}
void VisualizerPcm::Playing(bool value) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (playing_ != value) { ResetLocked(); playing_ = value; }
}
void VisualizerPcm::Seeking(bool value) {
  std::lock_guard<std::mutex> lock(mutex_); ResetLocked(); seeking_ = value;
}
void VisualizerPcm::Rate(double value) {
  std::lock_guard<std::mutex> lock(mutex_); ResetLocked(); normal_rate_ = value == 1.0;
}
void VisualizerPcm::Discontinuity() {
  std::lock_guard<std::mutex> lock(mutex_); ResetLocked();
}
}  // namespace video_player_videohole_tizen
